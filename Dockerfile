FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG USERNAME

# run privileged setup as root
USER root

# install: gnupg2, lastpass cli
RUN sudo apt-get update && sudo apt-get --no-install-recommends -yqq install \
    gnupg2 \
    lastpass-cli \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# install yq
RUN wget https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 -O /usr/local/bin/yq &&\
    chmod +x /usr/local/bin/yq

# remove any existing regular users
RUN getent passwd \
  | awk -F: '($3 >= 1000) && ($1 != "nobody") {print $1}' \
  | xargs -r -n 1 userdel -r

# setup user with same name as host (unless running as root for some reason)
RUN if [ "${USERNAME}" != "root" ]; then \
    groupadd --gid 1000 ${USERNAME} || true \
    && useradd -s /bin/bash -m -u 1000 -g 1000 ${USERNAME} \
    && mkdir -p /etc/sudoers.d \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && sudo groupadd -f docker \
    && sudo usermod -aG docker ${USERNAME} \
  ; fi

# copy arbitrary files into our container filesystem
COPY rootfs/ /
COPY scripts/container/ /usr/local/bin/
RUN find /usr/local/bin -type f -exec chmod +x {} \;

# copy files into home directory, setting appropriate permissions on any .ssh files
COPY home/ /home/${USERNAME}/
RUN chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}

# Finish any non-privileged setup
USER ${USERNAME}

# install: claude code
RUN curl -fsSL https://claude.ai/install.sh | bash

# create directories in our image which will be bind-mounted later (otherwise
# Docker will automatically create them as root-only when the container starts)
RUN mkdir -p /home/${USERNAME}/.claude \
  && mkdir -p /home/${USERNAME}/.config \
  && mkdir -p /home/${USERNAME}/.ssh \
  && chmod 700 /home/${USERNAME}/.ssh

CMD ["sleep", "infinity"]
