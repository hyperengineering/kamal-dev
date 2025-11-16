# frozen_string_literal: true

module Kamal
  module Dev
    # Represents a single devcontainer instance with its parsed configuration
    #
    # Provides methods to access Docker configuration and generate Docker run commands.
    #
    # @example Creating a devcontainer
    #   config = {
    #     image: "ruby:3.2",
    #     ports: [3000, 5432],
    #     mounts: [{source: "gem-cache", target: "/usr/local/bundle", type: "volume"}],
    #     env: {"RAILS_ENV" => "development"},
    #     options: ["--cpus=2", "--memory=4g"],
    #     user: "vscode",
    #     workspace: "/workspace"
    #   }
    #   devcontainer = Devcontainer.new(config)
    #   command = devcontainer.docker_run_command(name: "myapp-dev-1")
    class Devcontainer
      attr_reader :image, :ports, :mounts, :env, :options, :user, :workspace, :secrets

      # Initialize devcontainer with parsed configuration
      #
      # @param config [Hash] Parsed configuration hash with keys:
      #   - :image [String] Docker image name
      #   - :ports [Array<Integer>] Port mappings
      #   - :mounts [Array<Hash>] Volume/bind mounts
      #   - :env [Hash] Environment variables
      #   - :options [Array<String>] Docker run options
      #   - :user [String, nil] Remote user
      #   - :workspace [String, nil] Workspace folder path
      #   - :secrets [Hash, nil] Base64-encoded secrets (optional)
      def initialize(config)
        @image = config[:image]
        @ports = config[:ports] || []
        @mounts = config[:mounts] || []
        @env = config[:env] || {}
        @options = config[:options] || []
        @user = config[:user]
        @workspace = config[:workspace]
        @secrets = config[:secrets] || {}
      end

      # Generate Docker run flags from configuration
      #
      # @return [Array<String>] Array of Docker flags and their values
      def docker_run_flags
        flags = []

        # Port mappings (-p HOST:CONTAINER)
        @ports.each do |port|
          flags << "-p"
          flags << "#{port}:#{port}"
        end

        # Volume mounts (-v SOURCE:TARGET)
        @mounts.each do |mount|
          flags << "-v"
          flags << "#{mount[:source]}:#{mount[:target]}"
        end

        # Environment variables (-e KEY=VALUE)
        @env.each do |key, value|
          flags << "-e"
          flags << "#{key}=#{value}"
        end

        # Secrets (Base64-encoded) (-e KEY_B64=encoded_value)
        @secrets.each do |key, encoded_value|
          flags << "-e"
          flags << "#{key}_B64=#{encoded_value}"
        end

        # Docker run options (--cpus=2, --memory=4g, etc.)
        flags.concat(@options)

        # Remote user (--user USER)
        if @user
          flags << "--user"
          flags << @user
        end

        # Workspace folder (-w /workspace)
        if @workspace
          flags << "-w"
          flags << @workspace
        end

        flags
      end

      # Generate full Docker run command array
      #
      # @param name [String] Container name
      # @return [Array<String>] Full docker run command with all flags
      #
      # @example
      #   devcontainer.docker_run_command(name: "myapp-dev-1")
      #   #=> ["docker", "run", "-d", "--name", "myapp-dev-1", "-p", "3000:3000", ..., "ruby:3.2"]
      def docker_run_command(name:)
        command = ["docker", "run"]

        # Run in detached mode
        command << "-d"

        # Container name
        command << "--name"
        command << name

        # Add all flags
        command.concat(docker_run_flags)

        # Image must be last
        command << @image

        command
      end
    end
  end
end
