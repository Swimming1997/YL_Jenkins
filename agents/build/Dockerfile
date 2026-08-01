FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS node-runtime

FROM jenkins/ssh-agent:jdk21@sha256:dcded0f19987887f56c78100766a85e3ab2e9f36f255b93b4f86193f8be06a1d

USER root
COPY --from=node-runtime /usr/local/ /usr/local/
COPY agents/build/entrypoint.sh /usr/local/bin/platform-agent-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/platform-agent-entrypoint \
    && chmod 0755 /usr/local/bin/platform-agent-entrypoint \
    && node --version \
    && npm --version \
    && git --version

ENTRYPOINT ["platform-agent-entrypoint"]
