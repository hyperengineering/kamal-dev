# frozen_string_literal: true

require "spec_helper"
require "kamal/cli/dev"
require "tmpdir"
require "fileutils"

RSpec.describe Kamal::Cli::Dev, "CLI integration" do
  let(:config_dir) { Dir.mktmpdir }
  let(:config_path) { File.join(config_dir, "dev.yml") }

  after do
    FileUtils.rm_rf(config_dir)
  end

  let(:valid_config) do
    {
      "service" => "testapp-dev",
      "image" => ".devcontainer/devcontainer.json",
      "provider" => {
        "type" => "upcloud",
        "zone" => "us-nyc1"
      }
    }
  end

  describe "config loading" do
    it "loads config from default path when not specified" do
      # Create config in current directory
      Dir.chdir(config_dir) do
        FileUtils.mkdir_p("config")
        File.write("config/dev.yml", valid_config.to_yaml)

        cli = described_class.new
        config = cli.load_config

        expect(config.service).to eq("testapp-dev")
      end
    end

    it "loads config from custom path when --config specified" do
      File.write(config_path, valid_config.to_yaml)

      cli = described_class.new([], {config: config_path})
      config = cli.load_config

      expect(config.service).to eq("testapp-dev")
    end

    it "validates config automatically on load" do
      invalid_config = valid_config.dup
      invalid_config.delete("service")
      File.write(config_path, invalid_config.to_yaml)

      cli = described_class.new([], {config: config_path})

      expect {
        cli.load_config
      }.to raise_error(Kamal::Dev::ConfigurationError, /service.*required/i)
    end
  end

  describe "config accessor" do
    it "memoizes loaded config" do
      File.write(config_path, valid_config.to_yaml)

      cli = described_class.new([], {config: config_path})
      config1 = cli.load_config
      config2 = cli.load_config

      expect(config1.object_id).to eq(config2.object_id)
    end
  end
end
