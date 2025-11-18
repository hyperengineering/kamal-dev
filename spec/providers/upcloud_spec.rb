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
                    {address: "1.2.3.4", access: "public", family: "IPv4"}
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
                    {address: "1.2.3.5", access: "public", family: "IPv4"}
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

    # Regression test: Bug fixed 2025-11-18
    # Cost estimate was showing blank plan/zone because it expected symbol keys
    # but config.provider returns string keys
    context "with string keys (real usage from config.provider)" do
      let(:string_key_config) do
        {
          "zone" => "de-fra1",
          "plan" => "2xCPU-4GB"
        }
      end

      it "handles string keys correctly" do
        result = provider.estimate_cost(string_key_config)

        expect(result[:plan]).to eq("2xCPU-4GB")
        expect(result[:zone]).to eq("de-fra1")
        expect(result[:warning]).to include("2xCPU-4GB")
        expect(result[:warning]).to include("de-fra1")
      end
    end

    context "with symbol keys (test usage)" do
      it "handles symbol keys correctly" do
        result = provider.estimate_cost(vm_config)

        expect(result[:plan]).to eq("1xCPU-2GB")
        expect(result[:zone]).to eq("us-nyc1")
      end
    end
  end

  # Regression tests for UpCloud cloud-init template requirements
  # Bugs fixed during deployment testing 2025-11-18
  describe "server specification for cloud-init templates" do
    let(:server_spec) do
      provider.send(:build_server_spec, vm_config)
    end

    # Regression test: Bug fixed 2025-11-18
    # UpCloud API returned METADATA_DISABLED_ON_CLOUD-INIT error
    # Cloud-init templates require metadata: "yes" to be set
    it "includes metadata: yes for cloud-init support" do
      expect(server_spec[:server][:metadata]).to eq("yes")
    end

    # Regression test: Bug fixed 2025-11-18
    # UpCloud API returned STORAGE_INVALID error when using template name
    # Must use UUID instead of template title
    it "uses UUID for storage template (not title)" do
      storage = server_spec[:server][:storage_devices][:storage_device].first
      template = storage[:storage]

      # Verify it's a UUID format (8-4-4-4-12 hex digits)
      expect(template).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
    end

    it "uses Ubuntu 24.04 LTS UUID by default" do
      storage = server_spec[:server][:storage_devices][:storage_device].first
      # Verified from UpCloud API 2025-11-18
      expect(storage[:storage]).to eq("01000000-0000-4000-8000-000030240200")
    end

    it "allows custom storage template override" do
      custom_config = vm_config.merge(storage_template: "01000000-0000-4000-8000-000030220200")
      spec = provider.send(:build_server_spec, custom_config)
      storage = spec[:server][:storage_devices][:storage_device].first

      expect(storage[:storage]).to eq("01000000-0000-4000-8000-000030220200")
    end
  end

  # Regression test: Verify constant is in correct format
  describe "DEFAULT_UBUNTU_TEMPLATE constant" do
    it "is a valid UUID format" do
      expect(described_class::DEFAULT_UBUNTU_TEMPLATE)
        .to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
    end

    it "matches Ubuntu 24.04 LTS UUID from UpCloud API" do
      # Verified from spec/fixtures/providers/upcloud/storages-20251118.json
      expect(described_class::DEFAULT_UBUNTU_TEMPLATE).to eq("01000000-0000-4000-8000-000030240200")
    end
  end

  # Regression tests for IPv4 preference over IPv6
  # Bug fixed during deployment testing 2025-11-18
  # VMs were getting IPv6 addresses which aren't universally routable
  describe "IP address extraction priority" do
    let(:server_data_with_both_ips) do
      {
        "ip_addresses" => {
          "ip_address" => [
            {
              "address" => "2a04:3540:1000:310:4c20:1fff:fed9:3693",
              "access" => "public",
              "family" => "IPv6"
            },
            {
              "address" => "94.237.65.123",
              "access" => "public",
              "family" => "IPv4"
            }
          ]
        }
      }
    end

    # Regression test: Bug fixed 2025-11-18
    # Network unreachable error with IPv6 address
    # Many networks don't support IPv6, so prefer IPv4
    it "prefers IPv4 over IPv6 when both are available" do
      ip = provider.send(:extract_ip_address, server_data_with_both_ips)
      expect(ip).to eq("94.237.65.123")
      expect(ip).not_to include(":")
    end

    it "returns IPv4 even when IPv6 is listed first" do
      ip = provider.send(:extract_ip_address, server_data_with_both_ips)
      # Verify it's IPv4 format (no colons)
      expect(ip).to match(/\A\d+\.\d+\.\d+\.\d+\z/)
    end

    context "with only IPv6 available" do
      let(:ipv6_only_data) do
        {
          "ip_addresses" => {
            "ip_address" => [
              {
                "address" => "2a04:3540:1000:310::1",
                "access" => "public",
                "family" => "IPv6"
              }
            ]
          }
        }
      end

      it "falls back to IPv6 when no IPv4 available" do
        ip = provider.send(:extract_ip_address, ipv6_only_data)
        expect(ip).to eq("2a04:3540:1000:310::1")
      end
    end

    context "with mixed access levels" do
      let(:mixed_access_data) do
        {
          "ip_addresses" => {
            "ip_address" => [
              {
                "address" => "10.0.0.5",
                "access" => "private",
                "family" => "IPv4"
              },
              {
                "address" => "94.237.65.200",
                "access" => "public",
                "family" => "IPv4"
              }
            ]
          }
        }
      end

      it "prefers public IPv4 over private IPv4" do
        ip = provider.send(:extract_ip_address, mixed_access_data)
        expect(ip).to eq("94.237.65.200")
      end
    end

    context "with private IPv4 only" do
      let(:private_ipv4_data) do
        {
          "ip_addresses" => {
            "ip_address" => [
              {
                "address" => "10.0.0.5",
                "access" => "private",
                "family" => "IPv4"
              }
            ]
          }
        }
      end

      it "returns private IPv4 when it's the only IPv4 available" do
        ip = provider.send(:extract_ip_address, private_ipv4_data)
        expect(ip).to eq("10.0.0.5")
      end
    end
  end
end
