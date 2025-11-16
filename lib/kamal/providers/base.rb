# frozen_string_literal: true

module Kamal
  module Providers
    # Custom exception hierarchy for provider errors
    class ProvisioningError < StandardError; end
    class TimeoutError < ProvisioningError; end
    class QuotaExceededError < ProvisioningError; end
    class AuthenticationError < StandardError; end
    class RateLimitError < StandardError; end

    # Factory method to instantiate the appropriate provider
    #
    # @param config [Hash] Provider configuration including type and credentials
    # @option config [String] "type" Provider type (e.g., "upcloud")
    # @option config [String] "username" Provider API username (provider-specific)
    # @option config [String] "password" Provider API password (provider-specific)
    #
    # @return [Kamal::Providers::Base] Provider instance
    #
    # @raise [Kamal::Dev::ConfigurationError] if provider type is unknown
    #
    # @example
    #   provider = Kamal::Providers.for({
    #     "type" => "upcloud",
    #     "username" => ENV["UPCLOUD_USERNAME"],
    #     "password" => ENV["UPCLOUD_PASSWORD"]
    #   })
    def self.for(config)
      type = config["type"] || config[:type]

      case type&.to_s&.downcase
      when "upcloud"
        require_relative "upcloud" unless defined?(Upcloud)
        Upcloud.new(
          username: config["username"] || config[:username],
          password: config["password"] || config[:password]
        )
      else
        raise Kamal::Dev::ConfigurationError, "Unknown provider type: #{type.inspect}"
      end
    end

    # Abstract base class defining the provider adapter interface
    # All cloud provider implementations must inherit from this class
    # and implement the required methods.
    #
    # Example implementation:
    #   class MyProvider < Kamal::Providers::Base
    #     def provision_vm(config)
    #       # Implementation here
    #     end
    #   end
    class Base
      # Provision a new VM
      #
      # @param config [Hash] VM configuration
      #   @option config [String] :zone Cloud zone (e.g., "us-nyc1")
      #   @option config [String] :plan VM plan/size (e.g., "1xCPU-2GB")
      #   @option config [String] :ssh_key Public SSH key for access
      #   @option config [String] :title VM name/title
      #
      # @return [Hash] VM details
      #   @option return [String] :id VM identifier
      #   @option return [String] :ip Public IP address
      #   @option return [Symbol] :status VM status (:pending, :running, :failed)
      #
      # @raise [AuthenticationError] if credentials are invalid
      #   @raise [QuotaExceededError] if provider quota is exceeded
      #   @raise [TimeoutError] if VM doesn't start within timeout period
      #   @raise [ProvisioningError] for other provisioning failures
      def provision_vm(config)
        raise NotImplementedError, "#{self.class}#provision_vm must be implemented"
      end

      # Query VM status
      #
      # @param vm_id [String] VM identifier
      #
      # @return [Symbol] VM status
      #   - :pending - VM is being created
      #   - :running - VM is running
      #   - :failed - VM failed to start
      #   - :stopped - VM is stopped
      #
      # @raise [AuthenticationError] if credentials are invalid
      def query_status(vm_id)
        raise NotImplementedError, "#{self.class}#query_status must be implemented"
      end

      # Destroy VM and cleanup all associated resources
      #
      # @param vm_id [String] VM identifier
      #
      # @return [Boolean] true if successful, false otherwise
      #
      # @raise [AuthenticationError] if credentials are invalid
      def destroy_vm(vm_id)
        raise NotImplementedError, "#{self.class}#destroy_vm must be implemented"
      end

      # Estimate monthly cost for VM configuration
      #
      # This provides generic cost guidance and pricing page link.
      # Real-time pricing queries are not implemented in Phase 1.
      #
      # @param config [Hash] VM configuration
      #   @option config [String] :zone Cloud zone
      #   @option config [String] :plan VM plan/size
      #
      # @return [Hash] Cost estimate details
      #   @option return [String] :warning User-friendly cost warning message
      #   @option return [String] :plan VM plan being estimated
      #   @option return [String] :zone Cloud zone
      #   @option return [String] :pricing_url URL to provider's pricing page
      def estimate_cost(config)
        raise NotImplementedError, "#{self.class}#estimate_cost must be implemented"
      end
    end
  end
end
