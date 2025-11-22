# frozen_string_literal: true

require "yaml"

module Kamal
  module Dev
    # Parser for Docker Compose files
    #
    # Parses compose.yaml files to extract service definitions, build contexts,
    # and Dockerfiles. Identifies main application service vs dependent services
    # (databases, caches, etc.) for deployment orchestration.
    #
    # @example Basic usage
    #   parser = Kamal::Dev::ComposeParser.new(".devcontainer/compose.yaml")
    #   parser.main_service
    #   # => "app"
    #
    # @example Get build context
    #   parser.service_build_context("app")
    #   # => "."
    #
    # @example Check if service has build section
    #   parser.has_build_section?("postgres")
    #   # => false
    #
    class ComposeParser
      attr_reader :compose_file_path, :compose_data

      # Initialize parser with compose file path
      #
      # @param compose_file_path [String] Path to compose.yaml file
      # @raise [Kamal::Dev::ConfigurationError] if file not found or invalid YAML
      def initialize(compose_file_path)
        @compose_file_path = compose_file_path
        @compose_data = load_and_parse
      end

      # Get all services from compose file
      #
      # @return [Hash] Service definitions keyed by service name
      def services
        compose_data.fetch("services", {})
      end

      # Identify the main application service
      #
      # Uses heuristic: first service with a build: section,
      # or first service if none have build sections
      #
      # @return [String, nil] Main service name
      def main_service
        # Find first service with build section
        service_with_build = services.find { |_, config| config.key?("build") }
        return service_with_build[0] if service_with_build

        # Fallback to first service
        services.keys.first
      end

      # Get build context for a service
      #
      # Resolves context path relative to the compose file's directory,
      # since Docker Compose interprets paths relative to the compose file location.
      #
      # @param service_name [String] Service name
      # @return [String] Build context path resolved relative to compose file (default: ".")
      def service_build_context(service_name)
        service = services[service_name]
        return "." unless service

        build_config = service["build"]
        return "." unless build_config

        # Get context from build config
        context = if build_config.is_a?(String)
          # Handle string build path (shorthand) - this is the context
          build_config
        else
          # Handle object build config
          build_config["context"] || "."
        end

        # Resolve context relative to compose file's directory
        # Docker Compose does this automatically, but we're extracting values
        compose_dir = File.dirname(compose_file_path)
        File.expand_path(context, compose_dir)
      end

      # Get Dockerfile path for a service
      #
      # Returns path relative to the build context (as Docker expects),
      # NOT resolved to absolute path.
      #
      # @param service_name [String] Service name
      # @return [String] Dockerfile path relative to build context (default: "Dockerfile")
      def service_dockerfile(service_name)
        service = services[service_name]
        return "Dockerfile" unless service

        build_config = service["build"]
        return "Dockerfile" unless build_config

        # Handle object build config
        return "Dockerfile" if build_config.is_a?(String)

        # Return dockerfile path as-is (relative to build context)
        build_config["dockerfile"] || "Dockerfile"
      end

      # Check if service has a build section
      #
      # @param service_name [String] Service name
      # @return [Boolean] true if service uses build:, false if image:
      def has_build_section?(service_name)
        service = services[service_name]
        return false unless service

        service.key?("build")
      end

      # Get dependent services (services without build sections)
      #
      # These are typically databases, caches, message queues, etc.
      # that use pre-built images from registries
      #
      # @return [Array<String>] Service names without build sections
      def dependent_services
        services.select { |_, config| !config.key?("build") }.keys
      end

      # Transform compose file for deployment
      #
      # Replaces build: sections with image: references pointing to
      # the pushed registry image. Removes local bind mounts (DevPod-style).
      # Optionally injects git clone functionality for remote deployments.
      # Preserves named volumes and other service properties.
      #
      # @param image_ref [String] Full image reference (e.g., "ghcr.io/user/app:tag")
      # @param config [Kamal::Dev::Config] Optional config for git clone setup
      # @return [String] Transformed YAML content
      # @raise [Kamal::Dev::ConfigurationError] if transformation fails
      def transform_for_deployment(image_ref, config: nil)
        transformed = deep_copy(compose_data)
        main = main_service

        if main && transformed["services"][main]
          # Remove build section
          transformed["services"][main].delete("build")

          # Add image reference
          transformed["services"][main]["image"] = image_ref

          # Remove local bind mounts (DevPod-style: code will be cloned, not mounted)
          # Keep named volumes (databases, caches, etc.)
          if transformed["services"][main]["volumes"]
            transformed["services"][main]["volumes"] = transformed["services"][main]["volumes"].reject do |volume|
              # Reject if it's a bind mount (contains ":" and first part is a path)
              if volume.is_a?(String) && volume.include?(":")
                source, _target = volume.split(":", 2)
                # Named volumes don't start with . or / or ~
                source.start_with?(".", "/", "~")
              else
                false
              end
            end

            # Remove volumes array if empty
            transformed["services"][main].delete("volumes") if transformed["services"][main]["volumes"].empty?
          end

          # Inject git clone environment variables if configured
          # The actual cloning is handled by the entrypoint script in the image
          if config&.git_clone_enabled?
            inject_git_env_vars!(transformed["services"][main], config)
          end
        end

        # Convert back to YAML
        YAML.dump(transformed)
      rescue => e
        raise Kamal::Dev::ConfigurationError, "Failed to transform compose file: #{e.message}"
      end

      private

      # Inject git clone environment variables into service configuration
      #
      # The entrypoint script in the Docker image will use these variables
      # to clone the repository. Local devcontainers won't have these vars set,
      # so they'll use mounted code instead.
      #
      # @param service_config [Hash] Service configuration to modify
      # @param config [Kamal::Dev::Config] Configuration with git settings
      def inject_git_env_vars!(service_config, config)
        # Initialize environment hash if not present
        service_config["environment"] ||= {}

        # Inject git clone environment variables
        # These are used by /usr/local/bin/dev-entrypoint.sh in the image
        service_config["environment"]["KAMAL_DEV_GIT_REPO"] = config.git_repository
        service_config["environment"]["KAMAL_DEV_GIT_BRANCH"] = config.git_branch
        service_config["environment"]["KAMAL_DEV_WORKSPACE_FOLDER"] = config.git_workspace_folder

        # Inject authentication token if configured (for private repositories)
        if config.git_token
          service_config["environment"]["KAMAL_DEV_GIT_TOKEN"] = config.git_token
        end
      end

      # Load and parse compose YAML file
      #
      # @return [Hash] Parsed compose data
      # @raise [Kamal::Dev::ConfigurationError] if file not found or invalid
      def load_and_parse
        unless File.exist?(compose_file_path)
          raise Kamal::Dev::ConfigurationError, "Compose file not found: #{compose_file_path}"
        end

        content = File.read(compose_file_path)
        data = YAML.safe_load(content, permitted_classes: [Symbol])

        validate_compose_structure!(data)
        data
      rescue Psych::SyntaxError => e
        raise Kamal::Dev::ConfigurationError, "Invalid YAML in compose file: #{e.message}"
      end

      # Validate compose file structure
      #
      # @param data [Hash] Parsed compose data
      # @raise [Kamal::Dev::ConfigurationError] if structure invalid
      def validate_compose_structure!(data)
        unless data.is_a?(Hash)
          raise Kamal::Dev::ConfigurationError, "Compose file must be a YAML object"
        end

        unless data.key?("services")
          raise Kamal::Dev::ConfigurationError, "Compose file must have 'services' section"
        end

        if data["services"].empty?
          raise Kamal::Dev::ConfigurationError, "Compose file must define at least one service"
        end
      end

      # Deep copy hash to avoid modifying original
      #
      # @param obj [Object] Object to copy
      # @return [Object] Deep copy
      def deep_copy(obj)
        Marshal.load(Marshal.dump(obj))
      end
    end
  end
end
