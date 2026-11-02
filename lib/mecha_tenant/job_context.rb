# frozen_string_literal: true

require "active_support/concern"

module MechaTenant
  module JobContext
    extend ActiveSupport::Concern

    TENANT_PAYLOAD_KEY = "mecha_tenant"

    included do
      attr_accessor :mecha_tenant

      if respond_to?(:before_enqueue)
        before_enqueue do |job|
          job.mecha_tenant = MechaTenant.current_tenant if job.mecha_tenant.nil?
        end
      end

      if respond_to?(:around_perform)
        around_perform do |job, block|
          if job.mecha_tenant.nil?
            MechaTenant.clear_current_tenant!
            block.call
          else
            MechaTenant.with_tenant(job.mecha_tenant, &block)
          end
        end
      end
    end

    def serialize
      data = defined?(super) ? super : {}
      serialized_tenant = if mecha_tenant.nil?
        nil
      elsif defined?(ActiveJob::Arguments)
        ActiveJob::Arguments.serialize([mecha_tenant])
      else
        [mecha_tenant]
      end
      data.merge(TENANT_PAYLOAD_KEY => serialized_tenant)
    end

    def deserialize(job_data)
      super(job_data) if defined?(super)
      raw = job_data[TENANT_PAYLOAD_KEY]
      self.mecha_tenant = if raw.nil?
        nil
      elsif defined?(ActiveJob::Arguments)
        ActiveJob::Arguments.deserialize(raw).first
      else
        Array(raw).first
      end
    end
  end
end
