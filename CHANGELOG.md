## [Unreleased]

## [0.3.0] - 2025-11-22

### Added - DevPod-Style Remote Development with Git Clone

#### Remote Code Sync Feature
- **Git Clone Integration** for DevPod-style remote development
  - Code is cloned from git repository into containers (instead of mounted from local machine)
  - Supports private repositories via GitHub Personal Access Token (PAT)
  - Automatic credential caching for git operations (pull/push)
  - Works seamlessly alongside local VS Code devcontainer workflow (auto-detects deployment vs local)
  - Pure cloud deployment capability - no local file mounting required

- **Configuration Options** (`config/dev.yml`)
  ```yaml
  git:
    repository: https://github.com/user/repo.git  # Git repository URL (HTTPS format)
    branch: main                                   # Branch to checkout (default: main)
    workspace_folder: /workspaces/myapp           # Where to clone code
    token: GITHUB_TOKEN                           # Environment variable name for PAT
  ```

- **Entrypoint Script Injection** (`dev-entrypoint.sh`)
  - Automatically injected into Docker images during build when git clone is configured
  - Clones repository on first container startup
  - Handles authentication via token injection into HTTPS URL
  - Configures git credential helper for persistent authentication
  - Skips clone operation for local VS Code devcontainers (uses mounted code)
  - Creates `/workspaces` directory with proper ownership for non-root users

- **Token-Based Authentication**
  - HTTPS git cloning with GitHub Personal Access Token
  - Simpler and more robust than SSH key-based authentication
  - Single-line environment variable (no multi-line key handling issues)
  - Token loaded from `.kamal/secrets` via environment variable
  - Automatic validation before deployment with helpful error messages

- **Deployment Validation**
  - Pre-deployment git configuration validation
  - Errors if token ENV var configured but not set (prevents silent failures)
  - Warns when using public repository without token
  - Provides actionable error messages with setup instructions
  - Skips validation for SSH URLs (git@github.com:...)

- **Compose File Transformation**
  - Automatic injection of git environment variables into compose services
  - Environment variables set for remote deployments:
    - `KAMAL_DEV_GIT_REPO` - Repository URL
    - `KAMAL_DEV_GIT_BRANCH` - Branch name
    - `KAMAL_DEV_WORKSPACE_FOLDER` - Workspace path
    - `KAMAL_DEV_GIT_TOKEN` - Authentication token (if configured)
  - Preserves existing environment variables
  - Only injects variables when git clone is enabled

### Changed
- **Image Build Process**
  - Wrapper Dockerfile generation when git clone is enabled
  - Entrypoint script copied with execute permissions (755)
  - `/workspaces` directory created with proper ownership (vscode:vscode)
  - Original Dockerfile extended with git clone functionality
  - Build artifacts automatically cleaned up after build

- **ComposeParser** (`lib/kamal/dev/compose_parser.rb`)
  - Enhanced `transform_for_deployment` to accept optional config parameter
  - Git environment variables injected when config provided
  - Context paths now resolved relative to compose file location (fixes relative path issues)

### Documentation
- **README.md** - Comprehensive "Remote Code Sync (DevPod-Style)" section:
  - How it works (build → startup → clone workflow)
  - Step-by-step GitHub PAT setup instructions
  - Configuration examples
  - Verification commands
  - Troubleshooting guide with common issues
  - Important notes about HTTPS URLs, token security, and local development

### Testing
- **30 New Tests** (336 total examples, 0 failures)
  - **ComposeParser Tests** (5 tests): Git environment variable injection
    - Validates injection when git clone enabled
    - Verifies environment variable preservation
    - Tests no injection when disabled
    - Handles missing token gracefully
    - Creates environment section when missing
  - **Config Tests** (16 tests): Git configuration methods
    - `git_repository`, `git_branch`, `git_workspace_folder`
    - `git_token_env`, `git_token` (with ENV loading)
    - `git_clone_enabled?` validation logic
    - Default values and edge cases
  - **CLI Validation Tests** (9 tests): Token validation before deployment
    - Successful validation with token
    - Error on missing ENV var
    - Warning for public repos
    - SSH URL handling
    - Edge cases (nil, empty string)

### Technical Details
- **Authentication Method**: GitHub Personal Access Token (PAT) via HTTPS
  - Replaces earlier SSH key approach (simpler, more robust)
  - No multi-line environment variable handling issues
  - Works consistently across all shells and environments
- **Token Scopes Required**: `repo` scope for private repositories
- **Supported Git Hosts**: Any HTTPS-based git hosting (GitHub, GitLab, Bitbucket, etc.)
- **Supported URL Formats**: HTTPS only (`https://github.com/user/repo.git`)
- **Local Development**: Git clone automatically skipped when environment variables not present

### Examples

#### Private Repository Configuration
```yaml
# config/dev.yml
git:
  repository: https://github.com/myorg/private-repo.git
  branch: main
  workspace_folder: /workspaces/myapp
  token: GITHUB_TOKEN

# .kamal/secrets
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
```

#### Deploy and Verify
```bash
kamal dev deploy --count 2

# Verify git clone succeeded
ssh root@<vm-ip>
docker logs myapp-dev-1-app

# Output:
# [kamal-dev] Remote deployment detected
# [kamal-dev] Cloning https://github.com/myorg/private-repo.git (branch: main)
# [kamal-dev] Clone complete: /workspaces/myapp
```

### Migration Notes
- Existing deployments without git configuration continue to work unchanged
- Git clone is opt-in via `git:` section in `config/dev.yml`
- No breaking changes to existing functionality

## [0.2.0] - 2025-11-18

### Added - Epic 2: Docker Compose & Build Support

#### Story 2.1: Registry Configuration & Image Builder Integration
- **Registry Integration** (`Kamal::Dev::Registry`)
  - Container registry configuration (GHCR, Docker Hub, custom registries)
  - Credential loading from environment variables via `.kamal/secrets`
  - Docker login command generation
  - Image naming conventions: `{server}/{username}/{service}-dev:{tag}`
  - Tag generation strategies:
    - Timestamp tags (Unix timestamp)
    - Git SHA tags (7-character short hash)
  - Credential validation and error handling
  - Multi-registry support (ghcr.io, docker.io, custom)

- **Image Builder** (`Kamal::Dev::Builder`)
  - Docker image building from Dockerfiles
  - Build progress display and streaming output
  - Build arguments support
  - Tag management (timestamp, git SHA, custom)
  - Image pushing to container registries
  - Registry authentication (docker login)
  - Docker availability checks
  - Image existence verification
  - Comprehensive error handling:
    - Build failures with detailed output
    - Push failures (authentication, network)
    - Docker daemon availability

- **CLI Commands**
  - `kamal dev build` - Build image from Dockerfile
    - Auto-generates timestamp tag if not provided
    - Supports custom Dockerfile paths
    - Build arguments via `--build-arg`
    - Display build progress in real-time
  - `kamal dev push` - Push image to registry
    - Automatic registry authentication
    - Push progress display
    - Verification of successful push

#### Story 2.2: Compose Parser & Stack Deployment
- **Docker Compose Parser** (`Kamal::Dev::ComposeParser`)
  - Docker Compose YAML parsing and validation
  - Service extraction and analysis
  - Main service identification (first with `build:` section)
  - Build context and Dockerfile path extraction
  - Dependent service detection (services without `build:`)
  - Compose file transformation for deployment:
    - Replace `build:` sections with `image:` references
    - Preserve dependent services (postgres, redis, etc.)
    - Preserve volumes, networks, environment variables
    - Preserve service dependencies (`depends_on`)
  - Support for shorthand and expanded build syntax
  - Comprehensive error handling and validation

- **Devcontainer Compose Integration**
  - `dockerComposeFile` property support in devcontainer.json
  - Automatic compose file detection and loading
  - Seamless integration with existing devcontainer workflow

- **Multi-Service Stack Deployment**
  - Full compose stack deployment to each VM
  - Isolated stacks per workspace (each gets own database/cache)
  - Docker Compose v2 installation on VMs during bootstrap
  - Transformed compose.yaml deployment via `docker-compose up -d`
  - Container tracking for all services in stack
  - Support for complex stacks (app + database + cache + worker)

- **Enhanced CLI Commands**
  - `kamal dev deploy` - Enhanced with compose support
    - `--skip-build` flag - Use existing local image
    - `--skip-push` flag - Use local image, don't push to registry
    - Automatic build → push → deploy workflow
    - Multi-service deployment tracking
  - `kamal dev list` - Shows all containers in compose stacks
    - Displays app containers and dependent services
    - Status for each service in the stack

#### Story 2.3: Testing & Documentation
- **Test Coverage**
  - 252 total test examples (110 new for Epic 2)
  - Registry: 20 comprehensive unit tests
  - Builder: 15 comprehensive unit tests
  - ComposeParser: 47 comprehensive unit tests
  - 100% test pass rate
  - Code quality: Standard Ruby linter clean (0 violations)

- **Documentation**
  - **README.md** - Comprehensive Docker Compose support section:
    - Registry configuration guide
    - Building and pushing images
    - Multi-service deployment examples
    - Compose file requirements and limitations
    - Troubleshooting compose deployments
  - **docs/compose-workflow.md** - Complete workflow guide:
    - Step-by-step deployment process
    - Workflow diagram with visual representation
    - Compose file transformation explained
    - Service detection logic
    - Multi-VM deployment architecture
    - Examples: Rails + Postgres, Node + Mongo + Redis, Python + Celery
    - Best practices and troubleshooting
  - **docs/registry-setup.md** - Registry configuration guide:
    - GitHub Container Registry (GHCR) setup
    - Docker Hub setup
    - Custom/private registry configuration
    - AWS ECR, GCR, ACR integration
    - Authentication testing procedures
    - Security best practices
    - Cost considerations and comparisons

### Changed - Epic 2
- Enhanced `kamal dev deploy` to support full build → push → deploy workflow
- Updated state tracking to handle multi-service compose stacks
- Improved error messages for registry and build failures

### Technical Details - Epic 2
- **New Dependencies**: None (uses stdlib YAML and Open3)
- **Supported Registries**: GHCR, Docker Hub, custom Docker-compatible registries
- **Supported Compose Features**:
  - Services with `build:` sections
  - Services with `image:` references
  - Build context (string or object format)
  - Dockerfile path specification
  - Environment variables, volumes, ports
  - Service dependencies (`depends_on`)
  - Named volumes
- **Limitations**: Single architecture builds (amd64), no shared databases across VMs

### Examples - Epic 2

#### Rails Application with PostgreSQL
```yaml
services:
  app:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile
    environment:
      DATABASE_URL: postgres://postgres:postgres@postgres:5432/myapp_dev
    ports:
      - "3000:3000"
  postgres:
    image: postgres:16
    volumes:
      - postgres_data:/var/lib/postgresql/data
volumes:
  postgres_data:
```

Deploy: `kamal dev deploy --count 3` creates 3 isolated stacks

## [0.1.4] - 2025-11-16

### Added
- **`kamal dev init` command**: Generate `config/dev.yml` template
  - Creates comprehensive configuration template with inline documentation
  - Prompts before overwriting existing configuration
  - Automatically creates `config/` directory if needed
  - Displays helpful next steps after generation
  - Template includes all configuration options with examples and comments

### Changed
- **Quick Start documentation**: Updated to use `kamal dev init` instead of manual config creation
- **Commands Reference**: Added full documentation for `init` command

## [0.1.3] - 2025-11-16

### Added
- **Interactive Installation Mode Selection**: `plugin-kamal-dev` now prompts user to choose installation method
  - Option 1: Patch gem-installed kamal executable (global, works with `kamal dev` and `bundle exec kamal dev`)
  - Option 2: Create project binstub `bin/kamal` (local, use `bin/kamal dev`)
  - Default: Option 1 (gem executable patching)
- **Automatic Backup**: Creates `.backup` file before patching gem executable
- **Smart Executable Discovery**: Finds kamal executable via `bundle exec which`, `which`, or gem environment

### Changed
- Installer now defaults to patching gem executable instead of creating binstub
- Success messages updated based on chosen installation mode
- Better user guidance on how to use kamal dev after installation

## [0.1.2] - 2025-11-16

### Added
- **Automatic Plugin Installer** (`plugin-kamal-dev` executable)
  - One-command setup: `bundle exec plugin-kamal-dev`
  - Automatically generates `bin/kamal` binstub if missing
  - Intelligently patches binstub to load kamal-dev extension
  - Idempotent - safe to run multiple times
  - Three insertion strategies for maximum compatibility
  - Clear success/error messages with usage instructions
  - Comprehensive test suite (`test_installer.sh`)
- **Reference Implementation**: `bin/kamal-template` binstub example

### Changed
- **Simplified Installation Flow**: Plugin installer is now the primary installation method
  - Primary: `bundle exec plugin-kamal-dev` (one command, fully automated)
  - Alternative options available for users who prefer manual setup
  - Updated Quick Start examples to use `bin/kamal dev` commands
  - Updated Commands Reference with simpler usage patterns

### Documentation
- Restructured README with automatic installer as recommended approach
- Clear step-by-step installation instructions
- Alternative setup methods in collapsible section
- Examples updated to match installer output

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
