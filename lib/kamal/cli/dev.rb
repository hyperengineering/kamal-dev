# frozen_string_literal: true

require "thor"
require "json"
require "yaml"
require "sshkit"
require "sshkit/dsl"
require_relative "../dev/config"
require_relative "../dev/devcontainer_parser"
require_relative "../dev/devcontainer"
require_relative "../dev/state_manager"
require_relative "../providers/upcloud"

# Configure SSHKit
SSHKit.config.use_format :pretty
SSHKit.config.output_verbosity = Logger::INFO

module Kamal
  module Cli
    class Dev < Thor
      class_option :config, type: :string, default: "config/dev.yml", desc: "Path to configuration file"

      desc "deploy [NAME]", "Deploy devcontainer(s)"
      option :count, type: :numeric, default: 1, desc: "Number of containers to deploy"
      option :from, type: :string, default: ".devcontainer/devcontainer.json", desc: "Path to devcontainer.json"
      option :skip_cost_check, type: :boolean, default: false, desc: "Skip cost confirmation prompt"
      def deploy(name = nil)
        config = load_config
        count = options[:count] || 1

        puts "🚀 Deploying #{count} devcontainer workspace(s) for '#{config.service}'"
        puts

        # Step 1: Load and parse devcontainer
        devcontainer_config = config.devcontainer
        puts "✓ Loaded devcontainer configuration"
        puts "  Image: #{devcontainer_config.image}"
        puts "  Source: #{config.devcontainer_json? ? "devcontainer.json" : "direct image reference"}"
        puts

        # Step 2: Estimate cost and get confirmation
        unless options[:skip_cost_check]
          show_cost_estimate(config, count)
          return unless confirm_deployment
        end

        # Step 3: Provision VMs
        puts "Provisioning #{count} VM(s)..."
        vms = provision_vms(config, count)
        puts "✓ Provisioned #{vms.size} VM(s)"
        puts

        # Step 4: Bootstrap Docker on VMs
        puts "Bootstrapping Docker on #{vms.size} VM(s)..."
        bootstrap_docker(vms.map { |vm| vm[:ip] })
        puts "✓ Docker installed on all VMs"
        puts

        # Step 5: Generate container names and deploy containers
        state_manager = get_state_manager
        existing_state = state_manager.read_state
        deployments_data = existing_state.fetch("deployments", {})

        next_index = find_next_index(deployments_data, config.service)

        vms.each_with_index do |vm, idx|
          container_name = config.container_name(next_index + idx)
          docker_command = devcontainer_config.docker_run_command(name: container_name)

          # Deploy container via SSH
          puts "Deploying #{container_name} to #{vm[:ip]}..."
          deploy_container(vm[:ip], docker_command)

          # Save deployment state
          deployment = {
            name: container_name,
            vm_id: vm[:id],
            vm_ip: vm[:ip],
            container_name: container_name,
            status: "running",
            deployed_at: Time.now.utc.iso8601
          }

          state_manager.add_deployment(deployment)

          puts "✓ #{container_name}"
          puts "  VM: #{vm[:id]}"
          puts "  IP: #{vm[:ip]}"
          puts "  Status: running"
          puts
        end

        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts "✅ Deployment complete!"
        puts
        puts "#{count} workspace(s) deployed and running"
        puts
        puts "View deployments: kamal dev list"
        puts "Connect via SSH: ssh root@<VM_IP>"
        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      end

      desc "stop [NAME]", "Stop devcontainer(s)"
      option :all, type: :boolean, default: false, desc: "Stop all containers"
      def stop(name = nil)
        state_manager = get_state_manager
        deployments = state_manager.list_deployments

        if deployments.empty?
          puts "No deployments found"
          return
        end

        if options[:all]
          # Stop all containers
          count = 0
          deployments.each do |container_name, deployment|
            puts "Stopping #{container_name} on #{deployment["vm_ip"]}..."
            stop_container(deployment["vm_ip"], container_name)
            state_manager.update_deployment_status(container_name, "stopped")
            count += 1
          end
          puts "Stopped #{count} container(s)"
        elsif name
          # Stop specific container
          unless deployments.key?(name)
            puts "Container '#{name}' not found"
            return
          end

          deployment = deployments[name]
          puts "Stopping #{name} on #{deployment["vm_ip"]}..."
          stop_container(deployment["vm_ip"], name)
          state_manager.update_deployment_status(name, "stopped")
          puts "Container '#{name}' stopped"
        else
          puts "Error: Please specify a container name or use --all flag"
        end
      end

      desc "list", "List deployed devcontainers"
      option :format, type: :string, default: "table", desc: "Output format (table|json|yaml)"
      def list
        state_manager = get_state_manager
        deployments = state_manager.list_deployments

        if deployments.empty?
          puts "No deployments found"
          return
        end

        case options[:format]
        when "json"
          puts JSON.pretty_generate(deployments)
        when "yaml"
          puts YAML.dump(deployments)
        else
          # Table format (default)
          print_table(deployments)
        end
      end

      desc "remove [NAME]", "Remove devcontainer(s) and destroy VMs"
      option :all, type: :boolean, default: false, desc: "Remove all deployments"
      option :force, type: :boolean, default: false, desc: "Skip confirmation prompt"
      def remove(name = nil)
        state_manager = get_state_manager
        deployments = state_manager.list_deployments

        if deployments.empty?
          puts "No deployments found"
          return
        end

        # Load config and provider if available
        provider = nil
        begin
          config = load_config
          provider = get_provider(config)
        rescue => e
          puts "⚠️  Warning: Could not load config (#{e.message}). VMs will not be destroyed."
        end

        if options[:all]
          # Confirmation prompt
          unless options[:force]
            print "⚠️  This will destroy #{deployments.size} VM(s) and remove all containers. Continue? (y/n): "
            response = $stdin.gets.chomp.downcase
            return unless response == "y" || response == "yes"
          end

          # Remove all containers
          count = 0
          deployments.each do |container_name, deployment|
            if provider
              puts "Destroying VM #{deployment["vm_id"]} (#{deployment["vm_ip"]})..."
              begin
                stop_container(deployment["vm_ip"], container_name)
              rescue
                nil
              end
              provider.destroy_vm(deployment["vm_id"])
            end
            state_manager.remove_deployment(container_name)
            count += 1
          end
          puts "Removed #{count} deployment(s)"
        elsif name
          # Remove specific container
          unless deployments.key?(name)
            puts "Container '#{name}' not found"
            return
          end

          deployment = deployments[name]

          # Confirmation prompt
          unless options[:force]
            print "⚠️  This will destroy VM #{deployment["vm_id"]} and remove container '#{name}'. Continue? (y/n): "
            response = $stdin.gets.chomp.downcase
            return unless response == "y" || response == "yes"
          end

          if provider
            puts "Destroying VM #{deployment["vm_id"]} (#{deployment["vm_ip"]})..."
            begin
              stop_container(deployment["vm_ip"], name)
            rescue
              nil
            end
            provider.destroy_vm(deployment["vm_id"])
          end
          state_manager.remove_deployment(name)
          puts "Container '#{name}' removed"
        else
          puts "Error: Please specify a container name or use --all flag"
        end
      end

      desc "status [NAME]", "Show devcontainer status"
      option :all, type: :boolean, default: false, desc: "Show all deployments"
      option :verbose, type: :boolean, default: false, desc: "Include VM details"
      def status(name = nil)
        puts "Status command called"
        # Implementation will be added in later tasks
      end

      no_commands do
        include SSHKit::DSL

        # Load and memoize configuration
        def load_config
          @config ||= begin
            config_path = options[:config] || self.class.class_options[:config].default
            Kamal::Dev::Config.new(config_path, validate: true)
          end
        end

        # Get state manager instance
        def get_state_manager
          @state_manager ||= Kamal::Dev::StateManager.new(".kamal/dev_state.yml")
        end

        # Prepare SSH hosts with credentials
        #
        # Converts IP addresses to SSHKit host objects with SSH credentials configured.
        #
        # @param ips [Array<String>] IP addresses
        # @return [Array<SSHKit::Host>] Configured host objects
        def prepare_hosts(ips)
          Array(ips).map do |ip|
            host = SSHKit::Host.new(ip)
            host.user = ssh_user
            host.ssh_options = ssh_options
            host
          end
        end

        # SSH user for VM connections
        def ssh_user
          "root"  # TODO: Make configurable via config/dev.yml
        end

        # SSH options for connections
        def ssh_options
          {
            keys: [ssh_key_path],
            auth_methods: ["publickey"],
            verify_host_key: :never  # Development VMs, accept any host key
          }
        end

        # SSH key path
        def ssh_key_path
          File.expand_path("~/.ssh/id_rsa")  # TODO: Make configurable
        end

        # Bootstrap Docker on VMs if not already installed
        #
        # Checks if Docker is installed and installs it if missing.
        # Uses official Docker installation script.
        #
        # @param ips [Array<String>] VM IP addresses
        def bootstrap_docker(ips)
          on(prepare_hosts(ips)) do
            # Check if Docker is already installed
            docker_installed = execute("command", "-v", "docker", raise_on_non_zero_exit: false)

            if docker_installed.nil? || docker_installed.empty?
              puts "Installing Docker..."
              execute "curl", "-fsSL", "https://get.docker.com", "|", "sh"
              execute "systemctl", "start", "docker"
              execute "systemctl", "enable", "docker"
            end
          end
        end

        # Deploy container to VM via SSH
        #
        # Executes docker run command on remote VM.
        #
        # @param ip [String] VM IP address
        # @param docker_command [Array<String>] Docker run command array
        def deploy_container(ip, docker_command)
          on(prepare_hosts([ip])) do
            execute(*docker_command)
          end
        end

        # Stop container on VM via SSH
        #
        # @param ip [String] VM IP address
        # @param container_name [String] Container name
        def stop_container(ip, container_name)
          on(prepare_hosts([ip])) do
            # Check if container is running
            running = capture("docker", "ps", "-q", "-f", "name=#{container_name}", raise_on_non_zero_exit: false).strip
            if running && !running.empty?
              execute "docker", "stop", container_name
            end
          end
        end

        # Get cloud provider instance for VM provisioning
        #
        # Currently hardcoded to UpCloud provider. Credentials loaded from ENV variables.
        # Future enhancement will support multiple providers via factory pattern.
        #
        # @param config [Kamal::Dev::Config] Deployment configuration
        # @return [Kamal::Providers::Upcloud] UpCloud provider instance
        # @raise [RuntimeError] if UPCLOUD_USERNAME or UPCLOUD_PASSWORD not set
        #
        # @example
        #   provider = get_provider(config)
        #   vm = provider.provision_vm(zone: "us-nyc1", plan: "1xCPU-2GB", ...)
        def get_provider(config)
          # TODO: Support multiple providers via factory pattern
          # For now, assume UpCloud with credentials from ENV
          username = ENV["UPCLOUD_USERNAME"]
          password = ENV["UPCLOUD_PASSWORD"]

          unless username && password
            raise "Missing UpCloud credentials. Set UPCLOUD_USERNAME and UPCLOUD_PASSWORD environment variables."
          end

          Kamal::Providers::Upcloud.new(username: username, password: password)
        end

        # Display cost estimate and pricing information to user
        #
        # Queries provider for cost estimate and displays formatted output with:
        # - VM plan and zone information
        # - Cost warning message
        # - Link to provider's pricing page
        #
        # @param config [Kamal::Dev::Config] Deployment configuration
        # @param count [Integer] Number of VMs to deploy
        # @return [void]
        def show_cost_estimate(config, count)
          provider = get_provider(config)
          estimate = provider.estimate_cost(config.provider)

          puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          puts "💰 Cost Estimate"
          puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          puts
          puts "Deploying #{count} × #{estimate[:plan]} VMs in #{estimate[:zone]}"
          puts
          puts "⚠️  #{estimate[:warning]}"
          puts
          puts "For accurate pricing, visit: #{estimate[:pricing_url]}"
          puts
          puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          puts
        end

        # Prompt user for deployment confirmation
        #
        # Displays interactive prompt asking user to confirm deployment.
        # Accepts "y" or "yes" (case-insensitive) as confirmation.
        #
        # @return [Boolean] true if user confirmed, false otherwise
        def confirm_deployment
          print "Continue with deployment? (y/n): "
          response = $stdin.gets.chomp.downcase
          response == "y" || response == "yes"
        end

        # Provision VMs via cloud provider
        #
        # Provisions specified number of VMs sequentially, displaying progress dots.
        # Each VM is configured with zone, plan, title, and SSH key from config.
        #
        # @param config [Kamal::Dev::Config] Deployment configuration
        # @param count [Integer] Number of VMs to provision
        # @return [Array<Hash>] Array of VM details, each containing:
        #   - :id [String] VM identifier (UUID)
        #   - :ip [String] Public IP address
        #   - :status [Symbol] VM status (:running, :pending, etc.)
        #
        # @note Currently provisions VMs sequentially. Batching for count > 5 is TODO.
        # @note Displays progress dots during provisioning
        def provision_vms(config, count)
          provider = get_provider(config)
          vms = []

          # TODO: Implement batching for count > 5 (as per tech spec)
          # For now, provision sequentially
          count.times do |i|
            vm_config = {
              zone: config.provider["zone"],
              plan: config.provider["plan"],
              title: "#{config.service}-vm-#{i + 1}",
              ssh_key: load_ssh_key
            }

            vm = provider.provision_vm(vm_config)
            vms << vm

            print "."
          end

          puts # Newline after progress dots
          vms
        end

        # Load SSH public key for VM provisioning
        #
        # Reads SSH public key from configured location (configurable via ssh.key_path
        # in config/dev.yml, defaults to ~/.ssh/id_rsa.pub).
        # Key is injected into provisioned VMs for SSH access.
        #
        # @return [String] SSH public key content
        # @raise [RuntimeError] if SSH key file doesn't exist
        #
        # @note Key must be in OpenSSH format (starts with "ssh-rsa", "ssh-ed25519", etc.)
        def load_ssh_key
          ssh_key_path = File.expand_path(config.ssh_key_path)

          unless File.exist?(ssh_key_path)
            raise "SSH public key not found at #{ssh_key_path}. " \
                  "Configure ssh.key_path in config/dev.yml or generate an SSH key."
          end

          File.read(ssh_key_path).strip
        end

        # Find next available index for container naming
        #
        # Scans existing deployments and determines the next sequential index
        # for container naming. Extracts numeric indices from container names
        # matching the pattern "{service}-{index}".
        #
        # @param deployments [Hash] Hash of existing deployments (name => deployment_data)
        # @param service [String] Service name from config
        # @return [Integer] Next available index (starts at 1 if no existing deployments)
        #
        # @example
        #   # With existing deployments: myapp-1, myapp-2
        #   find_next_index(deployments, "myapp") #=> 3
        #
        #   # With no existing deployments
        #   find_next_index({}, "myapp") #=> 1
        def find_next_index(deployments, service)
          indices = deployments.keys.map do |name|
            # Extract index from pattern like "service-1", "service-2"
            if name =~ /^#{Regexp.escape(service)}-(\d+)$/
              $1.to_i
            end
          end.compact

          indices.empty? ? 1 : indices.max + 1
        end

        # Print deployments in formatted table
        #
        # Displays deployment information in a human-readable table format
        # with columns for NAME, IP, STATUS, and DEPLOYED AT.
        #
        # @param deployments [Hash] Hash of deployments (name => deployment_data)
        # @return [void]
        #
        # @example Output
        #   NAME                 IP              STATUS          DEPLOYED AT
        #   ----------------------------------------------------------------------
        #   myapp-dev-1          1.2.3.4         running         2025-11-16T10:00:00Z
        #   myapp-dev-2          1.2.3.5         running         2025-11-16T10:00:15Z
        def print_table(deployments)
          # Header
          puts "NAME                 IP              STATUS          DEPLOYED AT         "
          puts "-" * 70

          # Rows
          deployments.each do |name, deployment|
            puts format(
              "%-20s %-15s %-15s %-20s",
              name,
              deployment["vm_ip"],
              deployment["status"],
              deployment["deployed_at"]
            )
          end
        end
      end
    end
  end
end
