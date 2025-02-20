FROM debian:bullseye
LABEL maintainer="Huan LI (李卓桓) <zixia@zixia.net>"

ENV DEBIAN_FRONTEND     noninteractive
ENV WECHATY_DOCKER      1
ENV LC_ALL              C.UTF-8
ENV NODE_ENV            $NODE_ENV
ENV NPM_CONFIG_LOGLEVEL warn

# Python 3 und andere Abhängigkeiten installieren
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && apt-get install -y --no-install-recommends \
    apt-utils \
    autoconf \
    automake \
    bash \
    build-essential \
    ca-certificates \
    chromium \
    coreutils \
    curl \
    ffmpeg \
    figlet \
    git \
    gnupg2 \
    jq \
    libgconf-2-4 \
    libtool \
    libxtst6 \
    moreutils \
    shellcheck \
    sudo \
    tzdata \
    vim \
    wget \
    && apt-get purge --auto-remove \
    && rm -rf /tmp/* /var/lib/apt/lists/*

# Node.js 20 LTS installieren (statt 16)
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get purge --auto-remove \
    && rm -rf /tmp/* /var/lib/apt/lists/*

WORKDIR /wechaty

# Git initialisieren
RUN git init

COPY package.json .
RUN npm install \
    && rm -fr /tmp/* ~/.npm

COPY . .

RUN ./scripts/generate-package-json.sh && rm -f src/package-json.spec.ts
RUN npm test \
    && npm run dist \
    && npm link

# Puppet installieren
RUN npm install wechaty-puppet-padlocal \
    && sudo rm -fr /tmp/* ~/.npm

# ES Module Support
RUN echo '{"type": "module"}' > /package.json

# Node Modules Setup
RUN mkdir /node_modules \
    && ln -sfv /usr/lib/node_modules/* /node_modules/ \
    && ln -sfv /wechaty/node_modules/* /node_modules/ \
    && /wechaty/bin/clean-json.js /wechaty/tsconfig.json \
    | jq 'del(."ts-node")' > /tsconfig.json

WORKDIR /bot

ENTRYPOINT [ "/wechaty/bin/entrypoint.sh" ]
CMD [ "" ]

# Labels bleiben unverändert...

#
# https://docs.docker.com/docker-cloud/builds/advanced/
# http://label-schema.org/rc1/
#
LABEL \
  org.label-schema.license="Apache-2.0" \
  org.label-schema.build-date="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  org.label-schema.version="$DOCKER_TAG" \
  org.label-schema.schema-version="$(wechaty-version)" \
  org.label-schema.name="Wechaty" \
  org.label-schema.description="Wechat for Bot" \
  org.label-schema.usage="https://github.com/wechaty/wechaty/wiki/Docker" \
  org.label-schema.url="https://www.chatie.io" \
  org.label-schema.vendor="Chatie" \
  org.label-schema.vcs-ref="$SOURCE_COMMIT" \
  org.label-schema.vcs-url="https://github.com/wechaty/wechaty" \
  org.label-schema.docker.cmd="docker run -ti --rm wechaty/wechaty <code.js>" \
  org.label-schema.docker.cmd.test="docker run -ti --rm wechaty/wechaty test" \
  org.label-schema.docker.cmd.help="docker run -ti --rm wechaty/wechaty help" \
  org.label-schema.docker.params="WECHATY_TOKEN=token token from https://www.chatie.io, WECHATY_LOG=verbose Set Verbose Log, TZ='Asia/Shanghai' TimeZone"

