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

  def test_static_ast_auditor_catches_unregistered_model_in_tenant_scope_and_dead_skip_rules
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("User") { |u| u }
      config.define_scope("EmailMessage") { |u| u }
    end

    auditor = MechaTenant::Auditor::Static.new

    source = <<~RUBY
      class BrokenController < ApplicationController
        def show
          @item = tenant_scope(UnknownModel).find(params[:id])
        end
      end
    RUBY

    dummy_class = Class.new(DummyControllerBase) do
      def self.name
        "BrokenController"
      end

      skip_tenant_enforcement! only: [:nonexistent_action], reason: "Stale skip rule"

      def show; end
    end

    res = auditor.audit_source(source, controller_class: dummy_class, file_path: "app/controllers/broken_controller.rb")

    assert_equal 1, res[:violations].size
    assert_equal :unregistered_model_in_tenant_scope, res[:violations].first.kind
    assert_equal "UnknownModel", res[:violations].first.model

    assert_equal 1, res[:dead_skip_rules].size
    assert_includes res[:dead_skip_rules].first[:message], "skips non-existent action ':nonexistent_action'"
  end

  def test_static_auditor_propagates_helper_method_violations_and_checks_scope_parity
    # Configure with missing scope on EmailMessage and prohibited scope on global SvcOption
    MechaTenant.configure do |config|
      config.config_path = @sample_config
      config.define_scope("User") { |u| u }
      config.define_scope("SvcOption") { |u| u }
    end

    auditor = MechaTenant::Auditor::Static.new
    parity_errors = auditor.send(:check_scope_parity)

    assert_equal 2, parity_errors.size
    assert parity_errors.any? { |e| e.include?("Tenant model 'EmailMessage' is missing a `define_scope`") }
    assert parity_errors.any? { |e| e.include?("Global model 'SvcOption' must not have a `define_scope`") }

    source = <<~RUBY
      class OrdersController < ApplicationController
        def show
          load_message
        end

        private

        def load_message
          @msg = EmailMessage.find(params[:id])
        end
      end
    RUBY

    dummy_class = Class.new(DummyControllerBase) do
      def self.name
        "OrdersController"
      end

      def show; end
    end

    res = auditor.audit_source(source, controller_class: dummy_class, file_path: "app/controllers/orders_controller.rb")
    meta = res[:controllers]["OrdersController"]
    relevant = auditor.send(:resolve_action_methods, meta, "show")

    assert_includes relevant, "show"
    assert_includes relevant, "load_message"
    assert_equal 1, res[:violations].size
    assert_equal "load_message", res[:violations].first.method_name
  end

  def test_behavioral_prober_verifies_model_scope_isolation_and_catches_leaks
    fake_scope_class = Struct.new(:ids) do
      define_method(:where) do |id:|
        fake_scope_class.new(ids.include?(id) ? [id] : [])
      end

      def exists?
        !ids.empty?
      end
    end

    fake_record_class = Struct.new(:id, :title, :updated_at, :deleted, keyword_init: true) do
      def attributes
        { "id" => id, "title" => title, "updated_at" => updated_at }
      end
    end

    # 1. Properly isolated scope passes
    isolated_scopes = {
      "User" => ->(u) { fake_scope_class.new([u]) },
      "EmailMessage" => ->(u) { fake_scope_class.new(u == :victim ? [101] : [202]) }
    }
    registry = MechaTenant::Registry.new(@sample_config, isolated_scopes)
    prober = MechaTenant::Auditor::Prober.new(nil, registry: registry)

    victim_records = {
      "User" => fake_record_class.new(id: :victim),
      "EmailMessage" => fake_record_class.new(id: 101)
    }

    res = prober.probe_model_scopes(victim: :victim, attacker: :attacker, victim_records: victim_records)
    assert res.success?
    assert_equal 2, res.scoped_models_count

    # 2. Leaky scope where attacker sees victim record fails
    leaky_scopes = {
      "User" => ->(u) { fake_scope_class.new([u]) },
      "EmailMessage" => ->(_u) { fake_scope_class.new([101, 202]) }
    }
    leaky_registry = MechaTenant::Registry.new(@sample_config, leaky_scopes)
    leaky_prober = MechaTenant::Auditor::Prober.new(nil, registry: leaky_registry)

    leak_res = leaky_prober.probe_model_scopes(victim: :victim, attacker: :attacker, victim_records: victim_records)
    refute leak_res.success?
    assert_equal 1, leak_res.scope_failures.size
    assert_includes leak_res.scope_failures.first.message, "CROSS-TENANT LEAK"
  end

  def test_behavioral_prober_detects_idor_status_failures_and_cross_tenant_record_mutation
    record_store = {}

    record_class = Class.new do
      define_singleton_method(:name) { "EmailMessage" }
      define_singleton_method(:find_by) { |id:| record_store[id] }

      attr_accessor :id, :body

      def initialize(id:, body:)
        @id = id
        @body = body
      end

      def attributes
        { "id" => @id, "body" => @body, "updated_at" => Time.now }
      end
    end

    victim_msg = record_class.new(id: "42", body: "secret")
    record_store["42"] = victim_msg

    response_struct = Struct.new(:status)
    fake_session_class = Class.new do
      attr_reader :response

      def initialize(&on_request)
        @on_request = on_request
      end

      %i[get post patch put delete head].each do |m|
        define_method(m) do |path, headers: {}|
          status = @on_request.call(m, path, headers)
          @response = response_struct.new(status)
        end
      end
    end

    audit = MechaTenant::Auditor::Static::ActionAudit.new(
      verb: "PATCH",
      path: "/emails/:id",
      controller: "EmailsController",
      action: "update",
      status: :enforced,
      scopes_used: ["tenant_scope(EmailMessage)"],
      skip_reason: nil,
      route_roles: nil
    )

    registry = MechaTenant::Registry.new(@sample_config)

    # 1. Returning 404 without modifying victim record succeeds
    safe_session = fake_session_class.new { |_verb, _path, _headers| 404 }
    prober = MechaTenant::Auditor::Prober.new(safe_session, registry: registry)
    safe_res = prober.probe_single_idor_route(
      audit,
      victim_records: { "EmailMessage" => victim_msg },
      ui_auth: ->(_s) { {} }
    )
    assert safe_res.success?

    # 2. Returning 200 and mutating victim record triggers both status and mutation failures
    vulnerable_session = fake_session_class.new do |_verb, _path, _headers|
      record_store["42"] = record_class.new(id: "42", body: "hacked")
      200
    end
    vuln_prober = MechaTenant::Auditor::Prober.new(vulnerable_session, registry: registry)
    vuln_res = vuln_prober.probe_single_idor_route(
      audit,
      victim_records: { "EmailMessage" => victim_msg },
      ui_auth: ->(_s) { {} }
    )
    refute vuln_res.success?
    assert_equal 2, vuln_res.route_failures.size
    assert vuln_res.route_failures.any? { |f| f.message.include?("Expected HTTP 404") }
    assert vuln_res.route_failures.any? { |f| f.message.include?("CROSS-TENANT MUTATION") }
  end
end
