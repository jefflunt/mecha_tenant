# MechaTenant

`mecha_tenant` enforces closed-by-default multi-tenant isolation in Rails applications. It combines a YAML model registry, explicit `tenant_scope` query helpers, static Prism AST controller analysis, and behavioral IDOR route probing.

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem "mecha_tenant"
```

Or if developing locally:

```ruby
gem "mecha_tenant", path: "~/code/mecha_tenant"
```

And then execute:

```bash
bundle install
```

## Usage

### 1. Define `config/mecha_tenant.yml`

Classify every `ApplicationRecord` model as either `tenant` (with an explicit `ownership` description) or `global`:

```yaml
tenant_root: "User"

debug_colorization:
  tenant: :light_purple
  global: :light_cyan
  skipped: :yellow
  enforced: :green
  violation: :light_red
  unmapped: :dark_grey

models:
  - model: "User"
    classification: "tenant"
    ownership: "self (id == current_user.id)"

  - model: "EmailMessage"
    classification: "tenant"
    ownership: "email_account.user_id"

  - model: "SvcOption"
    classification: "global"
    notes: "Global service configuration options"
```

### 2. Configure the Initializer

Create `config/initializers/mecha_tenant.rb` to define tenant scopes for each tenant-classified model and include the controller concern:

```ruby
# config/initializers/mecha_tenant.rb
require "mecha_tenant"

MechaTenant.configure do |config|
  config.config_path = Rails.root.join("config/mecha_tenant.yml")
  config.tenant_method = :current_user
  config.base_model_class = "ApplicationRecord"
  config.controller_paths = [Rails.root.join("app/controllers")]

  config.define_scope "User" do |user|
    User.where(id: user.id)
  end

  config.define_scope "EmailMessage" do |user|
    EmailMessage.where(email_account_id: user.email_accounts.select(:id))
  end
end

ActiveSupport.on_load(:action_controller_base) do
  include MechaTenant::Controller
end
```

### 3. Scoping Queries in Controllers

In controllers, query tenant models via `tenant_scope(Model)` or through associations on `current_user`. Direct naked model references (e.g. `EmailMessage.find(params[:id])`) are flagged by the static AST auditor unless explicitly exempted:

```ruby
class EmailsController < ApplicationController
  def show
    @message = tenant_scope(EmailMessage).find(params[:id])
  end
end
```

For admin or public endpoints that intentionally operate without tenant scoping, declare `skip_tenant_enforcement!` with a mandatory `reason:`:

```ruby
class Admin::DashboardsController < ApplicationController
  skip_tenant_enforcement! only: [:show], reason: "Admin global dashboard metrics across all tenants"

  def show
    @total_users = User.count
  end
end
```

#### Outside requests: jobs, console and rake

There is no request to read the tenant from, so set it explicitly. `MechaTenant.tenant_scope` resolves against it and raises `MechaTenant::TenantMissingError` when none is set:

```ruby
MechaTenant.with_tenant(user) do
  MechaTenant.tenant_scope(EmailMessage).where(unread: true).count
end
```

To carry the tenant into background jobs, include `MechaTenant::JobContext`. The tenant active at enqueue time is serialized with the job (GlobalID for Active Record models) and restored around `perform`; a job enqueued without one runs without one:

```ruby
class ApplicationJob < ActiveJob::Base
  include MechaTenant::JobContext
end

class ApplicationController < ActionController::Base
  around_action { |_, action| MechaTenant.with_tenant(current_user, &action) }
end
```

Only wrap actions where `current_user` is always present; `with_tenant(nil)` raises.

### 4. Rake Tasks & Auditing

`mecha_tenant` automatically registers Rake tasks via its Railtie:

```bash
# Print all models and controller actions with their tenancy status
bin/rails mecha_tenant

# Statically verify model registry parity and controller AST scoping
bin/rails mecha_tenant:verify:static

# Run behavioral cross-tenant scope and IDOR route matrix tests
bin/rails mecha_tenant:verify:behavioral

# Run both static and behavioral verification
bin/rails mecha_tenant:verify
```

### 5. Dynamic Parallel Matrix Testing in Consuming Apps

`mecha_tenant` ships with [`MechaTenant::MatrixTest`](lib/mecha_tenant/matrix_test.rb), which dynamically generates an individual Minitest test method for every registered tenant model (scope isolation) and every enforced parameterized `:id` route (cross-tenant IDOR protection) so they run in parallel across all workers.

In your consuming Rails application's `test/test_helper.rb`:

```ruby
MechaTenant.configuration.configure_test_matrix(
  setup: -> {
    # Create @victim, @attacker, and @victim_records hash mapping model names to victim instances
  },
  context: -> {
    {
      victim: @victim,
      attacker: @attacker,
      victim_records: @victim_records,
      ui_auth: ->(session) { login_as(session, @attacker); {} },
      api_auth: ->(_session) { { "Authorization" => "Bearer #{@attacker_jwt}" } }
    }
  }
)

require "mecha_tenant/matrix_test" unless ENV["MECHA_MATRIX_STANDALONE"] == "1"
```

## Running Tests

To run the gem's standalone test suite:

```bash
bundle exec rake test
```

## License

Copyright 2026 Jeff Lunt. Released under the [MIT License](LICENSE).
