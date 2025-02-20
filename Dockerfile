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

# package.json erstellen
RUN echo '{\n\
  "name": "wechaty-bot",\n\
  "version": "1.0.0",\n\
  "type": "module",\n\
  "dependencies": {\n\
    "wechaty": "^1.20.2",\n\
    "wechaty-puppet-padlocal": "^1.20.1",\n\
    "qrcode-terminal": "^0.12.0"\n\
  }\n\
}' > /bot/package.json

# Bot-Skript erstellen
RUN echo 'import { WechatyBuilder } from "wechaty";\n\
import qrcode from "qrcode-terminal";\n\
import fetch from "node-fetch";\n\
\n\
const WEBHOOK_URL = process.env.N8N_WEBHOOK_URL;\n\
\n\
const bot = WechatyBuilder.build({\n\
  name: "padlocal-bot",\n\
  puppet: "wechaty-puppet-padlocal"\n\
});\n\
\n\
async function sendToWebhook(data) {\n\
  try {\n\
    const response = await fetch(WEBHOOK_URL, {\n\
      method: "POST",\n\
      headers: {\n\
        "Content-Type": "application/json",\n\
      },\n\
      body: JSON.stringify(data),\n\
    });\n\
    if (!response.ok) {\n\
      throw new Error(`HTTP error! status: ${response.status}`);\n\
    }\n\
    console.log("Successfully sent to webhook");\n\
  } catch (error) {\n\
    console.error("Error sending to webhook:", error);\n\
  }\n\
}\n\
\n\
bot\n\
  .on("scan", (qrcodeUrl, status) => {\n\
    if (status === 2) {\n\
      console.log("Scan QR Code to login:");\n\
      qrcode.generate(qrcodeUrl, {small: true}, (qrcodeAscii) => {\n\
        console.log(qrcodeAscii);\n\
      });\n\
    }\n\
  })\n\
  .on("login", async user => {\n\
    console.log(`User ${user} logged in`);\n\
    await sendToWebhook({\n\
      type: "login",\n\
      user: user.toString()\n\
    });\n\
  })\n\
  .on("message", async message => {\n\
    const messageData = {\n\
      type: "message",\n\
      fromId: message.from().id,\n\
      fromName: message.from().name(),\n\
      text: message.text(),\n\
      roomId: message.room()?.id,\n\
      roomTopic: await message.room()?.topic(),\n\
      timestamp: message.date().toISOString()\n\
    };\n\
    console.log("New message:", messageData);\n\
    await sendToWebhook(messageData);\n\
  })\n\
  .on("error", async error => {\n\
    console.error("Bot error:", error);\n\
    await sendToWebhook({\n\
      type: "error",\n\
      error: error.toString()\n\
    });\n\
  });\n\
\n\
process.on("uncaughtException", console.error);\n\
process.on("unhandledRejection", console.error);\n\
\n\
bot.start()\n\
  .then(() => console.log("Bot started successfully"))\n\
  .catch(e => console.error("Bot start failed:", e));' > /bot/mybot.js

# package.json anpassen für node-fetch
RUN echo '{\n\
  "name": "wechaty-bot",\n\
  "version": "1.0.0",\n\
  "type": "module",\n\
  "dependencies": {\n\
    "wechaty": "^1.20.2",\n\
    "wechaty-puppet-padlocal": "^1.20.1",\n\
    "qrcode-terminal": "^0.12.0",\n\
    "node-fetch": "^3.3.0"\n\
  }\n\
}' > /bot/package.json
# Dependencies installieren
RUN npm install \
    && chmod +x /bot/mybot.js

ENTRYPOINT [ "node" ]
CMD [ "mybot.js" ]

# Docker labels bleiben gleich...
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
