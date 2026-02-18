#!/bin/bash
set -e

# Generate Rails skeleton if it doesn't exist yet
# This creates all the boilerplate files (config/, bin/, etc.)
# It will NOT overwrite files that already exist (our custom controllers, views, etc.)
if [ ! -f "/rails/config/application.rb" ]; then
  echo "=== Generating Rails skeleton ==="
  rails new . --skip-test --skip-system-test --skip-active-record --skip-active-storage --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-action-cable --skip-bundle --skip-git --name=comisiones_dashboard
  echo "=== Rails skeleton generated ==="
fi

# Install gems
echo "=== Installing gems ==="
bundle install

# Setup importmap if needed
if [ ! -f "/rails/config/importmap.rb" ]; then
  echo "=== Setting up importmap ==="
  rails importmap:install 2>/dev/null || true
  rails turbo:install 2>/dev/null || true
  rails stimulus:install 2>/dev/null || true
fi

# Remove stale PID
rm -f /rails/tmp/pids/server.pid

echo "=== Starting server ==="
exec "$@"
