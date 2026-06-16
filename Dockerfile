# Project layer on top of the `workspace` image (ghcr.io/twin-digital/workspace), which
# provides the security hardening (no-sudo, the VS Code host-channel scrub, the IPC socket
# reaper), the credential consumer shims (devcred + the git/gh helpers +
# AWS_SHARED_CREDENTIALS_FILE), the keep-alive CMD, and the toolchains (aws-cli, gh, node/nvm,
# python, terraform, gnupg2, yq). Everything below is project-specific: pandoc, Claude Code,
# the rootfs helpers (tf, aws-get-account-id), the home seed, and the lifecycle scripts.
FROM ghcr.io/twin-digital/workspace:latest

# Pinned tool versions (kept at the top so they're easy to see and bump).
ARG PANDOC_VERSION=3.8.3
ARG PANDOC_SHA256=c224fab89f827d3623380ecb7c1078c163c769c849a14ac27e8d3bfbb914c9b4

USER root

# pandoc
RUN curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz" -o /tmp/pandoc.tar.gz \
  && echo "${PANDOC_SHA256}  /tmp/pandoc.tar.gz" | sha256sum -c - \
  && tar xzf /tmp/pandoc.tar.gz --strip-components 1 -C /usr/local/ \
  && rm /tmp/pandoc.tar.gz

# The unprivileged dev account. The username is configurable (--build-arg USERNAME=alice);
# uid/gid are pinned to 1000 and NOT overridable — the credential shelf vends 0600 files
# owned by uid 1000, so the consumer must run as 1000 to read them, and the workspace
# image's nvm dir is chowned to 1000. Renaming the user keeps that uid.
ARG USERNAME=vscode

# Drop the workspace image's pre-made users (uid >= 1000) and any residual sudoers grant
# files, then (re)create USERNAME as a plain, unprivileged account at uid/gid 1000.
RUN getent passwd \
    | awk -F: '($3 >= 1000) && ($1 != "nobody") {print $1}' \
    | xargs -r -n 1 userdel -r \
  && rm -rf /etc/sudoers.d/* \
  && if [ "${USERNAME}" != "root" ]; then \
       groupadd --gid 1000 "${USERNAME}" || true \
       && useradd -s /bin/bash -m -u 1000 -g 1000 "${USERNAME}"; \
     fi

# claude code — installed as the user (to ~/.local). Kept here, ahead of the frequently-
# edited COPY layers below, so a script change doesn't re-run this network install.
USER ${USERNAME}
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# ── Our files (edited more often; kept late so changes don't bust the cache above) ───────
# rootfs: the project's tf + aws-get-account-id helpers.
COPY rootfs/ /

COPY home/ /home/${USERNAME}/
# Lifecycle scripts (post-create/post-attach + their .d drop-ins) and gh-token-seed.
COPY scripts/container/ /usr/local/bin/
RUN find /usr/local/bin -type f -exec chmod +x {} \; \
  && chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}

# Pre-create dirs that get bind-mounted later (else Docker creates them root-owned at start).
USER ${USERNAME}
RUN mkdir -p /home/${USERNAME}/.claude /home/${USERNAME}/.config /home/${USERNAME}/.ssh \
  && chmod 700 /home/${USERNAME}/.ssh
