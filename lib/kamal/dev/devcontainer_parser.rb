# frozen_string_literal: true

require "json"

module Kamal
  module Dev
    # Parses VS Code devcontainer.json specifications into Docker configuration
    #
    # Handles JSON with comments (// and /* */), extracts container properties,
    # and transforms them into a standardized configuration hash for Docker deployment.
    #
    # @example Basic usage
    #   parser = DevcontainerParser.new(".devcontainer/devcontainer.json")
    #   config = parser.parse
    #   #=> {image: "ruby:3.2", ports: [3000], workspace: "/workspace", ...}
    class DevcontainerParser
      # Custom error for validation failures
      class ValidationError < StandardError; end

      attr_reader :file_path

      # Initialize parser with devcontainer.json file path
      #
      # @param file_path [String] Path to devcontainer.json file
      def initialize(file_path)
        @file_path = file_path
      end

      # Parse devcontainer.json and return standardized config hash
      #
      # @return [Hash] Configuration hash with keys:
      #   - :image [String] Docker image name
      #   - :ports [Array<Integer>] Port mappings
      #   - :mounts [Array<Hash>] Volume/bind mounts
      #   - :env [Hash] Environment variables
      #   - :options [Array<String>] Docker run options
      #   - :user [String, nil] Remote user
      #   - :workspace [String, nil] Workspace folder path
      #
      # @raise [Errno::ENOENT] if file doesn't exist
      # @raise [JSON::ParserError] if JSON is malformed
      # @raise [ValidationError] if required properties are missing
      def parse
        content = File.read(@file_path)
        clean_content = strip_comments(content)
        devcontainer_json = JSON.parse(clean_content)

        validate_required_properties!(devcontainer_json)

        {
          image: extract_image(devcontainer_json),
          ports: extract_ports(devcontainer_json),
          mounts: extract_mounts(devcontainer_json),
          env: extract_env(devcontainer_json),
          options: extract_options(devcontainer_json),
          user: extract_user(devcontainer_json),
          workspace: extract_workspace(devcontainer_json)
        }
      end

      # Check if devcontainer uses Docker Compose
      #
      # @return [Boolean] true if dockerComposeFile property is present
      def uses_compose?
        content = File.read(@file_path)
        clean_content = strip_comments(content)
        devcontainer_json = JSON.parse(clean_content)

        devcontainer_json.key?("dockerComposeFile")
      rescue
        false
      end

      # Get path to compose file if present
      #
      # Returns path relative to .devcontainer/ directory
      #
      # @return [String, nil] Path to compose file or nil if not using compose
      def compose_file_path
        return nil unless uses_compose?

        content = File.read(@file_path)
        clean_content = strip_comments(content)
        devcontainer_json = JSON.parse(clean_content)

        compose_file = devcontainer_json["dockerComposeFile"]
        return nil unless compose_file

        # Handle array of compose files (use first one)
        compose_file = compose_file.first if compose_file.is_a?(Array)

        # Resolve path relative to .devcontainer directory
        devcontainer_dir = File.dirname(@file_path)
        File.join(devcontainer_dir, compose_file)
      rescue
        nil
      end

      private

      # Strip single-line (//) and multi-line (/* */) comments from JSON
      #
      # @param content [String] Raw JSON content
      # @return [String] JSON without comments
      def strip_comments(content)
        # Remove multi-line comments /* ... */
        content = content.gsub(/\/\*.*?\*\//m, "")

        # Remove single-line comments //  ...
        # But preserve comments inside strings (basic approach)
        content.gsub(/(?<!:)\/\/.*?$/, "")
      end

      # Validate that required properties exist
      #
      # @param json [Hash] Parsed JSON hash
      # @raise [ValidationError] if image property is missing
      def validate_required_properties!(json)
        # Docker Compose files have their own validation - skip image check
        return if json["dockerComposeFile"]

        unless json["image"] || json["dockerfile"]
          raise ValidationError, "Devcontainer.json must specify either 'image', 'dockerfile', or 'dockerComposeFile' property"
        end
      end

      # Extract Docker image name
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [String] Image name
      # @raise [ValidationError] if neither image nor dockerfile specified
      def extract_image(json)
        if json["image"]
          json["image"]
        elsif json["dockerfile"]
          # Dockerfile builds not yet supported - raise validation error
          raise ValidationError, "Image property is required (Dockerfile builds not yet supported)"
        else
          raise ValidationError, "Image property is required"
        end
      end

      # Extract forward ports
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [Array<Integer>] List of ports to forward
      def extract_ports(json)
        return [] unless json["forwardPorts"]

        Array(json["forwardPorts"]).map(&:to_i)
      end

      # Extract mounts (volumes and bind mounts)
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [Array<Hash>] List of mount configurations with :source, :target, :type
      def extract_mounts(json)
        return [] unless json["mounts"]

        Array(json["mounts"]).map do |mount|
          {
            source: mount["source"],
            target: mount["target"],
            type: mount["type"] || "bind"
          }
        end
      end

      # Extract container environment variables
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [Hash] Environment variable key-value pairs
      def extract_env(json)
        json["containerEnv"] || {}
      end

      # Extract Docker run options (runArgs)
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [Array<String>] Docker run arguments
      def extract_options(json)
        return [] unless json["runArgs"]

        Array(json["runArgs"])
      end

      # Extract remote user
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [String, nil] Remote user name
      def extract_user(json)
        json["remoteUser"]
      end

      # Extract workspace folder path
      #
      # @param json [Hash] Parsed devcontainer.json
      # @return [String, nil] Workspace folder path
      def extract_workspace(json)
        json["workspaceFolder"]
      end
    end
  end
end
