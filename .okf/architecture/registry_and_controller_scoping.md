---
type: Architecture
title: Model Registry & Controller Scoping
description: Closed-by-default YAML model classification registry, scope resolver configuration, and controller concern enforcement.
tags: [architecture, registry, controller, configuration, scoping]
generated: { by: antigravity/gemini-4-argon, at: 2026-10-15T23:18:00Z }
sources:
  - id: configuration
    resource: ../lib/mecha_tenant/configuration.rb
    title: MechaTenant::Configuration
  - id: registry
    resource: ../lib/mecha_tenant/registry.rb
    title: MechaTenant::Registry
  - id: controller
    resource: ../lib/mecha_tenant/controller.rb
    title: MechaTenant::Controller
  - id: errors
    resource: ../lib/mecha_tenant/errors.rb
    title: MechaTenant::Errors
---

# Configuration (`MechaTenant::Configuration`)

`MechaTenant.configure` initializes and reloads the singleton `MechaTenant.configuration` and `MechaTenant.registry`:

- `config_path`: Path to `config/mecha_tenant.yml` (defaults to `Rails.root.join("config/mecha_tenant.yml")`) or an in-memory Hash for testing.
- `tenant_method`: Controller method returning the active tenant object (defaults to `:current_user`).
- `base_model_class`: Root model class whose concrete descendants must be registered (defaults to `"ApplicationRecord"`).
- `controller_paths`: Array of controller directories scanned by the static AST auditor (defaults to `[Rails.root.join("app/controllers")]`).
- `define_scope(model_name, callable = nil, &block)`: Registers a proc/lambda receiving the current tenant and returning an `ActiveRecord::Relation` scoped to that tenant.
- `configure_test_matrix(context:, setup:, teardown:)`: Registers lifecycle hooks and test fixture context for [Static AST Auditor & Behavioral IDOR Prober](static_ast_auditor_and_idor_prober.md).

# Model Registry (`MechaTenant::Registry`)

`MechaTenant::Registry` parses and validates the YAML model registry (`config/mecha_tenant.yml`).

## Schema & Validation Rules

1. Top-level `models` key must be an `Array` of model entry hashes.
2. Optional `tenant_root` specifies the root tenant model name (defaults to `"User"`).
3. Each entry requires:
   - `model`: Non-empty model class name string; duplicates raise `MechaTenant::ConfigurationError`.
   - `classification`: Must be `"tenant"` or `"global"`.
   - `ownership`: Mandatory non-empty string when `classification == "tenant"` documenting the foreign-key or association path to `tenant_root` (e.g., `"self"` or `"email_account.user_id"`).
   - `notes`: Optional descriptive string (commonly used for `"global"` models).

## Runtime Scope Resolution (`#scope_for`)

When `registry.scope_for(model_or_name, tenant)` is invoked:

| Condition | Behavior / Exception |
|-----------|----------------------|
| Model not in registry | Raises `MechaTenant::UnregisteredModelError` |
| Model classified as `:global` | Raises `MechaTenant::GlobalModelScopeError` |
| `tenant` argument is `nil` | Raises `MechaTenant::TenantMissingError` |
| No `define_scope` registered for model | Raises `MechaTenant::ConfigurationError` |
| Valid tenant model + tenant present | Calls `@scopes[model_name].call(tenant)` |

# Controller Concern (`MechaTenant::Controller`)

Included into `ActionController::Base` (or base controllers), `MechaTenant::Controller` exposes:

- **`tenant_scope(model_class)`** (also registered as a Rails view `helper_method`):
  Fetches the current tenant via `send(MechaTenant.configuration.tenant_method)`, resolves the scoped relation via `MechaTenant.registry.scope_for(model_class, tenant)`, and appends the model name to `@_mecha_tenant_scoped_models` (`#mecha_tenant_scoped_models`).
- **`skip_tenant_enforcement!(only: nil, except: nil, reason:)`**:
  Class-level macro allowing specific actions (or an entire controller) to opt out of static and behavioral tenant enforcement. A non-empty `reason:` string is strictly required (`ArgumentError` is raised otherwise). Rules are inherited across controller subclasses and evaluated in reverse declaration order via `tenant_enforcement_reason_for(action_name)`.
