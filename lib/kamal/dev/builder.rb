# frozen_string_literal: true

module Kamal
  module Dev
    # Builder for building and pushing Docker images
    #
    # Wraps Docker build and push operations with:
    # - Build progress display
    # - Tag management (timestamp, git SHA, custom)
    # - Error handling for build failures
    # - Registry authentication
    #
    # @example Build an image
    #   builder = Kamal::Dev::Builder.new(config, registry)
    #   builder.build(
    #     dockerfile: ".devcontainer/Dockerfile",
    #     context: ".",
    #     tag: "abc123"
    #   )
    #
    # @example Push an image
    #   builder.push("myapp-dev:abc123")
    #
    class Builder
      attr_reader :config, :registry

      # Initialize builder with configuration and registry
      #
      # @param config [Kamal::Dev::Config] Configuration object
      # @param registry [Kamal::Dev::Registry] Registry object
      def initialize(config, registry)
        @config = config
        @registry = registry
      end

      # Build Docker image from Dockerfile
      #
      # @param dockerfile [String] Path to Dockerfile
      # @param context [String] Build context path (default: ".")
      # @param tag [String] Image tag (optional, auto-generated if not provided)
      # @param image_base [String] Base image name from config (optional, uses config.service if not provided)
      # @param build_args [Hash] Build arguments (optional)
      # @param secrets [Hash] Build secrets (optional)
      # @return [String] Full image reference with tag
      # @raise [Kamal::Dev::BuildError] if build fails
      def build(dockerfile:, context: ".", tag: nil, image_base: nil, build_args: {}, secrets: {})
        tag ||= registry.tag_with_timestamp

        # Use image_base if provided (new format), otherwise fall back to service name (old format)
        image_ref = if image_base
          registry.image_tag(image_base, tag)
        else
          registry.image_tag(config.service, tag)
        end

        # If git clone is enabled, wrap Dockerfile with entrypoint injection
        if config.git_clone_enabled?
          build_with_entrypoint(
            dockerfile: dockerfile,
            context: context,
            image: image_ref,
            build_args: build_args,
            secrets: secrets
          )
        else
          command = build_command(
            dockerfile: dockerfile,
            context: context,
            image: image_ref,
            build_args: build_args,
            secrets: secrets
          )

          execute_with_output(command, "Building image #{image_ref}...")
        end

        image_ref
      end

      # Push Docker image to registry
      #
      # @param image_ref [String] Full image reference (registry/user/image:tag)
      # @return [Boolean] true if push succeeded
      # @raise [Kamal::Dev::BuildError] if push fails
      def push(image_ref)
        command = ["docker", "push", image_ref]

        execute_with_output(command, "Pushing image #{image_ref}...")

        true
      end

      # Authenticate with Docker registry
      #
      # @return [Boolean] true if login succeeded
      # @raise [Kamal::Dev::RegistryError] if login fails
      def login
        command = registry.login_command

        # Login command uses password on command line, so we execute silently
        result = execute_command(command)

        unless result[:success]
          raise Kamal::Dev::RegistryError,
            "Docker login failed: #{result[:error]}"
        end

        true
      end

      # Check if Docker is available
      #
      # @return [Boolean] true if Docker is installed and running
      def docker_available?
        result = execute_command(["docker", "version"])
        result[:success]
      end

      # Check if image exists locally
      #
      # @param image_ref [String] Full image reference
      # @return [Boolean] true if image exists
      def image_exists?(image_ref)
        result = execute_command(["docker", "image", "inspect", image_ref])
        result[:success]
      end

      # Tag image with timestamp
      #
      # @param base_image [String] Base image reference
      # @return [String] New image reference with timestamp tag
      def tag_with_timestamp(base_image)
        tag = registry.tag_with_timestamp
        new_image = "#{base_image}:#{tag}"

        execute_command(["docker", "tag", base_image, new_image])

        new_image
      end

      # Tag image with git SHA
      #
      # @param base_image [String] Base image reference
      # @return [String, nil] New image reference with git SHA tag or nil if not in git repo
      def tag_with_git_sha(base_image)
        tag = registry.tag_with_git_sha
        return nil unless tag

        new_image = "#{base_image}:#{tag}"

        execute_command(["docker", "tag", base_image, new_image])

        new_image
      end

      private

      # Build image with kamal-dev entrypoint injected
      #
      # Creates a temporary wrapper Dockerfile that:
      # 1. Builds from the original Dockerfile
      # 2. Injects the dev-entrypoint.sh script
      # 3. Sets it as the container entrypoint
      #
      # @param dockerfile [String] Original Dockerfile path
      # @param context [String] Build context
      # @param image [String] Target image name with tag
      # @param build_args [Hash] Build arguments
      # @param secrets [Hash] Build secrets
      def build_with_entrypoint(dockerfile:, context:, image:, build_args: {}, secrets: {})
        require "tmpdir"
        require "fileutils"

        Dir.mktmpdir("kamal-dev-build") do |temp_dir|
          # Copy entrypoint script to temp directory
          entrypoint_template = File.expand_path("../templates/dev-entrypoint.sh", __FILE__)
          entrypoint_dest = File.join(temp_dir, "dev-entrypoint.sh")
          FileUtils.cp(entrypoint_template, entrypoint_dest)
          FileUtils.chmod(0755, entrypoint_dest)

          # Create wrapper Dockerfile
          wrapper_dockerfile = File.join(temp_dir, "Dockerfile.kamal-dev")
          original_dockerfile_path = File.join(context, dockerfile)

          File.write(wrapper_dockerfile, generate_wrapper_dockerfile(original_dockerfile_path))

          # Copy wrapper to context so docker build can access it
          FileUtils.cp(wrapper_dockerfile, File.join(context, "Dockerfile.kamal-dev"))
          FileUtils.cp(entrypoint_dest, File.join(context, "dev-entrypoint.sh"))

          begin
            # Build using wrapper Dockerfile
            command = build_command(
              dockerfile: "Dockerfile.kamal-dev",
              context: context,
              image: image,
              build_args: build_args,
              secrets: secrets
            )

            execute_with_output(command, "Building image with kamal-dev entrypoint #{image}...")
          ensure
            # Cleanup temporary files from context
            FileUtils.rm_f(File.join(context, "Dockerfile.kamal-dev"))
            FileUtils.rm_f(File.join(context, "dev-entrypoint.sh"))
          end
        end
      end

      # Generate wrapper Dockerfile content
      #
      # @param original_dockerfile [String] Path to original Dockerfile
      # @return [String] Wrapper Dockerfile content
      def generate_wrapper_dockerfile(original_dockerfile)
        # Read original Dockerfile to extract final image
        # Use multi-stage build: stage 1 = original, stage 2 = add entrypoint
        <<~DOCKERFILE
          # Stage 1: Build original image
          FROM scratch AS original-dockerfile
          # This is a placeholder - we'll build from the original file

          # We can't easily include another Dockerfile, so we'll use a different approach
          # Build the original image first, then extend it

          # Actually, simpler approach: read the original and inline it
        DOCKERFILE

        # Better approach: Just extend the original Dockerfile directly
        original_content = File.read(original_dockerfile)

        <<~DOCKERFILE
          #{original_content}

          # Kamal Dev: Inject entrypoint for git clone functionality
          COPY dev-entrypoint.sh /usr/local/bin/dev-entrypoint.sh
          RUN chmod +x /usr/local/bin/dev-entrypoint.sh
          ENTRYPOINT ["/usr/local/bin/dev-entrypoint.sh"]
        DOCKERFILE
      end

      # Build docker build command
      #
      # @param dockerfile [String] Dockerfile path
      # @param context [String] Build context
      # @param image [String] Image reference with tag
      # @param build_args [Hash] Build arguments
      # @param secrets [Hash] Build secrets
      # @return [Array<String>] Docker build command
      def build_command(dockerfile:, context:, image:, build_args: {}, secrets: {})
        cmd = ["docker", "build"]

        # Add platform flag for cross-platform compatibility
        # Cloud VMs are typically linux/amd64, even when building on arm64 (Mac)
        cmd += ["--platform", "linux/amd64"]

        # Add dockerfile flag
        cmd += ["-f", dockerfile] if dockerfile != "Dockerfile"

        # Add tag
        cmd += ["-t", image]

        # Add build args
        build_args.each do |key, value|
          cmd += ["--build-arg", "#{key}=#{value}"]
        end

        # Add build secrets
        secrets.each do |key, value|
          cmd += ["--secret", "id=#{key},env=#{value}"]
        end

        # Add context (must be last)
        cmd << context

        cmd
      end

      # Execute command and capture output
      #
      # @param command [Array<String>] Command to execute
      # @param message [String] Progress message to display
      # @return [Hash] Result with :success, :output, :error
      # @raise [Kamal::Dev::BuildError] if command fails
      def execute_with_output(command, message)
        puts message if message

        result = execute_command(command, show_output: true)

        unless result[:success]
          raise Kamal::Dev::BuildError,
            "Command failed: #{command.join(" ")}\n#{result[:error]}"
        end

        result
      end

      # Execute shell command
      #
      # @param command [Array<String>] Command to execute
      # @param show_output [Boolean] Whether to show command output
      # @return [Hash] Result with :success, :output, :error
      def execute_command(command, show_output: false)
        require "open3"

        output, error, status = Open3.capture3(*command)

        if show_output && !output.empty?
          puts output
        end

        {
          success: status.success?,
          output: output,
          error: error
        }
      rescue => e
        {
          success: false,
          output: "",
          error: e.message
        }
      end
    end
  end
end
