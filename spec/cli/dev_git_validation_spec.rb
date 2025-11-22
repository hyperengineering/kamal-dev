# frozen_string_literal: true

require "spec_helper"
require "kamal/cli/dev"
require "tmpdir"
require "fileutils"

RSpec.describe Kamal::Cli::Dev do
  let(:config_dir) { Dir.mktmpdir }
  let(:config_path) { File.join(config_dir, "dev.yml") }

  after do
    FileUtils.rm_rf(config_dir)
    ENV.delete("GITHUB_TOKEN")
    ENV.delete("MISSING_TOKEN")
  end

  let(:base_config_hash) do
    {
      "service" => "test-app",
      "image" => "test-app:latest",
      "provider" => {
        "type" => "upcloud",
        "zone" => "us-nyc1",
        "plan" => "1xCPU-1GB"
      }
    }
  end

  describe "#validate_git_config!" do
    let(:cli) { described_class.new }

    context "when git clone is not enabled" do
      it "does not raise error" do
        config = Kamal::Dev::Config.new(base_config_hash)
        expect { cli.send(:validate_git_config!, config) }.not_to raise_error
      end
    end

    context "when git clone enabled with HTTPS repository" do
      context "with token configured and ENV var set" do
        it "validates successfully and prints confirmation" do
          config_with_git = base_config_hash.merge(
            "git" => {
              "repository" => "https://github.com/user/repo.git",
              "token" => "GITHUB_TOKEN"
            }
          )
          config = Kamal::Dev::Config.new(config_with_git)

          ENV["GITHUB_TOKEN"] = "ghp_test123"

          expect {
            cli.send(:validate_git_config!, config)
          }.to output(/✓ Git authentication configured \(using GITHUB_TOKEN\)/).to_stdout
        end
      end

      context "with token configured but ENV var not set" do
        it "raises ConfigurationError with helpful message" do
          config_with_git = base_config_hash.merge(
            "git" => {
              "repository" => "https://github.com/user/private-repo.git",
              "token" => "MISSING_TOKEN"
            }
          )
          config = Kamal::Dev::Config.new(config_with_git)

          expect {
            cli.send(:validate_git_config!, config)
          }.to raise_error(
            Kamal::Dev::ConfigurationError,
            /Git token environment variable 'MISSING_TOKEN' is configured but not set/
          )
        end

        it "includes helpful instructions in error message" do
          config_with_git = base_config_hash.merge(
            "git" => {
              "repository" => "https://github.com/user/private-repo.git",
              "token" => "GITHUB_TOKEN"
            }
          )
          config = Kamal::Dev::Config.new(config_with_git)

          expect {
            cli.send(:validate_git_config!, config)
          }.to raise_error(
            Kamal::Dev::ConfigurationError,
            /Please add to \.kamal\/secrets: export GITHUB_TOKEN="your_token_here"/
          )
        end
      end

      context "without token configured (public repo scenario)" do
        it "prints warning about public-only support" do
          config_with_git = base_config_hash.merge(
            "git" => {
              "repository" => "https://github.com/user/public-repo.git"
            }
          )
          config = Kamal::Dev::Config.new(config_with_git)

          expect {
            cli.send(:validate_git_config!, config)
          }.to output(/⚠️  Git clone configured without authentication token/).to_stdout
        end

        it "prints guidance for private repos" do
          config_with_git = base_config_hash.merge(
            "git" => {
              "repository" => "https://github.com/user/public-repo.git"
            }
          )
          config = Kamal::Dev::Config.new(config_with_git)

          expect {
            cli.send(:validate_git_config!, config)
          }.to output(/For private repos, configure git\.token in config\/dev\.yml/).to_stdout
        end
      end
    end

    context "when git clone enabled with SSH repository" do
      it "does not validate token (SSH uses keys)" do
        config_with_git = base_config_hash.merge(
          "git" => {
            "repository" => "git@github.com:user/repo.git"
          }
        )
        config = Kamal::Dev::Config.new(config_with_git)

        # Should not raise error or print warnings for SSH URLs
        expect {
          cli.send(:validate_git_config!, config)
        }.not_to raise_error
      end
    end

    context "edge cases" do
      it "handles empty repository URL gracefully" do
        config_with_empty_git = base_config_hash.merge(
          "git" => {"repository" => ""}
        )
        config = Kamal::Dev::Config.new(config_with_empty_git)

        # git_clone_enabled? should return false for empty string
        expect { cli.send(:validate_git_config!, config) }.not_to raise_error
      end

      it "handles nil repository URL gracefully" do
        config_with_nil_git = base_config_hash.merge(
          "git" => {"repository" => nil}
        )
        config = Kamal::Dev::Config.new(config_with_nil_git)

        expect { cli.send(:validate_git_config!, config) }.not_to raise_error
      end
    end
  end
end
