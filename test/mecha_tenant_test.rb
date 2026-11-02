# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"

class MechaTenantTest < Minitest::Test
  DummyControllerBase = Class.new do
    def self.helper_method(*); end
    def self.action_methods
      instance_methods(false).map(&:to_s)
    end
    include MechaTenant::Controller
  end

  def setup
    MechaTenant.reset_configuration!
    @sample_config = {
      "tenant_root" => "User",
      "debug_colorization" => {
        "tenant" => ":light_purple",
        "global" => ":light_cyan"
      },
      "models" => [
        {
          "model" => "User",
          "classification" => "tenant",
          "ownership" => "self"
        },
        {
          "model" => "EmailMessage",
          "classification" => "tenant",
          "ownership" => "email_account.user_id"
        },
        {
          "model" => "SvcOption",
          "classification" => "global",
          "notes" => "System-wide configuration"
        }
      ]
    }
  end

  def teardown
    MechaTenant.reset_configuration!
  end

  def test_version_is_defined
    refute_nil MechaTenant::VERSION
    assert_equal MechaTenant::VERSION, MechaTenant::Version
  end

  def test_registry_loads_and_classifies_models
    scopes = {
      "User" => ->(u) { [:user_scope, u] },
      "EmailMessage" => ->(u) { [:email_scope, u] }
    }
    registry = MechaTenant::Registry.new(@sample_config, scopes)

    assert_equal "User", registry.tenant_root
    assert registry.registered?("User")
    assert registry.tenant_model?("EmailMessage")
    assert registry.global_model?("SvcOption")
    refute registry.registered?("UnknownModel")

    assert_equal [:email_scope, :tenant_1], registry.scope_for("EmailMessage", :tenant_1)

    assert_raises(MechaTenant::TenantMissingError) do
      registry.scope_for("EmailMessage", nil)
    end

    assert_raises(MechaTenant::GlobalModelScopeError) do
      registry.scope_for("SvcOption", :tenant_1)
    end

    assert_raises(MechaTenant::UnregisteredModelError) do
      registry.scope_for("UnknownModel", :tenant_1)
    end
  end

  def test_registry_validates_schema
    assert_raises(MechaTenant::ConfigurationError) do
      MechaTenant::Registry.new({ "other" => [] })
    end

    assert_raises(MechaTenant::ConfigurationError) do
      MechaTenant::Registry.new({
        "models" => [
          { "model" => "User", "classification" => "tenant", "ownership" => "self" },
          { "model" => "User", "classification" => "tenant", "ownership" => "self" }
        ]
      })
    end

    assert_raises(MechaTenant::ConfigurationError) do
      MechaTenant::Registry.new({
        "models" => [
          { "model" => "User", "classification" => "tenant" }
        ]
      })
    end
  end

  def test_controller_concern_skip_rules_and_tenant_scope
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("EmailMessage") { |u| "scoped_messages_for_#{u}" }
    end

    ctrl_class = Class.new(DummyControllerBase) do
      attr_accessor :current_user
      def index; end
      def public_endpoint; end
    end

    assert_raises(ArgumentError) do
      ctrl_class.skip_tenant_enforcement!(reason: "")
    end

    ctrl_class.skip_tenant_enforcement!(only: [:public_endpoint], reason: "Webhook endpoint")
    assert ctrl_class.tenant_enforcement_skipped_for?(:public_endpoint)
    assert_equal "Webhook endpoint", ctrl_class.tenant_enforcement_reason_for(:public_endpoint)
    refute ctrl_class.tenant_enforcement_skipped_for?(:index)

    instance = ctrl_class.new
    instance.current_user = "user_42"
    assert_equal "scoped_messages_for_user_42", instance.tenant_scope("EmailMessage")
    assert_includes instance.mecha_tenant_scoped_models, "EmailMessage"
  end

  def test_static_ast_auditor_catches_naked_model_references_and_invalid_tenant_scope_calls
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("User") { |u| u }
      config.define_scope("EmailMessage") { |u| u }
    end

    auditor = MechaTenant::Auditor::Static.new

    bad_source = <<~RUBY
      class VulnerableController < ApplicationController
        def show
          @msg = EmailMessage.find(params[:id])
          @opt = tenant_scope(SvcOption).first
          @ok_const = EmailMessage::CATEGORIES
          @ok_scoped = tenant_scope(EmailMessage).find(params[:id])
        end
      end
    RUBY

    dummy_class = Class.new(DummyControllerBase) do
      def self.name
        "VulnerableController"
      end

      def show; end
    end

    res = auditor.audit_source(bad_source, controller_class: dummy_class, file_path: "app/controllers/vulnerable_controller.rb")
    violations = res[:violations]

    assert_equal 2, violations.size
    assert_equal :naked_model_reference, violations[0].kind
    assert_equal "EmailMessage", violations[0].model
    assert_equal 3, violations[0].line

    assert_equal :global_model_in_tenant_scope, violations[1].kind
    assert_equal "SvcOption", violations[1].model
    assert_equal 4, violations[1].line
  end

  def test_with_tenant_system_scope_and_console_helpers
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("EmailMessage") { |u| "scoped_messages_for_#{u}" }
    end

    assert_raises(MechaTenant::TenantMissingError) { MechaTenant.tenant_scope("EmailMessage") }
    assert_raises(MechaTenant::TenantMissingError) { MechaTenant.with_tenant(nil) {} }
    assert_raises(ArgumentError) { MechaTenant.with_tenant("user_a") }

    MechaTenant.with_tenant("user_a") do |tenant|
      assert_equal "user_a", tenant
      assert_equal "user_a", MechaTenant.current_tenant
      assert_equal "scoped_messages_for_user_a", MechaTenant.tenant_scope("EmailMessage")

      MechaTenant.with_tenant("user_b") do
        assert_equal "scoped_messages_for_user_b", MechaTenant.tenant_scope("EmailMessage")
      end
      assert_equal "user_a", MechaTenant.current_tenant

      assert_raises(RuntimeError) do
        MechaTenant.with_tenant("user_b") { raise "error in nested block" }
      end
      assert_equal "user_a", MechaTenant.current_tenant
    end

    assert_nil MechaTenant.current_tenant

    # Explicit system_scope escape hatch
    assert_raises(ArgumentError) { MechaTenant.system_scope(reason: "") {} }
    assert_raises(ArgumentError) { MechaTenant.system_scope(reason: "Valid reason") }

    MechaTenant.system_scope(reason: "Quarterly tax aggregation") do
      assert MechaTenant.system_scoped?
      assert_equal "Quarterly tax aggregation", MechaTenant.system_scope_reason
      assert_equal "EmailMessage", MechaTenant.tenant_scope("EmailMessage")
      assert_raises(MechaTenant::GlobalModelScopeError) { MechaTenant.tenant_scope("SvcOption") }
      assert_raises(MechaTenant::UnregisteredModelError) { MechaTenant.tenant_scope("Unknown") }
    end
    refute MechaTenant.system_scoped?

    # Console helpers
    assert_raises(MechaTenant::TenantMissingError) { MechaTenant.set_current_tenant(nil) }
    MechaTenant.set_current_tenant("console_user")
    assert_equal "scoped_messages_for_console_user", MechaTenant.tenant_scope("EmailMessage")
    MechaTenant.clear_current_tenant!
    assert_nil MechaTenant.current_tenant
  end

  def test_job_context_serializes_and_restores_enqueue_tenant
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("EmailMessage") { |u| "scoped_messages_for_#{u}" }
    end

    dummy_job_base = Class.new do
      class << self
        def before_enqueue(&block)
          @before_enqueue_callbacks ||= []
          @before_enqueue_callbacks << block
        end

        def around_perform(&block)
          @around_perform_callbacks ||= []
          @around_perform_callbacks << block
        end

        def before_enqueue_callbacks
          @before_enqueue_callbacks || []
        end

        def around_perform_callbacks
          @around_perform_callbacks || []
        end
      end

      def serialize
        {}
      end

      def deserialize(_job_data); end

      def enqueue_and_serialize
        self.class.before_enqueue_callbacks.each { |cb| cb.call(self) }
        serialize
      end

      def execute_from_payload(payload, &perform_block)
        deserialize(payload)
        cbs = self.class.around_perform_callbacks
        if cbs.any?
          cbs.first.call(self, perform_block)
        else
          perform_block.call
        end
      end
    end

    job_class = Class.new(dummy_job_base) do
      include MechaTenant::JobContext
    end

    payload_a = MechaTenant.with_tenant("user_a") { job_class.new.enqueue_and_serialize }
    assert_equal ["user_a"], payload_a["mecha_tenant"]

    # Executing while user_b is active still scopes to user_a and restores user_b afterwards
    observed = nil
    MechaTenant.with_tenant("user_b") do
      job_class.new.execute_from_payload(payload_a) do
        observed = MechaTenant.tenant_scope("EmailMessage")
      end
      assert_equal "user_b", MechaTenant.current_tenant
    end
    assert_equal "scoped_messages_for_user_a", observed

    # Job enqueued without a tenant executes without a tenant (closed by default)
    payload_nil = job_class.new.enqueue_and_serialize
    assert_nil payload_nil["mecha_tenant"]

    MechaTenant.with_tenant("user_b") do
      assert_raises(MechaTenant::TenantMissingError) do
        job_class.new.execute_from_payload(payload_nil) do
          MechaTenant.tenant_scope("EmailMessage")
        end
      end
    end
  end
end
