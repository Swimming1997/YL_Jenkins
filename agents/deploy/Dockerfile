FROM docker:29.3.1-dind@sha256:686d2c5464787b0ca42420e0aa03a94fc9781ff9bf8b5ff947614b9fa4c3c3e0 AS docker-cli

FROM jenkins/ssh-agent:jdk21@sha256:dcded0f19987887f56c78100766a85e3ab2e9f36f255b93b4f86193f8be06a1d

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
COPY agents/deploy/entrypoint.sh /usr/local/bin/platform-agent-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/platform-agent-entrypoint \
    && chmod 0755 /usr/local/bin/platform-agent-entrypoint /usr/local/bin/docker /usr/local/libexec/docker/cli-plugins/* \
    && curl --version \
    && python3 --version \
    && java -version \
    && docker --version \
    && docker compose version

ENTRYPOINT ["platform-agent-entrypoint"]
