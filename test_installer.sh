#!/bin/bash
# Test script for kamal-dev-install executable

set -e

echo "🧪 Testing kamal-dev-install..."
echo

# Store current directory (the gem root)
GEM_ROOT=$(pwd)

# Create a temporary test directory
TEST_DIR=$(mktemp -d)
echo "📁 Created test directory: $TEST_DIR"

cd "$TEST_DIR"

# Create a minimal Gemfile
cat > Gemfile <<EOF
source 'https://rubygems.org'

gem 'kamal', '~> 2.0'
gem 'kamal-dev', path: '$GEM_ROOT'
EOF

echo "✓ Created test Gemfile"

# Run bundle install
echo "📦 Running bundle install..."
bundle install --quiet

# Run the installer
echo "🔧 Running plugin-kamal-dev..."
bundle exec plugin-kamal-dev

# Verify bin/kamal exists
if [ ! -f "bin/kamal" ]; then
  echo "❌ FAILED: bin/kamal not created"
  exit 1
fi

echo "✓ bin/kamal exists"

# Verify it contains the require
if ! grep -q 'require "kamal-dev"' bin/kamal; then
  echo "❌ FAILED: bin/kamal does not contain kamal-dev require"
  exit 1
fi

echo "✓ bin/kamal contains kamal-dev require"

# Run installer again to test idempotency
echo "🔧 Running installer again (testing idempotency)..."
bundle exec plugin-kamal-dev

# Verify still only one require line
REQUIRE_COUNT=$(grep -c 'require "kamal-dev"' bin/kamal || true)
if [ "$REQUIRE_COUNT" -ne 1 ]; then
  echo "❌ FAILED: Expected 1 require line, found $REQUIRE_COUNT"
  exit 1
fi

echo "✓ Installer is idempotent"

# Cleanup
cd -
rm -rf "$TEST_DIR"
echo "🧹 Cleaned up test directory"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All installer tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
