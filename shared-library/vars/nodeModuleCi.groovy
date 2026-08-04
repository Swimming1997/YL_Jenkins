def call(Map config = [:]) {
    String module = config.module?.toString()?.trim()
    String logName = config.logName?.toString()?.trim()
    List commands = config.commands instanceof List ? config.commands : []

    if (!(module ==~ /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/)) {
        error('nodeModuleCi requires a safe module directory name')
    }
    if (!(logName ==~ /[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.log/)) {
        error('nodeModuleCi requires a safe .log artifact name')
    }
    if (!commands || commands.any { !(it instanceof CharSequence) || !it.toString().trim() || it.toString().contains('\n') || it.toString().contains('\r') }) {
        error('nodeModuleCi requires non-empty, single-line commands')
    }

    String commandBlock = commands.collect { it.toString() }.join('\n')
    String npmRetryHelper = libraryResource('xhsmedium/npm-ci-network-retry.sh')
    dir(module) {
        writeFile(file: '.npm-ci-network-retry.sh', text: npmRetryHelper)
        sh(
            label: "${module} read-only CI",
            script: """#!/usr/bin/env bash
set -euo pipefail
mkdir -p \"\$WORKSPACE/ci-evidence\"
: > \"\$WORKSPACE/ci-evidence/${logName}\"
exec > >(tee -a \"\$WORKSPACE/ci-evidence/${logName}\") 2>&1
cleanup_node_modules() { rm -rf -- node_modules; rm -f -- .npm-ci-network-retry.sh; }
trap cleanup_node_modules EXIT
chmod 0700 .npm-ci-network-retry.sh
${commandBlock}
"""
        )
    }
}
