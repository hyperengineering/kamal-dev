# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/registry"
require "kamal/dev/config"

RSpec.describe Kamal::Dev::Registry do
  let(:config_hash) do
    {
      "service" => "myapp",
      "image" => "ruby:3.2",
      "provider" => {"type" => "upcloud"},
      "registry" => {
        "server" => "ghcr.io",
        "username" => "GITHUB_USER",
        "password" => "GITHUB_TOKEN"
      }
    }
  end

  let(:config) { Kamal::Dev::Config.new(config_hash) }
  let(:registry) { described_class.new(config) }

  before do
    ENV["GITHUB_USER"] = "testuser"
    ENV["GITHUB_TOKEN"] = "ghp_secret123"
  end

  after do
    ENV.delete("GITHUB_USER")
    ENV.delete("GITHUB_TOKEN")
  end

  describe "#server" do
    it "returns registry server from config" do
      expect(registry.server).to eq("ghcr.io")
    end

    it "defaults to ghcr.io when not configured" do
      minimal_config = {"service" => "myapp", "image" => "ruby:3.2", "provider" => {"type" => "upcloud"}}
      config_without_registry = Kamal::Dev::Config.new(minimal_config)
      registry_without_server = described_class.new(config_without_registry)

      expect(registry_without_server.server).to eq("ghcr.io")
    end
  end

  describe "#username" do
    it "loads username from environment variable" do
      expect(registry.username).to eq("testuser")
    end

    it "returns nil when ENV variable not set" do
      ENV.delete("GITHUB_USER")
      expect(registry.username).to be_nil
    end
  end

  describe "#password" do
    it "loads password from environment variable" do
      expect(registry.password).to eq("ghp_secret123")
    end

    it "returns nil when ENV variable not set" do
      ENV.delete("GITHUB_TOKEN")
      expect(registry.password).to be_nil
    end
  end

  describe "#image_name" do
    it "generates image name without tag" do
      image = registry.image_name("myapp")
      expect(image).to eq("ghcr.io/testuser/myapp-dev")
    end

    it "raises error when username not configured" do
      ENV.delete("GITHUB_USER")

      expect {
        registry.image_name("myapp")
      }.to raise_error(Kamal::Dev::RegistryError, /Registry username not configured/)
    end

    it "generates correct format for different services" do
      expect(registry.image_name("api")).to eq("ghcr.io/testuser/api-dev")
      expect(registry.image_name("worker")).to eq("ghcr.io/testuser/worker-dev")
    end
  end

  describe "#image_tag" do
    it "generates full image reference with tag" do
      image = registry.image_tag("myapp", "abc123")
      expect(image).to eq("ghcr.io/testuser/myapp-dev:abc123")
    end

    it "works with timestamp tags" do
      image = registry.image_tag("myapp", "1700000000")
      expect(image).to eq("ghcr.io/testuser/myapp-dev:1700000000")
    end

    it "works with git SHA tags" do
      image = registry.image_tag("myapp", "abc123f")
      expect(image).to eq("ghcr.io/testuser/myapp-dev:abc123f")
    end

    it "raises error when username not configured" do
      ENV.delete("GITHUB_USER")

      expect {
        registry.image_tag("myapp", "latest")
      }.to raise_error(Kamal::Dev::RegistryError, /Registry username not configured/)
    end
  end

  describe "#login_command" do
    it "generates docker login command array" do
      command = registry.login_command

      expect(command).to eq([
        "docker",
        "login",
        "ghcr.io",
        "-u",
        "testuser",
        "-p",
        "ghp_secret123"
      ])
    end

    it "raises error when username missing" do
      ENV.delete("GITHUB_USER")

      expect {
        registry.login_command
      }.to raise_error(Kamal::Dev::RegistryError, /Registry credentials not configured/)
    end

    it "raises error when password missing" do
      ENV.delete("GITHUB_TOKEN")

      expect {
        registry.login_command
      }.to raise_error(Kamal::Dev::RegistryError, /Registry credentials not configured/)
    end

    it "works with custom registry server" do
      custom_config = config_hash.merge("registry" => {
        "server" => "hub.docker.com",
        "username" => "DOCKER_USER",
        "password" => "DOCKER_TOKEN"
      })
      ENV["DOCKER_USER"] = "dockeruser"
      ENV["DOCKER_TOKEN"] = "dockertoken"

      config_custom = Kamal::Dev::Config.new(custom_config)
      registry_custom = described_class.new(config_custom)

      command = registry_custom.login_command

      expect(command).to eq([
        "docker",
        "login",
        "hub.docker.com",
        "-u",
        "dockeruser",
        "-p",
        "dockertoken"
      ])

      ENV.delete("DOCKER_USER")
      ENV.delete("DOCKER_TOKEN")
    end
  end

  describe "#credentials_present?" do
    it "returns true when both username and password are set" do
      expect(registry.credentials_present?).to be true
    end

    it "returns false when username missing" do
      ENV.delete("GITHUB_USER")
      expect(registry.credentials_present?).to be false
    end

    it "returns false when password missing" do
      ENV.delete("GITHUB_TOKEN")
      expect(registry.credentials_present?).to be false
    end

    it "returns false when both missing" do
      ENV.delete("GITHUB_USER")
      ENV.delete("GITHUB_TOKEN")
      expect(registry.credentials_present?).to be false
    end
  end

  describe "#tag_with_timestamp" do
    it "generates unix timestamp tag" do
      tag = registry.tag_with_timestamp

      # Should be a string of digits
      expect(tag).to match(/^\d+$/)

      # Should be a recent timestamp (within last minute)
      timestamp = tag.to_i
      expect(timestamp).to be_within(60).of(Time.now.to_i)
    end

    it "generates unique tags on subsequent calls" do
      tag1 = registry.tag_with_timestamp
      sleep 1 # Wait 1 second to ensure different timestamp
      tag2 = registry.tag_with_timestamp

      expect(tag1).not_to eq(tag2)
    end
  end

  describe "#tag_with_git_sha" do
    it "generates short git SHA tag when in git repo", skip: ENV["CI"] do
      # This test will only pass if running in a git repository
      tag = registry.tag_with_git_sha

      if tag
        # Should be 7-character hex string (git default short SHA)
        expect(tag).to match(/^[a-f0-9]{7}$/)
      else
        # If not in git repo, should return nil
        expect(tag).to be_nil
      end
    end

    it "returns nil when not in git repository" do
      # Mock git command failure
      allow(Open3).to receive(:capture2).with("git", "rev-parse", "--short", "HEAD", err: :close).and_return(["", nil])

      expect(registry.tag_with_git_sha).to be_nil
    end
  end
end
