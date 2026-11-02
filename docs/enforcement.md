# MechaTenant Architecture & Enforcement Lifecycle Guide

This document details how `mecha_tenant` enforces multi-tenant isolation, the exact boundary between static audit-time checks and runtime behavior, and the guarantees and edge cases of its automated verification suite.

---

## 1. Step-by-Step Enforcement Pipeline

`mecha_tenant` operates across four coordinated layers:

### Step 1: YAML Registry Loading (`MechaTenant::Registry`)
- Loads `config/mecha_tenant.yml` and validates every model entry.
- Every `ApplicationRecord` descendant must be classified as either:
  - `tenant`: Requires a non-empty `ownership` description and a corresponding `config.define_scope("ModelName") { |tenant| ... }` block in the initializer.
  - `global`: System-wide models shared across tenants. Must **not** have a `define_scope` declaration.
- Duplicate entries, missing `ownership` declarations, or invalid classifications immediately raise `MechaTenant::ConfigurationError`.

### Step 2: Explicit Controller Scoping (`MechaTenant::Controller`)
- Controllers include `MechaTenant::Controller`, which provides the `tenant_scope(Model)` helper (also exposed as a view `helper_method`) and the `skip_tenant_enforcement!` class macro.
- When `tenant_scope(Model)` is called at runtime:
  1. It resolves the active tenant by invoking `MechaTenant.configuration.tenant_method` (default `:current_user`) on the controller.
  2. It delegates to `MechaTenant.registry.scope_for(Model, tenant)`.
  3. It records the scoped model name on the controller instance (`mecha_tenant_scoped_models`).

### Step 3: Static Prism AST Controller Analysis (`MechaTenant::Auditor::Static`)
- Discovers all concrete `ApplicationRecord` models under `app/models` and verifies 100% parity against `config/mecha_tenant.yml` and `define_scope` blocks (`unmapped_models`, `dead_models`, `missing_scopes`).
- Parses every controller file under `config.controller_paths` using the Ruby **Prism** AST parser:
  - Partitioning: Controller actions and private helper methods are partitioned into `enforced` vs. `skipped` based on `skip_tenant_enforcement!` declarations (while verifying that `only:` / `except:` rules do not reference non-existent actions).
  - AST Walking: Walks each method's AST looking for `Prism::ConstantReadNode` / `Prism::ConstantPathNode` references to registered models or `ApplicationRecord`.
  - Any direct constant reference to a model outside `tenant_scope(Model)` (except nested non-model constants like `EmailMessage::CATEGORIES`) is flagged as a `:naked_model_reference` violation.
  - Passing a `:global` model or an unregistered constant to `tenant_scope(...)` is flagged as `:global_model_in_tenant_scope` or `:unregistered_model_in_tenant_scope`.
  - Helper & Callback Propagation: Scopes and violations in private helper methods or `before_action` callbacks invoked by an enforced route action are attributed to that route action.

### Step 4: Behavioral IDOR & Scope Probing (`MechaTenant::Auditor::Prober` & `MechaTenant::MatrixTest`)
- **Model Scope Probing (`probe_model_scopes`)**: For every registered `tenant` model, evaluates `scope_for(Model, victim)` and `scope_for(Model, attacker)` against a persisted victim record:
  - Verifies the victim's scope **includes** the victim's own record.
  - Verifies the attacker's scope **excludes** the victim's record (preventing cross-tenant data leaks in `define_scope` SQL/ActiveRecord relations).
- **Route IDOR Probing (`probe_idor_routes`)**: For every enforced route containing `:id`, dispatches an integration request authenticated as `@attacker` targeting `@victim`'s record ID:
  - Actions using `tenant_scope` or tenant root associations must return HTTP `404`.
  - Actions without model queries must return one of HTTP `302, 303, 400, 404, 422`.
  - Snapshots the victim record before and after the request to guarantee the record was neither deleted nor mutated across tenant boundaries.

---

## 2. Static Audit Time vs. Runtime Behavior

A critical architectural distinction for adopting teams is understanding what happens at **static lint/audit time (CI gate)** versus **runtime request execution**:

| Scenario | Audit / CI Time (`rails mecha_tenant:verify`) | Runtime Request Execution |
| :--- | :--- | :--- |
| **Naked query in controller** (e.g., `Order.find(params[:id])`) | **Fails audit (`VIOLATION`)**. Static Prism AST auditor flags `:naked_model_reference` and behavioral IDOR prober catches cross-tenant access. Blocks CI/release. | **Not intercepted by `mecha_tenant`**. `mecha_tenant` intentionally avoids monkey-patching `ActiveRecord::Base` query methods at runtime; the naked query executes normally unless blocked prior to release by CI. |
| **`tenant_scope(Order).find(params[:id])` for another tenant's record** | **Passes audit (`ENFORCED`)**. Behavioral prober confirms HTTP 404 and zero record mutation. | `tenant_scope(Order)` filters by the active tenant's scope; `.find` raises `ActiveRecord::RecordNotFound`, which Rails rescues to render **HTTP 404 Not Found**. |
| **`tenant_scope(Order)` when `current_user` is `nil`** | Caught during behavioral route probing if an unauthenticated route attempts `tenant_scope`. | Raises `MechaTenant::TenantMissingError` immediately (fail-closed). |
| **`tenant_scope(GlobalModel)` on a `:global` model** | **Fails audit (`VIOLATION`)** with `:global_model_in_tenant_scope`. | Raises `MechaTenant::GlobalModelScopeError`. |
| **`tenant_scope(UnregisteredModel)`** | **Fails audit (`VIOLATION`)** with `:unregistered_model_in_tenant_scope`. | Raises `MechaTenant::UnregisteredModelError`. |
| **Unmapped model added to `app/models`** | **Fails audit** (`unmapped_models` check). | Raises `MechaTenant::UnregisteredModelError` if passed to `tenant_scope`. |

### Why `mecha_tenant` Does Not Monkey-Patch ActiveRecord at Runtime
 Relying on global `default_scope` or `ActiveRecord` query interception often leads to subtle bugs in associations, background jobs, authentication lookups, or uniqueness validations. Instead, `mecha_tenant` keeps runtime behavior explicit (`tenant_scope(Model)`) and enforces compliance deterministically at CI/test time via AST inspection and behavioral IDOR probing.

---

## 3. Automated Assurances & Known Edge Cases

### What the Automated Suite Guarantees
1. **100% Model Registry Parity**: Every concrete `ApplicationRecord` subclass in `app/models` is registered in `config/mecha_tenant.yml`, stale models are rejected, and every `tenant` model has a callable `define_scope`.
2. **Direct Constant Reference Detection**: Any direct reference to a registered model constant or `ApplicationRecord` inside an enforced controller action, private helper method, or `before_action` filter is caught statically.
3. **Skip Rule Hygiene**: Every `skip_tenant_enforcement!` declaration must provide a non-empty `reason:` string and reference valid controller actions.
4. **Live Scope & IDOR Isolation**: Every `define_scope` block is tested with real records across two distinct tenants (`victim` and `attacker`), and every `:id` route is probed to confirm `404` responses and record immutability.

### Known Edge Cases & Limitations to Keep in Mind
1. **Service Objects, Concerns, and Models Outside `controller_paths`**:
   - The Prism AST auditor scans files matching `*_controller.rb` under `config.controller_paths`. If a controller delegates a query to a service object in `app/services` without passing a scoped relation (e.g., `OrderExporter.call(params[:id])` where `OrderExporter` calls `Order.find`), the static controller AST scan will not see the `Order` constant inside `app/services`.
   - **Mitigation**: Pass the already-scoped relation from the controller (`OrderExporter.call(tenant_scope(Order))`), and rely on the behavioral IDOR prober (`mecha_tenant:verify:behavioral`), which exercises the full request stack including service objects and raises a failure if the endpoint returns a non-404 status or mutates/leaks the victim's record.
2. **Raw SQL and Metaprogramming**:
   - Dynamic constant resolution (`"Order".constantize.find(...)`, `Object.const_get(:Order)`) or raw SQL strings (`ActiveRecord::Base.connection.execute("SELECT * FROM orders")`) bypass constant-node AST matching for `Order` (though `ActiveRecord::Base` or `ApplicationRecord` references are flagged if `base_model_class` is referenced).
   - **Mitigation**: Behavioral IDOR route probing catches any cross-tenant record mutation/deletion or 2xx response on `:id` routes regardless of whether the underlying query used metaprogramming or raw SQL.
3. **Collection Routes Without `:id`**:
   - Behavioral IDOR route probing targets parameterized `:id` routes (`audit.path.include?(":id")`). Collection endpoints (e.g., `GET /orders`) are protected by the static AST auditor (which requires `tenant_scope(Order)` or `current_user.orders`) and by model scope probing (`probe_model_scopes`), which verifies that `tenant_scope(Order)` for `@attacker` never returns `@victim`'s records.
4. **Chained Unscoped Associations**:
   - Calling `current_user.orders` is recognized by the static auditor as scoped via the tenant root association. However, if a custom model method on an associated record executes an unscoped query internally, static controller AST analysis will not inspect the model method body. Keep model methods scoped to their receiver's associations.
