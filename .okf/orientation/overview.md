---
type: Reference
title: Orientation & Overview
description: Mission, dependency stack, directory layout, and development commands for the mecha_tenant Ruby gem.
tags: [orientation, ruby, rails, multitenancy, security]
generated: { by: antigravity/gemini-4-argon, at: 2026-10-15T23:18:00Z }
sources:
  - id: gemspec
    resource: ../mecha_tenant.gemspec
    title: MechaTenant Gem Specification
  - id: readme
    resource: ../README.md
    title: MechaTenant README
---

# Mission

`mecha_tenant` enforces closed-by-default multi-tenant isolation in Ruby on Rails applications. Rather than relying solely on implicit thread-global default scopes, `mecha_tenant` combines four defense-in-depth mechanisms:

1. **YAML Model Classification Registry**: Every application model must be explicitly classified in `config/mecha_tenant.yml` as either `tenant` (with a required `ownership` path description) or `global`.
2. **Explicit Controller Scoping (`tenant_scope`)**: Controllers resolve tenant-isolated `ActiveRecord::Relation` scopes via `tenant_scope(Model)` or associations on the configured tenant root (`current_user`), with explicit `skip_tenant_enforcement!(reason: ...)` declarations required for public or admin actions.
3. **Static Prism AST Controller Auditing**: Parses controller source files with `Prism` to detect direct naked model queries, invalid `tenant_scope` calls on global or unregistered models, unmapped/dead models, missing scope resolvers, and stale skip rules.
4. **Behavioral Cross-Tenant IDOR Probing & Parallel Matrix Tests**: Dynamically exercises every tenant model's scope resolver and every enforced parameterized (`:id`) route in `ActionDispatch::IntegrationTest` to verify that an attacker cannot read, mutate, or delete a victim's records.

# Technology Stack

| Component | Requirement / Gem | Role |
|-----------|-------------------|------|
| Ruby | `>= 3.2.0` | Runtime language |
| ActiveSupport | `>= 7.0` | Concern mixins, class descendants discovery, string inflections |
| ActionPack | `>= 7.0` (dev/host) | Controller routing introspection and `ActionDispatch::IntegrationTest` probing |
| Prism | `prism` | Ruby AST parsing for static controller query auditing |
| TinyColor | `tiny_color` | Terminal ANSI colorization for `bin/rails mecha_tenant` output |
| Minitest & Rake | `minitest`, `rake` | Unit test runner and task automation |

# Repository Structure

```text
mecha_tenant/
├── Gemfile
├── Gemfile.lock
├── LICENSE
├── README.md
├── Rakefile
├── mecha_tenant.gemspec
├── lib/
│   ├── mecha_tenant.rb
│   ├── mecha_tenant/
│   │   ├── auditor/
│   │   │   ├── prober.rb         # Behavioral scope & cross-tenant IDOR route prober
│   │   │   └── static.rb         # Prism AST controller & registry parity auditor
│   │   ├── configuration.rb      # Gem configuration & scope DSL
│   │   ├── controller.rb         # Controller concern (tenant_scope & skip_tenant_enforcement!)
│   │   ├── errors.rb             # Custom exception hierarchy
│   │   ├── matrix_test.rb        # Dynamic Minitest integration test generator
│   │   ├── railtie.rb            # Rails Railtie loading Rake tasks
│   │   ├── registry.rb           # YAML registry loader, validator, and scope dispatcher
│   │   └── version.rb            # Gem version constant
│   └── tasks/
│       └── mecha_tenant.rake     # CLI inspection & verification Rake tasks
└── test/
    ├── mecha_tenant_test.rb      # Standalone unit tests
    └── test_helper.rb            # Minitest bootstrap
```

# Development Commands

```bash
# Run the standalone unit test suite
bundle exec rake test

# Build the gem package
gem build mecha_tenant.gemspec
```
