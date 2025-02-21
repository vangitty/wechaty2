FROM debian:bookworm
LABEL maintainer="Huan LI (李卓桓) <zixia@zixia.net>"

ENV DEBIAN_FRONTEND=noninteractive
ENV WECHATY_DOCKER=1
ENV LC_ALL=C.UTF-8
ENV NODE_ENV=$NODE_ENV
ENV NPM_CONFIG_LOGLEVEL=warn

# -------------------------------------------------------
# 1) System-Pakete installieren
# -------------------------------------------------------
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     python3 \
     python3-pip \
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
  && ln -sf /usr/bin/python3 /usr/bin/python \
  && apt-get purge --auto-remove \
  && rm -rf /tmp/* /var/lib/apt/lists/*

# -------------------------------------------------------
# 2) Node.js 20 installieren
# -------------------------------------------------------
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && apt-get purge --auto-remove \
  && rm -rf /tmp/* /var/lib/apt/lists/*

WORKDIR /bot

# -------------------------------------------------------
# 3) package.json mit allen Abhängigkeiten
# -------------------------------------------------------
RUN echo '{"name":"wechaty-bot","version":"1.0.0","type":"module","dependencies":{"wechaty":"^1.20.2","wechaty-puppet-padlocal":"^1.20.1","qrcode-terminal":"^0.12.0","node-fetch":"^3.3.0","@aws-sdk/client-s3":"^3.300.0"}}' > /bot/package.json

# -------------------------------------------------------
# 4) NPM install
# -------------------------------------------------------
RUN npm install

# -------------------------------------------------------
# 5) Bot-Skript erstellen (mybot.js)
# -------------------------------------------------------
RUN echo '//=========================================================\n\
// mybot.js - WeChat Bot mit Wechaty\n\
//=========================================================\n\
\n\
import { WechatyBuilder } from "wechaty";\n\
import { types } from "wechaty-puppet";\n\
import qrcode from "qrcode-terminal";\n\
import fetch from "node-fetch";\n\
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";\n\
\n\
// ENV Variablen\n\
const WEBHOOK_URL = process.env.N8N_WEBHOOK_URL;\n\
const S3_ENDPOINT = process.env.S3_ENDPOINT;\n\
const S3_ACCESS_KEY = process.env.S3_ACCESS_KEY;\n\
const S3_SECRET_KEY = process.env.S3_SECRET_KEY;\n\
const S3_BUCKET = process.env.S3_BUCKET || "wechaty-files";\n\
\n\
if (!WEBHOOK_URL) {\n\
  console.error("N8N_WEBHOOK_URL is not set!");\n\
  process.exit(1);\n\
}\n\
\n\
// S3 Client\n\
const s3 = new S3Client({\n\
  endpoint: S3_ENDPOINT,\n\
  region: "us-east-1",\n\
  credentials: {\n\
    accessKeyId: S3_ACCESS_KEY,\n\
    secretAccessKey: S3_SECRET_KEY,\n\
  },\n\
  forcePathStyle: true,\n\
});\n\
\n\
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") {\n\
  try {\n\
    console.log(`Uploading file ${fileName} to S3...`);\n\
    const cmd = new PutObjectCommand({\n\
      Bucket: S3_BUCKET,\n\
      Key: fileName,\n\
      Body: fileBuffer,\n\
      ContentType: contentType\n\
    });\n\
    await s3.send(cmd);\n\
    const fileUrl = `${S3_ENDPOINT}/${S3_BUCKET}/${fileName}`;\n\
    console.log(`File uploaded successfully. URL: ${fileUrl}`);\n\
    return fileUrl;\n\
  } catch (error) {\n\
    console.error("Error uploading to S3:", error);\n\
    throw error;\n\
  }\n\
}\n\
\n\
// Webhook POST\n\
async function sendToWebhook(data) {\n\
  try {\n\
    console.log("Sending to webhook:", WEBHOOK_URL);\n\
    const response = await fetch(WEBHOOK_URL, {\n\
      method: "POST",\n\
      headers: { "Content-Type": "application/json" },\n\
      body: JSON.stringify(data),\n\
    });\n\
    if (!response.ok) {\n\
      const textResponse = await response.text();\n\
      throw new Error(`HTTP Error ${response.status} => ${textResponse}`);\n\
    }\n\
    console.log("Successfully sent to webhook");\n\
  } catch (error) {\n\
    console.error("Error sending to webhook:", error);\n\
  }\n\
}\n\
\n\
// WeChaty Bot Setup\n\
const bot = WechatyBuilder.build({\n\
  name: "padlocal-bot",\n\
  puppet: "wechaty-puppet-padlocal"\n\
});\n\
\n\
bot.on("scan", (qrcodeUrl, status) => {\n\
  if (status === 2) {\n\
    console.log("Scan QR Code to login:");\n\
    qrcode.generate(qrcodeUrl, { small: true }, (ascii) => {\n\
      console.log(ascii);\n\
    });\n\
  }\n\
});\n\
\n\
bot.on("login", async (user) => {\n\
  console.log(`User ${user} logged in`);\n\
  await sendToWebhook({ type: "login", user: user.toString() });\n\
});\n\
\n\
// Message Handler\n\
bot.on("message", async (message) => {\n\
  try {\n\
    const room = message.room();\n\
    const talker = message.talker();\n\
    const messageType = message.type();\n\
    const timestamp = message.date().toISOString();\n\
\n\
    console.log(`Received message type: ${messageType} from ${talker?.name()}`);\n\
\n\
    // Skip unsupported message types\n\
    if (messageType === types.Message.Unknown) {\n\
      console.log("Skipping unsupported message type");\n\
      return;\n\
    }\n\
\n\
    if (messageType === types.Message.Image) {\n\
      console.log("Processing image message...");\n\
      const fileBox = await message.toFileBox();\n\
      const buffer = await fileBox.toBuffer();\n\
      const fileName = fileBox.name || `image-${Date.now()}.jpg`;\n\
\n\
      const s3Url = await uploadToS3(fileName, buffer, "image/jpeg");\n\
\n\
      await sendToWebhook({\n\
        type: "message",\n\
        subType: "image",\n\
        fromId: talker?.id,\n\
        fromName: talker?.name(),\n\
        text: "",\n\
        roomId: room?.id,\n\
        roomTopic: room ? await room.topic() : null,\n\
        timestamp,\n\
        s3Url,\n\
      });\n\
\n\
    } else if (messageType === types.Message.Attachment) {\n\
      console.log("Processing attachment message...");\n\
      const fileBox = await message.toFileBox();\n\
      const buffer = await fileBox.toBuffer();\n\
      const fileName = fileBox.name || `file-${Date.now()}`;\n\
\n\
      const s3Url = await uploadToS3(fileName, buffer);\n\
\n\
      await sendToWebhook({\n\
        type: "message",\n\
        subType: "attachment",\n\
        fromId: talker?.id,\n\
        fromName: talker?.name(),\n\
        text: "",\n\
        roomId: room?.id,\n\
        roomTopic: room ? await room.topic() : null,\n\
        timestamp,\n\
        s3Url,\n\
      });\n\
\n\
    } else if (messageType === types.Message.Text) {\n\
      console.log("Processing text message...");\n\
      await sendToWebhook({\n\
        type: "message",\n\
        subType: "text",\n\
        fromId: talker?.id,\n\
        fromName: talker?.name(),\n\
        text: message.text(),\n\
        roomId: room?.id,\n\
        roomTopic: room ? await room.topic() : null,\n\
        timestamp,\n\
      });\n\
    }\n\
  } catch (err) {\n\
    console.error("Error processing message:", err);\n\
  }\n\
});\n\
\n\
bot.on("error", async (error) => {\n\
  console.error("Bot error:", error);\n\
  await sendToWebhook({ type: "error", error: error.toString() });\n\
});\n\
\n\
// Start bot\n\
bot.start()\n\
  .then(() => console.log("Bot started successfully"))\n\
  .catch((e) => console.error("Bot start failed:", e));' > /bot/mybot.js

# -------------------------------------------------------
# 6) Ausführbar machen
# -------------------------------------------------------
RUN chmod +x /bot/mybot.js

# -------------------------------------------------------
# 7) Container-Start: node /bot/mybot.js
# -------------------------------------------------------
ENTRYPOINT ["node"]
CMD ["mybot.js"]

# -------------------------------------------------------
# 8) Labels
# -------------------------------------------------------
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
  org.label-schema.docker.cmd.help="docker run -ti --rm wechaty/wechaty help"

