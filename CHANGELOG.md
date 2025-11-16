## [Unreleased]

## [0.1.1] - 2025-11-16

### Fixed
- **Namespace Conflict Resolution**: Refactored `Kamal::Configuration::*` to `Kamal::Dev::*` to avoid conflicts with base Kamal's Configuration class
  - Moved `lib/kamal/configuration/dev_config.rb` → `lib/kamal/dev/config.rb`
  - Renamed `DevConfig` → `Config` for cleaner namespace
  - Updated all requires and class references across codebase
  - Moved spec files to match new structure

### Added
- **CLI Integration Hook**: Integration with Kamal executable via class_eval
  - Added `lib/kamal-dev.rb` stub for bundler auto-require
  - Hook into `Kamal::Cli::Main` to register `dev` subcommand via `class_eval`
  - Extends existing kamal command rather than creating separate executable
  - **Note**: Kamal has no plugin system, so gem must be explicitly required
- **Automatic Installer** (`plugin-kamal-dev` executable)
  - One-command setup: `bundle exec plugin-kamal-dev`
  - Automatically generates `bin/kamal` binstub if missing
  - Intelligently patches binstub to load kamal-dev extension
  - Idempotent - safe to run multiple times
  - Three insertion strategies for maximum compatibility
  - Clear success/error messages with usage instructions
  - Tested with comprehensive integration test suite
- **Reference Implementation**: `bin/kamal-template` binstub example
- **Development Binstub**: Created `exe/kamal-dev` for local development testing

### Changed
- **Simplified Installation Flow**: README now features automatic installer as primary method
  - Primary: `bundle exec plugin-kamal-dev` (one command, fully automated)
  - Alternative options available for users who prefer manual setup
  - Updated Quick Start examples to use `bin/kamal dev` commands
  - Updated Commands Reference with simpler usage patterns
- All 142 tests passing with new namespace structure

### Documentation
- **Installation Guide**: Restructured with automatic installer as recommended approach
  - Clear step-by-step installation instructions
  - Alternative setup methods in collapsible section
  - Examples updated to match installer output
- **Installer Testing**: Added `test_installer.sh` for automated testing
  - Tests binstub generation and patching
  - Verifies idempotency
  - Validates file content and permissions
- Clarified that kamal-dev requires explicit loading due to lack of Kamal plugin system
- Provided multiple integration paths for different use cases and project setups

## [0.1.0] - 2025-11-15

### Architecture

#### Architectural Decision: Hybrid Kamal Integration (2025-11-16)
- **Decision**: Use à la carte component reuse instead of full `Kamal::Cli::Base` inheritance
- **Rationale**: kamal-dev provisions VMs dynamically; Kamal assumes static hosts in `config/deploy.yml`
- **What we reuse**: `.kamal/secrets` via `Kamal::Utils::Secrets`, SSHKit for SSH execution
- **What we don't use**: `Kamal::Cli::Base` inheritance, `config/deploy.yml`
- **Benefits**: Natural fit for dynamic infrastructure, loose coupling, maintainability
- **See**: `docs/adr/001-hybrid-kamal-integration.md` for full decision record

### Added

#### Story 1.3: Devcontainer Parser & Deployment
- **Devcontainer.json Parser** (`Kamal::Configuration::DevcontainerParser`)
  - VS Code devcontainer.json specification parsing
  - JSON comment stripping (single-line `//` and multi-line `/* */`)
  - Property extraction: image, forwardPorts, mounts, containerEnv, runArgs, remoteUser, workspaceFolder
  - Validation for required properties (image or dockerfile)
  - Comprehensive error messages with context

- **Devcontainer Configuration** (`Kamal::Configuration::Devcontainer`)
  - Immutable configuration object for parsed devcontainer specs
  - Docker run command generation from devcontainer properties
  - Port mapping conversion (`forwardPorts` → `-p HOST:CONTAINER`)
  - Volume mount conversion (`mounts` → `-v SOURCE:TARGET`)
  - Environment variable injection (`containerEnv` → `-e KEY=VALUE`)
  - Resource limit support via `runArgs` (--cpus, --memory, etc.)
  - Remote user and workspace folder configuration

- **State Management** (`Kamal::Dev::StateManager`)
  - File-based YAML state tracking (`.kamal/dev_state.yml`)
  - Thread-safe operations with file locking (File::LOCK_SH for reads, File::LOCK_EX for writes)
  - Atomic writes via temp file + rename pattern
  - Lock timeout (10s) with `LockTimeoutError`
  - Deployment CRUD operations: add, update status, remove, list
  - Automatic state file deletion when last deployment removed

- **CLI Commands**
  - `kamal dev deploy [NAME]` - Deploy devcontainer workspace(s)
    - VM provisioning via cloud provider
    - Devcontainer configuration loading
    - Cost estimation with user confirmation
    - State tracking and container naming
    - Options: `--count`, `--from`, `--skip-cost-check`
  - `kamal dev list` - List deployed devcontainers
    - Table, JSON, and YAML output formats
    - VM IP, status, and deployment timestamp display
  - `kamal dev stop [NAME]` - Stop devcontainer(s)
    - Single container or `--all` flag
    - Status update to "stopped" in state file
  - `kamal dev remove [NAME]` - Remove devcontainer(s) and destroy VMs
    - Single container or `--all` flag
    - Force flag (`--force`) for confirmation bypass
    - State cleanup and VM destruction

- **DevConfig Integration**
  - `#devcontainer` accessor for seamless devcontainer loading
  - `#devcontainer_json?` predicate for image type detection
  - Support for both devcontainer.json paths and direct image references
  - Automatic parser instantiation and caching

- **Integration Tests**
  - ENV-gated integration test suite (`INTEGRATION_TESTS=1` to enable)
  - Full lifecycle testing: deploy → list → stop → remove
  - VM provisioning verification with config validation
  - State file structure and integrity testing
  - Automatic cleanup hooks for VM destruction
  - Cost safety (~$0.01 per test run with minimal VMs)
  - Comprehensive README with setup, debugging, and CI/CD integration

#### Story 1.2: Provider Architecture
- Provider adapter architecture with pluggable cloud provider support
- `Kamal::Providers::Base` abstract interface defining provider contract
- `Kamal::Providers::Upcloud` implementation for UpCloud API v1.3
- Factory pattern `Kamal::Providers.for(config)` for provider instantiation
- Custom exception hierarchy: `ProvisioningError`, `TimeoutError`, `QuotaExceededError`, `AuthenticationError`, `RateLimitError`
- Faraday HTTP client with retry middleware for transient failures
- VM provisioning with status polling (120s timeout, 5s interval)
- VM cleanup with storage deletion support
- Cost estimation with pricing guidance

### Changed
- Updated `Kamal::Configuration::DevConfig` to integrate devcontainer loading
- Enhanced CLI error handling for missing credentials and SSH keys

### Technical Details
- **Test Coverage**: 129 specs passing (100% success rate)
  - 13 specs for DevcontainerParser
  - 16 specs for Devcontainer configuration
  - 17 specs for StateManager
  - 18 specs for CLI commands
  - 65 specs for configuration and providers
  - 4 integration test scenarios (ENV-gated)
- **Code Quality**: Standard Ruby linter clean (0 violations)
- **Documentation**: Comprehensive YARD comments on all public methods

### Dependencies
- Added `faraday ~> 2.0` for HTTP client
- Added `faraday-retry ~> 2.0` for retry logic with exponential backoff
- Added `webmock ~> 3.18` (development) for HTTP request stubbing
- Added `active_support` for Hash#deep_symbolize_keys

### Known Limitations
- Docker bootstrap and SSH container deployment deferred to integration phase
- VM batching for count > 5 not yet implemented (sequential provisioning only)
- SSH key path currently hardcoded to `~/.ssh/id_rsa.pub` (TODO: make configurable)
- Provider support limited to UpCloud (multi-provider factory pattern planned)

## [0.1.0] - 2025-11-15

- Initial release
