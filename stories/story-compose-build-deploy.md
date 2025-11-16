# Story: Docker Compose Build and Deploy Support

**Epic:** Core Functionality
**Story ID:** KDEV-002
**Priority:** High
**Estimated Effort:** 3-5 days
**Status:** TODO

## User Story

**As a** developer using kamal-dev with a Rails application
**I want to** deploy my devcontainer that uses Docker Compose with a custom Dockerfile
**So that** I can deploy isolated development workspaces with all required services (app + database)

## Current Limitation

Currently kamal-dev only supports devcontainer.json files with direct `image` property:

```json
{
  "image": "ruby:3.2"  // ✅ Works
}
```

It **does not support**:
- `build` property (custom Dockerfile)
- `dockerComposeFile` property (multi-service setups)
- Building and pushing images to registries

**Error encountered:**
```
ERROR (Kamal::Dev::DevcontainerParser::ValidationError):
Devcontainer.json must specify either 'image' or 'dockerfile' property
```

## Acceptance Criteria

### 1. Registry Configuration
- [ ] Add `registry` section to `config/dev.yml` template
- [ ] Support Docker Hub, GitHub Container Registry (GHCR), and other registries
- [ ] Load registry credentials from `.kamal/secrets`
- [ ] Default to GHCR if not specified

### 2. Devcontainer Parser Enhancement
- [ ] Parse `dockerComposeFile` property from devcontainer.json
- [ ] Parse `build` property (Dockerfile path)
- [ ] Handle `service` property (which service to use as main container)
- [ ] Extract build context from compose.yaml

### 3. Image Build Phase
- [ ] Integrate with Kamal 2.8.2's builder system (`Kamal::Commands::Builder`)
- [ ] Build Docker image from Dockerfile specified in compose.yaml
- [ ] Tag image with format: `{registry}/{user}/{service}-dev:{timestamp|git-sha}`
- [ ] Support build arguments and secrets
- [ ] Display build progress to user

### 4. Image Push Phase
- [ ] Push built image to configured registry
- [ ] Authenticate with registry using credentials from secrets
- [ ] Show push progress
- [ ] Verify image was pushed successfully

### 5. Compose Deployment
- [ ] Install `docker-compose` on VMs during bootstrap (if not present)
- [ ] Copy compose.yaml to VM
- [ ] Transform compose.yaml: replace `build:` with `image:` pointing to pushed image
- [ ] Handle volume mounts (workspace folder)
- [ ] Handle environment variables from devcontainer.json
- [ ] Deploy full compose stack: `docker-compose up -d`
- [ ] Each VM gets isolated stack (app + postgres + any other services)

### 6. CLI Enhancements
- [ ] `kamal dev build` - Build image only (no push)
- [ ] `kamal dev push` - Push built image to registry
- [ ] `kamal dev deploy` - Build, push, and deploy
- [ ] `--skip-build` flag to use existing image
- [ ] `--skip-push` flag to use local image only
- [ ] Display service status for all containers in compose stack

### 7. Error Handling
- [ ] Clear error if Docker is not installed locally
- [ ] Clear error if registry credentials are missing
- [ ] Clear error if build fails
- [ ] Clear error if push fails
- [ ] Cleanup on failure (remove partially built images)

## Technical Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Local Development Machine                                   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ kamal dev deploy --count 3                           │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Parse devcontainer.json + compose.yaml            │  │
│  │    - Extract build context                           │  │
│  │    - Identify services                               │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 2. Build Image (via Kamal::Commands::Builder)        │  │
│  │    docker build -t ghcr.io/user/app-dev:sha123 .     │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 3. Push to Registry                                  │  │
│  │    docker push ghcr.io/user/app-dev:sha123           │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
└─────────────────────┼────────────────────────────────────────┘
                      │
                      ▼
        ┌─────────────────────────────┐
        │ Container Registry (GHCR)   │
        │ ghcr.io/user/app-dev:sha123 │
        └─────────────┬───────────────┘
                      │
         ┌────────────┴────────────┐
         │                         │
         ▼                         ▼
┌─────────────────┐       ┌─────────────────┐
│ VM 1            │       │ VM 2            │
│                 │       │                 │
│ compose.yaml:   │       │ compose.yaml:   │
│                 │       │                 │
│ services:       │       │ services:       │
│   app:          │       │   app:          │
│     image: ghcr │       │     image: ghcr │
│   postgres:     │       │   postgres:     │
│     image: pg16 │       │     image: pg16 │
│                 │       │                 │
│ docker-compose  │       │ docker-compose  │
│   up -d         │       │   up -d         │
└─────────────────┘       └─────────────────┘
```

### Key Components to Implement

#### 1. Registry Configuration (`lib/kamal/dev/registry.rb`)

```ruby
class Kamal::Dev::Registry
  def initialize(config)
    @config = config
  end

  def server
    @config["server"] || "ghcr.io"
  end

  def username
    ENV[@config["username_env"]] || ENV["GITHUB_USER"]
  end

  def password
    ENV[@config["password_env"]] || ENV["GITHUB_TOKEN"]
  end

  def image_name(service)
    "#{server}/#{username}/#{service}-dev"
  end

  def image_tag(service, tag = "latest")
    "#{image_name(service)}:#{tag}"
  end

  def login_command
    # Generate docker login command
  end
end
```

#### 2. Builder Integration (`lib/kamal/dev/builder.rb`)

```ruby
class Kamal::Dev::Builder
  # Wrapper around Kamal::Commands::Builder
  # NOTE: Use Kamal 2.8.2 builder implementation as reference

  def build(dockerfile_path, context_path, tag)
    # Use Kamal's builder to build image
  end

  def push(tag)
    # Use Kamal's builder to push image
  end

  def tag_with_timestamp(base_tag)
    "#{base_tag}:#{Time.now.to_i}"
  end

  def tag_with_git_sha(base_tag)
    sha = `git rev-parse --short HEAD`.strip
    "#{base_tag}:#{sha}"
  end
end
```

#### 3. Compose Parser (`lib/kamal/dev/compose_parser.rb`)

```ruby
class Kamal::Dev::ComposeParser
  def initialize(compose_file_path)
    @compose_data = YAML.load_file(compose_file_path)
  end

  def services
    @compose_data["services"]
  end

  def main_service(service_name)
    services[service_name]
  end

  def build_context(service_name)
    service = main_service(service_name)
    service.dig("build", "context")
  end

  def dockerfile_path(service_name)
    service = main_service(service_name)
    service.dig("build", "dockerfile")
  end

  def transform_for_deploy(service_name, image_tag)
    # Clone compose config
    # Replace "build:" with "image: {image_tag}"
    # Remove volume mounts that reference local workspace
    # Return transformed YAML string
  end
end
```

#### 4. Enhanced Devcontainer Parser

Update `lib/kamal/dev/devcontainer_parser.rb`:

```ruby
def parse_compose_reference
  return nil unless devcontainer_config["dockerComposeFile"]

  compose_file = devcontainer_config["dockerComposeFile"]
  service_name = devcontainer_config["service"]

  {
    compose_file: compose_file,
    service: service_name,
    workspace_folder: devcontainer_config["workspaceFolder"]
  }
end
```

#### 5. Deploy Command Updates

Update `lib/kamal/cli/dev.rb#deploy`:

```ruby
def deploy(name = nil)
  config = load_config

  # 1. Check if devcontainer uses compose
  if config.devcontainer.uses_compose?
    deploy_with_compose(config)
  else
    deploy_with_simple_image(config)
  end
end

def deploy_with_compose(config)
  # 1. Build image
  puts "🔨 Building image..."
  builder = Kamal::Dev::Builder.new(config)
  image_tag = builder.build_and_tag

  # 2. Push to registry
  puts "⬆️  Pushing to registry..."
  builder.push(image_tag)

  # 3. Provision VMs
  puts "☁️  Provisioning VMs..."
  vms = provision_vms(config, count)

  # 4. Bootstrap VMs (Docker + docker-compose)
  puts "🔧 Bootstrapping VMs..."
  bootstrap_vms(vms, install_compose: true)

  # 5. Deploy compose stack to each VM
  puts "🚀 Deploying compose stacks..."
  vms.each do |vm|
    deploy_compose_to_vm(vm, config, image_tag)
  end
end

def deploy_compose_to_vm(vm, config, image_tag)
  # Copy transformed compose.yaml
  # Run docker-compose up -d via SSH
  # Verify all services started
end
```

### Configuration Schema (`config/dev.yml`)

```yaml
service: metalsmoney-dev

# Registry configuration for built images
registry:
  server: ghcr.io  # or hub.docker.com, or custom registry
  username_env: GITHUB_USER
  password_env: GITHUB_TOKEN

# Image configuration
image:
  # Option 1: Use devcontainer.json
  devcontainer: .devcontainer/devcontainer.json

  # Option 2: Direct image reference (simple case)
  # name: ruby:3.2

# Build configuration (optional, for advanced use)
build:
  cache: true
  args:
    RUBY_VERSION: 3.4.6
  secrets:
    - BUNDLE_GITHUB__COM

# Provider, secrets, defaults, vms (unchanged)
# ...
```

### Secrets Configuration (`.kamal/secrets`)

```bash
# Existing
export UPCLOUD_USERNAME="..."
export UPCLOUD_PASSWORD="..."

# New - Registry credentials
export GITHUB_USER="ljuti"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"

# Or for Docker Hub
export DOCKER_HUB_USERNAME="..."
export DOCKER_HUB_PASSWORD="..."

# Build secrets
export BUNDLE_GITHUB__COM="x-access-token:${GITHUB_TOKEN}"
```

## Implementation Steps

### Phase 1: Registry & Builder Foundation (Day 1)
1. Create `Kamal::Dev::Registry` class
2. Create `Kamal::Dev::Builder` wrapper around Kamal 2.8.2 builder
3. Add registry config to `dev.yml` template
4. Add registry credentials loading from secrets
5. Test: Build and push simple image manually

### Phase 2: Compose Parsing (Day 2)
1. Create `Kamal::Dev::ComposeParser` class
2. Update `DevcontainerParser` to detect compose usage
3. Parse compose.yaml to extract build context and services
4. Test: Parse example Rails compose.yaml correctly

### Phase 3: Build & Push Integration (Day 3)
1. Integrate builder into deploy command
2. Add build progress output
3. Add push progress output
4. Handle build failures gracefully
5. Test: Build and push metalsmoney image

### Phase 4: Compose Deployment (Day 4)
1. Install docker-compose on VMs during bootstrap
2. Transform compose.yaml (build → image)
3. Copy compose.yaml to VM via SSH
4. Deploy compose stack via SSH
5. Verify services started
6. Update state with all running containers
7. Test: Deploy full stack to single VM

### Phase 5: Multi-VM & Polish (Day 5)
1. Deploy to multiple VMs
2. Add `kamal dev build` command
3. Add `kamal dev push` command
4. Add `--skip-build` and `--skip-push` flags
5. Update README with compose workflow
6. Test: Full end-to-end workflow with 3 VMs

## Testing Strategy

### Unit Tests
- [ ] `Kamal::Dev::Registry` specs
  - Image name generation
  - Credential loading
  - Login command generation

- [ ] `Kamal::Dev::Builder` specs
  - Build command generation
  - Push command generation
  - Tagging strategies

- [ ] `Kamal::Dev::ComposeParser` specs
  - Service extraction
  - Build context resolution
  - Compose transformation

### Integration Tests
**Note:** Mark with `skip unless ENV["RUN_INTEGRATION_TESTS"]`

- [ ] Build and push image to test registry
- [ ] Deploy compose stack to single VM
- [ ] Verify all services running
- [ ] Cleanup (remove containers, VMs, registry images)

### Manual Test Case (metalsmoney example)
```bash
# Setup
cd /path/to/metalsmoney
echo 'export GITHUB_USER="ljuti"' >> .kamal/secrets
echo 'export GITHUB_TOKEN="ghp_xxx"' >> .kamal/secrets

# Initialize
kamal dev init

# Edit config/dev.yml (add registry config)

# Deploy
kamal dev deploy --count 2

# Expected result:
# - Image built: ghcr.io/ljuti/metalsmoney-dev:abc123
# - Image pushed to GHCR
# - 2 VMs provisioned
# - Each VM running:
#   - metalsmoney-dev-1 (rails-app container)
#   - metalsmoney-dev-1-postgres (database container)
# - Can SSH to VM and run: docker-compose ps
```

## Dependencies

- Kamal 2.8.2 source code (for builder reference)
- Docker buildx (for multi-platform builds, if needed)
- Docker Compose v2 on VMs
- Container registry (GHCR, Docker Hub, etc.)

## Known Limitations & Future Work

- **Single Dockerfile only**: Current scope handles one app image. Multi-image builds deferred.
- **No docker-compose features**: Advanced features (networks, configs, profiles) not supported yet.
- **No image caching**: Each build is fresh. Add layer caching in future.
- **No multi-platform builds**: Focus on single architecture. Add arm64/amd64 support later.
- **Workspace mounting**: Currently removed from compose on deploy. Consider adding read-only workspace sync.

## Documentation Updates

### README.md
- [ ] Add "Docker Compose Support" section
- [ ] Document registry configuration
- [ ] Add full Rails app example
- [ ] Update Quick Start with build workflow

### CHANGELOG.md
- [ ] Document new registry configuration
- [ ] Document compose support
- [ ] Note Kamal 2.8.2 builder integration

### New Documentation
- [ ] Create `docs/compose-workflow.md`
- [ ] Create `docs/registry-setup.md`
- [ ] Add troubleshooting for build failures

## Definition of Done

- [ ] All acceptance criteria met
- [ ] Unit tests passing (90%+ coverage for new code)
- [ ] Integration tests passing (with real registry and VM)
- [ ] Manual test with metalsmoney app successful
- [ ] Documentation updated (README, CHANGELOG, new docs)
- [ ] Code reviewed
- [ ] Works with Kamal 2.8.2 builder
- [ ] No regressions (simple image deployment still works)

## Notes

- **CRITICAL**: Reference Kamal 2.8.2 source when integrating builder, not 2.2.2
  - Path: `~/.gem/ruby/3.2.3/gems/kamal-2.8.2/lib/kamal/commands/builder.rb`
  - Check for new features added in 2.8.x (e.g., local registry support)
- Consider using Kamal's local registry feature for simpler deployments (no external registry needed)
- Compose transformation must preserve service dependencies
- Each workspace is isolated (own database) - this is intentional for dev environments
