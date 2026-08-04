#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
secret_dir="$repo_root/.secrets"
compose_files="-f $repo_root/compose.yaml -f $repo_root/compose.paper-server.yaml"

if [ "$repo_root" != "/opt/jenkins-platform" ]; then
    echo "This bootstrap must run from /opt/jenkins-platform." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required." >&2; exit 1; }

umask 077
mkdir -p "$secret_dir"

new_secret() {
    openssl rand -base64 36 | tr '+/' '-_' | tr -d '=\n'
}

ensure_secret() {
    name=$1
    path="$secret_dir/$name"
    if [ ! -s "$path" ]; then
        new_secret > "$path"
        chmod 600 "$path"
        echo "Generated server Secret: $name"
    fi
}

for name in \
    jenkins_admin_password \
    jenkins_audit_password \
    registry_password \
    deploy_dev_mysql_password \
    deploy_dev_jwt_secret \
    deploy_dev_draft_key \
    deploy_test_mysql_password \
    deploy_test_jwt_secret \
    deploy_test_draft_key
do
    ensure_secret "$name"
done

if [ ! -s "$secret_dir/registry_username" ]; then
    printf '%s' 'jenkins-release' > "$secret_dir/registry_username"
    chmod 600 "$secret_dir/registry_username"
    echo "Generated server Secret: registry_username"
fi

for name in \
    build_agent_ssh_key \
    regression_agent_ssh_key \
    release_agent_ssh_key \
    deploy_dev_agent_ssh_key \
    deploy_test_agent_ssh_key
do
    private_path="$secret_dir/$name"
    public_path="$private_path.pub"
    if [ ! -s "$private_path" ] || [ ! -s "$public_path" ]; then
        rm -f -- "$private_path" "$public_path"
        ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C "jenkins-platform-$name-paper-server" -f "$private_path"
        chmod 600 "$private_path"
        chmod 644 "$public_path"
        echo "Generated server Agent key: $name"
    fi
done

if [ ! -s "$secret_dir/xhsmedium_scm_token" ]; then
    echo "Missing required read-only SCM Secret: .secrets/xhsmedium_scm_token" >&2
    exit 1
fi
chmod 600 "$secret_dir/xhsmedium_scm_token"

if [ ! -f "$repo_root/.env" ]; then
    cp "$repo_root/.env.example" "$repo_root/.env"
    chmod 600 "$repo_root/.env"
fi

docker compose $compose_files config --quiet
docker compose $compose_files up --detach --build controller build-agent registry
docker compose $compose_files ps
