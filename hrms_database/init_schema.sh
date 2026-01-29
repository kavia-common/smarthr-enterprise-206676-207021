#!/bin/bash
set -euo pipefail

# Applies schema.sql to the running database once PostgreSQL is up.
# This script is safe to run multiple times; schema.sql uses IF NOT EXISTS and ON CONFLICT.
DB_NAME="myapp"
DB_USER="appuser"
DB_PORT="5000"

PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Initializing HRMS schema (if needed)..."

# Wait until server is ready (startup.sh already does, but keep this robust)
for i in {1..30}; do
  if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Apply schema as the app user (so objects belong to appuser by default privileges)
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -v ON_ERROR_STOP=1 -U ${DB_USER} -f "$(dirname "$0")/schema.sql"

echo "✓ HRMS schema initialized."
