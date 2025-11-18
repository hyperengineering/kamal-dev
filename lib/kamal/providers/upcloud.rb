# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"
require_relative "base"

module Kamal
  module Providers
    # UpCloud API v1.3 provider implementation
    #
    # Implements VM provisioning, status querying, and cleanup via UpCloud's REST API.
    # Uses Faraday with retry middleware for robust HTTP communication.
    #
    # @example Initialize provider
    #   provider = Kamal::Providers::Upcloud.new(
    #     username: ENV['UPCLOUD_USERNAME'],
    #     password: ENV['UPCLOUD_PASSWORD']
    #   )
    #
    # @example Provision a VM
    #   vm = provider.provision_vm(
    #     zone: 'us-nyc1',
    #     plan: '1xCPU-2GB',
    #     title: 'my-dev-vm',
    #     ssh_key: File.read('~/.ssh/id_rsa.pub')
    #   )
    #   # => { id: 'uuid', ip: '1.2.3.4', status: :running }
    class Upcloud < Base
      API_BASE_URL = "https://api.upcloud.com"
      API_VERSION = "1.3"
      POLLING_INTERVAL = 5 # seconds
      POLLING_TIMEOUT = 120 # seconds

      # UpCloud storage template for Ubuntu 24.04 LTS (latest LTS)
      # Using template UUID (universal across all UpCloud zones)
      # Template type: cloud-init
      # See: https://developers.upcloud.com/1.3/7-templates/
      #
      # Available Ubuntu templates:
      #   - Ubuntu 24.04 LTS (Noble Numbat) - UUID: 01000000-0000-4000-8000-000030240200
      #   - Ubuntu 22.04 LTS (Jammy Jellyfish) - UUID: 01000000-0000-4000-8000-000030220200
      #
      # Note: UUIDs verified from UpCloud API (2025-11-18)
      DEFAULT_UBUNTU_TEMPLATE = "01000000-0000-4000-8000-000030240200"

      # Initialize UpCloud provider with credentials
      #
      # @param username [String] UpCloud API username
      # @param password [String] UpCloud API password
      def initialize(username:, password:)
        @conn = build_connection(username, password)
      end

      # Provision a new VM on UpCloud
      #
      # @param config [Hash] VM configuration
      # @option config [String] :zone Cloud zone (e.g., "us-nyc1")
      # @option config [String] :plan VM plan (e.g., "1xCPU-2GB")
      # @option config [String] :title VM name/title
      # @option config [String] :ssh_key Public SSH key for access
      #
      # @return [Hash] VM details
      # @option return [String] :id VM identifier (UUID)
      # @option return [String] :ip Public IP address
      # @option return [Symbol] :status VM status (:running)
      #
      # @raise [AuthenticationError] if credentials are invalid
      # @raise [QuotaExceededError] if provider quota is exceeded
      # @raise [TimeoutError] if VM doesn't start within timeout
      # @raise [ProvisioningError] for other failures
      def provision_vm(config)
        response = @conn.post("/#{API_VERSION}/server") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = build_server_spec(config).to_json
        end

        server_data = parse_response(response)
        vm_id = server_data["uuid"]
        vm_ip = extract_ip_address(server_data)

        # If already started, return immediately
        return {id: vm_id, ip: vm_ip, status: :running} if server_data["state"] == "started"

        # Otherwise poll until running
        poll_until_running(vm_id)

        {id: vm_id, ip: vm_ip, status: :running}
      rescue Faraday::UnauthorizedError
        raise AuthenticationError, "Invalid UpCloud credentials"
      rescue Faraday::ForbiddenError => e
        handle_forbidden_error(e)
      rescue Faraday::ClientError => e
        raise ProvisioningError, "UpCloud API error: #{e.response[:body]}"
      rescue Faraday::ServerError
        raise ProvisioningError, "UpCloud service unavailable"
      end

      # Query VM status
      #
      # @param vm_id [String] VM identifier (UUID)
      #
      # @return [Symbol] VM status
      #   - :pending - VM is being created or in maintenance
      #   - :running - VM is running
      #   - :failed - VM failed to start
      #   - :stopped - VM is stopped
      #
      # @raise [AuthenticationError] if credentials are invalid
      def query_status(vm_id)
        response = @conn.get("/#{API_VERSION}/server/#{vm_id}")
        server_data = response.body["server"]

        map_state_to_status(server_data["state"])
      rescue Faraday::UnauthorizedError
        raise AuthenticationError, "Invalid UpCloud credentials"
      end

      # Destroy VM and cleanup all associated resources
      #
      # @param vm_id [String] VM identifier (UUID)
      #
      # @return [Boolean] true if successful (idempotent)
      #
      # @raise [AuthenticationError] if credentials are invalid
      def destroy_vm(vm_id)
        @conn.delete("/#{API_VERSION}/server/#{vm_id}") do |req|
          req.params["storages"] = "1" # Delete attached storages
        end

        true
      rescue Faraday::ResourceNotFound
        # Already deleted - idempotent
        true
      rescue Faraday::UnauthorizedError
        raise AuthenticationError, "Invalid UpCloud credentials"
      end

      # Estimate monthly cost for VM configuration
      #
      # Provides generic cost guidance and pricing page link.
      # Real-time pricing queries not implemented in Phase 1.
      #
      # @param config [Hash] VM configuration
      # @option config [String] "zone" Cloud zone (string key)
      # @option config [String] "plan" VM plan (string key)
      #
      # @return [Hash] Cost estimate details
      # @option return [String] :warning User-friendly cost warning
      # @option return [String] :plan VM plan
      # @option return [String] :zone Cloud zone
      # @option return [String] :pricing_url UpCloud pricing page
      def estimate_cost(config)
        plan = config["plan"] || config[:plan]
        zone = config["zone"] || config[:zone]

        {
          warning: "Deploying VMs with plan #{plan} in zone #{zone}. " \
                   "Check pricing for accurate costs.",
          plan: plan,
          zone: zone,
          pricing_url: "https://upcloud.com/pricing"
        }
      end

      private

      # Build Faraday connection with middleware
      def build_connection(username, password)
        Faraday.new(url: API_BASE_URL) do |f|
          # Request middleware (order matters!)
          f.request :authorization, :basic, username, password
          f.request :json # Auto-encode request bodies as JSON

          # Retry middleware with exponential backoff
          f.request :retry,
            max: 3,
            interval: 0.5,
            interval_randomness: 0.5,
            backoff_factor: 2,
            retry_statuses: [429, 500, 502, 503, 504],
            methods: [:get, :post, :delete]

          # Response middleware
          f.response :json, content_type: /\bjson$/ # Auto-parse JSON responses
          f.response :raise_error # Raise on 4xx/5xx responses

          # Adapter (must be last)
          f.adapter Faraday.default_adapter
        end
      end

      # Build UpCloud server specification from config
      def build_server_spec(config)
        # Determine storage template UUID
        # Priority: 1) config override, 2) default Ubuntu 24.04 template
        # Template UUIDs are universal (same across all UpCloud zones)
        storage_template = config[:storage_template] || DEFAULT_UBUNTU_TEMPLATE

        {
          server: {
            zone: config[:zone],
            title: config[:title] || "kamal-dev-vm",
            hostname: "#{config[:title] || "kamal-dev-vm"}.local",
            plan: config[:plan],
            storage_devices: {
              storage_device: [
                {
                  action: "clone",
                  storage: storage_template,
                  title: "#{config[:title]}-disk",
                  size: config[:disk_size] || 25 # GB
                }
              ]
            },
            login_user: {
              username: "root",
              ssh_keys: {
                ssh_key: [config[:ssh_key]]
              }
            }
          }
        }
      end

      # Parse JSON response
      def parse_response(response)
        response.body["server"] || response.body
      end

      # Extract public IP address from server data
      def extract_ip_address(server_data)
        ip_addresses = server_data.dig("ip_addresses", "ip_address") || []
        public_ip = ip_addresses.find { |ip| ip["access"] == "public" }
        public_ip&.fetch("address") || ip_addresses.first&.fetch("address")
      end

      # Poll VM status until running or timeout
      def poll_until_running(vm_id)
        start_time = Time.now

        loop do
          status = query_status(vm_id)

          return if status == :running

          raise ProvisioningError, "VM failed to start" if status == :failed
          raise TimeoutError, "VM provision timeout after #{POLLING_TIMEOUT}s" if Time.now - start_time > POLLING_TIMEOUT

          sleep POLLING_INTERVAL
        end
      end

      # Map UpCloud state to standard status symbol
      def map_state_to_status(state)
        case state
        when "started"
          :running
        when "stopped"
          :stopped
        when "error"
          :failed
        when "maintenance", "pending"
          :pending
        else
          :pending
        end
      end

      # Handle 403 Forbidden errors (quota, credits, etc.)
      def handle_forbidden_error(error)
        body = error.response[:body].to_s

        if body.include?("quota")
          raise QuotaExceededError, "UpCloud quota exceeded"
        elsif body.include?("credit")
          raise ProvisioningError, "Insufficient UpCloud credits"
        else
          raise ProvisioningError, "Access forbidden: #{body}"
        end
      end
    end
  end
end
