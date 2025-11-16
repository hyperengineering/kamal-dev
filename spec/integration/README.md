# Integration Tests

This directory contains end-to-end integration tests that provision real cloud VMs on UpCloud.

**⚠️ WARNING: These tests provision real VMs and incur costs!**

## Prerequisites

1. **UpCloud Account**: You need a funded UpCloud account with available credits
2. **API Credentials**: Generate API credentials from UpCloud control panel
3. **SSH Key**: You must have an SSH public key at `~/.ssh/id_rsa.pub`
4. **Ruby Dependencies**: Run `bundle install` first

## Running Integration Tests

Integration tests are **disabled by default** to prevent accidental costs.

### Enable Integration Tests

Set the `INTEGRATION_TESTS` environment variable:

```bash
# Set UpCloud credentials
export UPCLOUD_USERNAME="your-api-username"
export UPCLOUD_PASSWORD="your-api-password"

# Run integration tests
INTEGRATION_TESTS=1 bundle exec rspec spec/integration/
```

### What Gets Tested

The full integration test suite covers:

1. **VM Provisioning**
   - Provisions 2 VMs on UpCloud (us-nyc1, 1xCPU-1GB plan)
   - Verifies VMs reach "running" status within timeout
   - Validates VM configuration (zone, plan, SSH key)

2. **State Management**
   - Creates `.kamal/dev_state.yml` with deployment records
   - Verifies state file structure and data integrity
   - Tests atomic writes and file locking

3. **Devcontainer Configuration**
   - Parses test devcontainer.json with comments
   - Generates Docker run commands with all flags
   - Validates port mappings, environment variables, resource limits

4. **CLI Commands**
   - `kamal dev deploy --count 2` - Deploys 2 containers
   - `kamal dev list` - Lists deployments
   - `kamal dev stop --all` - Stops all containers
   - `kamal dev remove --all --force` - Removes all deployments

5. **Cleanup**
   - Destroys provisioned VMs
   - Deletes state file when empty
   - Automatic cleanup on test failure

## Cost Estimation

Based on UpCloud's pricing (as of 2024):

- **Plan**: 1xCPU-1GB VM in us-nyc1
- **Hourly**: ~$0.01 per VM
- **Test Duration**: ~2-5 minutes per run
- **Estimated Cost**: **< $0.01 per test run**

The test suite provisions VMs for a few minutes then destroys them. Total cost should be negligible if tests complete successfully.

## Automatic Cleanup

The integration tests include **automatic cleanup hooks**:

- `after(:each)` hook destroys all provisioned VMs
- Cleanup runs even if tests fail
- VM IDs tracked in `provisioned_vms` array
- State file deleted after tests

**If cleanup fails**, manually destroy VMs via:

```bash
# List VMs in UpCloud control panel
# Or use UpCloud CLI:
upctl server list | grep kamal-dev-test
upctl server delete <vm-uuid>
```

## Test Configuration

Test fixtures in `spec/fixtures/integration/`:

- `devcontainer.json` - Minimal Ruby 3.2 devcontainer for testing
- `dev.yml` - Test configuration (2 VMs, us-nyc1, 1xCPU-1GB)

These use minimal resources to keep costs low.

## Debugging Failed Tests

If integration tests fail:

1. **Check UpCloud Dashboard**: Verify VMs were created
2. **Check State File**: Look at `.kamal/dev_state_integration_test.yml`
3. **Check VM Logs**: SSH to VMs if they weren't destroyed
4. **Check Credentials**: Verify `UPCLOUD_USERNAME` and `UPCLOUD_PASSWORD`
5. **Check SSH Key**: Verify `~/.ssh/id_rsa.pub` exists

## Running Specific Tests

```bash
# Run full lifecycle test
INTEGRATION_TESTS=1 bundle exec rspec spec/integration/dev_deployment_lifecycle_spec.rb

# Run specific describe block
INTEGRATION_TESTS=1 bundle exec rspec spec/integration/dev_deployment_lifecycle_spec.rb -e "VM provisioning"

# Verbose output
INTEGRATION_TESTS=1 bundle exec rspec spec/integration/ --format documentation
```

## Skipping Integration Tests

Integration tests are automatically skipped when `INTEGRATION_TESTS` is not set:

```bash
# Regular test suite (skips integration)
bundle exec rspec

# Output:
# ⚠️  Integration tests skipped (set INTEGRATION_TESTS=1 to run)
# 129 examples, 0 failures
```

## CI/CD Integration

For CI/CD pipelines (GitHub Actions, etc.):

```yaml
# .github/workflows/integration.yml
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run integration tests
        env:
          INTEGRATION_TESTS: 1
          UPCLOUD_USERNAME: ${{ secrets.UPCLOUD_USERNAME }}
          UPCLOUD_PASSWORD: ${{ secrets.UPCLOUD_PASSWORD }}
        run: bundle exec rspec spec/integration/
```

Store credentials in GitHub Secrets.

## Safety Features

1. **ENV Guard**: Tests skip unless `INTEGRATION_TESTS=1`
2. **Credential Check**: Tests skip if credentials missing
3. **SSH Key Check**: Tests skip if SSH key not found
4. **Automatic Cleanup**: VMs destroyed after each test
5. **Minimal Resources**: Uses smallest available VM plan
6. **Short Duration**: Tests complete in 2-5 minutes

## Limitations (Current Implementation)

**Note**: The current `kamal dev deploy` implementation does not yet include:

- SSH connection to VMs (deferred)
- Docker bootstrap on VMs (deferred)
- Actual container deployment via `docker run` (deferred)

Integration tests currently verify:
- ✅ VM provisioning
- ✅ State management
- ✅ Devcontainer parsing
- ✅ CLI command structure
- ⏸️ SSH/Docker execution (will be added in integration phase)

Full end-to-end Docker deployment will be tested once SSH integration is complete.

## Support

If you encounter issues:

1. Check prerequisites above
2. Verify UpCloud account has sufficient credits
3. Review UpCloud API documentation: https://developers.upcloud.com/
4. Open an issue with test output and error messages
