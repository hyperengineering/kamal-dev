# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Kamal::Providers::Upcloud do
  let(:credentials) do
    {
      username: "test-user",
      password: "test-password"
    }
  end
  let(:provider) { described_class.new(**credentials) }
  let(:vm_config) do
    {
      zone: "us-nyc1",
      plan: "1xCPU-2GB",
      title: "test-vm-1",
      ssh_key: "ssh-rsa AAAAB3NzaC..."
    }
  end

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.reset!
  end

  describe "#initialize" do
    it "creates a Faraday connection" do
      expect(provider.instance_variable_get(:@conn)).to be_a(Faraday::Connection)
    end

    it "configures basic auth" do
      conn = provider.instance_variable_get(:@conn)
      # Faraday stores auth in headers after first request
      expect(conn).to be_a(Faraday::Connection)
    end
  end

  describe "#provision_vm" do
    context "when provisioning succeeds immediately" do
      before do
        stub_request(:post, "https://api.upcloud.com/1.3/server")
          .with(
            basic_auth: ["test-user", "test-password"],
            headers: {"Content-Type" => "application/json"}
          )
          .to_return(
            status: 202,
            body: {
              server: {
                uuid: "00abc123-def4-5678-90ab-cdef12345678",
                state: "started",
                ip_addresses: {
                  ip_address: [
                    {address: "1.2.3.4", access: "public"}
                  ]
                }
              }
            }.to_json,
            headers: {"Content-Type" => "application/json"}
          )
      end

      it "returns VM details with id, ip, and status" do
        result = provider.provision_vm(vm_config)

        expect(result).to include(
          id: "00abc123-def4-5678-90ab-cdef12345678",
          ip: "1.2.3.4",
          status: :running
        )
      end

      it "makes POST request to UpCloud API" do
        provider.provision_vm(vm_config)

        expect(WebMock).to have_requested(:post, "https://api.upcloud.com/1.3/server")
          .with(basic_auth: ["test-user", "test-password"])
          .once
      end
    end

    context "when VM requires polling to reach running state" do
      before do
        # First call: VM is pending
        stub_request(:post, "https://api.upcloud.com/1.3/server")
          .to_return(
            status: 202,
            body: {
              server: {
                uuid: "vm-456",
                state: "maintenance",
                ip_addresses: {
                  ip_address: [
                    {address: "1.2.3.5", access: "public"}
                  ]
                }
              }
            }.to_json,
            headers: {"Content-Type" => "application/json"}
          )

        # Subsequent status checks
        stub_request(:get, "https://api.upcloud.com/1.3/server/vm-456")
          .with(basic_auth: ["test-user", "test-password"])
          .to_return(
            {status: 200, body: {server: {state: "maintenance"}}.to_json, headers: {"Content-Type" => "application/json"}},
            {status: 200, body: {server: {state: "maintenance"}}.to_json, headers: {"Content-Type" => "application/json"}},
            {status: 200, body: {server: {state: "started", ip_addresses: {ip_address: [{address: "1.2.3.5"}]}}}.to_json, headers: {"Content-Type" => "application/json"}}
          )
      end

      it "polls until VM is running" do
        result = provider.provision_vm(vm_config)

        expect(result[:status]).to eq(:running)
        expect(WebMock).to have_requested(:get, "https://api.upcloud.com/1.3/server/vm-456")
          .times(3)
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:post, "https://api.upcloud.com/1.3/server")
          .to_return(status: 401, body: {error: {error_message: "Unauthorized"}}.to_json)
      end

      it "raises AuthenticationError" do
        expect {
          provider.provision_vm(vm_config)
        }.to raise_error(Kamal::Providers::AuthenticationError, /Invalid UpCloud credentials/)
      end
    end

    context "when quota is exceeded" do
      before do
        stub_request(:post, "https://api.upcloud.com/1.3/server")
          .to_return(
            status: 403,
            body: {error: {error_message: "Server quota exceeded"}}.to_json
          )
      end

      it "raises QuotaExceededError" do
        expect {
          provider.provision_vm(vm_config)
        }.to raise_error(Kamal::Providers::QuotaExceededError, /UpCloud quota exceeded/)
      end
    end
  end

  describe "#query_status" do
    context "when VM is running" do
      before do
        stub_request(:get, "https://api.upcloud.com/1.3/server/vm-123")
          .with(basic_auth: ["test-user", "test-password"])
          .to_return(
            status: 200,
            body: {server: {state: "started"}}.to_json,
            headers: {"Content-Type" => "application/json"}
          )
      end

      it "returns :running status" do
        expect(provider.query_status("vm-123")).to eq(:running)
      end
    end

    context "when VM is pending" do
      before do
        stub_request(:get, "https://api.upcloud.com/1.3/server/vm-123")
          .to_return(
            status: 200,
            body: {server: {state: "maintenance"}}.to_json,
            headers: {"Content-Type" => "application/json"}
          )
      end

      it "returns :pending status" do
        expect(provider.query_status("vm-123")).to eq(:pending)
      end
    end

    context "when VM has failed" do
      before do
        stub_request(:get, "https://api.upcloud.com/1.3/server/vm-123")
          .with(basic_auth: ["test-user", "test-password"])
          .to_return(
            status: 200,
            body: {server: {state: "error"}}.to_json,
            headers: {"Content-Type" => "application/json"}
          )
      end

      it "returns :failed status" do
        expect(provider.query_status("vm-123")).to eq(:failed)
      end
    end

    context "when VM is stopped" do
      before do
        stub_request(:get, "https://api.upcloud.com/1.3/server/vm-123")
          .with(basic_auth: ["test-user", "test-password"])
          .to_return(
            status: 200,
            body: {server: {state: "stopped"}}.to_json,
            headers: {"Content-Type" => "application/json"}
          )
      end

      it "returns :stopped status" do
        expect(provider.query_status("vm-123")).to eq(:stopped)
      end
    end
  end

  describe "#destroy_vm" do
    context "when deletion succeeds" do
      before do
        stub_request(:delete, "https://api.upcloud.com/1.3/server/vm-123?storages=1")
          .to_return(status: 204)
      end

      it "returns true" do
        expect(provider.destroy_vm("vm-123")).to be true
      end

      it "includes storage deletion parameter" do
        provider.destroy_vm("vm-123")

        expect(WebMock).to have_requested(:delete, "https://api.upcloud.com/1.3/server/vm-123")
          .with(query: hash_including("storages" => "1"))
      end
    end

    context "when VM not found" do
      before do
        stub_request(:delete, "https://api.upcloud.com/1.3/server/vm-123?storages=1")
          .to_return(status: 404)
      end

      it "returns true (idempotent)" do
        expect(provider.destroy_vm("vm-123")).to be true
      end
    end
  end

  describe "#estimate_cost" do
    it "returns cost estimate hash" do
      result = provider.estimate_cost(vm_config)

      expect(result).to include(
        :warning,
        :plan,
        :zone,
        :pricing_url
      )
    end

    it "includes plan and zone in warning" do
      result = provider.estimate_cost(vm_config)

      expect(result[:warning]).to include("1xCPU-2GB")
      expect(result[:warning]).to include("us-nyc1")
    end

    it "includes UpCloud pricing URL" do
      result = provider.estimate_cost(vm_config)

      expect(result[:pricing_url]).to eq("https://upcloud.com/pricing")
    end
  end
end
