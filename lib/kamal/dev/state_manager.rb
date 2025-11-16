# frozen_string_literal: true

require "yaml"
require "fileutils"
require "timeout"

module Kamal
  module Dev
    # Manages deployment state file with file locking for concurrency safety
    #
    # Provides thread-safe read/write operations to `.kamal/dev_state.yml` using
    # File.flock with exclusive locks for writes and shared locks for reads.
    #
    # State file format:
    # ```yaml
    # deployments:
    #   container-name-1:
    #     vm_id: "vm-123"
    #     vm_ip: "1.2.3.4"
    #     container_name: "container-name-1"
    #     status: "running"
    #     deployed_at: "2025-11-16T10:00:00Z"
    # ```
    #
    # @example Basic usage
    #   manager = StateManager.new(".kamal/dev_state.yml")
    #   state = manager.read_state
    #   manager.add_deployment({name: "myapp-dev-1", vm_id: "vm-123", ...})
    class StateManager
      # Lock timeout in seconds
      LOCK_TIMEOUT = 10

      attr_reader :state_file

      # Custom error for lock timeouts
      class LockTimeoutError < StandardError; end

      # Initialize state manager with state file path
      #
      # @param state_file_path [String] Path to state YAML file
      def initialize(state_file_path)
        @state_file = state_file_path
      end

      # Read state with shared lock (multiple readers allowed)
      #
      # @return [Hash] State hash with deployment data
      def read_state
        with_lock(:shared) do |file|
          content = file.read
          return {} if content.empty?
          YAML.safe_load(content, permitted_classes: [Symbol, Time], aliases: true, symbolize_names: false) || {}
        end
      rescue Errno::ENOENT
        {} # File doesn't exist yet
      end

      # Write state with exclusive lock (single writer)
      #
      # @param state [Hash] State data to write
      def write_state(state)
        atomic_write(state)
      end

      # Update state (read-modify-write pattern with exclusive lock)
      #
      # @yield [state] Yields current state for modification
      # @yieldparam state [Hash] Current state hash
      # @yieldreturn [Hash] Modified state hash
      def update_state
        with_lock(:exclusive) do |file|
          file.rewind
          content = file.read
          current_state = if content && !content.empty?
            YAML.safe_load(content, permitted_classes: [Symbol, Time], aliases: true, symbolize_names: false) || {}
          else
            {}
          end

          new_state = yield(current_state)

          atomic_write(new_state)
        end
      end

      # Add a new deployment to state
      #
      # @param deployment [Hash] Deployment data with keys:
      #   - :name [String] Container name (key in deployments hash)
      #   - :vm_id [String] VM identifier
      #   - :vm_ip [String] VM IP address
      #   - :container_name [String] Docker container name
      #   - :status [String] Deployment status
      #   - :deployed_at [String] ISO 8601 timestamp
      def add_deployment(deployment)
        update_state do |state|
          state["deployments"] ||= {}
          state["deployments"][deployment[:name]] = {
            "vm_id" => deployment[:vm_id],
            "vm_ip" => deployment[:vm_ip],
            "container_name" => deployment[:container_name],
            "status" => deployment[:status],
            "deployed_at" => deployment[:deployed_at]
          }
          state
        end
      end

      # Update deployment status
      #
      # @param name [String] Container name
      # @param new_status [String] New status value
      def update_deployment_status(name, new_status)
        update_state do |state|
          if state.dig("deployments", name)
            state["deployments"][name]["status"] = new_status
          end
          state
        end
      end

      # Remove deployment from state
      #
      # @param name [String] Container name
      def remove_deployment(name)
        should_delete_file = false

        update_state do |state|
          state["deployments"]&.delete(name)

          # Mark for deletion if no deployments remain
          if state["deployments"].nil? || state["deployments"].empty?
            should_delete_file = true
          end

          state
        end

        # Delete state file outside of lock
        File.delete(@state_file) if should_delete_file && File.exist?(@state_file)
      end

      # List all deployments
      #
      # @return [Hash] Hash of deployments keyed by container name
      def list_deployments
        state = read_state
        state["deployments"] || {}
      end

      private

      # Acquire lock and execute block
      #
      # @param mode [Symbol] :shared or :exclusive
      # @yield [file] File handle with lock acquired
      def with_lock(mode)
        lock_mode = (mode == :exclusive) ? File::LOCK_EX : File::LOCK_SH

        FileUtils.mkdir_p(File.dirname(@state_file))

        File.open(@state_file, File::RDWR | File::CREAT, 0o644) do |file|
          acquire_lock(file, lock_mode)
          yield(file)
        end
      end

      # Acquire file lock with timeout
      #
      # @param file [File] File handle
      # @param lock_mode [Integer] File::LOCK_SH or File::LOCK_EX
      # @raise [LockTimeoutError] if lock cannot be acquired within timeout
      def acquire_lock(file, lock_mode)
        Timeout.timeout(LOCK_TIMEOUT) do
          file.flock(lock_mode)
        end
      rescue Timeout::Error
        mode_name = (lock_mode == File::LOCK_EX) ? "exclusive" : "shared"
        raise LockTimeoutError, "Could not acquire #{mode_name} lock on state file after #{LOCK_TIMEOUT}s"
      end

      # Atomic write using temp file + rename
      #
      # @param state [Hash] State data to write
      def atomic_write(state)
        FileUtils.mkdir_p(File.dirname(@state_file))

        tmp_file = "#{@state_file}.tmp.#{Process.pid}"

        begin
          File.write(tmp_file, YAML.dump(state))
          File.rename(tmp_file, @state_file) # Atomic on POSIX
        ensure
          File.delete(tmp_file) if File.exist?(tmp_file)
        end
      end
    end
  end
end
