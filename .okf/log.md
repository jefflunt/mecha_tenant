# Knowledge Base Update Log

## 2026-10-15
* **Creation**: Initialized the Open Knowledge Format (`.okf`) knowledge base adhering to OKF v0.2.
* **Update**: Documented project mission, dependency stack, repository layout, and development workflow in [Orientation & Overview](orientation/overview.md).
* **Update**: Documented `MechaTenant::Configuration`, `MechaTenant::Registry` YAML schema and runtime scope resolution, and `MechaTenant::Controller` enforcement concern in [Model Registry & Controller Scoping](architecture/registry_and_controller_scoping.md).
* **Update**: Documented `MechaTenant::Auditor::Static` Prism AST analysis, `MechaTenant::Auditor::Prober` behavioral cross-tenant scope and IDOR route probing, `MechaTenant::MatrixTest` parallel test generation, and Railtie Rake tasks in [Static AST Auditor & Behavioral IDOR Prober](architecture/static_ast_auditor_and_idor_prober.md).
* **Update**: Added `.gitignore` for Ruby gem build artifacts (`*.gem`, `/pkg/`), Bundler state, coverage/documentation output, temporary/log files, local environment files, and editor/OS metadata.
* **Update**: Bumped gem version to `0.1.2` for gem build and release.
