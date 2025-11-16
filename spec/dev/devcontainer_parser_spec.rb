# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kamal::Dev::DevcontainerParser do
  let(:fixtures_path) { File.join(__dir__, "../fixtures/devcontainer") }

  describe "#initialize" do
    it "accepts a file path" do
      parser = described_class.new(File.join(fixtures_path, "basic.json"))
      expect(parser).to be_a(described_class)
    end
  end

  describe "#parse" do
    context "with basic devcontainer.json" do
      subject(:parser) { described_class.new(File.join(fixtures_path, "basic.json")) }

      it "extracts the image property" do
        config = parser.parse
        expect(config[:image]).to eq("ruby:3.2")
      end

      it "extracts forward ports" do
        config = parser.parse
        expect(config[:ports]).to eq([3000, 5432])
      end

      it "extracts workspace folder" do
        config = parser.parse
        expect(config[:workspace]).to eq("/workspace")
      end
    end

    context "with comments in JSON" do
      subject(:parser) { described_class.new(File.join(fixtures_path, "with_comments.json")) }

      it "strips single-line comments" do
        expect { parser.parse }.not_to raise_error
      end

      it "strips multi-line comments" do
        config = parser.parse
        expect(config[:image]).to eq("ruby:3.2")
      end

      it "preserves environment variables" do
        config = parser.parse
        expect(config[:env]).to eq({"RAILS_ENV" => "development"})
      end
    end

    context "with full-featured devcontainer.json" do
      subject(:parser) { described_class.new(File.join(fixtures_path, "full_featured.json")) }

      it "extracts all properties" do
        config = parser.parse

        expect(config[:image]).to eq("mcr.microsoft.com/devcontainers/ruby:3.2")
        expect(config[:ports]).to eq([3000, 5432, 6379])
        expect(config[:mounts]).to be_an(Array)
        expect(config[:mounts].size).to eq(2)
        expect(config[:env]).to include("RAILS_ENV" => "development")
        expect(config[:options]).to eq(["--cpus=2", "--memory=4g"])
        expect(config[:user]).to eq("vscode")
        expect(config[:workspace]).to eq("/workspace")
      end

      it "extracts bind mounts correctly" do
        config = parser.parse
        bind_mount = config[:mounts].find { |m| m[:type] == "bind" }

        expect(bind_mount).to include(
          source: "${localWorkspaceFolder}",
          target: "/workspace",
          type: "bind"
        )
      end

      it "extracts volume mounts correctly" do
        config = parser.parse
        volume_mount = config[:mounts].find { |m| m[:type] == "volume" }

        expect(volume_mount).to include(
          source: "gem-cache",
          target: "/usr/local/bundle",
          type: "volume"
        )
      end
    end

    context "when image property is missing" do
      subject(:parser) { described_class.new(File.join(fixtures_path, "no_image.json")) }

      it "raises ValidationError" do
        expect { parser.parse }.to raise_error(
          Kamal::Dev::DevcontainerParser::ValidationError,
          /image.*required/i
        )
      end
    end

    context "when file does not exist" do
      subject(:parser) { described_class.new("/nonexistent/path.json") }

      it "raises an error" do
        expect { parser.parse }.to raise_error(Errno::ENOENT)
      end
    end

    context "with invalid JSON syntax" do
      let(:invalid_json_path) { File.join(fixtures_path, "invalid.json") }

      before do
        File.write(invalid_json_path, "{ invalid json }")
      end

      after do
        File.delete(invalid_json_path) if File.exist?(invalid_json_path)
      end

      subject(:parser) { described_class.new(invalid_json_path) }

      it "raises JSON parse error" do
        expect { parser.parse }.to raise_error(JSON::ParserError)
      end
    end
  end
end
