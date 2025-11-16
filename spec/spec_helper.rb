# frozen_string_literal: true

require "kamal/dev"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Integration test configuration
  config.define_derived_metadata(file_path: %r{/spec/integration/}) do |metadata|
    metadata[:type] = :integration
  end

  # Exclude integration tests by default (require explicit tag or ENV)
  config.filter_run_excluding type: :integration unless ENV["INTEGRATION_TESTS"]

  # Display integration test skip message
  config.before(:suite) do
    if RSpec.configuration.exclusion_filter[:type] == :integration
      puts "\n⚠️  Integration tests skipped (set INTEGRATION_TESTS=1 to run)"
    end
  end
end
