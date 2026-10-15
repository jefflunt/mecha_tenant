# frozen_string_literal: true

require_relative "lib/mecha_tenant/version"

Gem::Specification.new do |s|
  s.name        = "mecha_tenant"
  s.version     = MechaTenant::VERSION
  s.summary     = "Closed-by-default multi-tenant model registry, AST controller auditing, and IDOR probing for Rails"
  s.description = "MechaTenant enforces strict tenant isolation in Rails applications via a YAML model classification registry, explicit tenant_scope helpers, Prism AST static analysis of controllers, and behavioral IDOR route probing."
  s.authors     = ["Jeff Lunt"]
  s.email       = ["jefflunt@gmail.com"]
  s.homepage    = "https://github.com/jefflunt/mecha_tenant"
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.2.0"

  s.require_paths = ["lib"]
  s.files         = Dir["lib/**/*", "LICENSE", "README.md", "Rakefile"]

  s.add_dependency "activesupport", ">= 7.0"
  s.add_dependency "prism"
  s.add_dependency "tiny_color"
end
