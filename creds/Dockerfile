# Derived credential sidecar that bakes THIS repo's vend.yaml (what to vend) — a reviewed
# rebuild, NOT a /workspace bind-mount, so changing vend scope is human-gated.
FROM ghcr.io/twin-digital/credential-shelf:latest
COPY vend.yaml /etc/credential-shelf/vend.yaml
