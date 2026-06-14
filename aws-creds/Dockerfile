# Derived AWS credential sidecar that bakes THIS repo's accounts.yaml (which account/role(s)
# to vend) — a reviewed rebuild, NOT a /workspace bind-mount, so changing vend scope is
# human-gated. The upstream SSO session (start URL + region) comes from env in
# docker-compose.yml.
FROM ghcr.io/skleinjung/devcontainers/credential-shelf-aws:latest
COPY accounts.yaml /etc/credential-shelf/accounts.yaml
