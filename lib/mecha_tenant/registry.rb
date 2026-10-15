# frozen_string_literal: true

require "yaml"

module MechaTenant
  class Registry
    VALID_CLASSIFICATIONS = %w[tenant global].freeze

    attr_reader :models, :tenant_root, :colorization

    def initialize(config_path_or_hash = nil, scopes = {})
      @scopes = scopes.transform_keys(&:to_s)
      @models = {}
      @tenant_root = "User"
      @colorization = {}

      if config_path_or_hash.is_a?(Hash)
        load_from_hash(config_path_or_hash)
      elsif config_path_or_hash
        load_from_file(config_path_or_hash)
      end
    end

    def load_from_file(path)
      raise ConfigurationError, "Tenancy configuration file missing: #{path}" unless File.exist?(path)

      data = begin
        YAML.load_file(path)
      rescue => e
        raise ConfigurationError, "Invalid YAML syntax in #{path}: #{e.message}"
      end

      load_from_hash(data)
    end

    def load_from_hash(data)
      unless data.is_a?(Hash) && data.key?("models") && data["models"].is_a?(Array)
        raise ConfigurationError, "Tenancy config must have a top-level 'models' list"
      end

      @tenant_root = data["tenant_root"].to_s.strip if data["tenant_root"].present?
      @models = {}

      data["models"].each_with_index do |entry, idx|
        validate_model_entry!(entry, idx)
        model_name = entry["model"].strip
        if @models.key?(model_name)
          raise ConfigurationError, "Duplicate model entry '#{model_name}' in tenancy configuration"
        end

        @models[model_name] = {
          model: model_name,
          classification: entry["classification"].to_sym,
          ownership: entry["ownership"]&.to_s&.strip,
          notes: entry["notes"]&.to_s&.strip
        }.freeze
      end

      if data["debug_colorization"].is_a?(Hash)
        @colorization = data["debug_colorization"].transform_keys(&:to_sym).transform_values do |v|
          v.to_s.sub(/^:/, "").to_sym
        end
      end

      @models.freeze
      self
    end

    def registered?(model_or_name)
      @models.key?(normalize_model_name(model_or_name))
    end

    def model_entry(model_or_name)
      @models[normalize_model_name(model_or_name)]
    end

    def tenant_model?(model_or_name)
      entry = model_entry(model_or_name)
      entry ? entry[:classification] == :tenant : false
    end

    def global_model?(model_or_name)
      entry = model_entry(model_or_name)
      entry ? entry[:classification] == :global : false
    end

    def tenant_models
      @models.select { |_k, v| v[:classification] == :tenant }
    end

    def global_models
      @models.select { |_k, v| v[:classification] == :global }
    end

    def scope_defined?(model_or_name)
      @scopes.key?(normalize_model_name(model_or_name))
    end

    def scope_for(model_or_name, tenant)
      name = normalize_model_name(model_or_name)
      entry = @models[name]

      if entry.nil?
        raise UnregisteredModelError, "Model '#{name}' is not registered in MechaTenant configuration"
      end

      if entry[:classification] == :global
        raise GlobalModelScopeError, "Model '#{name}' is classified as :global and cannot be queried via tenant_scope"
      end

      raise TenantMissingError, "Cannot resolve tenant_scope(#{name}) when current tenant is nil" if tenant.nil?

      resolver = @scopes[name]
      if resolver.nil?
        raise ConfigurationError, "No scope resolver defined for tenant model '#{name}'"
      end

      resolver.call(tenant)
    end

    private

    def normalize_model_name(model_or_name)
      case model_or_name
      when Class, Module
        model_or_name.name.to_s
      else
        model_or_name.to_s
      end
    end

    def validate_model_entry!(entry, idx)
      unless entry.is_a?(Hash)
        raise ConfigurationError, "Tenancy model entry at index #{idx} must be a Hash"
      end

      model_name = entry["model"]
      unless model_name.is_a?(String) && !model_name.strip.empty?
        raise ConfigurationError, "Tenancy model entry at index #{idx} must have a non-empty string for 'model'"
      end

      classification = entry["classification"]
      unless classification.is_a?(String) && VALID_CLASSIFICATIONS.include?(classification)
        raise ConfigurationError,
              "Tenancy model '#{model_name}' at index #{idx} must have classification in #{VALID_CLASSIFICATIONS.inspect}, got #{classification.inspect}"
      end

      if classification == "tenant"
        ownership = entry["ownership"]
        unless ownership.is_a?(String) && !ownership.strip.empty?
          raise ConfigurationError,
                "Tenancy model '#{model_name}' (classification: tenant) must explicitly declare 'ownership'"
        end
      end
    end
  end
end
