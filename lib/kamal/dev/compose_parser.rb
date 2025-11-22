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
      # @param service_name [String] Service name
      # @return [String] Build context path (default: ".")
      def service_build_context(service_name)
        service = services[service_name]
        return "." unless service

        build_config = service["build"]
        return "." unless build_config

        # Handle string build path (shorthand)
        return build_config if build_config.is_a?(String)

        # Handle object build config
        build_config["context"] || "."
      end

      # Get Dockerfile path for a service
      #
      # @param service_name [String] Service name
      # @return [String] Dockerfile path (default: "Dockerfile")
      def service_dockerfile(service_name)
        service = services[service_name]
        return "Dockerfile" unless service

        build_config = service["build"]
        return "Dockerfile" unless build_config

        # Handle object build config
        return "Dockerfile" if build_config.is_a?(String)

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

          # Inject git clone functionality if configured
          if config&.git_clone_enabled?
            inject_git_clone!(transformed["services"][main], config)
          end
        end

        # Convert back to YAML
        YAML.dump(transformed)
      rescue => e
        raise Kamal::Dev::ConfigurationError, "Failed to transform compose file: #{e.message}"
      end

      private

      # Inject git clone functionality into service configuration
      #
      # Adds environment variables and wraps command with git clone script.
      # Only executes clone if KAMAL_DEV_GIT_REPO is set (remote deployment).
      # Local devcontainers won't have these vars, so they use mounted code.
      #
      # @param service_config [Hash] Service configuration to modify
      # @param config [Kamal::Dev::Config] Configuration with git settings
      def inject_git_clone!(service_config, config)
        # Initialize environment hash if not present
        service_config["environment"] ||= {}

        # Inject git clone environment variables (all must go in environment section)
        service_config["environment"]["KAMAL_DEV_GIT_REPO"] = config.git_repository
        service_config["environment"]["KAMAL_DEV_GIT_BRANCH"] = config.git_branch
        service_config["environment"]["KAMAL_DEV_WORKSPACE_FOLDER"] = config.git_workspace_folder

        # Get original command (or default to sleep infinity)
        original_command = service_config["command"] || "sleep infinity"

        # Wrap command with git clone script
        # This only runs on kamal-dev deployments (env vars present)
        # Local devcontainers won't have these vars, so script is skipped
        service_config["command"] = build_git_clone_wrapper(original_command, config)
      end

      # Build bash script that clones git repo before running original command
      #
      # @param original_command [String] Original container command
      # @param config [Kamal::Dev::Config] Configuration with git settings
      # @return [String] Bash script as single command
      def build_git_clone_wrapper(original_command, config)
        # Inline bash script that:
        # 1. Checks if KAMAL_DEV_GIT_REPO is set (kamal-dev deployment)
        # 2. If yes and workspace is empty, clones the repo
        # 3. Execs the original command
        # Use single-quote heredoc to prevent Ruby interpolation of $VARS
        # Return as string - Docker Compose will handle it properly
        script = <<~'BASH'.chomp
          if [ -n "$KAMAL_DEV_GIT_REPO" ]; then
            echo "[kamal-dev] Remote deployment detected"
            if [ ! -d "$KAMAL_DEV_WORKSPACE_FOLDER/.git" ]; then
              echo "[kamal-dev] Cloning $KAMAL_DEV_GIT_REPO (branch: $KAMAL_DEV_GIT_BRANCH)"
              mkdir -p "$KAMAL_DEV_WORKSPACE_FOLDER"
              git clone --depth 1 --branch "$KAMAL_DEV_GIT_BRANCH" "$KAMAL_DEV_GIT_REPO" "$KAMAL_DEV_WORKSPACE_FOLDER"
              echo "[kamal-dev] Clone complete"
            else
              echo "[kamal-dev] Repository already cloned, pulling latest changes"
              cd "$KAMAL_DEV_WORKSPACE_FOLDER" && git pull
            fi
          else
            echo "[kamal-dev] Local development mode (code mounted, not cloned)"
          fi
          exec ORIGINAL_COMMAND_PLACEHOLDER
        BASH
        # Replace placeholder with actual command, wrap in sh -c for proper execution
        "sh -c " + (script.gsub("ORIGINAL_COMMAND_PLACEHOLDER", original_command).dump)
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
