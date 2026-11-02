# frozen_string_literal: true

require "active_support/isolated_execution_state"

module MechaTenant
  module Context
    CURRENT_TENANT_KEY = :mecha_tenant_current_tenant
    SYSTEM_SCOPE_REASON_KEY = :mecha_tenant_system_scope_reason

    def with_tenant(tenant)
      raise TenantMissingError, "with_tenant requires a non-nil tenant" if tenant.nil?
      raise ArgumentError, "with_tenant requires a block" unless block_given?

      previous_tenant = ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY]
      previous_system = ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY]

      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = tenant
      ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY] = nil
      begin
        yield(tenant)
      ensure
        ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = previous_tenant
        ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY] = previous_system
      end
    end

    def system_scope(reason:)
      if reason.nil? || !reason.is_a?(String) || reason.strip.empty?
        raise ArgumentError, "system_scope requires a non-empty 'reason:' string"
      end
      raise ArgumentError, "system_scope requires a block" unless block_given?

      previous_system = ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY]
      ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY] = reason.strip
      begin
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY] = previous_system
      end
    end

    def current_tenant
      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY]
    end

    def set_current_tenant(tenant)
      raise TenantMissingError, "set_current_tenant requires a non-nil tenant (use clear_current_tenant! to reset)" if tenant.nil?

      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = tenant
    end

    def clear_current_tenant!
      ActiveSupport::IsolatedExecutionState[CURRENT_TENANT_KEY] = nil
    end

    def system_scoped?
      !system_scope_reason.nil?
    end

    def system_scope_reason
      ActiveSupport::IsolatedExecutionState[SYSTEM_SCOPE_REASON_KEY]
    end

    def tenant_scope(model_class)
      if system_scoped?
        validate_tenant_scoping_target!(model_class)
        return resolve_unscoped_relation(model_class)
      end

      registry.scope_for(model_class, current_tenant)
    end

    private

    def validate_tenant_scoping_target!(model_or_name)
      name = model_or_name.is_a?(Class) || model_or_name.is_a?(Module) ? model_or_name.name.to_s : model_or_name.to_s
      entry = registry.model_entry(name)

      if entry.nil?
        raise UnregisteredModelError, "Model '#{name}' is not registered in MechaTenant configuration"
      end

      if entry[:classification] == :global
        raise GlobalModelScopeError, "Model '#{name}' is classified as :global and cannot be queried via tenant_scope"
      end
    end

    def resolve_unscoped_relation(model_or_name)
      klass = case model_or_name
      when Class, Module
        model_or_name
      else
        model_or_name.to_s.safe_constantize
      end

      if klass && klass.respond_to?(:all)
        klass.all
      else
        klass || model_or_name
      end
    end
  end
end
