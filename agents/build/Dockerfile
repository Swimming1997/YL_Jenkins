FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS node-runtime

FROM jenkins/ssh-agent:jdk21@sha256:dcded0f19987887f56c78100766a85e3ab2e9f36f255b93b4f86193f8be06a1d

ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=

USER root
RUN set -eux; \
    if [ -n "$DEBIAN_MIRROR" ] || [ -n "$DEBIAN_SECURITY_MIRROR" ]; then \
        test -n "$DEBIAN_MIRROR"; \
        test -n "$DEBIAN_SECURITY_MIRROR"; \
        for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do \
            [ -f "$source_file" ] || continue; \
            sed -i \
                -e "s|http://deb.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g" \
                -e "s|http://deb.debian.org/debian|$DEBIAN_MIRROR|g" \
                "$source_file"; \
        done; \
    fi; \
    apt-get update \
        -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=20 \
        -o Acquire::https::Timeout=20 \
    && DEBIAN_FRONTEND=noninteractive apt-get install \
        -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=20 \
        -o Acquire::https::Timeout=20 \
        --yes --no-install-recommends \
        g++ make python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=node-runtime /usr/local/ /usr/local/
COPY agents/build/entrypoint.sh /usr/local/bin/platform-agent-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/platform-agent-entrypoint \
    && chmod 0755 /usr/local/bin/platform-agent-entrypoint \
    && node --version \
    && npm --version \
    && python3 --version \
    && make --version \
    && g++ --version \
    && git --version

ENTRYPOINT ["platform-agent-entrypoint"]
