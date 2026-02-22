#!/bin/bash
set -e

# Remove stale PID
rm -f /rails/tmp/pids/server.pid

echo "=== Starting server ==="
exec "$@"
