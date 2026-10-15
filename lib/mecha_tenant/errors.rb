# frozen_string_literal: true

module MechaTenant
  module Errors
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class UnregisteredModelError < Error; end
    class GlobalModelScopeError < Error; end
    class TenantMissingError < Error; end
    class UnscopedQueryError < Error; end
  end

  Error = Errors::Error
  ConfigurationError = Errors::ConfigurationError
  UnregisteredModelError = Errors::UnregisteredModelError
  GlobalModelScopeError = Errors::GlobalModelScopeError
  TenantMissingError = Errors::TenantMissingError
  UnscopedQueryError = Errors::UnscopedQueryError
end
