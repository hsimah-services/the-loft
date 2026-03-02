FROM ghcr.io/actions/actions-runner:latest

USER root

# Install docker-ce-cli, docker-compose-plugin, and utilities
RUN apt-get update -qq \
    && apt-get install -y -qq ca-certificates curl gnupg unzip jq > /dev/null \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update -qq \
    && apt-get install -y -qq docker-ce-cli docker-compose-plugin > /dev/null \
    && rm -rf /var/lib/apt/lists/*

# Match host docker group GID so runner can use the mounted socket
RUN groupmod -g 988 docker && usermod -aG docker runner

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner

ENTRYPOINT ["/entrypoint.sh"]
