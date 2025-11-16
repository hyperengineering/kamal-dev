# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/config"

RSpec.describe Kamal::Dev::Config, "validation" do
  describe "missing required fields" do
    it "raises error when service is missing" do
      config = {
        "image" => ".devcontainer/devcontainer.json",
        "provider" => {"type" => "upcloud"}
      }

      expect {
        described_class.new(config).validate!
      }.to raise_error(Kamal::Dev::ConfigurationError, /service.*required/i)
    end

    it "raises error when image is missing" do
      config = {
        "service" => "myapp-dev",
        "provider" => {"type" => "upcloud"}
      }

      expect {
        described_class.new(config).validate!
      }.to raise_error(Kamal::Dev::ConfigurationError, /image.*required/i)
    end

    it "raises error when provider is missing" do
      config = {
        "service" => "myapp-dev",
        "image" => ".devcontainer/devcontainer.json"
      }

      expect {
        described_class.new(config).validate!
      }.to raise_error(Kamal::Dev::ConfigurationError, /provider.*required/i)
    end

    it "raises error when provider.type is missing" do
      config = {
        "service" => "myapp-dev",
        "image" => ".devcontainer/devcontainer.json",
        "provider" => {"zone" => "us-nyc1"}
      }

      expect {
        described_class.new(config).validate!
      }.to raise_error(Kamal::Dev::ConfigurationError, /provider\.type.*required/i)
    end
  end

  describe "valid configuration" do
    it "does not raise error for valid minimal config" do
      config = {
        "service" => "myapp-dev",
        "image" => ".devcontainer/devcontainer.json",
        "provider" => {
          "type" => "upcloud",
          "zone" => "us-nyc1"
        }
      }

      expect {
        described_class.new(config).validate!
      }.not_to raise_error
    end

    it "returns self to allow chaining" do
      config = {
        "service" => "myapp-dev",
        "image" => ".devcontainer/devcontainer.json",
        "provider" => {"type" => "upcloud"}
      }

      result = described_class.new(config).validate!
      expect(result).to be_a(described_class)
    end
  end

  describe "validation on initialization with option" do
    it "validates automatically when validate: true option passed" do
      config = {
        "image" => ".devcontainer/devcontainer.json",
        "provider" => {"type" => "upcloud"}
      }

      expect {
        described_class.new(config, validate: true)
      }.to raise_error(Kamal::Dev::ConfigurationError, /service.*required/i)
    end
  end
end
