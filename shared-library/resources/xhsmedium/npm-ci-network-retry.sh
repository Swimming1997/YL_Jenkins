#!/usr/bin/env bash
set -uo pipefail

attempt=1
max_attempts=3
retry_log=''

cleanup_retry_log() {
    if [ -n "$retry_log" ]; then
        rm -f -- "$retry_log"
        retry_log=''
    fi
}
trap cleanup_retry_log EXIT
trap 'cleanup_retry_log; exit 130' INT TERM

while [ "$attempt" -le "$max_attempts" ]; do
    retry_log=$(mktemp "${TMPDIR:-/tmp}/npm-ci-network-retry.XXXXXX")
    npm ci "$@" 2>&1 | tee "$retry_log"
    status=${PIPESTATUS[0]}

    if [ "$status" -eq 0 ]; then
        cleanup_retry_log
        exit 0
    fi

    reason=$(grep -Eo 'ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|ECONNREFUSED|ERR_SOCKET_TIMEOUT' "$retry_log" | head -n 1 || true)
    if [ -z "$reason" ] || [ "$attempt" -ge "$max_attempts" ]; then
        cleanup_retry_log
        exit "$status"
    fi

    next_attempt=$((attempt + 1))
    delay=$((attempt * 2))
    echo "NPM_CI_NETWORK_RETRY attempt=$attempt next_attempt=$next_attempt reason=$reason delay_seconds=$delay"
    cleanup_retry_log
    sleep "$delay"
    attempt=$next_attempt
done

exit 70
