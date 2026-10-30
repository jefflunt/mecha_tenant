# frozen_string_literal: true

require_relative "mecha_tenant/version"
require_relative "mecha_tenant/errors"
require_relative "mecha_tenant/configuration"
require_relative "mecha_tenant/registry"
require_relative "mecha_tenant/controller"
require_relative "mecha_tenant/auditor/static"
require_relative "mecha_tenant/auditor/prober"
require_relative "mecha_tenant/railtie" if defined?(Rails::Railtie)
require "active_support/isolated_execution_state"

module MechaTenant
  autoload :JobContext, File.expand_path("mecha_tenant/job_context", __dir__)

  CURRENT_TENANT_KEY = :mecha_tenant_current_tenant

  class << self
    # Sets the tenant for code that runs outside a request (jobs, console,
    # rake tasks) and restores the previous one afterwards, so blocks nest.
    def with_tenant(tenant)
      raise TenantMissingError, "with_tenant requires a non-nil tenant" if tenant.nil?

      previous = ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY]
      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = tenant
      begin
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = previous
      end
    end

    def current_tenant
      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY]
    end

    # Same as the controller helper, but resolved against the tenant set by
    # with_tenant. Raises TenantMissingError when no tenant is active.
    def tenant_scope(model_class)
      registry.scope_for(model_class, current_tenant)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      reload!
    end

    def reset_configuration!
      @configuration = Configuration.new
      @registry = nil
    end

    def registry
      @registry ||= Registry.new(configuration.config_path, configuration.scopes)
    end

    def reload!
      @registry = Registry.new(configuration.config_path, configuration.scopes)
    end
  end
end
