# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kamal::Providers::Base do
  let(:provider) { described_class.new }

  describe "interface methods" do
    describe "#provision_vm" do
      it "raises NotImplementedError" do
        expect { provider.provision_vm({}) }.to raise_error(NotImplementedError)
      end
    end

    describe "#query_status" do
      it "raises NotImplementedError" do
        expect { provider.query_status("vm-123") }.to raise_error(NotImplementedError)
      end
    end

    describe "#destroy_vm" do
      it "raises NotImplementedError" do
        expect { provider.destroy_vm("vm-123") }.to raise_error(NotImplementedError)
      end
    end

    describe "#estimate_cost" do
      it "raises NotImplementedError" do
        expect { provider.estimate_cost({}) }.to raise_error(NotImplementedError)
      end
    end
  end

  describe "exception hierarchy" do
    it "defines ProvisioningError as StandardError subclass" do
      expect(Kamal::Providers::ProvisioningError.superclass).to eq(StandardError)
    end

    it "defines TimeoutError as ProvisioningError subclass" do
      expect(Kamal::Providers::TimeoutError.superclass).to eq(Kamal::Providers::ProvisioningError)
    end

    it "defines QuotaExceededError as ProvisioningError subclass" do
      expect(Kamal::Providers::QuotaExceededError.superclass).to eq(Kamal::Providers::ProvisioningError)
    end

    it "defines AuthenticationError as StandardError subclass" do
      expect(Kamal::Providers::AuthenticationError.superclass).to eq(StandardError)
    end

    it "defines RateLimitError as StandardError subclass" do
      expect(Kamal::Providers::RateLimitError.superclass).to eq(StandardError)
    end
  end

  describe "method signatures and documentation" do
    it "documents provision_vm parameters and return value" do
      # This test ensures the method signature is correct
      expect(described_class.instance_method(:provision_vm).arity).to eq(1)
    end

    it "documents query_status parameters" do
      expect(described_class.instance_method(:query_status).arity).to eq(1)
    end

    it "documents destroy_vm parameters" do
      expect(described_class.instance_method(:destroy_vm).arity).to eq(1)
    end

    it "documents estimate_cost parameters" do
      expect(described_class.instance_method(:estimate_cost).arity).to eq(1)
    end
  end
end
