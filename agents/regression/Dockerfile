FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS node-runtime
FROM docker:29.3.1-dind@sha256:686d2c5464787b0ca42420e0aa03a94fc9781ff9bf8b5ff947614b9fa4c3c3e0 AS docker-cli

FROM mcr.microsoft.com/playwright:v1.59.1-noble@sha256:b0ab6f3cb99aa7803adbc14d9027ec1785fc6e433b97e134e0f8fe61683b6b53

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates g++ git make openjdk-21-jre-headless openssh-server python3 tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --home-dir /home/jenkins --shell /bin/bash --uid 1002 jenkins \
    && install -d -m 0755 /run/sshd \
    && install -d -m 0700 -o jenkins -g jenkins /home/jenkins/.ssh /home/jenkins/agent \
    && ssh-keygen -A \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        'AllowUsers jenkins' \
        'X11Forwarding no' \
        'AllowTcpForwarding no' \
        >> /etc/ssh/sshd_config

COPY --from=node-runtime /usr/local/ /usr/local/
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
COPY agents/regression/entrypoint.sh /usr/local/bin/platform-agent-entrypoint

RUN sed -i 's/\r$//' /usr/local/bin/platform-agent-entrypoint \
    && chmod 0755 /usr/local/bin/platform-agent-entrypoint /usr/local/bin/docker /usr/local/libexec/docker/cli-plugins/* \
    && node --version \
    && npm --version \
    && python3 --version \
    && make --version \
    && g++ --version \
    && java -version \
    && docker --version \
    && docker compose version

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV AGENT_WORKDIR=/home/jenkins/agent
ENTRYPOINT ["/usr/bin/tini", "--", "platform-agent-entrypoint"]
