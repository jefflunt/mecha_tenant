---
name: Bug Report
about: Report a tenancy audit discrepancy, false positive, false negative, or IDOR probe issue
title: "[Bug]: "
labels: ["bug"]
assignees: ""
---

### Describe the Bug
A clear and concise description of the unexpected behavior.

### Type of Issue
- [ ] Prism AST false positive (flagged a valid scoped query as unscoped)
- [ ] Prism AST false negative (missed an unscoped query or raw SQL bypass)
- [ ] IDOR probe failure or false positive
- [ ] Model registry classification issue (`tenant` vs `global`)
- [ ] Non-HTTP execution error (background jobs, console, rake)
- [ ] CLI / reporting formatting issue

### Minimal Reproduction
1. Rails version:
2. Ruby version:
3. Minimal Model & Controller snippet:

```ruby
# app/models/... or app/controllers/...
```

4. Minimal configuration (`config/mecha_tenant.yml`):

```yaml
# Relevant config snippet
```

### Expected Behavior
What should the audit, probe, or runtime have reported instead?
