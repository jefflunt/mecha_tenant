# frozen_string_literal: true

require "active_support/concern"

module MechaTenant
  module Controller
    extend ActiveSupport::Concern

    included do
      if respond_to?(:helper_method)
        helper_method :tenant_scope
      end
    end

    class_methods do
      def skip_tenant_enforcement!(only: nil, except: nil, reason:)
        if reason.nil? || !reason.is_a?(String) || reason.strip.empty?
          raise ArgumentError, "skip_tenant_enforcement! requires a non-empty 'reason:' string"
        end

        @mecha_tenant_skip_rules ||= []
        rule = {
          only: only ? Array(only).map(&:to_s) : nil,
          except: except ? Array(except).map(&:to_s) : nil,
          reason: reason.strip
        }.freeze
        @mecha_tenant_skip_rules << rule
      end

      def own_tenant_enforcement_rules
        @mecha_tenant_skip_rules || []
      end

      def tenant_enforcement_rules
        inherited = if superclass.respond_to?(:tenant_enforcement_rules)
          superclass.tenant_enforcement_rules
        else
          []
        end
        inherited + own_tenant_enforcement_rules
      end

      def reset_tenant_enforcement_rules!
        @mecha_tenant_skip_rules = []
      end

      def tenant_enforcement_skipped_for?(action_name)
        !tenant_enforcement_reason_for(action_name).nil?
      end

      def tenant_enforcement_reason_for(action_name)
        act = action_name.to_s
        tenant_enforcement_rules.reverse_each do |rule|
          if rule[:only]
            return rule[:reason] if rule[:only].include?(act)
          elsif rule[:except]
            return rule[:reason] unless rule[:except].include?(act)
          else
            return rule[:reason]
          end
        end
        nil
      end
    end

    def tenant_scope(model_class)
      tenant_method = MechaTenant.configuration.tenant_method
      tenant = respond_to?(tenant_method, true) ? send(tenant_method) : nil
      scope = MechaTenant.registry.scope_for(model_class, tenant)
      @_mecha_tenant_scoped_models ||= []
      @_mecha_tenant_scoped_models << model_class.to_s
      scope
    end

    def mecha_tenant_scoped_models
      @_mecha_tenant_scoped_models || []
    end
  end
end
