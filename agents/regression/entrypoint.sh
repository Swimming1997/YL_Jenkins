#!/usr/bin/env bash
set -euo pipefail

key_file=/run/secrets/regression_agent_ssh_public_key
if [[ ! -s "${key_file}" ]]; then
  echo "Regression Agent public key secret is missing." >&2
  exit 1
fi

install -m 0600 -o jenkins -g jenkins "${key_file}" /home/jenkins/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
