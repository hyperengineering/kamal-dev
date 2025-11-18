# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/builder"
require "kamal/dev/registry"
require "kamal/dev/config"

RSpec.describe Kamal::Dev::Builder do
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
  let(:registry) { Kamal::Dev::Registry.new(config) }
  let(:builder) { described_class.new(config, registry) }

  before do
    ENV["GITHUB_USER"] = "testuser"
    ENV["GITHUB_TOKEN"] = "ghp_secret123"
  end

  after do
    ENV.delete("GITHUB_USER")
    ENV.delete("GITHUB_TOKEN")
  end

  describe "#build" do
    it "builds image with provided tag" do
      allow(builder).to receive(:execute_with_output).and_return({success: true, output: "", error: ""})

      result = builder.build(
        dockerfile: "Dockerfile",
        context: ".",
        tag: "abc123"
      )

      expect(result).to eq("ghcr.io/testuser/myapp-dev:abc123")
      expect(builder).to have_received(:execute_with_output).with(
        array_including("docker", "build", "-t", "ghcr.io/testuser/myapp-dev:abc123"),
        /Building image/
      )
    end

    it "auto-generates timestamp tag when not provided" do
      allow(registry).to receive(:tag_with_timestamp).and_return("1700000000")
      allow(builder).to receive(:execute_with_output).and_return({success: true, output: "", error: ""})

      result = builder.build(
        dockerfile: "Dockerfile",
        context: "."
      )

      expect(result).to eq("ghcr.io/testuser/myapp-dev:1700000000")
    end

    it "includes dockerfile flag when not default" do
      allow(builder).to receive(:execute_with_output).and_return({success: true, output: "", error: ""})

      builder.build(
        dockerfile: ".devcontainer/Dockerfile",
        context: ".",
        tag: "test"
      )

      expect(builder).to have_received(:execute_with_output).with(
        array_including("-f", ".devcontainer/Dockerfile"),
        anything
      )
    end

    it "includes build args" do
      allow(builder).to receive(:execute_with_output).and_return({success: true, output: "", error: ""})

      builder.build(
        dockerfile: "Dockerfile",
        context: ".",
        tag: "test",
        build_args: {"NODE_VERSION" => "18", "RUBY_VERSION" => "3.2"}
      )

      expect(builder).to have_received(:execute_with_output).with(
        array_including(
          "--build-arg", "NODE_VERSION=18",
          "--build-arg", "RUBY_VERSION=3.2"
        ),
        anything
      )
    end

    it "raises BuildError when build fails" do
      allow(builder).to receive(:execute_with_output).and_raise(
        Kamal::Dev::BuildError, "Build failed: error message"
      )

      expect {
        builder.build(dockerfile: "Dockerfile", context: ".")
      }.to raise_error(Kamal::Dev::BuildError, /Build failed/)
    end
  end

  describe "#push" do
    it "pushes image to registry" do
      allow(builder).to receive(:execute_with_output).and_return({success: true, output: "", error: ""})

      result = builder.push("ghcr.io/testuser/myapp-dev:abc123")

      expect(result).to be true
      expect(builder).to have_received(:execute_with_output).with(
        ["docker", "push", "ghcr.io/testuser/myapp-dev:abc123"],
        /Pushing image/
      )
    end

    it "raises BuildError when push fails" do
      allow(builder).to receive(:execute_with_output).and_raise(
        Kamal::Dev::BuildError, "Push failed: unauthorized"
      )

      expect {
        builder.push("ghcr.io/testuser/myapp-dev:abc123")
      }.to raise_error(Kamal::Dev::BuildError, /Push failed/)
    end
  end

  describe "#login" do
    it "logs in to Docker registry" do
      allow(builder).to receive(:execute_command).and_return({success: true, output: "Login Succeeded", error: ""})

      result = builder.login

      expect(result).to be true
      expect(builder).to have_received(:execute_command).with(
        ["docker", "login", "ghcr.io", "-u", "testuser", "-p", "ghp_secret123"]
      )
    end

    it "raises RegistryError when login fails" do
      allow(builder).to receive(:execute_command).and_return({success: false, output: "", error: "unauthorized"})

      expect {
        builder.login
      }.to raise_error(Kamal::Dev::RegistryError, /Docker login failed/)
    end
  end

  describe "#docker_available?" do
    it "returns true when Docker is available" do
      allow(builder).to receive(:execute_command).and_return({success: true, output: "Docker version 24.0.0", error: ""})

      expect(builder.docker_available?).to be true
    end

    it "returns false when Docker is not available" do
      allow(builder).to receive(:execute_command).and_return({success: false, output: "", error: "command not found"})

      expect(builder.docker_available?).to be false
    end
  end

  describe "#image_exists?" do
    it "returns true when image exists locally" do
      allow(builder).to receive(:execute_command).and_return({success: true, output: "[...]", error: ""})

      expect(builder.image_exists?("myapp:latest")).to be true
    end

    it "returns false when image does not exist" do
      allow(builder).to receive(:execute_command).and_return({success: false, output: "", error: "No such image"})

      expect(builder.image_exists?("nonexistent:latest")).to be false
    end
  end

  describe "#tag_with_timestamp" do
    it "tags image with timestamp" do
      allow(registry).to receive(:tag_with_timestamp).and_return("1700000000")
      allow(builder).to receive(:execute_command).and_return({success: true, output: "", error: ""})

      result = builder.tag_with_timestamp("myapp:latest")

      expect(result).to eq("myapp:latest:1700000000")
      expect(builder).to have_received(:execute_command).with(
        ["docker", "tag", "myapp:latest", "myapp:latest:1700000000"]
      )
    end
  end

  describe "#tag_with_git_sha" do
    it "tags image with git SHA" do
      allow(registry).to receive(:tag_with_git_sha).and_return("abc123f")
      allow(builder).to receive(:execute_command).and_return({success: true, output: "", error: ""})

      result = builder.tag_with_git_sha("myapp:latest")

      expect(result).to eq("myapp:latest:abc123f")
    end

    it "returns nil when not in git repository" do
      allow(registry).to receive(:tag_with_git_sha).and_return(nil)

      result = builder.tag_with_git_sha("myapp:latest")

      expect(result).to be_nil
    end
  end
end
