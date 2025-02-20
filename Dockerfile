# Nutzen wir ein neueres Base Image
FROM debian:bookworm
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

# Node.js 20 LTS installieren
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get purge --auto-remove \
    && rm -rf /tmp/* /var/lib/apt/lists/*

WORKDIR /bot

# package.json für den Bot erstellen
COPY <<EOF /bot/package.json
{
  "name": "wechaty-bot",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "wechaty": "^1.20.2",
    "wechaty-puppet-padlocal": "^1.20.1"
  }
}
EOF

# Zusätzliches Paket für QR-Code Installation
RUN npm install qrcode-terminal

# Bot-Skript anpassen
COPY <<EOF /bot/mybot.js
import { WechatyBuilder } from 'wechaty';
import qrcode from 'qrcode-terminal';

const bot = WechatyBuilder.build({
  name: 'padlocal-bot',
  puppet: 'wechaty-puppet-padlocal'
});

bot
  .on('scan', (qrcodeUrl, status) => {
    if (status === 2) {
      console.log('Scan QR Code to login:');
      qrcode.generate(qrcodeUrl, {small: true}, (qrcodeAscii) => {
        console.log(qrcodeAscii);
      });
    }
  })
  .on('login', user => {
    console.log(`User ${user} logged in`);
  })
  .on('message', message => {
    console.log(`Message: ${message.text()}`);
  })
  .on('error', error => {
    console.error('Bot error:', error);
  });

process.on('uncaughtException', console.error);
process.on('unhandledRejection', console.error);

bot.start()
  .then(() => console.log('Bot started successfully'))
  .catch(e => console.error('Bot start failed:', e));
EOF

# Installiere Dependencies
RUN npm install \
    && chmod +x /bot/mybot.js

ENTRYPOINT [ "node" ]
CMD [ "mybot.js" ]

# Docker labels
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
