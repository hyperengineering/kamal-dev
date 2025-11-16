# frozen_string_literal: true

require "yaml"
require "active_support/core_ext/hash"
require_relative "devcontainer_parser"
require_relative "devcontainer"
require_relative "secrets_loader"

module Kamal
  module Dev
    class Config
      attr_reader :raw_config

      def initialize(config, validate: false)
        @raw_config = case config
        when String
          load_from_file(config)
        when Hash
          config.deep_symbolize_keys
        else
          raise Kamal::Dev::ConfigurationError, "Config must be a file path (String) or Hash"
        end

        validate! if validate
      end

      def service
        raw_config[:service]
      end

      def image
        raw_config[:image]
      end

      def provider
        raw_config[:provider]&.deep_stringify_keys || {}
      end

      def defaults
        raw_config[:defaults]&.deep_stringify_keys || {}
      end

      def vms
        raw_config[:vms]&.deep_stringify_keys || {}
      end

      def vm_count
        vms["count"] || 1
      end

      def naming_pattern
        raw_config.dig(:naming, :pattern) || "{service}-{index}"
      end

      def secrets
        raw_config[:secrets] || []
      end

      def secrets_file
        raw_config[:secrets_file] || ".kamal/secrets"
      end

      def ssh
        raw_config[:ssh]&.deep_stringify_keys || {}
      end

      def ssh_key_path
        ssh["key_path"] || "~/.ssh/id_rsa.pub"
      end

      def container_name(index)
        pattern = naming_pattern

        # Handle zero-padded indexes like {index:03}
        pattern = pattern.gsub(/\{index:(\d+)\}/) do
          format("%0#{$1}d", index)
        end

        # Replace standard placeholders
        name = pattern.gsub("{service}", service.to_s)
          .gsub("{index}", index.to_s)

        validate_docker_name!(name)
        name
      end

      # Load and parse devcontainer configuration
      #
      # Handles both:
      # - Direct image reference: image: "ruby:3.2"
      # - Devcontainer.json path: image: ".devcontainer/devcontainer.json"
      #
      # @return [Devcontainer] Parsed devcontainer configuration
      def devcontainer
        @devcontainer ||= load_devcontainer
      end

      # Check if image config points to a devcontainer.json file
      #
      # @return [Boolean] true if image is a path to devcontainer.json
      def devcontainer_json?
        image.to_s.end_with?(".json") || image.to_s.include?("devcontainer")
      end

      def validate!
        errors = []

        errors << "Configuration must include 'service' (service name is required)" if service.nil? || service.empty?
        errors << "Configuration must include 'image' (image reference is required)" if image.nil? || image.empty?

        if provider.empty?
          errors << "Configuration must include 'provider' (provider configuration is required)"
        elsif provider["type"].nil? || provider["type"].empty?
          errors << "Configuration must include 'provider.type' (provider type is required)"
        end

        # Validate service name against Docker naming rules
        unless service.nil? || service.empty?
          unless docker_name_valid?(service)
            errors << "Service name '#{service}' is invalid. Docker names must start with a letter or number and contain only [a-zA-Z0-9_.-]"
          end
        end

        raise Kamal::Dev::ConfigurationError, errors.join("\n") unless errors.empty?

        self
      end

      private

      def load_from_file(path)
        unless File.exist?(path)
          raise Kamal::Dev::ConfigurationError, "Configuration file not found: #{path}"
        end

        YAML.load_file(path, symbolize_names: true)
      rescue Psych::SyntaxError => e
        raise Kamal::Dev::ConfigurationError, "Invalid YAML in #{path}: #{e.message}"
      end

      # Load devcontainer configuration
      #
      # @return [Devcontainer] Devcontainer instance
      def load_devcontainer
        config_hash = if devcontainer_json?
          # Parse devcontainer.json file
          parser = DevcontainerParser.new(image)
          parser.parse
        else
          # Direct image reference - create minimal config
          {
            image: image,
            ports: [],
            mounts: [],
            env: {},
            options: [],
            user: nil,
            workspace: nil
          }
        end

        # Load and inject secrets if configured
        if !secrets.empty? && File.exist?(secrets_file)
          loader = Kamal::Dev::SecretsLoader.new(secrets_file)
          loaded_secrets = loader.load_secrets_for(secrets)
          config_hash[:secrets] = loaded_secrets
        else
          config_hash[:secrets] = {}
        end

        Devcontainer.new(config_hash)
      end

      # Validate Docker name against naming rules
      #
      # Docker container names must:
      # - Start with a letter or number
      # - Contain only: letters, numbers, underscores, periods, hyphens
      #
      # @param name [String] Container name to validate
      # @return [Boolean] true if valid, false otherwise
      def docker_name_valid?(name)
        return false if name.nil? || name.empty?

        # Must start with alphanumeric and contain only [a-zA-Z0-9_.-]
        name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
      end

      # Validate and raise error if Docker name is invalid
      #
      # @param name [String] Container name to validate
      # @raise [Kamal::Dev::ConfigurationError] if name is invalid
      def validate_docker_name!(name)
        return if docker_name_valid?(name)

        raise Kamal::Dev::ConfigurationError,
          "Container name '#{name}' is invalid. Docker names must start with a letter or number and contain only [a-zA-Z0-9_.-]"
      end
    end
  end
end
