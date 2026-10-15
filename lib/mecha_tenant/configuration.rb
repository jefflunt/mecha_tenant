# frozen_string_literal: true

module MechaTenant
  class Configuration
    attr_accessor :config_path,
                  :tenant_method,
                  :base_model_class,
                  :controller_paths,
                  :route_classifier,
                  :enforce_runtime,
                  :debug_colorization,
                  :test_setup,
                  :test_teardown,
                  :test_matrix_context

    attr_reader :scopes

    def initialize
      @config_path = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("config/mecha_tenant.yml")
      else
        "config/mecha_tenant.yml"
      end
      @tenant_method = :current_user
      @base_model_class = "ApplicationRecord"
      @controller_paths = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        [Rails.root.join("app/controllers")]
      else
        ["app/controllers"]
      end
      @route_classifier = nil
      @enforce_runtime = true
      @scopes = {}
      @debug_colorization = {
        tenant: :light_purple,
        global: :light_cyan,
        skipped: :yellow,
        enforced: :green,
        violation: :light_red,
        unmapped: :dark_grey
      }
      @test_setup = nil
      @test_teardown = nil
      @test_matrix_context = nil
    end

    def define_scope(model_name, callable = nil, &block)
      resolver = callable || block
      raise ConfigurationError, "Scope for #{model_name} must be a callable Proc or block" unless resolver.respond_to?(:call)

      @scopes[model_name.to_s] = resolver
    end

    def configure_test_matrix(context: nil, setup: nil, teardown: nil)
      @test_matrix_context = context if context
      @test_setup = setup if setup
      @test_teardown = teardown if teardown
    end
  end
end
