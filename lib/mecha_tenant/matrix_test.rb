# frozen_string_literal: true

unless defined?(ActionDispatch::IntegrationTest)
  app_test_helper = File.join(Dir.pwd, "test/test_helper.rb")
  require app_test_helper if File.exist?(app_test_helper)
end
require "mecha_tenant"

module MechaTenant
  class MatrixTest < ActionDispatch::IntegrationTest
    setup do
      if MechaTenant.configuration.test_setup
        instance_exec(&MechaTenant.configuration.test_setup)
      end
    end

    teardown do
      if MechaTenant.configuration.test_teardown
        instance_exec(&MechaTenant.configuration.test_teardown)
      end
    end

    test "static model registry and controller AST audit passes with zero violations" do
      result = MechaTenant::Auditor::Static.new.audit

      assert_empty result.unmapped_models, "Found unmapped models missing from config/mecha_tenant.yml: #{result.unmapped_models.inspect}"
      assert_empty result.dead_models, "Found dead models in config/mecha_tenant.yml: #{result.dead_models.inspect}"
      assert_empty result.missing_scopes, "Found missing/invalid scopes: #{result.missing_scopes.inspect}"
      assert_empty result.dead_skip_rules, "Found dead skip_tenant_enforcement! rules: #{result.dead_skip_rules.inspect}"
      assert_empty result.violations, "Found controller AST tenant violations:\n" +
        result.violations.map { |v| "  - #{v.file}:#{v.line} [#{v.controller}##{v.method_name}] #{v.message}" }.join("\n")
      assert result.success?
    end

    test "static AST auditor deterministically catches naked model queries and invalid tenant_scope calls" do
      auditor = MechaTenant::Auditor::Static.new
      tenant_model = MechaTenant.registry.tenant_models.keys.first
      global_model = MechaTenant.registry.global_models.keys.first
      return unless tenant_model && global_model

      bad_source = <<~RUBY
        class VulnerableController < ApplicationController
          def show
            @msg = #{tenant_model}.find(params[:id])
            @opt = tenant_scope(#{global_model}).first
            @ok_const = #{tenant_model}::SOME_CONSTANT
            @ok_scoped = tenant_scope(#{tenant_model}).find(params[:id])
          end
        end
      RUBY

      dummy_class = Class.new(ApplicationController) do
        def self.name
          "VulnerableController"
        end

        def show; end
      end

      res = auditor.audit_source(bad_source, controller_class: dummy_class, file_path: "app/controllers/vulnerable_controller.rb")
      violations = res[:violations]

      assert_equal 2, violations.size
      assert_equal :naked_model_reference, violations[0].kind
      assert_equal tenant_model, violations[0].model
      assert_equal 3, violations[0].line

      assert_equal :global_model_in_tenant_scope, violations[1].kind
      assert_equal global_model, violations[1].model
      assert_equal 4, violations[1].line
    end

    def self.define_tenant_matrix_tests!
      return if @tenant_matrix_tests_defined
      @tenant_matrix_tests_defined = true

      # 1. One test per registered tenant model for scope isolation
      MechaTenant.registry.tenant_models.each_key do |model_name|
        test "behavioral tenant scope isolation for model #{model_name}" do
          ctx_proc = MechaTenant.configuration.test_matrix_context
          assert_not_nil ctx_proc, "MechaTenant.configuration.test_matrix_context must be configured for behavioral matrix testing"

          ctx = instance_exec(&ctx_proc)
          prober = MechaTenant::Auditor::Prober.new(self)
          result = prober.probe_single_model_scope(
            model_name,
            victim: ctx[:victim],
            attacker: ctx[:attacker],
            victim_records: ctx[:victim_records]
          )

          assert result.success?, "Model scope isolation failed for #{model_name}:\n" +
            result.scope_failures.map { |f| "  - [#{f.model}]: #{f.message}" }.join("\n")
        end
      end

      # 2. One test per enforced parameterized (:id) route for cross-tenant IDOR protection
      enforced_id_audits = MechaTenant::Auditor::Prober.collect_enforced_id_audits
      enforced_id_audits.each do |audit|
        test "behavioral IDOR route isolation for #{audit.verb} #{audit.path} (#{audit.controller}##{audit.action})" do
          ctx_proc = MechaTenant.configuration.test_matrix_context
          assert_not_nil ctx_proc, "MechaTenant.configuration.test_matrix_context must be configured for behavioral matrix testing"

          ctx = instance_exec(&ctx_proc)
          prober = MechaTenant::Auditor::Prober.new(self)
          result = prober.probe_single_idor_route(
            audit,
            victim_records: ctx[:victim_records],
            ui_auth: ctx[:ui_auth],
            api_auth: ctx[:api_auth]
          )

          assert result.success?, "Cross-tenant IDOR route prober failed for #{audit.verb} #{audit.path}:\n" +
            result.route_failures.map { |f| "  - #{f.route} [#{f.target_model}]: #{f.message}" }.join("\n")
        end
      end
    end

    define_tenant_matrix_tests!
  end
end
