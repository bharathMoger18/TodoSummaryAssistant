FROM jenkins/jenkins:lts-jdk17
USER root

# Tools the pipeline needs: git, jq, ssh, openssl, plus the Docker CLI (it talks to the
# host's Docker through the mounted socket, it does not run its own Docker).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip git jq openssl openssh-client \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && . /etc/os-release \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# Terraform, pinned. The zip is picked by CPU type so this also builds on Apple Silicon.
ARG TERRAFORM_VERSION=1.9.8
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" -o /tmp/tf.zip; \
    unzip -q /tmp/tf.zip -d /usr/local/bin terraform; \
    rm /tmp/tf.zip

# AWS CLI v2
RUN set -eux; \
    case "$(dpkg --print-architecture)" in amd64) a=x86_64;; arm64) a=aarch64;; esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${a}.zip" -o /tmp/aws.zip; \
    unzip -q /tmp/aws.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/aws.zip

# Plugins and Configuration as Code: Jenkins comes up already configured, no setup wizard.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
COPY casc.yaml /usr/share/jenkins/ref/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/ref/casc.yaml
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
