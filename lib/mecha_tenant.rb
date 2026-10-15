# frozen_string_literal: true

require_relative "mecha_tenant/version"
require_relative "mecha_tenant/errors"
require_relative "mecha_tenant/configuration"
require_relative "mecha_tenant/registry"
require_relative "mecha_tenant/controller"
require_relative "mecha_tenant/auditor/static"
require_relative "mecha_tenant/auditor/prober"
require_relative "mecha_tenant/railtie" if defined?(Rails::Railtie)

module MechaTenant
  class << self
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
