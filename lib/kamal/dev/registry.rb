# frozen_string_literal: true

require "open3"

module Kamal
  module Dev
    # Registry configuration and authentication for image building and pushing
    #
    # Provides methods for:
    # - Registry server configuration (default: ghcr.io)
    # - Credential loading from environment variables
    # - Image naming conventions ({registry}/{user}/{service}-dev:{tag})
    # - Docker login command generation
    #
    # @example Basic usage
    #   registry = Kamal::Dev::Registry.new(config)
    #   image = registry.image_name("myapp")
    #   # => "ghcr.io/ljuti/myapp-dev"
    #
    # @example With tag
    #   registry.image_tag("myapp", "abc123")
    #   # => "ghcr.io/ljuti/myapp-dev:abc123"
    #
    # @example Docker login
    #   registry.login_command
    #   # => ["docker", "login", "ghcr.io", "-u", "ljuti", "-p", "token"]
    #
    class Registry
      attr_reader :config

      # Initialize registry with configuration
      #
      # @param config [Kamal::Dev::Config] Configuration object
      def initialize(config)
        @config = config
      end

      # Registry server URL
      #
      # @return [String] Registry server (default: ghcr.io)
      def server
        config.registry_server
      end

      # Registry username loaded from environment variable
      #
      # @return [String, nil] Username from ENV
      def username
        config.registry_username
      end

      # Registry password/token loaded from environment variable
      #
      # @return [String, nil] Password from ENV
      def password
        config.registry_password
      end

      # Generate image name without tag
      #
      # Format: {registry}/{user}/{service}-dev
      # Example: ghcr.io/ljuti/myapp-dev
      #
      # @param service [String] Service name (from config.service)
      # @return [String] Full image name without tag
      # @raise [Kamal::Dev::RegistryError] if username not configured
      def image_name(service)
        raise Kamal::Dev::RegistryError, "Registry username not configured" unless username

        "#{server}/#{username}/#{service}-dev"
      end

      # Generate full image reference with tag
      #
      # Format: {registry}/{user}/{service}-dev:{tag}
      # Example: ghcr.io/ljuti/myapp-dev:abc123
      #
      # @param service [String] Service name
      # @param tag [String] Image tag (timestamp, git SHA, or custom)
      # @return [String] Full image reference with tag
      # @raise [Kamal::Dev::RegistryError] if username not configured
      def image_tag(service, tag)
        "#{image_name(service)}:#{tag}"
      end

      # Generate docker login command
      #
      # @return [Array<String>] Docker login command array
      # @raise [Kamal::Dev::RegistryError] if credentials not configured
      # @example
      #   registry.login_command
      #   # => ["docker", "login", "ghcr.io", "-u", "ljuti", "-p", "token"]
      def login_command
        raise Kamal::Dev::RegistryError, "Registry credentials not configured" unless credentials_present?

        ["docker", "login", server, "-u", username, "-p", password]
      end

      # Check if credentials are present
      #
      # @return [Boolean] true if username and password are set
      def credentials_present?
        !!(username && password)
      end

      # Generate timestamp-based tag
      #
      # Format: unix_timestamp (e.g., "1700000000")
      #
      # @return [String] Unix timestamp tag
      def tag_with_timestamp
        Time.now.to_i.to_s
      end

      # Generate git SHA-based tag
      #
      # Format: short_sha (e.g., "abc123f")
      #
      # @return [String, nil] Short git commit SHA or nil if git not available
      def tag_with_git_sha
        sha, _status = Open3.capture2("git", "rev-parse", "--short", "HEAD", err: :close)
        sha = sha.strip
        sha.empty? ? nil : sha
      rescue
        nil
      end
    end
  end
end
