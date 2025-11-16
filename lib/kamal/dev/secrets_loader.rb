# frozen_string_literal: true

require "base64"

module Kamal
  module Dev
    # Loads and processes secrets from .kamal/secrets file
    #
    # Parses shell script format (export KEY="value") and provides
    # Base64-encoded values for container injection.
    #
    # @example Basic usage
    #   loader = SecretsLoader.new(".kamal/secrets")
    #   secrets = loader.load_secrets
    #   #=> {"DATABASE_URL" => "base64_encoded_value", ...}
    class SecretsLoader
      # Custom error for missing secrets file
      class SecretsNotFoundError < StandardError; end

      # Custom error for secrets parsing failures
      class SecretsParseError < StandardError; end

      attr_reader :secrets_file

      # Initialize secrets loader with file path
      #
      # @param secrets_file_path [String] Path to secrets file
      def initialize(secrets_file_path = ".kamal/secrets")
        @secrets_file = secrets_file_path
      end

      # Load and parse secrets from file
      #
      # @return [Hash<String, String>] Hash of secret keys to Base64-encoded values
      # @raise [SecretsNotFoundError] if secrets file doesn't exist
      # @raise [SecretsParseError] if file cannot be parsed
      def load_secrets
        unless File.exist?(@secrets_file)
          raise SecretsNotFoundError, "Secrets file not found: #{@secrets_file}"
        end

        parse_secrets_file
      end

      # Load secrets for specific keys only
      #
      # @param keys [Array<String>] List of secret keys to load
      # @return [Hash<String, String>] Hash of requested keys to Base64-encoded values
      def load_secrets_for(keys)
        all_secrets = load_secrets
        keys.each_with_object({}) do |key, result|
          result[key] = all_secrets[key] if all_secrets.key?(key)
        end
      end

      private

      # Parse shell script format secrets file
      #
      # Supports formats:
      #   export KEY="value"
      #   export KEY='value'
      #   export KEY=value
      #
      # @return [Hash<String, String>] Parsed and Base64-encoded secrets
      def parse_secrets_file
        content = File.read(@secrets_file)
        secrets = {}

        content.each_line do |line|
          # Skip comments and empty lines
          next if line.strip.start_with?("#") || line.strip.empty?

          # Match: export KEY="value" or export KEY='value' or export KEY=value
          if line =~ /^\s*export\s+([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$/
            key = $1
            value = $2.strip

            # Remove quotes if present
            value = value[1..-2] if value.start_with?('"', "'") && value.end_with?('"', "'")

            # Base64 encode the value
            secrets[key] = Base64.strict_encode64(value)
          end
        end

        secrets
      rescue => e
        raise SecretsParseError, "Failed to parse secrets file: #{e.message}"
      end
    end
  end
end
