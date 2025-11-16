# Kamal::Dev

**Scale your development capacity horizontally with cloud-powered devcontainer workspaces.**

Kamal::Dev extends [Kamal](https://github.com/basecamp/kamal) to deploy and manage development container workspaces to cloud infrastructure. Deploy multiple parallel development environments for AI-assisted development, remote pair programming, or horizontal scaling of development tasks.

## Features

- 🚀 **One-command deployment** - Deploy devcontainers from `.devcontainer/devcontainer.json` specifications
- ☁️ **Multi-cloud support** - Pluggable provider architecture (UpCloud reference implementation)
- 💰 **Cost estimation** - Preview cloud costs before provisioning VMs
- 🔒 **Secrets injection** - Secure credential management via `.kamal/secrets` system
- 📦 **State tracking** - Atomic state file operations with file locking
- 🔄 **Lifecycle management** - Full control: deploy, list, stop, remove workspaces
- ⚙️ **Resource limits** - Enforce CPU/memory constraints per container
- 🎯 **Docker-native** - Direct Docker command generation from devcontainer specs

## Installation

Add to your application's Gemfile:

```ruby
gem "kamal", "~> 2.0"
gem "kamal-dev"
```

Then run:

```bash
bundle install

# Run the plugin installer to set up kamal dev commands
bundle exec plugin-kamal-dev
```

The plugin installer will:
- Generate `bin/kamal` binstub if it doesn't exist
- Patch the binstub to load kamal-dev automatically
- Make `bin/kamal dev` commands available

**That's it!** You can now use `bin/kamal dev deploy`, `bin/kamal dev list`, etc.

### Alternative Setup Methods

If you prefer not to use the installer, you can manually set up kamal-dev:

<details>
<summary>Click to expand alternative setup options</summary>

**Option 1: Quick test (no installation)**

Use `bundle exec` with the `-r` flag:

```bash
bundle exec ruby -rkamal-dev -S kamal dev deploy
```

**Option 2: Manual binstub edit**

Generate the binstub and edit it manually:

```bash
bundle binstubs kamal --force
```

Then edit `bin/kamal` to add this line after the bundler setup:

```ruby
require "kamal-dev"  # Add this line to load kamal-dev extension
```

**Option 3: Rails/Boot file require**

If your project has a boot file (e.g., Rails `config/boot.rb`), add:

```ruby
require "kamal-dev"
```

Then use: `bundle exec kamal dev`

</details>

## Quick Start

**1. Create configuration file** (`config/dev.yml`):

```yaml
service: myapp-dev
image: .devcontainer/devcontainer.json  # Or direct image: "ruby:3.2"

provider:
  type: upcloud
  zone: us-nyc1
  plan: 1xCPU-2GB

secrets:
  - UPCLOUD_USERNAME
  - UPCLOUD_PASSWORD

defaults:
  cpus: 2
  memory: 4g

vms:
  count: 3
```

**2. Set up secrets** (`.kamal/secrets`):

```bash
export UPCLOUD_USERNAME="your-username"
export UPCLOUD_PASSWORD="your-password"
export GITHUB_TOKEN="ghp_..."
```

**3. Deploy workspaces:**

```bash
bin/kamal dev deploy --count 3
```

**4. List running workspaces:**

```bash
bin/kamal dev list

# Output:
# NAME          IP            STATUS   DEPLOYED AT
# myapp-dev-1   1.2.3.4       running  2025-11-16 10:30:00 UTC
# myapp-dev-2   2.3.4.5       running  2025-11-16 10:30:15 UTC
# myapp-dev-3   3.4.5.6       running  2025-11-16 10:30:30 UTC
```

**5. Stop/remove when done:**

```bash
bin/kamal dev stop --all     # Stop containers, keep VMs
bin/kamal dev remove --all   # Destroy VMs, cleanup state
```

## Configuration

### config/dev.yml Structure

```yaml
# Required fields
service: myapp-dev              # Service name prefix
image: .devcontainer/devcontainer.json  # Devcontainer spec or direct image

provider:
  type: upcloud                 # Cloud provider (upcloud, hetzner, aws, gcp)
  zone: us-nyc1                 # Data center location
  plan: 1xCPU-2GB               # VM size/plan

# Optional fields
secrets:                        # Secrets to inject from .kamal/secrets
  - GITHUB_TOKEN
  - DATABASE_URL

secrets_file: .kamal/secrets    # Custom secrets file path (default: .kamal/secrets)

ssh:
  key_path: ~/.ssh/id_ed25519.pub  # SSH public key (default: ~/.ssh/id_rsa.pub)

defaults:
  cpus: 2                       # Default CPU limit
  memory: 4g                    # Default memory limit
  memory_swap: 8g               # Swap limit

vms:
  count: 5                      # Number of workspaces to deploy
  spread: false                 # Colocate (false) or one per VM (true)

naming:
  pattern: "{service}-{index}"  # Container naming pattern
```

### Devcontainer.json Support

Kamal::Dev parses VS Code [devcontainer.json](https://containers.dev/) specifications and generates Docker run commands automatically:

**Supported properties:**
- `image` - Base Docker image
- `forwardPorts` - Port mappings (`-p 3000:3000`)
- `mounts` - Volume mounts (`-v source:target`)
- `containerEnv` - Environment variables (`-e KEY=value`)
- `runArgs` - Docker run flags (e.g., `--cpus=2`)
- `remoteUser` - Container user (`--user vscode`)
- `workspaceFolder` - Working directory (`-w /workspace`)

**Example devcontainer.json:**

```json
{
  "image": "ruby:3.2",
  "forwardPorts": [3000, 5432],
  "containerEnv": {
    "RAILS_ENV": "development"
  },
  "mounts": [
    "source=${localWorkspaceFolder},target=/workspace,type=bind"
  ],
  "remoteUser": "vscode",
  "workspaceFolder": "/workspace"
}
```

### Secrets Management

Secrets are loaded from `.kamal/secrets` (shell script with `export` statements) and injected into containers as Base64-encoded environment variables.

**.kamal/secrets:**

```bash
export GITHUB_TOKEN="ghp_your_token_here"
export DATABASE_URL="postgres://user:pass@host:5432/db"
```

**In container:**

```bash
# Secrets available as env vars
echo $GITHUB_TOKEN_B64 | base64 -d  # Decode if needed
```

## Commands Reference

All commands below assume you've run `bundle exec plugin-kamal-dev` as described in the Installation section. If you're using an alternative setup method, adjust the commands accordingly (see Alternative Setup Methods in Installation).

### deploy

Deploy devcontainer workspaces to cloud VMs.

```bash
kamal dev deploy [OPTIONS]

Options:
  --count N         Number of containers to deploy (default: from config)
  --from PATH       Path to devcontainer.json (default: from config)
  --config PATH     Path to config file (default: config/dev.yml)
```

**What it does:**
1. Loads configuration and devcontainer spec
2. Estimates cloud costs → prompts for confirmation
3. Provisions VMs via cloud provider API
4. Bootstraps Docker on VMs (if not installed)
5. Deploys containers with injected secrets
6. Saves state to `.kamal/dev_state.yml`

### list

List deployed devcontainer workspaces.

```bash
kamal dev list [OPTIONS]

Options:
  --format FORMAT   Output format: table (default), json, yaml
```

**Example output:**

```
NAME          IP            STATUS   DEPLOYED AT
myapp-dev-1   1.2.3.4       running  2025-11-16 10:30:00 UTC
myapp-dev-2   2.3.4.5       stopped  2025-11-16 10:30:15 UTC
```

### stop

Stop devcontainer(s) without destroying VMs.

```bash
kamal dev stop [NAME] [OPTIONS]

Arguments:
  NAME              Container name to stop (optional)

Options:
  --all             Stop all containers
```

**What it does:**
- Executes `docker stop {container}` via SSH
- Updates state file: status → "stopped"
- VMs remain running (reduces restart time)

### remove

Destroy VMs and remove container state.

```bash
kamal dev remove [NAME] [OPTIONS]

Arguments:
  NAME              Container name to remove (optional)

Options:
  --all             Remove all containers
  --force           Skip confirmation prompt
```

**What it does:**
1. Prompts for confirmation (unless `--force`)
2. Stops containers via `docker stop`
3. Destroys VMs via provider API
4. Removes entries from state file
5. Deletes state file if empty

### status

Show detailed status of devcontainer(s).

```bash
kamal dev status [NAME] [OPTIONS]

Arguments:
  NAME              Container name to check (optional)

Options:
  --all             Show status for all containers
```

## Troubleshooting

### VM Provisioning Fails

**Problem:** `ProvisioningError: VM failed to reach running state`

**Solutions:**
- Check provider API credentials in `.kamal/secrets`
- Verify zone/region availability
- Check account quotas (VMs, storage, IPs)
- Try smaller VM plan (e.g., 1xCPU-1GB)

### Container Won't Start

**Problem:** Container status shows "failed"

**Solutions:**
- Check image name in devcontainer.json
- Verify secrets are valid (Base64 encoding issues)
- SSH to VM and check Docker logs: `ssh root@{vm_ip} docker logs {container}`
- Review resource limits (may be too restrictive)

### State File Corruption

**Problem:** "State file appears corrupted or locked"

**Solutions:**
```bash
# Check for lock file
ls -la .kamal/dev_state.yml.lock

# Remove stale lock (if no processes using it)
rm .kamal/dev_state.yml.lock

# Rebuild state from provider dashboard
kamal dev list --rebuild  # (future feature)
```

### SSH Key Not Found

**Problem:** "SSH public key not found at ~/.ssh/id_rsa.pub"

**Solutions:**
```yaml
# Configure custom SSH key in config/dev.yml
ssh:
  key_path: ~/.ssh/id_ed25519.pub
```

Or generate new SSH key:
```bash
ssh-keygen -t ed25519 -C "kamal-dev@example.com"
```

### Debug Mode

Enable verbose logging:

```bash
VERBOSE=1 kamal dev deploy --count 2
```

## Development

After checking out the repo:

```bash
# Install dependencies
bin/setup

# Run tests
bundle exec rspec

# Run linter
bundle exec standardrb

# Run full suite (tests + linter)
bundle exec rake

# Interactive console
bin/console

# Install locally for testing
bundle exec rake install
```

### Integration Tests

Integration tests provision real VMs (costs money). Set up test credentials:

```bash
# Create .kamal/secrets with UpCloud test account
export UPCLOUD_USERNAME="test-user"
export UPCLOUD_PASSWORD="test-password"

# Run integration tests
INTEGRATION_TESTS=1 bundle exec rspec
```

**⚠️ Warning:** Integration tests will provision and destroy VMs. Estimated cost: ~$0.01-0.05 per test run.

## Architecture

### Provider Adapter Pattern

```
┌─────────────┐
│   CLI       │
│  Commands   │
└──────┬──────┘
       │
       ▼
┌──────────────────┐      ┌─────────────────┐
│ Provider::Base   │◄─────┤ DevConfig       │
│  (interface)     │      │ (configuration) │
└────────┬─────────┘      └─────────────────┘
         │
         ├──► Provider::Upcloud
         ├──► Provider::Hetzner  (future)
         ├──► Provider::AWS      (future)
         └──► Provider::GCP      (future)
```

### State Management

State is tracked in `.kamal/dev_state.yml` with file locking to prevent corruption:

```yaml
deployments:
  myapp-dev-1:
    vm_id: "00abc123-def4-5678-90ab-cdef12345678"
    vm_ip: "1.2.3.4"
    container_name: "myapp-dev-1"
    status: running
    deployed_at: "2025-11-16T14:30:00Z"
```

**File locking:**
- Uses `File.flock(File::LOCK_EX)` for exclusive writes
- Uses `File.flock(File::LOCK_SH)` for shared reads
- NFS-compatible dotlock fallback

## Roadmap

- [ ] Hetzner Cloud provider adapter
- [ ] AWS EC2 provider adapter
- [ ] GCP Compute Engine provider adapter
- [ ] Multi-project workspace sharing
- [ ] Automatic workspace hibernation (cost optimization)
- [ ] Devcontainer features support (via devcontainer CLI)
- [ ] Web UI for workspace management

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ljuti/kamal-dev.

**Before submitting a PR:**
1. Run full test suite: `bundle exec rake`
2. Ensure linter passes: `bundle exec standardrb`
3. Add tests for new features
4. Update CHANGELOG.md
5. Update documentation (README, YARD comments)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Built as an extension to [Kamal](https://github.com/basecamp/kamal) by Basecamp.
