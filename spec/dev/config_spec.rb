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

  describe "#build" do
    it "returns empty hash when build section not present" do
      config = described_class.new(valid_config_hash)
      expect(config.build).to eq({})
    end

    it "returns build configuration when present" do
      config_with_build = valid_config_hash.merge(
        "build" => {
          "devcontainer" => ".devcontainer/devcontainer.json",
          "context" => ".devcontainer"
        }
      )
      config = described_class.new(config_with_build)

      build = config.build
      expect(build["devcontainer"]).to eq(".devcontainer/devcontainer.json")
      expect(build["context"]).to eq(".devcontainer")
    end

    it "returns build configuration for Dockerfile builds" do
      config_with_build = valid_config_hash.merge(
        "build" => {
          "dockerfile" => ".devcontainer/Dockerfile",
          "context" => "."
        }
      )
      config = described_class.new(config_with_build)

      build = config.build
      expect(build["dockerfile"]).to eq(".devcontainer/Dockerfile")
      expect(build["context"]).to eq(".")
    end
  end

  describe "#build?" do
    it "returns false when build section not present" do
      config = described_class.new(valid_config_hash)
      expect(config.build?).to be false
    end

    it "returns true when build section present" do
      config_with_build = valid_config_hash.merge(
        "build" => {"devcontainer" => ".devcontainer/devcontainer.json"}
      )
      config = described_class.new(config_with_build)
      expect(config.build?).to be true
    end

    it "returns false when build section is empty" do
      config_with_empty_build = valid_config_hash.merge("build" => {})
      config = described_class.new(config_with_empty_build)
      expect(config.build?).to be false
    end
  end

  describe "#build_source_type" do
    it "returns :devcontainer when devcontainer specified" do
      config_with_devcontainer = valid_config_hash.merge(
        "build" => {"devcontainer" => ".devcontainer/devcontainer.json"}
      )
      config = described_class.new(config_with_devcontainer)
      expect(config.build_source_type).to eq(:devcontainer)
    end

    it "returns :dockerfile when dockerfile specified" do
      config_with_dockerfile = valid_config_hash.merge(
        "build" => {"dockerfile" => "Dockerfile"}
      )
      config = described_class.new(config_with_dockerfile)
      expect(config.build_source_type).to eq(:dockerfile)
    end

    it "returns nil when build section empty" do
      config = described_class.new(valid_config_hash)
      expect(config.build_source_type).to be_nil
    end

    it "returns nil when build has no devcontainer or dockerfile" do
      config_with_context_only = valid_config_hash.merge(
        "build" => {"context" => "."}
      )
      config = described_class.new(config_with_context_only)
      expect(config.build_source_type).to be_nil
    end

    it "prioritizes devcontainer over dockerfile when both present" do
      config_with_both = valid_config_hash.merge(
        "build" => {
          "devcontainer" => ".devcontainer/devcontainer.json",
          "dockerfile" => "Dockerfile"
        }
      )
      config = described_class.new(config_with_both)
      expect(config.build_source_type).to eq(:devcontainer)
    end
  end

  describe "#build_source_path" do
    it "returns devcontainer path when type is :devcontainer" do
      config_with_devcontainer = valid_config_hash.merge(
        "build" => {"devcontainer" => ".devcontainer/devcontainer.json"}
      )
      config = described_class.new(config_with_devcontainer)
      expect(config.build_source_path).to eq(".devcontainer/devcontainer.json")
    end

    it "returns dockerfile path when type is :dockerfile" do
      config_with_dockerfile = valid_config_hash.merge(
        "build" => {"dockerfile" => ".devcontainer/Dockerfile"}
      )
      config = described_class.new(config_with_dockerfile)
      expect(config.build_source_path).to eq(".devcontainer/Dockerfile")
    end

    it "returns nil when no build source" do
      config = described_class.new(valid_config_hash)
      expect(config.build_source_path).to be_nil
    end
  end

  describe "#build_context" do
    it "returns configured build context" do
      config_with_context = valid_config_hash.merge(
        "build" => {
          "dockerfile" => "Dockerfile",
          "context" => ".devcontainer"
        }
      )
      config = described_class.new(config_with_context)
      expect(config.build_context).to eq(".devcontainer")
    end

    it "defaults to '.' when context not specified" do
      config_with_build = valid_config_hash.merge(
        "build" => {"dockerfile" => "Dockerfile"}
      )
      config = described_class.new(config_with_build)
      expect(config.build_context).to eq(".")
    end

    it "defaults to '.' when no build section" do
      config = described_class.new(valid_config_hash)
      expect(config.build_context).to eq(".")
    end
  end

  describe "#devcontainer_json? - backward compatibility" do
    it "returns true for new format with build.devcontainer" do
      config_new_format = valid_config_hash.merge(
        "image" => "myorg/myapp",
        "build" => {"devcontainer" => ".devcontainer/devcontainer.json"}
      )
      config = described_class.new(config_new_format)
      expect(config.devcontainer_json?).to be true
    end

    it "returns true for old format with image pointing to .json" do
      config_old_format = valid_config_hash.merge(
        "image" => ".devcontainer/devcontainer.json"
      )
      config = described_class.new(config_old_format)
      expect(config.devcontainer_json?).to be true
    end

    it "returns false when using direct image reference" do
      config_direct_image = valid_config_hash.merge(
        "image" => "ruby:3.2"
      )
      config = described_class.new(config_direct_image)
      expect(config.devcontainer_json?).to be false
    end

    it "returns false when using build.dockerfile" do
      config_dockerfile = valid_config_hash.merge(
        "image" => "myorg/myapp",
        "build" => {"dockerfile" => "Dockerfile"}
      )
      config = described_class.new(config_dockerfile)
      expect(config.devcontainer_json?).to be false
    end
  end

  describe "git configuration methods" do
    describe "#git" do
      it "returns empty hash when git not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git).to eq({})
      end

      it "returns git configuration when configured" do
        config_with_git = valid_config_hash.merge(
          "git" => {
            "repository" => "https://github.com/user/repo.git",
            "branch" => "develop",
            "workspace_folder" => "/workspace/app",
            "token" => "GITHUB_TOKEN"
          }
        )
        config = described_class.new(config_with_git)

        git = config.git
        expect(git["repository"]).to eq("https://github.com/user/repo.git")
        expect(git["branch"]).to eq("develop")
        expect(git["workspace_folder"]).to eq("/workspace/app")
        expect(git["token"]).to eq("GITHUB_TOKEN")
      end
    end

    describe "#git_repository" do
      it "returns nil when git not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_repository).to be_nil
      end

      it "returns repository URL when configured" do
        config_with_git = valid_config_hash.merge(
          "git" => {"repository" => "https://github.com/user/repo.git"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_repository).to eq("https://github.com/user/repo.git")
      end
    end

    describe "#git_branch" do
      it "defaults to 'main' when not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_branch).to eq("main")
      end

      it "returns configured branch" do
        config_with_git = valid_config_hash.merge(
          "git" => {"branch" => "develop"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_branch).to eq("develop")
      end
    end

    describe "#git_workspace_folder" do
      it "defaults to /workspaces/{service} when not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_workspace_folder).to eq("/workspaces/myapp-dev")
      end

      it "returns configured workspace folder" do
        config_with_git = valid_config_hash.merge(
          "git" => {"workspace_folder" => "/custom/workspace"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_workspace_folder).to eq("/custom/workspace")
      end
    end

    describe "#git_token_env" do
      it "returns nil when token not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_token_env).to be_nil
      end

      it "returns token environment variable name when configured" do
        config_with_git = valid_config_hash.merge(
          "git" => {"token" => "GITHUB_TOKEN"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_token_env).to eq("GITHUB_TOKEN")
      end
    end

    describe "#git_token" do
      it "returns nil when token env not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_token).to be_nil
      end

      it "returns nil when token env var not set" do
        config_with_git = valid_config_hash.merge(
          "git" => {"token" => "MISSING_TOKEN"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_token).to be_nil
      end

      it "loads token from environment variable" do
        config_with_git = valid_config_hash.merge(
          "git" => {"token" => "GITHUB_TOKEN"}
        )
        config = described_class.new(config_with_git)

        ENV["GITHUB_TOKEN"] = "ghp_secret123"
        expect(config.git_token).to eq("ghp_secret123")
        ENV.delete("GITHUB_TOKEN")
      end
    end

    describe "#git_clone_enabled?" do
      it "returns false when git repository not configured" do
        config = described_class.new(valid_config_hash)
        expect(config.git_clone_enabled?).to be false
      end

      it "returns false when git repository is empty string" do
        config_with_empty_git = valid_config_hash.merge(
          "git" => {"repository" => ""}
        )
        config = described_class.new(config_with_empty_git)
        expect(config.git_clone_enabled?).to be false
      end

      it "returns true when git repository is configured" do
        config_with_git = valid_config_hash.merge(
          "git" => {"repository" => "https://github.com/user/repo.git"}
        )
        config = described_class.new(config_with_git)
        expect(config.git_clone_enabled?).to be true
      end
    end
  end
end
