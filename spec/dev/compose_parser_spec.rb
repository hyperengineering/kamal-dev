# frozen_string_literal: true

require "spec_helper"
require "kamal/dev/compose_parser"
require "tempfile"

RSpec.describe Kamal::Dev::ComposeParser do
  let(:minimal_compose) { File.expand_path("../fixtures/compose/minimal.yaml", __dir__) }
  let(:rails_postgres_compose) { File.expand_path("../fixtures/compose/rails-postgres.yaml", __dir__) }
  let(:full_stack_compose) { File.expand_path("../fixtures/compose/full-stack.yaml", __dir__) }
  let(:shorthand_build_compose) { File.expand_path("../fixtures/compose/shorthand-build.yaml", __dir__) }
  let(:invalid_compose) { File.expand_path("../fixtures/compose/invalid.yaml", __dir__) }
  let(:nonexistent_compose) { "/tmp/nonexistent-compose.yaml" }

  describe "#initialize" do
    context "with valid compose file" do
      it "loads and parses compose file successfully" do
        parser = described_class.new(minimal_compose)
        expect(parser.compose_data).to be_a(Hash)
        expect(parser.compose_data["services"]).to be_a(Hash)
      end
    end

    context "with nonexistent file" do
      it "raises ConfigurationError" do
        expect {
          described_class.new(nonexistent_compose)
        }.to raise_error(Kamal::Dev::ConfigurationError, /not found/)
      end
    end

    context "with invalid YAML" do
      it "raises ConfigurationError with YAML error message" do
        expect {
          described_class.new(invalid_compose)
        }.to raise_error(Kamal::Dev::ConfigurationError, /Invalid YAML/)
      end
    end

    context "with missing services section" do
      let(:no_services_file) { Tempfile.new(["compose", ".yaml"]) }

      before do
        no_services_file.write("version: '3'\n")
        no_services_file.close
      end

      after do
        no_services_file.unlink
      end

      it "raises ConfigurationError" do
        expect {
          described_class.new(no_services_file.path)
        }.to raise_error(Kamal::Dev::ConfigurationError, /must have 'services' section/)
      end
    end

    context "with empty services section" do
      let(:empty_services_file) { Tempfile.new(["compose", ".yaml"]) }

      before do
        empty_services_file.write("services: {}\n")
        empty_services_file.close
      end

      after do
        empty_services_file.unlink
      end

      it "raises ConfigurationError" do
        expect {
          described_class.new(empty_services_file.path)
        }.to raise_error(Kamal::Dev::ConfigurationError, /must define at least one service/)
      end
    end
  end

  describe "#services" do
    it "returns all services from minimal compose" do
      parser = described_class.new(minimal_compose)
      services = parser.services

      expect(services).to be_a(Hash)
      expect(services.keys).to eq(["app"])
    end

    it "returns all services from rails-postgres compose" do
      parser = described_class.new(rails_postgres_compose)
      services = parser.services

      expect(services.keys).to include("app", "postgres")
    end

    it "returns all services from full-stack compose" do
      parser = described_class.new(full_stack_compose)
      services = parser.services

      expect(services.keys).to include("app", "postgres", "redis", "sidekiq")
    end
  end

  describe "#main_service" do
    context "with single service with build section" do
      it "returns the service name" do
        parser = described_class.new(minimal_compose)
        expect(parser.main_service).to eq("app")
      end
    end

    context "with multiple services, first has build" do
      it "returns the first service with build section" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.main_service).to eq("app")
      end
    end

    context "with multiple services with build sections" do
      it "returns the first service with build" do
        parser = described_class.new(full_stack_compose)
        expect(parser.main_service).to eq("app")
      end
    end
  end

  describe "#service_build_context" do
    context "with explicit context path" do
      it "returns the context path" do
        parser = described_class.new(minimal_compose)
        expect(parser.service_build_context("app")).to eq(".")
      end
    end

    context "with shorthand build syntax" do
      it "returns the build path as context" do
        parser = described_class.new(shorthand_build_compose)
        expect(parser.service_build_context("app")).to eq(".")
      end
    end

    context "with custom context path" do
      it "returns the custom context" do
        parser = described_class.new(full_stack_compose)
        expect(parser.service_build_context("app")).to eq(".")
      end
    end

    context "with service without build section" do
      it "returns default context" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.service_build_context("postgres")).to eq(".")
      end
    end

    context "with nonexistent service" do
      it "returns default context" do
        parser = described_class.new(minimal_compose)
        expect(parser.service_build_context("nonexistent")).to eq(".")
      end
    end
  end

  describe "#service_dockerfile" do
    context "with explicit dockerfile path" do
      it "returns the dockerfile path" do
        parser = described_class.new(minimal_compose)
        expect(parser.service_dockerfile("app")).to eq("Dockerfile")
      end
    end

    context "with custom dockerfile path" do
      it "returns the custom path" do
        parser = described_class.new(full_stack_compose)
        expect(parser.service_dockerfile("app")).to eq(".devcontainer/Dockerfile")
      end
    end

    context "with shorthand build syntax" do
      it "returns default Dockerfile" do
        parser = described_class.new(shorthand_build_compose)
        expect(parser.service_dockerfile("app")).to eq("Dockerfile")
      end
    end

    context "with service without build section" do
      it "returns default Dockerfile" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.service_dockerfile("postgres")).to eq("Dockerfile")
      end
    end

    context "with nonexistent service" do
      it "returns default Dockerfile" do
        parser = described_class.new(minimal_compose)
        expect(parser.service_dockerfile("nonexistent")).to eq("Dockerfile")
      end
    end
  end

  describe "#has_build_section?" do
    context "with service that has build section" do
      it "returns true" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.has_build_section?("app")).to be true
      end
    end

    context "with service that uses image" do
      it "returns false" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.has_build_section?("postgres")).to be false
      end
    end

    context "with nonexistent service" do
      it "returns false" do
        parser = described_class.new(minimal_compose)
        expect(parser.has_build_section?("nonexistent")).to be false
      end
    end

    context "with multiple services with builds" do
      it "correctly identifies each" do
        parser = described_class.new(full_stack_compose)
        expect(parser.has_build_section?("app")).to be true
        expect(parser.has_build_section?("sidekiq")).to be true
        expect(parser.has_build_section?("postgres")).to be false
        expect(parser.has_build_section?("redis")).to be false
      end
    end
  end

  describe "#dependent_services" do
    context "with minimal compose (no dependents)" do
      it "returns empty array" do
        parser = described_class.new(minimal_compose)
        expect(parser.dependent_services).to eq([])
      end
    end

    context "with rails-postgres compose" do
      it "returns postgres" do
        parser = described_class.new(rails_postgres_compose)
        expect(parser.dependent_services).to eq(["postgres"])
      end
    end

    context "with full-stack compose" do
      it "returns postgres and redis (not sidekiq which has build)" do
        parser = described_class.new(full_stack_compose)
        dependents = parser.dependent_services

        expect(dependents).to include("postgres", "redis")
        expect(dependents).not_to include("app", "sidekiq")
      end
    end
  end

  describe "#transform_for_deployment" do
    let(:image_ref) { "ghcr.io/ljuti/myapp-dev:abc123" }

    context "with minimal compose" do
      it "replaces build with image reference" do
        parser = described_class.new(minimal_compose)
        transformed = parser.transform_for_deployment(image_ref)

        # Parse transformed YAML
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        expect(result["services"]["app"]["image"]).to eq(image_ref)
        expect(result["services"]["app"]["build"]).to be_nil
      end

      it "preserves other service properties" do
        parser = described_class.new(minimal_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        # Check original properties are preserved
        expect(result["services"]["app"]["ports"]).to eq(["3000:3000"])
        expect(result["services"]["app"]["environment"]["RAILS_ENV"]).to eq("development")
      end
    end

    context "with rails-postgres compose" do
      it "only transforms main service, leaves postgres unchanged" do
        parser = described_class.new(rails_postgres_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        # App service transformed
        expect(result["services"]["app"]["image"]).to eq(image_ref)
        expect(result["services"]["app"]["build"]).to be_nil

        # Postgres unchanged
        expect(result["services"]["postgres"]["image"]).to eq("postgres:16")
        expect(result["services"]["postgres"]["build"]).to be_nil
      end

      it "preserves volumes section" do
        parser = described_class.new(rails_postgres_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        expect(result["volumes"]).to eq({"postgres_data" => nil})
      end

      it "preserves depends_on" do
        parser = described_class.new(rails_postgres_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        expect(result["services"]["app"]["depends_on"]).to eq(["postgres"])
      end
    end

    context "with full-stack compose" do
      it "transforms only main service (app)" do
        parser = described_class.new(full_stack_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        # App transformed
        expect(result["services"]["app"]["image"]).to eq(image_ref)
        expect(result["services"]["app"]["build"]).to be_nil

        # Sidekiq still has build (only main service transformed)
        expect(result["services"]["sidekiq"]["build"]).to be_a(Hash)

        # Postgres and redis unchanged
        expect(result["services"]["postgres"]["image"]).to eq("postgres:16")
        expect(result["services"]["redis"]["image"]).to eq("redis:7-alpine")
      end

      it "preserves all volumes" do
        parser = described_class.new(full_stack_compose)
        transformed = parser.transform_for_deployment(image_ref)
        result = YAML.safe_load(transformed, permitted_classes: [Symbol])

        expect(result["volumes"].keys).to include("postgres_data", "redis_data")
      end
    end

    context "with transformation errors" do
      it "raises ConfigurationError on failure" do
        parser = described_class.new(minimal_compose)

        # Mock YAML.dump to raise error
        allow(YAML).to receive(:dump).and_raise(StandardError.new("Simulated error"))

        expect {
          parser.transform_for_deployment("ghcr.io/test/image:tag")
        }.to raise_error(Kamal::Dev::ConfigurationError, /Failed to transform/)
      end
    end
  end

  describe "edge cases" do
    context "with compose file with no build sections" do
      let(:no_build_file) { Tempfile.new(["compose", ".yaml"]) }

      before do
        no_build_file.write({
          "services" => {
            "postgres" => {"image" => "postgres:16"},
            "redis" => {"image" => "redis:7"}
          }
        }.to_yaml)
        no_build_file.close
      end

      after do
        no_build_file.unlink
      end

      it "returns first service as main service" do
        parser = described_class.new(no_build_file.path)
        expect(parser.main_service).to eq("postgres")
      end

      it "returns empty dependent services list" do
        parser = described_class.new(no_build_file.path)
        expect(parser.dependent_services).to eq(["postgres", "redis"])
      end
    end

    context "with service having empty build config" do
      let(:empty_build_file) { Tempfile.new(["compose", ".yaml"]) }

      before do
        empty_build_file.write({
          "services" => {
            "app" => {
              "build" => {},
              "ports" => ["3000:3000"]
            }
          }
        }.to_yaml)
        empty_build_file.close
      end

      after do
        empty_build_file.unlink
      end

      it "returns default context for empty build" do
        parser = described_class.new(empty_build_file.path)
        expect(parser.service_build_context("app")).to eq(".")
      end

      it "returns default dockerfile for empty build" do
        parser = described_class.new(empty_build_file.path)
        expect(parser.service_dockerfile("app")).to eq("Dockerfile")
      end
    end

    context "with compose file with only one service using build" do
      it "correctly identifies main and dependent services" do
        parser = described_class.new(rails_postgres_compose)

        expect(parser.main_service).to eq("app")
        expect(parser.has_build_section?("app")).to be true
        expect(parser.has_build_section?("postgres")).to be false
        expect(parser.dependent_services).to eq(["postgres"])
      end
    end
  end
end
