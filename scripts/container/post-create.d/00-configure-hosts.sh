#!/usr/bin/env bash
set -euo pipefail

# Get the current container hostname dynamically
HOSTNAME=$(hostname)

# Add hostname to /etc/hosts if not already present
if ! grep -q "^127.0.0.1.*${HOSTNAME}" /etc/hosts; then
  echo "127.0.0.1 ${HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
fi
