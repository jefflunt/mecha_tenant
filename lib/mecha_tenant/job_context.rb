# frozen_string_literal: true

require "active_job"

module MechaTenant
  # Carries the tenant that was active at enqueue time into the job, and
  # restores it around perform. A job enqueued without a tenant runs without
  # one, so MechaTenant.tenant_scope raises instead of leaking across tenants.
  module JobContext
    extend ActiveSupport::Concern

    included do
      attr_accessor :mecha_tenant

      before_enqueue { |job| job.mecha_tenant ||= MechaTenant.current_tenant }

      around_perform do |job, block|
        job.mecha_tenant.nil? ? block.call : MechaTenant.with_tenant(job.mecha_tenant, &block)
      end
    end

    def serialize
      super.merge("mecha_tenant" => mecha_tenant.nil? ? nil : ActiveJob::Arguments.serialize([mecha_tenant]))
    end

    def deserialize(job_data)
      super
      data = job_data["mecha_tenant"]
      self.mecha_tenant = data.nil? ? nil : ActiveJob::Arguments.deserialize(data).first
    end
  end
end
