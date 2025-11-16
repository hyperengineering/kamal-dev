# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/config"

RSpec.describe Kamal::Dev::Config, "naming" do
  let(:base_config) do
    {
      "service" => "myapp-dev",
      "image" => ".devcontainer/devcontainer.json",
      "provider" => {"type" => "upcloud"}
    }
  end

  describe "#container_name" do
    it "generates default name pattern {service}-{index}" do
      config = described_class.new(base_config)

      expect(config.container_name(1)).to eq("myapp-dev-1")
      expect(config.container_name(2)).to eq("myapp-dev-2")
      expect(config.container_name(10)).to eq("myapp-dev-10")
    end

    it "uses custom naming pattern from config" do
      custom_config = base_config.merge(
        "naming" => {
          "pattern" => "dev-{service}-{index}"
        }
      )
      config = described_class.new(custom_config)

      expect(config.container_name(1)).to eq("dev-myapp-dev-1")
      expect(config.container_name(5)).to eq("dev-myapp-dev-5")
    end

    it "supports zero-padded indexes" do
      custom_config = base_config.merge(
        "naming" => {
          "pattern" => "{service}-{index:03}"
        }
      )
      config = described_class.new(custom_config)

      expect(config.container_name(1)).to eq("myapp-dev-001")
      expect(config.container_name(42)).to eq("myapp-dev-042")
      expect(config.container_name(999)).to eq("myapp-dev-999")
    end

    it "supports custom prefix" do
      custom_config = base_config.merge(
        "naming" => {
          "pattern" => "worker-{index}"
        }
      )
      config = described_class.new(custom_config)

      expect(config.container_name(1)).to eq("worker-1")
    end
  end

  describe "#naming_pattern" do
    it "returns default pattern when not specified" do
      config = described_class.new(base_config)
      expect(config.naming_pattern).to eq("{service}-{index}")
    end

    it "returns custom pattern from config" do
      custom_config = base_config.merge(
        "naming" => {"pattern" => "custom-{service}-{index}"}
      )
      config = described_class.new(custom_config)

      expect(config.naming_pattern).to eq("custom-{service}-{index}")
    end
  end
end
