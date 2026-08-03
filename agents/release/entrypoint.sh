#!/usr/bin/env bash
set -euo pipefail

key_file=/run/secrets/release_agent_ssh_public_key
if [[ ! -s "${key_file}" ]]; then
  echo "Release Agent public key secret is missing." >&2
  exit 1
fi

export JENKINS_AGENT_SSH_PUBKEY
JENKINS_AGENT_SSH_PUBKEY="$(tr -d '\r\n' < "${key_file}")"
exec /usr/local/bin/setup-sshd

