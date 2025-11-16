# frozen_string_literal: true

# Load base Kamal first to ensure CLI classes are available
require "kamal"

require_relative "dev/version"
require_relative "dev/config"
require_relative "dev/devcontainer_parser"
require_relative "dev/devcontainer"
require_relative "dev/state_manager"
require_relative "dev/secrets_loader"
require_relative "providers/base"
require_relative "providers/upcloud"
require_relative "cli/dev"

module Kamal
  module Dev
    class Error < StandardError; end
    class ConfigurationError < Error; end
  end
end

# Hook into Kamal's CLI to register the 'dev' subcommand
# This allows users to run: kamal dev deploy, kamal dev list, etc.
Kamal::Cli::Main.class_eval do
  desc "dev", "Manage development containers"
  subcommand "dev", Kamal::Cli::Dev
end
