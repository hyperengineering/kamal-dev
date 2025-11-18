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

      # Get full image name with registry server prepended if needed
      #
      # Supports both patterns:
      # - Full path: "ghcr.io/org/app" → "ghcr.io/org/app"
      # - Short path: "org/app" → "ghcr.io/org/app" (registry prepended)
      # - Name only: "app" → "ghcr.io/app"
      #
      # @param image_ref [String] Image reference from config.image
      # @return [String] Full image name with registry
      def full_image_name(image_ref)
        # Check if image already includes a registry
        # Registry indicators: has a . (ghcr.io) or : (localhost:5000) in first component
        first_component = image_ref.split("/").first

        if first_component.include?(".") || first_component.include?(":")
          # Already has registry: "ghcr.io/org/app", "docker.io/library/ruby", "localhost:5000/app"
          image_ref
        else
          # No registry: "org/app" or "app" - prepend registry server
          "#{server}/#{image_ref}"
        end
      end

      # Generate image name without tag (DEPRECATED - kept for backward compatibility)
      #
      # @deprecated Use full_image_name(config.image) instead
      # @param service [String] Service name (from config.service)
      # @return [String] Full image name without tag
      # @raise [Kamal::Dev::RegistryError] if username not configured
      def image_name(service)
        raise Kamal::Dev::RegistryError, "Registry username not configured" unless username

        "#{server}/#{username}/#{service}-dev"
      end

      # Generate full image reference with tag
      #
      # @param image_base [String] Base image name (can be full or short path)
      # @param tag [String] Image tag (timestamp, git SHA, or custom)
      # @return [String] Full image reference with tag
      def image_tag(image_base, tag)
        base = (image_base.is_a?(String) && (image_base.include?("/") || image_base.include?("."))) ?
                 full_image_name(image_base) :
                 image_name(image_base)  # Backward compatibility
        "#{base}:#{tag}"
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
