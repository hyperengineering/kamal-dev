# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kamal::Providers, ".for" do
  describe "factory method" do
    context "when provider type is 'upcloud'" do
      let(:config) do
        {
          "type" => "upcloud",
          "username" => "test-user",
          "password" => "test-pass"
        }
      end

      it "returns an Upcloud provider instance" do
        provider = described_class.for(config)
        expect(provider).to be_a(Kamal::Providers::Upcloud)
      end

      it "initializes provider with correct credentials" do
        provider = described_class.for(config)
        # Verify credentials are passed by checking connection exists
        expect(provider.instance_variable_get(:@conn)).to be_a(Faraday::Connection)
      end
    end

    context "when provider type uses symbol keys" do
      let(:config) do
        {
          type: "upcloud",
          username: "test-user",
          password: "test-pass"
        }
      end

      it "handles symbol keys correctly" do
        provider = described_class.for(config)
        expect(provider).to be_a(Kamal::Providers::Upcloud)
      end
    end

    context "when provider type is capitalized" do
      let(:config) do
        {
          "type" => "UpCloud",
          "username" => "test-user",
          "password" => "test-pass"
        }
      end

      it "handles case-insensitive provider types" do
        provider = described_class.for(config)
        expect(provider).to be_a(Kamal::Providers::Upcloud)
      end
    end

    context "when provider type is unknown" do
      let(:config) do
        {
          "type" => "unknown-provider",
          "username" => "test-user",
          "password" => "test-pass"
        }
      end

      it "raises ConfigurationError" do
        expect {
          described_class.for(config)
        }.to raise_error(Kamal::Dev::ConfigurationError, /Unknown provider type/)
      end
    end

    context "when provider type is missing" do
      let(:config) do
        {
          "username" => "test-user",
          "password" => "test-pass"
        }
      end

      it "raises ConfigurationError" do
        expect {
          described_class.for(config)
        }.to raise_error(Kamal::Dev::ConfigurationError, /Unknown provider type/)
      end
    end
  end
end
