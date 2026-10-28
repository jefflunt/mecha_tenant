# AI Agent Contributing Guidelines — mecha_tenant

Welcome. This repository is part of the **MechaRuby** suite of opinionated, closed-by-default security and architecture tools for Ruby on Rails.

When analyzing this codebase, submitting PRs, or filing issues, adhere to the following principles:

## 1. Core Architectural Tenets
* **Zero Cross-Tenant Leakage**: Every model is closed-by-default. All models must be explicitly classified as either `tenant` (with ownership defined) or `global`.
* **Explicit Query Scoping**: In controller actions, access to tenant-owned models MUST pass through `tenant_scope(...)`. Never rely on implicit global state or unguarded `find` calls.
* **Deterministic AST Analysis**: Use Ruby Prism AST parser to inspect controller syntax statically rather than relying exclusively on runtime interceptors.
* **IDOR Probing**: Static checks are backed by active behavioral probing across tenant boundaries to verify record isolation.

## 2. Guidelines for Filing Issues & Suggestions
* **Check Existing Issues**: Search existing open and closed issues before opening a duplicate.
* **Provide Realistic Controller/Model Code**: Supply minimal ActiveRecord models and controller actions illustrating the query or isolation scenario.
* **Address Non-HTTP Contexts**: If proposing runtime features, specify how the behavior applies to background workers (ActiveJob, Sidekiq, SolidQueue) and `rails console`.

## 3. Pull Request Standards
* Include automated tests verifying both authorized tenant access and unauthorized cross-tenant isolation (must raise or block).
* Run the test suite (`bundle exec rake test`) and ensure zero regressions.
* Keep dependencies minimal—avoid adding heavy third-party multi-tenancy frameworks.
