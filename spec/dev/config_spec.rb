# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/config"
require "tmpdir"
require "fileutils"

RSpec.describe Kamal::Dev::Config do
  let(:config_dir) { Dir.mktmpdir }
  let(:config_path) { File.join(config_dir, "dev.yml") }

  after do
    FileUtils.rm_rf(config_dir)
  end

  let(:valid_config_hash) do
    {
      "service" => "myapp-dev",
      "image" => ".devcontainer/devcontainer.json",
      "provider" => {
        "type" => "upcloud",
        "zone" => "us-nyc1",
        "plan" => "1xCPU-2GB"
      },
      "defaults" => {
        "cpus" => 2,
        "memory" => "4g"
      },
      "vms" => {
        "count" => 5
      }
    }
  end

  describe "#initialize" do
    it "loads config from valid YAML file path" do
      File.write(config_path, valid_config_hash.to_yaml)
      config = described_class.new(config_path)

      expect(config.service).to eq("myapp-dev")
      expect(config.image).to eq(".devcontainer/devcontainer.json")
    end

    it "accepts a config hash directly" do
      config = described_class.new(valid_config_hash)

      expect(config.service).to eq("myapp-dev")
      expect(config.image).to eq(".devcontainer/devcontainer.json")
    end
  end

  describe "#service" do
    it "returns the service name" do
      config = described_class.new(valid_config_hash)
      expect(config.service).to eq("myapp-dev")
    end
  end

  describe "#image" do
    it "returns the image reference" do
      config = described_class.new(valid_config_hash)
      expect(config.image).to eq(".devcontainer/devcontainer.json")
    end
  end

  describe "#provider" do
    it "returns the provider configuration hash" do
      config = described_class.new(valid_config_hash)
      provider = config.provider

      expect(provider["type"]).to eq("upcloud")
      expect(provider["zone"]).to eq("us-nyc1")
      expect(provider["plan"]).to eq("1xCPU-2GB")
    end
  end

  describe "#defaults" do
    it "returns defaults configuration hash" do
      config = described_class.new(valid_config_hash)
      defaults = config.defaults

      expect(defaults["cpus"]).to eq(2)
      expect(defaults["memory"]).to eq("4g")
    end
  end

  describe "#vms" do
    it "returns vms configuration hash" do
      config = described_class.new(valid_config_hash)
      vms = config.vms

      expect(vms["count"]).to eq(5)
    end
  end

  describe "#vm_count" do
    it "returns the number of VMs from vms.count" do
      config = described_class.new(valid_config_hash)
      expect(config.vm_count).to eq(5)
    end

    it "defaults to 1 when vms.count not specified" do
      minimal_config = valid_config_hash.dup
      minimal_config.delete("vms")
      config = described_class.new(minimal_config)

      expect(config.vm_count).to eq(1)
    end
  end

  describe "#container_name" do
    it "generates valid container name with default pattern" do
      config = described_class.new(valid_config_hash)
      name = config.container_name(1)

      expect(name).to eq("myapp-dev-1")
    end

    it "validates container name against Docker naming rules" do
      config = described_class.new(valid_config_hash)

      # Valid names should not raise
      expect { config.container_name(1) }.not_to raise_error
    end

    it "rejects container names starting with invalid characters" do
      invalid_config = valid_config_hash.merge("service" => "-invalid")
      config = described_class.new(invalid_config)

      expect {
        config.container_name(1)
      }.to raise_error(Kamal::Dev::ConfigurationError, /Container name.*invalid.*must start with a letter or number/)
    end

    it "rejects container names with invalid characters" do
      invalid_config = valid_config_hash.merge("service" => "my@app")
      config = described_class.new(invalid_config)

      expect {
        config.container_name(1)
      }.to raise_error(Kamal::Dev::ConfigurationError, /Container name.*invalid.*contain only/)
    end

    it "accepts container names with allowed special characters" do
      valid_special_config = valid_config_hash.merge("service" => "my-app_v1.0")
      config = described_class.new(valid_special_config)

      expect { config.container_name(1) }.not_to raise_error
      expect(config.container_name(1)).to eq("my-app_v1.0-1")
    end
  end

  describe "#ssh_key_path" do
    it "returns default SSH key path when not configured" do
      config = described_class.new(valid_config_hash)

      expect(config.ssh_key_path).to eq("~/.ssh/id_rsa.pub")
    end

    it "returns configured SSH key path" do
      config_with_ssh = valid_config_hash.merge(
        "ssh" => {
          "key_path" => "~/.ssh/custom_key.pub"
        }
      )
      config = described_class.new(config_with_ssh)

      expect(config.ssh_key_path).to eq("~/.ssh/custom_key.pub")
    end

    it "supports absolute paths" do
      config_with_ssh = valid_config_hash.merge(
        "ssh" => {
          "key_path" => "/home/user/.ssh/id_ed25519.pub"
        }
      )
      config = described_class.new(config_with_ssh)

      expect(config.ssh_key_path).to eq("/home/user/.ssh/id_ed25519.pub")
    end
  end

  describe "#registry" do
    it "returns empty hash when registry not configured" do
      config = described_class.new(valid_config_hash)
      expect(config.registry).to eq({})
    end

    it "returns registry configuration when configured" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {
          "server" => "ghcr.io",
          "username" => "GITHUB_USER",
          "password" => "GITHUB_TOKEN"
        }
      )
      config = described_class.new(config_with_registry)

      registry = config.registry
      expect(registry["server"]).to eq("ghcr.io")
      expect(registry["username"]).to eq("GITHUB_USER")
      expect(registry["password"]).to eq("GITHUB_TOKEN")
    end
  end

  describe "#registry_server" do
    it "defaults to ghcr.io when not configured" do
      config = described_class.new(valid_config_hash)
      expect(config.registry_server).to eq("ghcr.io")
    end

    it "returns configured registry server" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {"server" => "hub.docker.com"}
      )
      config = described_class.new(config_with_registry)

      expect(config.registry_server).to eq("hub.docker.com")
    end
  end

  describe "#registry_username" do
    it "returns nil when username_env not configured" do
      config = described_class.new(valid_config_hash)
      expect(config.registry_username).to be_nil
    end

    it "loads username from environment variable" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {"username" => "GITHUB_USER"}
      )
      config = described_class.new(config_with_registry)

      ENV["GITHUB_USER"] = "testuser"
      expect(config.registry_username).to eq("testuser")
      ENV.delete("GITHUB_USER")
    end
  end

  describe "#registry_password" do
    it "returns nil when password_env not configured" do
      config = described_class.new(valid_config_hash)
      expect(config.registry_password).to be_nil
    end

    it "loads password from environment variable" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {"password" => "GITHUB_TOKEN"}
      )
      config = described_class.new(config_with_registry)

      ENV["GITHUB_TOKEN"] = "ghp_secret123"
      expect(config.registry_password).to eq("ghp_secret123")
      ENV.delete("GITHUB_TOKEN")
    end
  end

  describe "#registry_configured?" do
    it "returns false when registry not configured" do
      config = described_class.new(valid_config_hash)
      expect(config.registry_configured?).to be false
    end

    it "returns false when only username configured" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {"username" => "GITHUB_USER"}
      )
      config = described_class.new(config_with_registry)

      expect(config.registry_configured?).to be false
    end

    it "returns true when both username and password configured" do
      config_with_registry = valid_config_hash.merge(
        "registry" => {
          "username" => "GITHUB_USER",
          "password" => "GITHUB_TOKEN"
        }
      )
      config = described_class.new(config_with_registry)

      expect(config.registry_configured?).to be true
    end
  end

  describe "#validate!" do
    it "validates service name against Docker naming rules" do
      invalid_config = valid_config_hash.merge("service" => "@invalid-service")
      config = described_class.new(invalid_config)

      expect {
        config.validate!
      }.to raise_error(Kamal::Dev::ConfigurationError, /Service name.*invalid.*must start with a letter or number/)
    end

    it "accepts valid service names" do
      valid_service_config = valid_config_hash.merge("service" => "my-app_1.0")
      config = described_class.new(valid_service_config)

      expect { config.validate! }.not_to raise_error
    end
  end
end
