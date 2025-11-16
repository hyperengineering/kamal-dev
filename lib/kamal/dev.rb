# frozen_string_literal: true

require_relative "dev/version"
require_relative "dev/state_manager"
require_relative "cli/dev"
require_relative "configuration/dev_config"
require_relative "configuration/devcontainer_parser"
require_relative "configuration/devcontainer"
require_relative "providers/base"
require_relative "providers/upcloud"

module Kamal
  module Dev
    class Error < StandardError; end
    class ConfigurationError < Error; end
  end
end
