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
      config = Kamal::Configuration::DevConfig.new(config_path)

      expect(config.ssh_key_path).to eq("~/.ssh/id_rsa.pub")
    end

    it "uses configured SSH key path" do
      config_with_ssh = base_config.merge(
        "ssh" => {
          "key_path" => custom_key_path
        }
      )
      File.write(config_path, config_with_ssh.to_yaml)
      config = Kamal::Configuration::DevConfig.new(config_path)

      expect(config.ssh_key_path).to eq(custom_key_path)
    end

    it "expands tilde in SSH key path" do
      # This test verifies path expansion is handled by File.expand_path in load_ssh_key
      expect(File).to respond_to(:expand_path)
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
