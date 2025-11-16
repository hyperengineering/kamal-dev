# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "yaml"

RSpec.describe "Kamal Dev Deployment Lifecycle (Integration)", type: :integration do
  # Skip unless integration tests explicitly enabled via ENV
  before(:all) do
    skip "Integration tests disabled. Set INTEGRATION_TESTS=1 to run." unless ENV["INTEGRATION_TESTS"]

    # Verify required credentials are present
    unless ENV["UPCLOUD_USERNAME"] && ENV["UPCLOUD_PASSWORD"]
      skip "Missing UpCloud credentials. Set UPCLOUD_USERNAME and UPCLOUD_PASSWORD."
    end

    # Verify SSH key exists
    ssh_key_path = File.expand_path("~/.ssh/id_rsa.pub")
    skip "SSH public key not found at #{ssh_key_path}" unless File.exist?(ssh_key_path)
  end

  # Test configuration
  let(:test_config_path) { "spec/fixtures/integration/dev.yml" }
  let(:test_state_file) { ".kamal/dev_state_integration_test.yml" }
  let(:service_name) { "kamal-dev-test" }

  # Track provisioned VMs for cleanup
  let(:provisioned_vms) { [] }

  before(:each) do
    # Clean up any existing test state
    FileUtils.rm_f(test_state_file) if File.exist?(test_state_file)

    # Override state file path for tests
    allow_any_instance_of(Kamal::Cli::Dev).to receive(:get_state_manager).and_return(
      Kamal::Dev::StateManager.new(test_state_file)
    )
  end

  after(:each) do
    # Cleanup: Destroy all provisioned VMs
    unless provisioned_vms.empty?
      puts "\n🧹 Cleaning up #{provisioned_vms.size} test VM(s)..."

      provider = Kamal::Providers::Upcloud.new(
        username: ENV["UPCLOUD_USERNAME"],
        password: ENV["UPCLOUD_PASSWORD"]
      )

      provisioned_vms.each do |vm_id|
        provider.destroy_vm(vm_id)
        puts "  ✓ Destroyed VM: #{vm_id}"
      rescue => e
        puts "  ⚠️  Failed to destroy VM #{vm_id}: #{e.message}"
      end
    end

    # Clean up test state file
    FileUtils.rm_f(test_state_file) if File.exist?(test_state_file)
  end

  describe "Full deployment lifecycle" do
    it "provisions VMs, manages state, and cleans up successfully" do
      puts "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts "🧪 Running Integration Test: Deployment Lifecycle"
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      # Phase 1: Deploy 2 containers
      puts "\n📦 Phase 1: Deploying 2 containers..."

      # Note: We can't use Thor CLI directly in tests, so we instantiate the CLI class
      # and stub stdin for confirmation prompts
      cli = Kamal::Cli::Dev.new([], {config: test_config_path, skip_cost_check: true, count: 2})

      # Capture deploy output
      expect {
        # Stub stdin to auto-confirm
        allow($stdin).to receive(:gets).and_return("y\n")

        # Mock provider to track provisioned VMs
        original_provision = nil
        allow_any_instance_of(Kamal::Providers::Upcloud).to receive(:provision_vm) do |provider, config|
          original_provision ||= provider.method(:provision_vm).super_method
          result = original_provision.call(config)
          provisioned_vms << result[:id] # Track for cleanup
          result
        end

        cli.deploy
      }.to output(/Deploying 2 devcontainer workspace/).to_stdout

      # Verify state file was created
      expect(File.exist?(test_state_file)).to be true

      # Load and verify state
      state_manager = Kamal::Dev::StateManager.new(test_state_file)
      deployments = state_manager.list_deployments

      expect(deployments.size).to eq(2)

      # Verify deployment structure
      deployments.each do |name, deployment|
        expect(name).to match(/^kamal-dev-test-\d+$/)
        expect(deployment["vm_id"]).to be_a(String)
        expect(deployment["vm_ip"]).to match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)
        expect(deployment["status"]).to eq("provisioning") # Note: Docker deployment deferred
        expect(deployment["deployed_at"]).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      end

      puts "  ✓ 2 VMs provisioned and tracked in state file"
      puts "  ✓ VM IDs: #{deployments.values.map { |d| d["vm_id"] }.join(", ")}"

      # Phase 2: List deployments
      puts "\n📋 Phase 2: Listing deployments..."

      list_cli = Kamal::Cli::Dev.new([], {config: test_config_path})
      expect {
        list_cli.list
      }.to output(/kamal-dev-test/).to_stdout

      puts "  ✓ List command displays deployments"

      # Phase 3: Stop all containers
      puts "\n⏸️  Phase 3: Stopping all containers..."

      stop_cli = Kamal::Cli::Dev.new([], {config: test_config_path, all: true})
      expect {
        stop_cli.stop
      }.to output(/Stopped 2 container/).to_stdout

      # Verify status updated to "stopped"
      deployments = state_manager.list_deployments
      deployments.each do |_name, deployment|
        expect(deployment["status"]).to eq("stopped")
      end

      puts "  ✓ All containers marked as stopped in state"

      # Phase 4: Remove all deployments
      puts "\n🗑️  Phase 4: Removing all deployments..."

      remove_cli = Kamal::Cli::Dev.new([], {config: test_config_path, all: true, force: true})

      # Stub provider destroy to verify it's called
      destroy_calls = []
      allow_any_instance_of(Kamal::Providers::Upcloud).to receive(:destroy_vm) do |_provider, vm_id|
        destroy_calls << vm_id
        true
      end

      expect {
        remove_cli.remove
      }.to output(/Removed 2 deployment/).to_stdout

      # Note: Current implementation doesn't call destroy_vm yet (TODO in remove command)
      # This will be implemented in integration phase

      # Verify state file cleaned up (should be deleted when empty)
      # Note: StateManager deletes file when last deployment removed
      expect(File.exist?(test_state_file)).to be false

      puts "  ✓ All deployments removed from state"
      puts "  ✓ State file deleted (empty state)"

      # Mark VMs as cleaned up (we destroyed them in the remove step)
      # Note: In current implementation, VMs aren't actually destroyed yet
      # They're cleaned up in after(:each) hook

      puts "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts "✅ Integration Test Passed!"
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    end
  end

  describe "Error handling" do
    it "cleans up VMs on deploy failure" do
      skip "Not implemented yet - TODO for integration phase"
      # TODO: Test VM cleanup when deploy fails mid-process
    end

    it "handles VM provision timeout gracefully" do
      skip "Not implemented yet - TODO for integration phase"
      # TODO: Test timeout scenario with provider mock
    end
  end

  describe "VM provisioning" do
    it "provisions VM with correct configuration" do
      puts "\n🔍 Testing single VM provision with config verification..."

      cli = Kamal::Cli::Dev.new([], {config: test_config_path, skip_cost_check: true, count: 1})

      # Capture provision_vm call to verify config
      provision_config = nil
      allow_any_instance_of(Kamal::Providers::Upcloud).to receive(:provision_vm) do |provider, config|
        provision_config = config
        result = provider.method(:provision_vm).super_method.call(config)
        provisioned_vms << result[:id]
        result
      end

      allow($stdin).to receive(:gets).and_return("y\n")
      cli.deploy

      # Verify provision config
      expect(provision_config).to include(
        zone: "us-nyc1",
        plan: "1xCPU-1GB"
      )
      expect(provision_config[:title]).to match(/kamal-dev-test/)
      expect(provision_config[:ssh_key]).to be_a(String)
      expect(provision_config[:ssh_key]).to start_with("ssh-")

      puts "  ✓ VM provisioned with correct zone, plan, and SSH key"
    end
  end

  describe "Devcontainer configuration" do
    it "loads devcontainer.json and generates correct Docker config" do
      puts "\n🐳 Testing devcontainer.json parsing and Docker config generation..."

      config = Kamal::Configuration::DevConfig.new(test_config_path, validate: true)
      devcontainer = config.devcontainer

      # Verify devcontainer parsed correctly
      expect(devcontainer.image).to eq("ruby:3.2-slim")
      expect(devcontainer.ports).to eq([3000])
      expect(devcontainer.workspace).to eq("/workspace")
      expect(devcontainer.user).to eq("root")
      expect(devcontainer.env).to include("RAILS_ENV" => "test", "TEST_VAR" => "integration_test")

      # Verify Docker command generation
      docker_cmd = devcontainer.docker_run_command(name: "test-container")
      docker_cmd_str = docker_cmd.join(" ")

      expect(docker_cmd_str).to include("docker run -d")
      expect(docker_cmd_str).to include("--name test-container")
      expect(docker_cmd_str).to include("-p 3000:3000")
      expect(docker_cmd_str).to include("-e RAILS_ENV=test")
      expect(docker_cmd_str).to include("-w /workspace")
      expect(docker_cmd_str).to include("--user root")
      expect(docker_cmd_str).to include("--cpus=1")
      expect(docker_cmd_str).to include("--memory=1g")
      expect(docker_cmd_str).to end_with("ruby:3.2-slim")

      puts "  ✓ Devcontainer.json parsed successfully"
      puts "  ✓ Docker command generated with all flags"
    end
  end
end
