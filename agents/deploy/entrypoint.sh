#!/usr/bin/env bash
set -euo pipefail

key_file=/run/secrets/deploy_agent_ssh_public_key
if [[ ! -s "${key_file}" ]]; then
  echo "Deploy Agent public key secret is missing." >&2
  exit 1
fi

export JENKINS_AGENT_SSH_PUBKEY
JENKINS_AGENT_SSH_PUBKEY="$(tr -d '\r\n' < "${key_file}")"
exec /usr/local/bin/setup-sshd
