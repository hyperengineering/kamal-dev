# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Kamal::Dev::StateManager do
  let(:temp_dir) { Dir.mktmpdir }
  let(:state_file_path) { File.join(temp_dir, "dev_state.yml") }

  subject(:manager) { described_class.new(state_file_path) }

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe "#initialize" do
    it "accepts a state file path" do
      expect(manager).to be_a(described_class)
      expect(manager.state_file).to eq(state_file_path)
    end
  end

  describe "#read_state" do
    context "when state file exists" do
      before do
        File.write(state_file_path, {
          "deployments" => {
            "myapp-dev-1" => {
              "vm_id" => "vm-123",
              "vm_ip" => "1.2.3.4",
              "container_name" => "myapp-dev-1",
              "status" => "running",
              "deployed_at" => "2025-11-16T10:00:00Z"
            }
          }
        }.to_yaml)
      end

      it "reads and parses the YAML file" do
        state = manager.read_state
        expect(state["deployments"]).to have_key("myapp-dev-1")
        expect(state["deployments"]["myapp-dev-1"]["vm_id"]).to eq("vm-123")
      end

      it "uses shared lock (File::LOCK_SH)" do
        file_double = instance_double(File)
        allow(File).to receive(:open).and_yield(file_double)
        allow(file_double).to receive(:flock)
        allow(file_double).to receive(:read).and_return({deployments: {}}.to_yaml)

        manager.read_state

        expect(file_double).to have_received(:flock).with(File::LOCK_SH)
      end
    end

    context "when state file does not exist" do
      it "returns empty hash" do
        state = manager.read_state
        expect(state).to eq({})
      end

      it "does not raise an error" do
        expect { manager.read_state }.not_to raise_error
      end
    end

    context "when state file is empty" do
      before do
        File.write(state_file_path, "")
      end

      it "returns empty hash" do
        state = manager.read_state
        expect(state).to eq({})
      end
    end
  end

  describe "#write_state" do
    let(:state_data) do
      {
        "deployments" => {
          "myapp-dev-1" => {
            "vm_id" => "vm-123",
            "vm_ip" => "1.2.3.4",
            "container_name" => "myapp-dev-1",
            "status" => "running",
            "deployed_at" => "2025-11-16T10:00:00Z"
          }
        }
      }
    end

    it "writes state to file as YAML" do
      manager.write_state(state_data)

      content = File.read(state_file_path)
      parsed = YAML.safe_load(content)

      expect(parsed["deployments"]).to have_key("myapp-dev-1")
    end

    it "creates parent directory if it doesn't exist" do
      nested_path = File.join(temp_dir, "nested", "dir", "state.yml")
      nested_manager = described_class.new(nested_path)

      expect {
        nested_manager.write_state(state_data)
      }.not_to raise_error

      expect(File.exist?(nested_path)).to be true
    end

    it "uses atomic write (temp file + rename)" do
      manager.write_state(state_data)

      # Verify no .tmp files left behind
      tmp_files = Dir.glob(File.join(temp_dir, "*.tmp*"))
      expect(tmp_files).to be_empty
    end
  end

  describe "#update_state" do
    before do
      File.write(state_file_path, {
        "deployments" => {
          "myapp-dev-1" => {
            "vm_id" => "vm-123",
            "vm_ip" => "1.2.3.4",
            "status" => "running"
          }
        }
      }.to_yaml)
    end

    it "yields current state for modification" do
      manager.update_state do |state|
        expect(state["deployments"]).to have_key("myapp-dev-1")
        state
      end
    end

    it "writes modified state back to file" do
      manager.update_state do |state|
        state["deployments"]["myapp-dev-2"] = {
          vm_id: "vm-456",
          vm_ip: "2.3.4.5",
          status: "running"
        }
        state
      end

      new_state = manager.read_state
      expect(new_state["deployments"]).to have_key("myapp-dev-2")
    end

    it "uses exclusive lock for the entire operation" do
      file_double = instance_double(File)
      allow(File).to receive(:open).and_yield(file_double)
      allow(file_double).to receive(:flock)
      allow(file_double).to receive(:rewind)
      allow(file_double).to receive(:read).and_return({deployments: {}}.to_yaml)
      allow(FileUtils).to receive(:mkdir_p)

      manager.update_state { |state| state }

      expect(file_double).to have_received(:flock).with(File::LOCK_EX)
    end
  end

  describe "#add_deployment" do
    it "adds a new deployment to state" do
      deployment = {
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: Time.now.iso8601
      }

      manager.add_deployment(deployment)

      state = manager.read_state
      expect(state["deployments"]["myapp-dev-1"]).to include(
        "vm_id" => "vm-123",
        "status" => "running"
      )
    end
  end

  describe "#update_deployment_status" do
    before do
      manager.add_deployment({
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: Time.now.iso8601
      })
    end

    it "updates the status of an existing deployment" do
      manager.update_deployment_status("myapp-dev-1", "stopped")

      state = manager.read_state
      expect(state["deployments"]["myapp-dev-1"]["status"]).to eq("stopped")
    end
  end

  describe "#remove_deployment" do
    before do
      manager.add_deployment({
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: Time.now.iso8601
      })
    end

    it "removes a deployment from state" do
      # Add a second deployment so the file doesn't get deleted
      manager.add_deployment({
        name: "myapp-dev-2",
        vm_id: "vm-456",
        vm_ip: "2.3.4.5",
        container_name: "myapp-dev-2",
        status: "running",
        deployed_at: Time.now.iso8601
      })

      manager.remove_deployment("myapp-dev-1")

      state = manager.read_state
      expect(state["deployments"]).not_to have_key("myapp-dev-1")
      expect(state["deployments"]).to have_key("myapp-dev-2") # Second one still exists
    end

    it "deletes state file if no deployments remain" do
      manager.remove_deployment("myapp-dev-1")

      expect(File.exist?(state_file_path)).to be false
    end
  end

  describe "#list_deployments" do
    before do
      manager.add_deployment({
        name: "myapp-dev-1",
        vm_id: "vm-123",
        vm_ip: "1.2.3.4",
        container_name: "myapp-dev-1",
        status: "running",
        deployed_at: Time.now.iso8601
      })
      manager.add_deployment({
        name: "myapp-dev-2",
        vm_id: "vm-456",
        vm_ip: "2.3.4.5",
        container_name: "myapp-dev-2",
        status: "stopped",
        deployed_at: Time.now.iso8601
      })
    end

    it "returns all deployments" do
      deployments = manager.list_deployments

      expect(deployments.size).to eq(2)
      expect(deployments).to have_key("myapp-dev-1")
      expect(deployments).to have_key("myapp-dev-2")
    end
  end
end
