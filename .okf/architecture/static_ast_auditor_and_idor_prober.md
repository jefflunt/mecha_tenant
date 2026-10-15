---
type: Architecture
title: Static AST Auditor & Behavioral IDOR Prober
description: Prism AST static analysis of controllers, dynamic behavioral cross-tenant route probing, parallel Minitest matrix generation, and Railtie Rake tasks.
tags: [architecture, ast, prism, idor, testing, rake]
generated: { by: antigravity/gemini-4-argon, at: 2026-10-15T23:18:00Z }
sources:
  - id: static_auditor
    resource: ../lib/mecha_tenant/auditor/static.rb
    title: MechaTenant::Auditor::Static
  - id: prober
    resource: ../lib/mecha_tenant/auditor/prober.rb
    title: MechaTenant::Auditor::Prober
  - id: matrix_test
    resource: ../lib/mecha_tenant/matrix_test.rb
    title: MechaTenant::MatrixTest
  - id: rake_tasks
    resource: ../lib/tasks/mecha_tenant.rake
    title: MechaTenant Rake Tasks
---

# Static AST Auditor (`MechaTenant::Auditor::Static`)

`MechaTenant::Auditor::Static#audit` performs five static verification checks across the host Rails application:

1. **Model Registry Parity**:
   Eager-loads the Rails application and inspects all non-abstract `ApplicationRecord` descendants defined under `app/models`:
   - `unmapped_models`: Application models missing from `config/mecha_tenant.yml`.
   - `dead_models`: Models listed in `config/mecha_tenant.yml` that no longer exist in the application.
2. **Scope Resolver Parity (`#check_scope_parity`)**:
   - Every `:tenant` model must have a corresponding `define_scope` block.
   - No `:global` model may have a `define_scope` block.
3. **Dead Skip Rule Detection (`#check_dead_skip_rules`)**:
   Flags `skip_tenant_enforcement!` rules whose `:only` or `:except` action names do not exist on the controller.
4. **Prism AST Controller Analysis (`#analyze_controller_ast`)**:
   Parses every `*_controller.rb` file with `Prism.parse` and walks each enforced method's AST:
   - Flags `:naked_model_reference` whenever a known model constant (`ConstantReadNode` or `ConstantPathNode`) is referenced outside `tenant_scope(Model)` arguments, while permitting nested non-model constants such as `EmailMessage::CATEGORIES`.
   - Flags `:global_model_in_tenant_scope` and `:unregistered_model_in_tenant_scope` if `tenant_scope(...)` is called with a global or unknown model constant.
   - Records valid scoping usages (`tenant_scope(Model)` and `current_user.<association>`) across actions, called private helpers, and `before_action` callbacks.
5. **Route Action Audit Table (`#build_route_action_audits`)**:
   Correlates Rails routes (`ActionDispatch::Routing::RouteWrapper`) with controller AST metadata to classify each route as `:enforced`, `:skipped`, or `:violation`.

# Behavioral Cross-Tenant Prober (`MechaTenant::Auditor::Prober`)

`MechaTenant::Auditor::Prober` executes live runtime checks against two distinct tenant fixtures (`victim` and `attacker`) and a map of `victim_records`:

1. **Model Scope Isolation (`#probe_single_model_scope`)**:
   For a given `:tenant` model, resolves both `victim_scope` and `attacker_scope`:
   - Verifies `victim_scope.where(id: record.id).exists?` is `true`.
   - Verifies `attacker_scope.where(id: record.id).exists?` is `false` (preventing cross-tenant data leaks).
2. **Parameterized Route IDOR Probing (`#probe_single_idor_route`)**:
   For each `:enforced` route containing `:id`:
   - Infers the target model from `tenant_scope(Model)`, `current_user.<association>`, or the singularized controller name.
   - Substitutes `:id` with the victim record's ID (and other route params with `"1"`), authenticates the integration session as `attacker` (using `api_auth` for `/api/*` routes or `ui_auth` otherwise), and dispatches the HTTP request.
   - Asserts the response status is `404` when `scopes_used` is non-empty (or in `[302, 303, 400, 404, 422]` when the action makes no model queries) and rescues `ActiveRecord::RecordNotFound` / `ActionController::RoutingError` as `404`.
   - Reloads the victim record after the request and verifies it was neither deleted nor mutated (`attributes.except("updated_at")`).

# Parallel Matrix Testing (`MechaTenant::MatrixTest`)

[`MechaTenant::MatrixTest`](../lib/mecha_tenant/matrix_test.rb) subclasses `ActionDispatch::IntegrationTest` and calls `define_tenant_matrix_tests!` at load time to dynamically define:
- Two static AST audit tests.
- One test method per registered `:tenant` model (`behavioral tenant scope isolation for model <Model>`).
- One test method per enforced `:id` route (`behavioral IDOR route isolation for <VERB> <PATH>`).

Because each model and route is defined as its own Minitest test method, Rails parallel testing distributes the entire IDOR matrix across worker processes.

# Railtie & Rake Tasks (`lib/tasks/mecha_tenant.rake`)

Loaded automatically via [`MechaTenant::Railtie`](../lib/mecha_tenant/railtie.rb):
- `bin/rails mecha_tenant`: Prints a colorized report of the Model Tenancy Registry and Controller Action Tenancy Enforcement table.
- `bin/rails mecha_tenant:verify:static`: Runs the static AST & registry audit, exiting non-zero on any unmapped models, dead models, missing scopes, dead skip rules, or AST violations.
- `bin/rails mecha_tenant:verify:behavioral`: Executes `MechaTenant::MatrixTest` via `bin/rails test` with `MECHA_MATRIX_STANDALONE=1`.
- `bin/rails mecha_tenant:verify`: Runs both `verify:static` and `verify:behavioral`.
