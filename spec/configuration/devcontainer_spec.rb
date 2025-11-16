# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kamal::Configuration::Devcontainer do
  describe "#initialize" do
    it "accepts a parsed config hash" do
      config = {
        image: "ruby:3.2",
        ports: [3000],
        mounts: [],
        env: {},
        options: [],
        user: nil,
        workspace: "/workspace"
      }

      devcontainer = described_class.new(config)
      expect(devcontainer).to be_a(described_class)
    end
  end

  describe "accessors" do
    let(:config) do
      {
        image: "ruby:3.2",
        ports: [3000, 5432],
        mounts: [{source: "gem-cache", target: "/usr/local/bundle", type: "volume"}],
        env: {"RAILS_ENV" => "development"},
        options: ["--cpus=2", "--memory=4g"],
        user: "vscode",
        workspace: "/workspace"
      }
    end

    subject(:devcontainer) { described_class.new(config) }

    it "provides access to image" do
      expect(devcontainer.image).to eq("ruby:3.2")
    end

    it "provides access to ports" do
      expect(devcontainer.ports).to eq([3000, 5432])
    end

    it "provides access to mounts" do
      expect(devcontainer.mounts.size).to eq(1)
      expect(devcontainer.mounts.first[:source]).to eq("gem-cache")
    end

    it "provides access to environment variables" do
      expect(devcontainer.env).to eq({"RAILS_ENV" => "development"})
    end

    it "provides access to Docker options" do
      expect(devcontainer.options).to eq(["--cpus=2", "--memory=4g"])
    end

    it "provides access to user" do
      expect(devcontainer.user).to eq("vscode")
    end

    it "provides access to workspace" do
      expect(devcontainer.workspace).to eq("/workspace")
    end
  end

  describe "#docker_run_flags" do
    context "with ports" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [3000, 5432],
          mounts: [],
          env: {},
          options: [],
          user: nil,
          workspace: nil
        }
      end

      it "generates -p flags for each port" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("-p", "3000:3000")
        expect(flags).to include("-p", "5432:5432")
      end
    end

    context "with volume mounts" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [],
          mounts: [
            {source: "gem-cache", target: "/usr/local/bundle", type: "volume"},
            {source: "/local/path", target: "/container/path", type: "bind"}
          ],
          env: {},
          options: [],
          user: nil,
          workspace: nil
        }
      end

      it "generates -v flags for each mount" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("-v", "gem-cache:/usr/local/bundle")
        expect(flags).to include("-v", "/local/path:/container/path")
      end
    end

    context "with environment variables" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [],
          mounts: [],
          env: {"RAILS_ENV" => "development", "DATABASE_URL" => "postgres://localhost/db"},
          options: [],
          user: nil,
          workspace: nil
        }
      end

      it "generates -e flags for each env var" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("-e", "RAILS_ENV=development")
        expect(flags).to include("-e", "DATABASE_URL=postgres://localhost/db")
      end
    end

    context "with Docker options" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [],
          mounts: [],
          env: {},
          options: ["--cpus=2", "--memory=4g", "--restart=unless-stopped"],
          user: nil,
          workspace: nil
        }
      end

      it "includes the options in flags" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("--cpus=2")
        expect(flags).to include("--memory=4g")
        expect(flags).to include("--restart=unless-stopped")
      end
    end

    context "with remote user" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [],
          mounts: [],
          env: {},
          options: [],
          user: "vscode",
          workspace: nil
        }
      end

      it "generates --user flag" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("--user", "vscode")
      end
    end

    context "with workspace folder" do
      let(:config) do
        {
          image: "ruby:3.2",
          ports: [],
          mounts: [],
          env: {},
          options: [],
          user: nil,
          workspace: "/workspace"
        }
      end

      it "generates -w flag" do
        devcontainer = described_class.new(config)
        flags = devcontainer.docker_run_flags

        expect(flags).to include("-w", "/workspace")
      end
    end
  end

  describe "#docker_run_command" do
    let(:config) do
      {
        image: "ruby:3.2",
        ports: [3000],
        mounts: [{source: "gem-cache", target: "/usr/local/bundle", type: "volume"}],
        env: {"RAILS_ENV" => "development"},
        options: ["--cpus=2"],
        user: "vscode",
        workspace: "/workspace"
      }
    end

    it "returns full docker run command array" do
      devcontainer = described_class.new(config)
      command = devcontainer.docker_run_command(name: "myapp-dev-1")

      expect(command).to be_an(Array)
      expect(command).to include("docker", "run")
      expect(command).to include("--name", "myapp-dev-1")
      expect(command).to include("-d") # detached mode
      expect(command).to include("ruby:3.2") # image at end
    end

    it "includes all flags from docker_run_flags" do
      devcontainer = described_class.new(config)
      command = devcontainer.docker_run_command(name: "test")

      expect(command).to include("-p", "3000:3000")
      expect(command).to include("-v", "gem-cache:/usr/local/bundle")
      expect(command).to include("-e", "RAILS_ENV=development")
      expect(command).to include("--cpus=2")
      expect(command).to include("--user", "vscode")
      expect(command).to include("-w", "/workspace")
    end
  end
end
