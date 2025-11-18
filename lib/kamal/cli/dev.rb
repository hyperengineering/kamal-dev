# frozen_string_literal: true

require "thor"
require "json"
require "yaml"
require "shellwords"
require "net/ssh"
require "sshkit"
require "sshkit/dsl"
require_relative "../dev/config"
require_relative "../dev/devcontainer_parser"
require_relative "../dev/devcontainer"
require_relative "../dev/state_manager"
require_relative "../dev/compose_parser"
require_relative "../dev/registry"
require_relative "../dev/builder"
require_relative "../providers/upcloud"

# Configure SSHKit
SSHKit.config.use_format :pretty
SSHKit.config.output_verbosity = Logger::INFO

module Kamal
  module Cli
    class Dev < Thor
      class_option :config, type: :string, default: "config/dev.yml", desc: "Path to configuration file"

      desc "init", "Generate config/dev.yml template"
      def init
        config_path = "config/dev.yml"

        if File.exist?(config_path)
          print "⚠️  #{config_path} already exists. Overwrite? (y/n): "
          response = $stdin.gets.chomp.downcase
          return unless response == "y" || response == "yes"
        end

        # Create config directory if it doesn't exist
        FileUtils.mkdir_p("config") unless Dir.exist?("config")

        # Copy template to config/dev.yml
        template_path = File.expand_path("../../dev/templates/dev.yml", __FILE__)
        FileUtils.cp(template_path, config_path)

        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts "✅ Created #{config_path}"
        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts
        puts "Next steps:"
        puts
        puts "1. Edit #{config_path} with your cloud provider credentials"
        puts "2. Create .kamal/secrets file with your secrets:"
        puts "   export UPCLOUD_USERNAME=\"your-username\""
        puts "   export UPCLOUD_PASSWORD=\"your-password\""
        puts
        puts "3. Deploy your first workspace:"
        puts "   kamal dev deploy --count 3"
        puts
      end

      desc "build", "Build image from Dockerfile and push to registry"
      option :tag, type: :string, desc: "Custom image tag (defaults to timestamp)"
      option :dockerfile, type: :string, desc: "Path to Dockerfile (overrides config)"
      option :context, type: :string, desc: "Build context path (overrides config)"
      option :skip_push, type: :boolean, default: false, desc: "Skip pushing image to registry"
      def build
        config = load_config
        registry = Kamal::Dev::Registry.new(config)
        builder = Kamal::Dev::Builder.new(config, registry)

        # Check Docker is available
        unless builder.docker_available?
          puts "❌ Error: Docker is required to build images"
          puts "   Please install Docker Desktop or Docker Engine"
          exit 1
        end

        # Check registry credentials
        unless registry.credentials_present?
          username_var = config.registry["username"]
          password_var = config.registry["password"]
          puts "❌ Error: Registry credentials not found"
          puts "   Please set #{username_var} and #{password_var} in .kamal/secrets"
          exit 1
        end

        puts "🔨 Building image for '#{config.service}'"
        puts

        # Authenticate with registry
        puts "Authenticating with registry..."
        begin
          builder.login
          puts "✓ Logged in to #{registry.server}"
        rescue Kamal::Dev::RegistryError => e
          puts "❌ Registry login failed: #{e.message}"
          exit 1
        end
        puts

        # Determine build source from config or options
        # Priority: CLI options > config.build > defaults
        dockerfile = options[:dockerfile]
        context = options[:context]

        # If not provided via CLI, check config
        unless dockerfile && context
          if config.build_source_type == :devcontainer
            # Parse devcontainer.json to get Dockerfile and context
            devcontainer_path = config.build_source_path
            parser = Kamal::Dev::DevcontainerParser.new(devcontainer_path)

            if parser.uses_compose?
              # Extract from compose file
              compose_file = parser.compose_file_path
              compose_parser = Kamal::Dev::ComposeParser.new(compose_file)
              main_service = compose_parser.main_service

              dockerfile ||= compose_parser.service_dockerfile(main_service)
              context ||= compose_parser.service_build_context(main_service)
            else
              # For non-compose devcontainers, this will be implemented later
              raise Kamal::Dev::ConfigurationError, "Non-compose devcontainer builds not yet supported. Use build.dockerfile instead."
            end
          elsif config.build_source_type == :dockerfile
            dockerfile ||= config.build["dockerfile"]
            context ||= config.build_context
          else
            dockerfile ||= "Dockerfile"
            context ||= "."
          end
        end

        tag = options[:tag]

        puts "Building image..."
        puts "  Dockerfile: #{dockerfile}"
        puts "  Context: #{context}"
        puts "  Destination: #{config.image}"
        puts "  Tag: #{tag || "(auto-generated timestamp)"}"
        puts

        begin
          # Use config.image as base name, registry will handle full path
          image_ref = builder.build(
            dockerfile: dockerfile,
            context: context,
            tag: tag,
            image_base: config.image
          )
          puts
          puts "✓ Built image: #{image_ref}"
        rescue Kamal::Dev::BuildError => e
          puts "❌ Build failed: #{e.message}"
          exit 1
        end
        puts

        # Push image (unless --skip-push)
        unless options[:skip_push]
          puts "Pushing image to registry..."
          begin
            builder.push(image_ref)
            puts
            puts "✓ Pushed image: #{image_ref}"
          rescue Kamal::Dev::BuildError => e
            puts "❌ Push failed: #{e.message}"
            exit 1
          end
          puts
        end

        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts "✅ Build complete!"
        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts
        puts "Image: #{image_ref}"
        puts
      end

      desc "push IMAGE", "Push image to registry"
      def push(image_ref = nil)
        config = load_config
        registry = Kamal::Dev::Registry.new(config)
        builder = Kamal::Dev::Builder.new(config, registry)

        # Use provided image or generate from config
        image_ref ||= begin
          puts "No image specified. Using image from config..."
          tag = registry.tag_with_timestamp
          registry.image_tag(config.image, tag)
        end

        # Check Docker is available
        unless builder.docker_available?
          puts "❌ Error: Docker is required to push images"
          puts "   Please install Docker Desktop or Docker Engine"
          exit 1
        end

        # Check registry credentials
        unless registry.credentials_present?
          username_var = config.registry["username"]
          password_var = config.registry["password"]
          puts "❌ Error: Registry credentials not found"
          puts "   Please set #{username_var} and #{password_var} in .kamal/secrets"
          exit 1
        end

        puts "📤 Pushing image '#{image_ref}'"
        puts

        # Authenticate with registry
        puts "Authenticating with registry..."
        begin
          builder.login
          puts "✓ Logged in to #{registry.server}"
        rescue Kamal::Dev::RegistryError => e
          puts "❌ Registry login failed: #{e.message}"
          exit 1
        end
        puts

        # Push image
        puts "Pushing image to registry..."
        begin
          builder.push(image_ref)
          puts
          puts "✓ Pushed image: #{image_ref}"
        rescue Kamal::Dev::BuildError => e
          puts "❌ Push failed: #{e.message}"
          exit 1
        end
        puts

        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts "✅ Push complete!"
        puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        puts
        puts "Image: #{image_ref}"
        puts
      end

      desc "deploy [NAME]", "Deploy devcontainer(s)"
      option :count, type: :numeric, default: 1, desc: "Number of containers to deploy"
      option :from, type: :string, default: ".devcontainer/devcontainer.json", desc: "Path to devcontainer.json"
      option :skip_cost_check, type: :boolean, default: false, desc: "Skip cost confirmation prompt"
      option :skip_build, type: :boolean, default: false, desc: "Skip building image (use existing)"
      option :skip_push, type: :boolean, default: false, desc: "Skip pushing image to registry"
      def deploy(name = nil)
        config = load_config
        count = options[:count] || 1

        puts "🚀 Deploying #{count} devcontainer workspace(s) for '#{config.service}'"
        puts

        # Step 1: Check if using Docker Compose
        # For new format: use build.devcontainer path
        # For old format: use image path (backward compatibility)
        devcontainer_path = config.build_source_path || config.image
        devcontainer_path = options[:from] if options[:from] != ".devcontainer/devcontainer.json" # CLI override

        parser = Kamal::Dev::DevcontainerParser.new(devcontainer_path)
        uses_compose = parser.uses_compose?

        if uses_compose
          deploy_compose_stack(config, count, parser)
        else
          deploy_single_container(config, count)
        end
      end

      no_commands do
        # Deploy Docker Compose stacks to multiple VMs
        #
        # Handles full compose deployment workflow: build, push, transform, deploy
        #
        # @param config [Kamal::Dev::Config] Configuration object
        # @param count [Integer] Number of VMs to deploy
        # @param parser [Kamal::Dev::DevcontainerParser] Devcontainer parser
        def deploy_compose_stack(config, count, parser)
          compose_file = parser.compose_file_path
          unless compose_file && File.exist?(compose_file)
            raise Kamal::Dev::ConfigurationError, "Compose file not found at: #{compose_file || "unknown path"}"
          end

          compose_parser = Kamal::Dev::ComposeParser.new(compose_file)
          registry = Kamal::Dev::Registry.new(config)
          builder = Kamal::Dev::Builder.new(config, registry)

          # Validate main service has build section
          unless compose_parser.main_service
            raise Kamal::Dev::ConfigurationError, "No services found in compose file: #{compose_file}"
          end

          unless options[:skip_build] || compose_parser.has_build_section?(compose_parser.main_service)
            raise Kamal::Dev::ConfigurationError, "Main service '#{compose_parser.main_service}' has no build section. Use --skip-build with existing image."
          end

          puts "✓ Detected Docker Compose deployment"
          puts "  Compose file: #{File.basename(compose_file)}"
          puts "  Main service: #{compose_parser.main_service}"
          puts "  Dependent services: #{compose_parser.dependent_services.join(", ")}" unless compose_parser.dependent_services.empty?
          puts

          # Build and push main service image (unless skipped)
          if options[:skip_build]
            # Use existing image
            tag = options[:tag] || "latest"
            image_ref = registry.image_tag(config.image, tag)
            puts "Using existing image: #{image_ref}"
            puts
          else
            main_service = compose_parser.main_service
            dockerfile = compose_parser.service_dockerfile(main_service)
            context = compose_parser.service_build_context(main_service)

            puts "🔨 Building image for service '#{main_service}'"
            tag = options[:tag] || Time.now.utc.strftime("%Y%m%d%H%M%S")

            begin
              image_ref = builder.build(
                dockerfile: dockerfile,
                context: context,
                tag: tag,
                image_base: config.image
              )
              puts "✓ Built #{image_ref}"
              puts
            rescue => e
              raise Kamal::Dev::BuildError, "Failed to build image: #{e.message}"
            end

            unless options[:skip_push]
              puts "📤 Pushing #{image_ref} to registry..."
              begin
                builder.push(image_ref)
                puts "✓ Pushed #{image_ref}"
                puts
              rescue => e
                raise Kamal::Dev::RegistryError, "Failed to push image: #{e.message}"
              end
            end
          end

          # Transform compose file
          puts "Transforming compose file..."
          transformed_yaml = compose_parser.transform_for_deployment(image_ref)
          puts "✓ Transformed compose.yaml (build → image)"
          puts

          # Estimate cost and get confirmation
          unless options[:skip_cost_check]
            show_cost_estimate(config, count)
            return unless confirm_deployment
          end

          # Provision or reuse VMs
          puts "Provisioning #{count} VM(s)..."
          vms = provision_vms(config, count)
          puts "✓ #{vms.size} VM(s) ready"
          puts

          # Save VM state immediately (before bootstrap) to track orphaned VMs
          # Only save NEW VMs that don't already have state
          state_manager = get_state_manager
          existing_state = state_manager.read_state
          deployments_data = existing_state.fetch("deployments", {})

          vms.each_with_index do |vm, idx|
            vm_name = vm[:name] || "#{config.service}-#{idx + 1}"
            # Skip if this VM already has state (reused VM)
            next if deployments_data.key?(vm_name)

            state_manager.add_compose_deployment(vm_name, vm[:id], vm[:ip], [])
          end

          # Wait for SSH to become available
          puts "Waiting for SSH to become available on #{vms.size} VM(s)..."
          wait_for_ssh(vms.map { |vm| vm[:ip] })
          puts "✓ SSH ready on all VMs"
          puts

          # Bootstrap Docker + Compose
          puts "Bootstrapping Docker and Compose on #{vms.size} VM(s)..."
          bootstrap_docker(vms.map { |vm| vm[:ip] })
          puts "✓ Docker and Compose installed on all VMs"
          puts

          # Login to registry on remote VMs
          puts "Logging into container registry on #{vms.size} VM(s)..."
          login_to_registry(vms.map { |vm| vm[:ip] }, registry)
          puts "✓ Registry login successful"
          puts

          # Deploy compose stacks to each VM
          deployed_vms = []

          vms.each_with_index do |vm, idx|
            vm_name = "#{config.service}-#{idx + 1}"
            puts "Deploying compose stack to #{vm_name} (#{vm[:ip]})..."

            containers = []

            begin
              on(prepare_hosts([vm[:ip]])) do
                # Copy transformed compose file
                upload! StringIO.new(transformed_yaml), "/root/compose.yaml"

                # Deploy stack
                execute "docker", "compose", "-f", "/root/compose.yaml", "up", "-d"

                # Get container information
                containers_json = capture("docker", "compose", "-f", "/root/compose.yaml", "ps", "--format", "json")

                # Parse container information
                containers_json.each_line do |line|
                  next if line.strip.empty?
                  container_data = JSON.parse(line.strip)
                  containers << {
                    name: container_data["Name"],
                    service: container_data["Service"],
                    image: container_data["Image"],
                    status: container_data["State"]
                  }
                rescue JSON::ParserError => e
                  warn "Warning: Failed to parse container JSON: #{e.message}"
                end
              end

              # Save compose deployment to state
              state_manager.add_compose_deployment(vm_name, vm[:id], vm[:ip], containers)
              deployed_vms << vm

              puts "✓ Deployed stack to #{vm_name}"
              puts "  VM: #{vm[:id]}"
              puts "  IP: #{vm[:ip]}"
              puts "  Containers: #{containers.map { |c| c[:service] }.join(", ")}"
              puts
            rescue => e
              warn "❌ Failed to deploy to #{vm_name}: #{e.message}"
              puts "   VM will be cleaned up..."
              # Continue with other VMs
            end
          end

          # Check if any deployments succeeded
          if deployed_vms.empty?
            raise Kamal::Dev::DeploymentError, "All compose stack deployments failed"
          elsif deployed_vms.size < vms.size
            warn "⚠️  Warning: #{vms.size - deployed_vms.size} of #{vms.size} deployments failed"
          end

          puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          puts "✅ Compose deployment complete!"
          puts
          puts "#{count} compose stack(s) deployed and running"
          puts
          puts "View deployments: kamal dev list"
          puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        end

        # Deploy single containers (non-compose workflow)
        #
        # Original deployment flow for direct image deployments
        #
        # @param config [Kamal::Dev::Config] Configuration object
        # @param count [Integer] Number of containers to deploy
        def deploy_single_container(config, count)
          # Load devcontainer
          devcontainer_config = config.devcontainer
          puts "✓ Loaded devcontainer configuration"
          puts "  Image: #{devcontainer_config.image}"
          puts "  Source: #{config.devcontainer_json? ? "devcontainer.json" : "direct image reference"}"
          puts

          # Estimate cost and get confirmation
          unless options[:skip_cost_check]
            show_cost_estimate(config, count)
            return unless confirm_deployment
          end

          # Provision or reuse VMs
          puts "Provisioning #{count} VM(s)..."
          vms = provision_vms(config, count)
          puts "✓ #{vms.size} VM(s) ready"
          puts

          # Save VM state immediately (before bootstrap) to track orphaned VMs
          # Only save NEW VMs that don't already have state
          state_manager = get_state_manager
          existing_state = state_manager.read_state
          deployments_data = existing_state.fetch("deployments", {})
          next_index = find_next_index(deployments_data, config.service)

          vms.each_with_index do |vm, idx|
            # Skip if this VM already has state (reused VM)
            next if vm[:name] && deployments_data.key?(vm[:name])

            container_name = vm[:name] || config.container_name(next_index + idx)
            deployment = {
              name: container_name,
              vm_id: vm[:id],
              vm_ip: vm[:ip],
              container_name: container_name,
              status: "provisioned", # Track VM even if bootstrap fails
              deployed_at: Time.now.utc.iso8601
            }
            state_manager.add_deployment(deployment)
          end

          # Wait for SSH to become available
          puts "Waiting for SSH to become available on #{vms.size} VM(s)..."
          wait_for_ssh(vms.map { |vm| vm[:ip] })
          puts "✓ SSH ready on all VMs"
          puts

          # Bootstrap Docker on VMs
          puts "Bootstrapping Docker on #{vms.size} VM(s)..."
          bootstrap_docker(vms.map { |vm| vm[:ip] })
          puts "✓ Docker installed on all VMs"
          puts

          # Deploy containers
          vms.each_with_index do |vm, idx|
            container_name = config.container_name(next_index + idx)
            docker_command = devcontainer_config.docker_run_command(name: container_name)

            puts "Deploying #{container_name} to #{vm[:ip]}..."
            deploy_container(vm[:ip], docker_command)

            # Update deployment state to running
            state_manager.update_deployment_status(container_name, "running")

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

        # Wait for SSH to become available on VMs with exponential backoff
        #
        # Retries SSH connection with exponential backoff until successful or timeout.
        # Cloud-init VMs may take 30-60s to boot and start SSH daemon.
        #
        # @param ips [Array<String>] VM IP addresses
        # @param max_retries [Integer] Maximum number of retry attempts (default: 12)
        # @param initial_delay [Integer] Initial delay in seconds (default: 5)
        # @raise [RuntimeError] if SSH doesn't become available within timeout
        #
        # Retry schedule (total ~6 minutes):
        # - Attempt 1-3: 5s, 10s, 20s (fast retries for quick boots)
        # - Attempt 4-8: 30s each (steady retries)
        # - Attempt 9-12: 30s each (final attempts)
        def wait_for_ssh(ips, max_retries: 12, initial_delay: 5)
          ips.each do |ip|
            retries = 0
            delay = initial_delay
            connected = false

            while retries < max_retries && !connected
              begin
                # Attempt SSH connection with short timeout
                Net::SSH.start(ip, "root",
                  keys: [File.expand_path(load_config.ssh_key_path).sub(/\.pub$/, "")],
                  timeout: 5,
                  auth_methods: ["publickey"],
                  verify_host_key: :never,
                  non_interactive: true) do |ssh|
                  # Simple command to verify SSH is working
                  ssh.exec!("echo 'SSH ready'")
                  connected = true
                end
              rescue Net::SSH::Exception, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, SocketError => e
                retries += 1
                if retries < max_retries
                  print "."
                  sleep delay
                  # Exponential backoff: 5s -> 10s -> 20s -> 30s (cap at 30s)
                  delay = [delay * 2, 30].min
                else
                  raise "SSH connection to #{ip} failed after #{max_retries} attempts (#{max_retries * initial_delay}s timeout). Error: #{e.message}"
                end
              end
            end

            puts " ready" if connected
          end
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
            # Note: execute with raise_on_non_zero_exit: false returns false on failure
            docker_installed = execute("command", "-v", "docker", raise_on_non_zero_exit: false)

            unless docker_installed && !docker_installed.to_s.strip.empty?
              puts "Installing Docker..."
              execute "curl", "-fsSL", "https://get.docker.com", "|", "sh"
              execute "systemctl", "start", "docker"
              execute "systemctl", "enable", "docker"
            end

            # Check if Docker Compose v2 is installed
            compose_installed = execute("docker", "compose", "version", raise_on_non_zero_exit: false)

            unless compose_installed && !compose_installed.to_s.strip.empty?
              puts "Installing Docker Compose v2..."
              # Install docker-compose-plugin (works on Ubuntu/Debian)
              execute "apt-get", "update", raise_on_non_zero_exit: false
              execute "apt-get", "install", "-y", "docker-compose-plugin", raise_on_non_zero_exit: false

              # Verify installation succeeded
              compose_check = execute("docker", "compose", "version", raise_on_non_zero_exit: false)
              unless compose_check && !compose_check.to_s.strip.empty?
                raise Kamal::Dev::ConfigurationError, "Docker Compose v2 installation failed. Please install manually."
              end
            end
          end
        end

        # Login to container registry on remote VMs
        #
        # Authenticates Docker on remote VMs with the configured registry.
        # Required before pulling private images in compose deployments.
        # Uses --password-stdin for secure password transmission.
        #
        # @param ips [Array<String>] VM IP addresses
        # @param registry [Kamal::Dev::Registry] Registry configuration
        def login_to_registry(ips, registry)
          unless registry.credentials_present?
            puts "⚠️  Warning: Registry credentials not configured, skipping login"
            puts "   Private image pulls may fail without authentication"
            return
          end

          # Debug output
          if ENV["DEBUG"]
            puts "DEBUG: Registry class: #{registry.class}"
            puts "DEBUG: Server: #{registry.server.inspect} (#{registry.server.class})"
            puts "DEBUG: Username: #{registry.username.inspect} (#{registry.username.class})"
            puts "DEBUG: Password length: #{registry.password.to_s.length} (#{registry.password.class})"
          end

          on(prepare_hosts(ips)) do
            # Use --password-stdin for secure password transmission
            # Properly escape shell arguments to avoid injection
            password_escaped = Shellwords.escape(registry.password.to_s)
            username_escaped = Shellwords.escape(registry.username.to_s)
            server_escaped = Shellwords.escape(registry.server.to_s)

            execute "sh", "-c", "echo #{password_escaped} | docker login #{server_escaped} -u #{username_escaped} --password-stdin"
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
            # Note: capture with raise_on_non_zero_exit: false may return false on failure
            running = capture("docker", "ps", "-q", "-f", "name=#{container_name}", raise_on_non_zero_exit: false)
            running = running.to_s.strip if running
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

        # Provision or reuse VMs for deployment
        #
        # Checks state file for existing VMs and reuses them if available.
        # Only provisions NEW VMs if needed to reach desired count.
        #
        # @param config [Kamal::Dev::Config] Deployment configuration
        # @param count [Integer] Number of VMs needed
        # @return [Array<Hash>] Array of VM details, each containing:
        #   - :id [String] VM identifier (UUID)
        #   - :ip [String] Public IP address
        #   - :status [Symbol] VM status (:running, :pending, etc.)
        #
        # @note Reuses existing VMs from state file before provisioning new ones
        # @note Currently provisions VMs sequentially. Batching for count > 5 is TODO.
        def provision_vms(config, count)
          state_manager = get_state_manager
          existing_state = state_manager.read_state
          deployments = existing_state.fetch("deployments", {})

          # Find existing VMs for this service
          existing_vms = deployments.select { |name, data|
            name.start_with?(config.service)
          }.map { |name, data|
            {
              id: data["vm_id"],
              ip: data["vm_ip"],
              status: :running,
              name: name
            }
          }

          if existing_vms.size >= count
            puts "Found #{existing_vms.size} existing VM(s), reusing #{count}"
            return existing_vms.first(count)
          end

          # Need to provision additional VMs
          needed = count - existing_vms.size
          provider = get_provider(config)
          new_vms = []

          puts "Found #{existing_vms.size} existing VM(s), provisioning #{needed} more..." if existing_vms.any?

          needed.times do |i|
            vm_index = existing_vms.size + i + 1
            vm_config = {
              zone: config.provider["zone"],
              plan: config.provider["plan"],
              title: "#{config.service}-vm-#{vm_index}",
              ssh_key: load_ssh_key
            }

            vm = provider.provision_vm(vm_config)
            new_vms << vm

            print "."
          end

          puts # Newline after progress dots

          # Return combination of existing and new VMs
          existing_vms + new_vms
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
          ssh_key_path = File.expand_path(load_config.ssh_key_path)

          unless File.exist?(ssh_key_path)
            puts "❌ SSH public key not found"
            puts
            puts "Expected location: #{ssh_key_path}"
            puts
            puts "To fix this issue, choose one of the following:"
            puts
            puts "Option 1: Generate a new SSH key pair"
            puts "  ssh-keygen -t ed25519 -C \"kamal-dev@#{ENV["USER"]}\" -f ~/.ssh/id_rsa"
            puts "  (Press Enter to accept defaults)"
            puts
            puts "Option 2: Use an existing SSH key"
            puts "  Add to config/dev.yml:"
            puts "  ssh:"
            puts "    key_path: ~/.ssh/id_ed25519.pub  # Path to your public key"
            puts
            puts "Option 3: Copy existing key to default location"
            puts "  cp ~/.ssh/your_existing_key.pub ~/.ssh/id_rsa.pub"
            puts
            exit 1
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
        # Displays deployment information in a human-readable table format.
        # For compose deployments, shows all containers in the stack.
        #
        # @param deployments [Hash] Hash of deployments (name => deployment_data)
        # @return [void]
        #
        # @example Single Container Output
        #   NAME                 IP              STATUS          DEPLOYED AT
        #   ----------------------------------------------------------------------
        #   myapp-dev-1          1.2.3.4         running         2025-11-16T10:00:00Z
        #
        # @example Compose Stack Output
        #   VM: myapp-1          IP: 1.2.3.4     DEPLOYED AT: 2025-11-16T10:00:00Z
        #   ----------------------------------------------------------------------
        #     ├─ app             running         ghcr.io/user/myapp:abc123
        #     └─ postgres        running         postgres:16
        def print_table(deployments)
          state_manager = get_state_manager

          deployments.each do |name, deployment|
            if state_manager.compose_deployment?(name)
              # Compose deployment - show VM header and containers
              puts ""
              puts "VM: #{name.ljust(17)} IP: #{deployment["vm_ip"].ljust(13)} DEPLOYED AT: #{deployment["deployed_at"]}"
              puts "-" * 80

              containers = deployment["containers"]
              containers.each_with_index do |container, idx|
                prefix = (idx == containers.size - 1) ? "  └─" : "  ├─"
                status_indicator = (container["status"] == "running") ? "✓" : "✗"
                puts format(
                  "%s %-15s  %s %-13s  %s",
                  prefix,
                  container["service"],
                  status_indicator,
                  container["status"],
                  container["image"]
                )
              end
            else
              # Single container deployment - original format
              if deployments.values.none? { |d| d["type"] == "compose" }
                # Only show header once for single-container-only list
                if name == deployments.keys.first
                  puts "NAME                 IP              STATUS          DEPLOYED AT"
                  puts "-" * 80
                end
              end

              status = deployment["status"] || "unknown"
              container_name = deployment["container_name"] || name
              puts format(
                "%-20s %-15s %-15s %-20s",
                container_name,
                deployment["vm_ip"],
                status,
                deployment["deployed_at"]
              )
            end
          end

          puts "" if deployments.any?
        end
      end
    end
  end
end
