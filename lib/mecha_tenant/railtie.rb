# frozen_string_literal: true

require "rails/railtie"

module MechaTenant
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/mecha_tenant.rake", __dir__)
    end
  end
end
