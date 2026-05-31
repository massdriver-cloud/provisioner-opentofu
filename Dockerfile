ARG OPENTOFU_VERSION=1.10.1
ARG CHECKOV_VERSION=3.2.530
ARG RUN_IMG=debian:13.5-slim
ARG USER=massdriver
ARG UID=10001

FROM ${RUN_IMG} AS build
ARG OPENTOFU_VERSION
ARG CHECKOV_VERSION

# install opentofu, yq, massdriver cli, kubectl
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip make jq && \
    rm -rf /var/lib/apt/lists/* && \
    curl -s https://api.github.com/repos/massdriver-cloud/xo/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url' | xargs curl -sSL -o xo.tar.gz && tar -xvf xo.tar.gz -C /tmp && mv /tmp/xo /usr/local/bin/ && rm *.tar.gz && \
    curl -sSL https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_amd64.zip > opentofu.zip && unzip opentofu.zip && mv tofu /usr/local/bin/ && rm *.zip && \
    curl -sSL https://github.com/bridgecrewio/checkov/releases/download/${CHECKOV_VERSION}/checkov_linux_X86_64.zip > checkov.zip && unzip checkov.zip && mv dist/checkov /usr/local/bin/ && rm *.zip

FROM ${RUN_IMG}
ARG USER
ARG UID

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates jq git openssh-client && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 777 /massdriver

RUN useradd \
    --create-home \
    --shell /bin/bash \
    --uid ${UID} \
    ${USER} && \
    chown -R ${USER}:${USER} /massdriver

COPY --from=build /usr/local/bin/xo /usr/local/bin/xo
COPY --from=build /usr/local/bin/tofu /usr/local/bin/tofu
COPY --from=build /usr/local/bin/checkov /usr/local/bin/checkov
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER ${USER}

ENV MASSDRIVER_PROVISIONER=opentofu

WORKDIR /massdriver

ENTRYPOINT ["entrypoint.sh"]
