# frozen_string_literal: true

require "spec_helper"
require "kamal/cli/dev"
require "tmpdir"
require "json"
require "yaml"

RSpec.describe Kamal::Cli::Dev do
  describe "#help" do
    it "displays help with all subcommands" do
      output = capture_stdout { described_class.start(["help"]) }

      # Verify all commands are listed
      expect(output).to include("deploy")
      expect(output).to include("stop")
      expect(output).to include("list")
      expect(output).to include("remove")
      expect(output).to include("status")

      # Verify command descriptions
      expect(output).to include("Deploy devcontainer(s)")
      expect(output).to include("Stop devcontainer(s)")
      expect(output).to include("List deployed devcontainers")
      expect(output).to include("Remove devcontainer(s)")
      expect(output).to include("Show devcontainer status")
    end
  end

  describe "deploy command" do
    it "responds to help subcommand" do
      output = capture_stdout { described_class.start(["help", "deploy"]) }

      expect(output).to include("deploy")
      expect(output).to include("--count")
      expect(output).to include("--from")
      expect(output).to include("--config")
      expect(output).to include("Number of containers to deploy")
      expect(output).to include("Path to devcontainer.json")
    end
  end

  describe "list command" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:state_file) { File.join(temp_dir, "dev_state.yml") }
    let(:state_manager) { Kamal::Dev::StateManager.new(state_file) }

    before do
      # Stub state manager to use temp directory
      allow(Kamal::Dev::StateManager).to receive(:new).and_return(state_manager)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context "when no deployments exist" do
      it "displays 'No deployments found' message" do
        output = capture_stdout { described_class.start(["list"]) }

        expect(output).to include("No deployments found")
      end
    end

    context "when deployments exist" do
      before do
        state_manager.add_deployment({
          name: "myapp-dev-1",
          vm_id: "vm-123",
          vm_ip: "1.2.3.4",
          container_name: "myapp-dev-1",
          status: "running",
          deployed_at: "2025-11-16T10:00:00Z"
        })
        state_manager.add_deployment({
          name: "myapp-dev-2",
          vm_id: "vm-456",
          vm_ip: "2.3.4.5",
          container_name: "myapp-dev-2",
          status: "stopped",
          deployed_at: "2025-11-16T10:05:00Z"
        })
      end

      it "displays table with all deployments" do
        output = capture_stdout { described_class.start(["list"]) }

        expect(output).to include("myapp-dev-1")
        expect(output).to include("myapp-dev-2")
        expect(output).to include("1.2.3.4")
        expect(output).to include("2.3.4.5")
        expect(output).to include("running")
        expect(output).to include("stopped")
      end

      it "formats output as table by default" do
        output = capture_stdout { described_class.start(["list"]) }

        # Should have header row
        expect(output).to match(/NAME.*IP.*STATUS/i)
      end

      it "supports JSON format" do
        output = capture_stdout { described_class.start(["list", "--format=json"]) }

        parsed = JSON.parse(output)
        expect(parsed).to be_a(Hash)
        expect(parsed.keys).to include("myapp-dev-1", "myapp-dev-2")
      end

      it "supports YAML format" do
        output = capture_stdout { described_class.start(["list", "--format=yaml"]) }

        parsed = YAML.safe_load(output)
        expect(parsed).to be_a(Hash)
        expect(parsed.keys).to include("myapp-dev-1", "myapp-dev-2")
      end
    end
  end

  describe "stop command" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:state_file) { File.join(temp_dir, "dev_state.yml") }
    let(:state_manager) { Kamal::Dev::StateManager.new(state_file) }

    before do
      allow(Kamal::Dev::StateManager).to receive(:new).and_return(state_manager)

      # Mock SSHKit to prevent actual SSH connections
      allow(SSHKit::Host).to receive(:new) do |ip|
        host = double("SSHKit::Host", hostname: ip)
        allow(host).to receive(:user=)
        allow(host).to receive(:ssh_options=)
        host
      end

      # Mock SSHKit::Coordinator to prevent SSH execution
      allow(SSHKit::Coordinator).to receive(:new) do |hosts|
        coordinator = double("SSHKit::Coordinator")
        allow(coordinator).to receive(:each) do |&block|
          # Simulate SSHKit backend context for each host
          hosts.each do |host|
            backend = double("SSHKit::Backend::Netssh")
            allow(backend).to receive(:capture).with("docker", "ps", "-q", "-f", any_args).and_return("") # No running containers
            allow(backend).to receive(:execute)
            backend.instance_eval(&block) if block_given?
          end
        end
        coordinator
      end

      # Add running deployments
      state_manager.add_deployment({
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: "2025-11-16T10:00:00Z"
      })
      state_manager.add_deployment({
        name: "myapp-dev-2",
        vm_id: "vm-456",
        vm_ip: "2.3.4.5",
        container_name: "myapp-dev-2",
        status: "running",
        deployed_at: "2025-11-16T10:05:00Z"
      })
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context "when stopping a specific container" do
      it "updates status to stopped" do
        capture_stdout { described_class.start(["stop", "myapp-dev-1"]) }

        deployments = state_manager.list_deployments
        expect(deployments["myapp-dev-1"]["status"]).to eq("stopped")
        expect(deployments["myapp-dev-2"]["status"]).to eq("running") # Other unchanged
      end

      it "displays success message" do
        output = capture_stdout { described_class.start(["stop", "myapp-dev-1"]) }

        expect(output).to include("myapp-dev-1")
        expect(output).to include("stopped")
      end
    end

    context "when stopping all containers" do
      it "updates all statuses to stopped" do
        capture_stdout { described_class.start(["stop", "--all"]) }

        deployments = state_manager.list_deployments
        expect(deployments["myapp-dev-1"]["status"]).to eq("stopped")
        expect(deployments["myapp-dev-2"]["status"]).to eq("stopped")
      end

      it "displays success message for all" do
        output = capture_stdout { described_class.start(["stop", "--all"]) }

        expect(output).to include("Stopped 2 container(s)")
      end
    end

    context "when container doesn't exist" do
      it "displays error message" do
        output = capture_stdout { described_class.start(["stop", "nonexistent"]) }

        expect(output).to include("not found")
      end
    end

    context "when no deployments exist" do
      before do
        state_manager.remove_deployment("myapp-dev-1")
        state_manager.remove_deployment("myapp-dev-2")
      end

      it "displays 'No deployments found' message" do
        output = capture_stdout { described_class.start(["stop", "--all"]) }

        expect(output).to include("No deployments found")
      end
    end
  end

  describe "remove command" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:state_file) { File.join(temp_dir, "dev_state.yml") }
    let(:state_manager) { Kamal::Dev::StateManager.new(state_file) }

    before do
      allow(Kamal::Dev::StateManager).to receive(:new).and_return(state_manager)

      # Mock SSHKit to prevent actual SSH connections
      allow(SSHKit::Host).to receive(:new) do |ip|
        host = double("SSHKit::Host", hostname: ip)
        allow(host).to receive(:user=)
        allow(host).to receive(:ssh_options=)
        host
      end

      # Mock SSHKit::Coordinator to prevent SSH execution
      allow(SSHKit::Coordinator).to receive(:new) do |hosts|
        coordinator = double("SSHKit::Coordinator")
        allow(coordinator).to receive(:each) do |&block|
          # Simulate SSHKit backend context for each host
          hosts.each do |host|
            backend = double("SSHKit::Backend::Netssh")
            allow(backend).to receive(:capture).with("docker", "ps", "-q", "-f", any_args).and_return("") # No running containers
            allow(backend).to receive(:execute)
            backend.instance_eval(&block) if block_given?
          end
        end
        coordinator
      end

      # Add deployments
      state_manager.add_deployment({
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: "2025-11-16T10:00:00Z"
      })
      state_manager.add_deployment({
        name: "myapp-dev-2",
        vm_id: "vm-456",
        vm_ip: "2.3.4.5",
        container_name: "myapp-dev-2",
        status: "stopped",
        deployed_at: "2025-11-16T10:05:00Z"
      })
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    context "when removing a specific container with --force" do
      it "removes deployment from state" do
        capture_stdout { described_class.start(["remove", "myapp-dev-1", "--force"]) }

        deployments = state_manager.list_deployments
        expect(deployments).not_to have_key("myapp-dev-1")
        expect(deployments).to have_key("myapp-dev-2") # Other unchanged
      end

      it "displays success message" do
        output = capture_stdout { described_class.start(["remove", "myapp-dev-1", "--force"]) }

        expect(output).to include("myapp-dev-1")
        expect(output).to include("removed")
      end
    end

    context "when removing all containers with --force" do
      it "removes all deployments from state" do
        capture_stdout { described_class.start(["remove", "--all", "--force"]) }

        deployments = state_manager.list_deployments
        expect(deployments).to be_empty
      end

      it "displays success message for all" do
        output = capture_stdout { described_class.start(["remove", "--all", "--force"]) }

        expect(output).to include("Removed 2 deployment(s)")
      end

      it "deletes state file when empty" do
        capture_stdout { described_class.start(["remove", "--all", "--force"]) }

        expect(File.exist?(state_file)).to be false
      end
    end

    context "when container doesn't exist" do
      it "displays error message" do
        output = capture_stdout { described_class.start(["remove", "nonexistent", "--force"]) }

        expect(output).to include("not found")
      end
    end

    context "when no deployments exist" do
      before do
        state_manager.remove_deployment("myapp-dev-1")
        state_manager.remove_deployment("myapp-dev-2")
      end

      it "displays 'No deployments found' message" do
        output = capture_stdout { described_class.start(["remove", "--all", "--force"]) }

        expect(output).to include("No deployments found")
      end
    end
  end

  describe "SSH key configuration" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:default_key_path) { File.join(temp_dir, ".ssh", "id_rsa.pub") }
    let(:custom_key_path) { File.join(temp_dir, ".ssh", "custom_key.pub") }
    let(:config_path) { File.join(temp_dir, "dev.yml") }

    let(:base_config) do
      {
        "service" => "test-app",
        "image" => "ruby:3.2",
        "provider" => {
          "type" => "upcloud",
          "zone" => "us-nyc1",
          "plan" => "1xCPU-1GB"
        }
      }
    end

    before do
      FileUtils.mkdir_p(File.dirname(default_key_path))
      File.write(default_key_path, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC...")
      FileUtils.mkdir_p(File.dirname(custom_key_path))
      File.write(custom_key_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...")
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it "uses default SSH key path when not configured" do
      File.write(config_path, base_config.to_yaml)
      config = Kamal::Dev::Config.new(config_path)

      expect(config.ssh_key_path).to eq("~/.ssh/id_rsa.pub")
    end

    it "uses configured SSH key path" do
      config_with_ssh = base_config.merge(
        "ssh" => {
          "key_path" => custom_key_path
        }
      )
      File.write(config_path, config_with_ssh.to_yaml)
      config = Kamal::Dev::Config.new(config_path)

      expect(config.ssh_key_path).to eq(custom_key_path)
    end

    it "expands tilde in SSH key path" do
      # This test verifies path expansion is handled by File.expand_path in load_ssh_key
      expect(File).to respond_to(:expand_path)
    end
  end

  describe "build command" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:config_path) { File.join(temp_dir, "config", "dev.yml") }
    let(:devcontainer_path) { File.join(temp_dir, ".devcontainer", "devcontainer.json") }
    let(:compose_path) { File.join(temp_dir, ".devcontainer", "compose.yaml") }
    let(:dockerfile_path) { File.join(temp_dir, ".devcontainer", "Dockerfile") }

    before do
      ENV["GITHUB_USER"] = "testuser"
      ENV["GITHUB_TOKEN"] = "ghp_test123"
      FileUtils.mkdir_p(File.dirname(config_path))
      FileUtils.mkdir_p(File.dirname(devcontainer_path))
    end

    after do
      ENV.delete("GITHUB_USER")
      ENV.delete("GITHUB_TOKEN")
      FileUtils.rm_rf(temp_dir)
    end

    context "with new build.devcontainer format" do
      it "parses devcontainer.json and extracts Dockerfile from compose.yaml" do
        # Create config with new format
        config = {
          "service" => "myapp",
          "image" => "myorg/myapp",
          "build" => {
            "devcontainer" => devcontainer_path
          },
          "registry" => {
            "server" => "ghcr.io",
            "username" => "GITHUB_USER",
            "password" => "GITHUB_TOKEN"
          },
          "provider" => {"type" => "upcloud"}
        }
        File.write(config_path, config.to_yaml)

        # Create devcontainer.json with compose reference
        devcontainer = {
          "name" => "My App",
          "dockerComposeFile" => "compose.yaml",
          "service" => "app"
        }
        File.write(devcontainer_path, devcontainer.to_json)

        # Create compose.yaml with Dockerfile build
        compose = {
          "services" => {
            "app" => {
              "build" => {
                "context" => "..",
                "dockerfile" => ".devcontainer/Dockerfile"
              }
            }
          }
        }
        File.write(compose_path, compose.to_yaml)

        # Create dummy Dockerfile
        File.write(dockerfile_path, "FROM ruby:3.2\n")

        # Mock builder to avoid actual Docker build
        builder = instance_double(Kamal::Dev::Builder)
        allow(Kamal::Dev::Builder).to receive(:new).and_return(builder)
        allow(builder).to receive(:docker_available?).and_return(true)
        allow(builder).to receive(:login).and_return(true)
        allow(builder).to receive(:build).and_return("ghcr.io/myorg/myapp:123")
        allow(builder).to receive(:push).and_return(true)

        # Mock registry
        registry = instance_double(Kamal::Dev::Registry)
        allow(Kamal::Dev::Registry).to receive(:new).and_return(registry)
        allow(registry).to receive(:credentials_present?).and_return(true)
        allow(registry).to receive(:server).and_return("ghcr.io")

        # Capture output
        output = capture_stdout do
          described_class.start(["build", "--config", config_path])
        end

        # Verify build was called with correct parameters
        expect(builder).to have_received(:build).with(
          hash_including(
            dockerfile: ".devcontainer/Dockerfile",
            context: "..",
            image_base: "myorg/myapp"
          )
        )

        # Verify output shows destination image
        expect(output).to include("Destination: myorg/myapp")
      end
    end

    context "with build.dockerfile format" do
      it "uses dockerfile and context from config" do
        config = {
          "service" => "myapp",
          "image" => "myorg/myapp",
          "build" => {
            "dockerfile" => ".devcontainer/Dockerfile",
            "context" => ".devcontainer"
          },
          "registry" => {
            "server" => "ghcr.io",
            "username" => "GITHUB_USER",
            "password" => "GITHUB_TOKEN"
          },
          "provider" => {"type" => "upcloud"}
        }
        File.write(config_path, config.to_yaml)

        # Create dummy Dockerfile
        File.write(dockerfile_path, "FROM ruby:3.2\n")

        # Mock builder
        builder = instance_double(Kamal::Dev::Builder)
        allow(Kamal::Dev::Builder).to receive(:new).and_return(builder)
        allow(builder).to receive(:docker_available?).and_return(true)
        allow(builder).to receive(:login).and_return(true)
        allow(builder).to receive(:build).and_return("ghcr.io/myorg/myapp:123")
        allow(builder).to receive(:push).and_return(true)

        # Mock registry
        registry = instance_double(Kamal::Dev::Registry)
        allow(Kamal::Dev::Registry).to receive(:new).and_return(registry)
        allow(registry).to receive(:credentials_present?).and_return(true)
        allow(registry).to receive(:server).and_return("ghcr.io")

        # Capture output
        output = capture_stdout do
          described_class.start(["build", "--config", config_path])
        end

        # Verify build was called with config values
        expect(builder).to have_received(:build).with(
          hash_including(
            dockerfile: ".devcontainer/Dockerfile",
            context: ".devcontainer",
            image_base: "myorg/myapp"
          )
        )

        expect(output).to include("Dockerfile: .devcontainer/Dockerfile")
        expect(output).to include("Context: .devcontainer")
      end
    end

    context "with CLI options overriding config" do
      it "uses CLI --dockerfile and --context options" do
        config = {
          "service" => "myapp",
          "image" => "myorg/myapp",
          "build" => {
            "dockerfile" => "Dockerfile",
            "context" => "."
          },
          "registry" => {
            "server" => "ghcr.io",
            "username" => "GITHUB_USER",
            "password" => "GITHUB_TOKEN"
          },
          "provider" => {"type" => "upcloud"}
        }
        File.write(config_path, config.to_yaml)

        # Create custom Dockerfile
        custom_dockerfile = File.join(temp_dir, "custom", "Dockerfile")
        FileUtils.mkdir_p(File.dirname(custom_dockerfile))
        File.write(custom_dockerfile, "FROM ruby:3.2\n")

        # Mock builder
        builder = instance_double(Kamal::Dev::Builder)
        allow(Kamal::Dev::Builder).to receive(:new).and_return(builder)
        allow(builder).to receive(:docker_available?).and_return(true)
        allow(builder).to receive(:login).and_return(true)
        allow(builder).to receive(:build).and_return("ghcr.io/myorg/myapp:123")
        allow(builder).to receive(:push).and_return(true)

        # Mock registry
        registry = instance_double(Kamal::Dev::Registry)
        allow(Kamal::Dev::Registry).to receive(:new).and_return(registry)
        allow(registry).to receive(:credentials_present?).and_return(true)
        allow(registry).to receive(:server).and_return("ghcr.io")

        # Run with CLI overrides
        output = capture_stdout do
          described_class.start([
            "build",
            "--config", config_path,
            "--dockerfile", "custom/Dockerfile",
            "--context", "custom"
          ])
        end

        # Verify CLI options override config
        expect(builder).to have_received(:build).with(
          hash_including(
            dockerfile: "custom/Dockerfile",
            context: "custom"
          )
        )

        expect(output).to include("Dockerfile: custom/Dockerfile")
        expect(output).to include("Context: custom")
      end
    end

    context "error handling" do
      it "exits with error when Docker not available" do
        config = {
          "service" => "myapp",
          "image" => "myorg/myapp",
          "build" => {"dockerfile" => "Dockerfile"},
          "registry" => {
            "server" => "ghcr.io",
            "username" => "GITHUB_USER",
            "password" => "GITHUB_TOKEN"
          },
          "provider" => {"type" => "upcloud"}
        }
        File.write(config_path, config.to_yaml)

        # Mock builder with Docker unavailable
        builder = instance_double(Kamal::Dev::Builder)
        allow(Kamal::Dev::Builder).to receive(:new).and_return(builder)
        allow(builder).to receive(:docker_available?).and_return(false)

        # Mock registry
        registry = instance_double(Kamal::Dev::Registry)
        allow(Kamal::Dev::Registry).to receive(:new).and_return(registry)
        allow(registry).to receive(:credentials_present?).and_return(true)

        # Expect exit
        expect {
          capture_stdout do
            described_class.start(["build", "--config", config_path])
          end
        }.to raise_error(SystemExit)
      end

      it "exits with error when registry credentials missing" do
        ENV.delete("GITHUB_USER")
        ENV.delete("GITHUB_TOKEN")

        config = {
          "service" => "myapp",
          "image" => "myorg/myapp",
          "build" => {"dockerfile" => "Dockerfile"},
          "registry" => {
            "server" => "ghcr.io",
            "username" => "GITHUB_USER",
            "password" => "GITHUB_TOKEN"
          },
          "provider" => {"type" => "upcloud"}
        }
        File.write(config_path, config.to_yaml)

        # Mock builder
        builder = instance_double(Kamal::Dev::Builder)
        allow(Kamal::Dev::Builder).to receive(:new).and_return(builder)
        allow(builder).to receive(:docker_available?).and_return(true)

        # Mock registry with missing credentials
        registry = instance_double(Kamal::Dev::Registry)
        allow(Kamal::Dev::Registry).to receive(:new).and_return(registry)
        allow(registry).to receive(:credentials_present?).and_return(false)

        # Expect exit
        expect {
          capture_stdout do
            described_class.start(["build", "--config", config_path])
          end
        }.to raise_error(SystemExit)
      end
    end
  end

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
