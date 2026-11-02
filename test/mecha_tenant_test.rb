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

  def test_mecha_tenant_rake_task_filters_by_status_and_validates_inputs
    require "rake"
    Rake::Task.clear
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/mecha_tenant.rake", __dir__)

    enforced_audit = MechaTenant::Auditor::Static::ActionAudit.new(
      verb: "GET",
      path: "/emails/:id",
      controller: "EmailsController",
      action: "show",
      status: :enforced,
      scopes_used: ["tenant_scope(EmailMessage)"],
      skip_reason: nil,
      route_roles: nil
    )

    skipped_audit = MechaTenant::Auditor::Static::ActionAudit.new(
      verb: "GET",
      path: "/admin/dashboard",
      controller: "Admin::DashboardsController",
      action: "show",
      status: :skipped,
      scopes_used: [],
      skip_reason: "Admin metrics",
      route_roles: nil
    )

    clean_result = MechaTenant::Auditor::Static::Result.new(
      mapped_models: [
        { model: "EmailMessage", classification: :tenant, ownership: "email_account.user_id" },
        { model: "SvcOption", classification: :global, ownership: nil }
      ],
      unmapped_models: [],
      dead_models: [],
      missing_scopes: [],
      dead_skip_rules: [],
      violations: [],
      action_audits: [enforced_audit, skipped_audit]
    )

    auditor_singleton = MechaTenant::Auditor::Static.singleton_class
    auditor_singleton.alias_method :_orig_new_for_issue2, :new

    begin
      stub_auditor = Object.new
      stub_auditor.define_singleton_method(:audit) { clean_result }
      auditor_singleton.define_method(:new) { |*_args| stub_auditor }

      # 1. Filter by [violation,skipped] when 0 violations and 1 skipped exist
      out, _err = capture_io do
        Rake::Task["mecha_tenant"].reenable
        Rake::Task["mecha_tenant"].invoke("violation", "skipped")
      end
      assert_includes out, "Admin::DashboardsController#show"
      assert_includes out, "SKIP: Admin metrics"
      refute_includes out, "EmailsController#show"
      refute_includes out, "EmailMessage"
      assert_includes out, "NO VIOLATIONS FOUND"
      refute_includes out, "NO SKIPPED FOUND"

      # 2. Filter by [VIOLATION,SKIPPED] when both are empty (case-insensitive)
      no_skipped_result = MechaTenant::Auditor::Static::Result.new(
        mapped_models: [{ model: "EmailMessage", classification: :tenant, ownership: "email_account.user_id" }],
        unmapped_models: [],
        dead_models: [],
        missing_scopes: [],
        dead_skip_rules: [],
        violations: [],
        action_audits: [enforced_audit]
      )
      stub_auditor.define_singleton_method(:audit) { no_skipped_result }

      out, _err = capture_io do
        Rake::Task["mecha_tenant"].reenable
        Rake::Task["mecha_tenant"].invoke("VIOLATION,SKIPPED")
      end
      assert_includes out, "NO VIOLATIONS FOUND\nNO SKIPPED FOUND"

      # 3. Duplicate status returns non-zero exit status
      dup_err = nil
      out, _err = capture_io do
        Rake::Task["mecha_tenant"].reenable
        dup_err = assert_raises(SystemExit) do
          Rake::Task["mecha_tenant"].invoke("violation", "VIOLATION")
        end
      end
      assert_equal 1, dup_err.status
      assert_includes out, "Duplicate status filter"

      # 4. Invalid status returns non-zero exit status
      inv_err = nil
      out, _err = capture_io do
        Rake::Task["mecha_tenant"].reenable
        inv_err = assert_raises(SystemExit) do
          Rake::Task["mecha_tenant"].invoke("unknown_status")
        end
      end
      assert_equal 1, inv_err.status
      assert_includes out, "Invalid status filter"

      # 5. Any violation still triggers non-zero exit status even when filtering [skipped]
      violation_audit = MechaTenant::Auditor::Static::ActionAudit.new(
        verb: "GET",
        path: "/orders/:id",
        controller: "OrdersController",
        action: "show",
        status: :violation,
        scopes_used: [],
        skip_reason: nil,
        route_roles: nil
      )
      violation_result = MechaTenant::Auditor::Static::Result.new(
        mapped_models: [{ model: "EmailMessage", classification: :tenant, ownership: "email_account.user_id" }],
        unmapped_models: [],
        dead_models: [],
        missing_scopes: [],
        dead_skip_rules: [],
        violations: [],
        action_audits: [skipped_audit, violation_audit]
      )
      stub_auditor.define_singleton_method(:audit) { violation_result }

      viol_err = nil
      out, _err = capture_io do
        Rake::Task["mecha_tenant"].reenable
        viol_err = assert_raises(SystemExit) do
          Rake::Task["mecha_tenant"].invoke("skipped")
        end
      end
      assert_equal 1, viol_err.status
      assert_includes out, "Admin::DashboardsController#show"
      refute_includes out, "OrdersController#show"
    ensure
      auditor_singleton.alias_method :new, :_orig_new_for_issue2
      auditor_singleton.remove_method :_orig_new_for_issue2
    end
  end
end
