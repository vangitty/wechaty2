FROM debian:bookworm
LABEL maintainer="Huan LI (李卓桓) <zixia@zixia.net>"

ENV DEBIAN_FRONTEND=noninteractive
ENV WECHATY_DOCKER=1
ENV LC_ALL=C.UTF-8
ENV NODE_ENV=$NODE_ENV
ENV NPM_CONFIG_LOGLEVEL=warn

# System-Pakete installieren
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

# Node.js 20 installieren
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && apt-get purge --auto-remove \
  && rm -rf /tmp/* /var/lib/apt/lists/*

WORKDIR /bot

# package.json mit allen Abhängigkeiten
RUN echo '{"name":"wechaty-bot","version":"1.0.0","type":"module","dependencies":{"wechaty":"^1.20.2","wechaty-puppet-padlocal":"^1.20.1","qrcode-terminal":"^0.12.0","node-fetch":"^3.3.0","@aws-sdk/client-s3":"^3.300.0"}}' > /bot/package.json

# NPM install
RUN npm install

# Bot-Skript erstellen (mybot.js)
RUN echo 'import { WechatyBuilder } from "wechaty";\n\
import { types } from "wechaty-puppet";\n\
import qrcode from "qrcode-terminal";\n\
import fetch from "node-fetch";\n\
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";\n\
\n\
// Umgebungsvariablen mit Defaultwerten und Validierung\n\
const config = {\n\
  webhook: {\n\
    url: process.env.N8N_WEBHOOK_URL,\n\
    required: true\n\
  },\n\
  s3: {\n\
    endpoint: process.env.S3_ENDPOINT,\n\
    accessKey: process.env.S3_ACCESS_KEY,\n\
    secretKey: process.env.S3_SECRET_KEY,\n\
    bucket: process.env.S3_BUCKET || "wechaty-files",\n\
    required: true\n\
  }\n\
};\n\
\n\
// Konfigurationsvalidierung\n\
function validateConfig() {\n\
  const missingVars = [];\n\
  Object.entries(config).forEach(([service, conf]) => {\n\
    Object.entries(conf).forEach(([key, value]) => {\n\
      if (conf.required && !value && key !== "required") {\n\
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`);\n\
      }\n\
    });\n\
  });\n\
\n\
  if (missingVars.length > 0) {\n\
    console.error(`[Config] Fehlende erforderliche Umgebungsvariablen: ${missingVars.join(", ")}`);\n\
    process.exit(1);\n\
  }\n\
}\n\
\n\
validateConfig();\n\
\n\
// S3 Client Initialisierung\n\
const s3 = new S3Client({\n\
  endpoint: config.s3.endpoint,\n\
  region: "us-east-1",\n\
  credentials: {\n\
    accessKeyId: config.s3.accessKey,\n\
    secretAccessKey: config.s3.secretKey,\n\
  },\n\
  forcePathStyle: true,\n\
});\n\
\n\
// Verbesserte S3 Upload Funktion mit Retry-Logik\n\
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream", retries = 3) {\n\
  for (let attempt = 1; attempt <= retries; attempt++) {\n\
    try {\n\
      console.log(`[S3] Upload-Versuch ${attempt} für ${fileName} (${fileBuffer.length} Bytes)`);\n\
      \n\
      const cmd = new PutObjectCommand({\n\
        Bucket: config.s3.bucket,\n\
        Key: fileName,\n\
        Body: fileBuffer,\n\
        ContentType: contentType,\n\
        Metadata: {\n\
          "upload-timestamp": new Date().toISOString(),\n\
          "upload-attempt": attempt.toString()\n\
        }\n\
      });\n\
\n\
      await s3.send(cmd);\n\
      const fileUrl = `${config.s3.endpoint}/${config.s3.bucket}/${fileName}`;\n\
      console.log(`[S3] Upload erfolgreich: ${fileUrl}`);\n\
      return fileUrl;\n\
\n\
    } catch (error) {\n\
      console.error(`[S3] Upload-Fehler (Versuch ${attempt}):`, error);\n\
      if (attempt === retries) throw error;\n\
      await new Promise(resolve => setTimeout(resolve, 1000 * attempt));\n\
    }\n\
  }\n\
}\n\
\n\
// Verbesserte Webhook-Funktion mit Validierung und Retry\n\
async function sendToWebhook(data, retries = 3) {\n\
  const cleanData = JSON.parse(JSON.stringify(data, (key, value) => {\n\
    if (value === null || value === undefined) return "";\n\
    return value;\n\
  }));\n\
\n\
  for (let attempt = 1; attempt <= retries; attempt++) {\n\
    try {\n\
      console.log(`[Webhook] Sende Daten (Versuch ${attempt}):`, cleanData);\n\
      \n\
      const response = await fetch(config.webhook.url, {\n\
        method: "POST",\n\
        headers: { \n\
          "Content-Type": "application/json",\n\
          "X-Retry-Attempt": attempt.toString()\n\
        },\n\
        body: JSON.stringify(cleanData),\n\
      });\n\
\n\
      if (!response.ok) {\n\
        throw new Error(`HTTP ${response.status}: ${await response.text()}`);\n\
      }\n\
\n\
      console.log(`[Webhook] Erfolgreich gesendet (Versuch ${attempt})`);\n\
      return;\n\
\n\
    } catch (error) {\n\
      console.error(`[Webhook] Fehler (Versuch ${attempt}):`, error);\n\
      if (attempt === retries) throw error;\n\
      await new Promise(resolve => setTimeout(resolve, 1000 * attempt));\n\
    }\n\
  }\n\
}\n\
\n\
// Bot Initialisierung\n\
const bot = WechatyBuilder.build({\n\
  name: "padlocal-bot",\n\
  puppet: "wechaty-puppet-padlocal",\n\
  puppetOptions: {\n\
    timeout: 30000,\n\
  }\n\
});\n\
\n\
// Event Handler\n\
bot.on("scan", (qrcodeUrl, status) => {\n\
  if (status === 2) {\n\
    console.log("[QR] Scannen zum Einloggen:");\n\
    qrcode.generate(qrcodeUrl, { small: true });\n\
  }\n\
  console.log(`[QR] Status: ${status}`);\n\
});\n\
\n\
bot.on("login", async (user) => {\n\
  try {\n\
    console.log(`[Login] ${user} eingeloggt`);\n\
    await sendToWebhook({ \n\
      type: "login", \n\
      user: user.toString(),\n\
      timestamp: new Date().toISOString()\n\
    });\n\
  } catch (error) {\n\
    console.error("[Login] Webhook-Fehler:", error);\n\
  }\n\
});\n\
\n\
// Hauptnachrichtenverarbeitung\n\
bot.on("message", async (message) => {\n\
  try {\n\
    if (!message) {\n\
      console.error("[Message] Ungültige Nachricht erhalten");\n\
      return;\n\
    }\n\
\n\
    const room = message.room();\n\
    const talker = message.talker();\n\
    const messageType = message.type();\n\
    const timestamp = message.date().toISOString();\n\
\n\
    console.log("[Message] Rohdaten:", {\n\
      messageId: message.id,\n\
      messageType,\n\
      talker: talker ? { id: talker.id, name: await talker.name() } : null,\n\
      room: room ? { id: room.id, topic: await room.topic() } : null\n\
    });\n\
\n\
    if (messageType === types.Message.Unknown || messageType === 51) {\n\
      console.log("[Message] System- oder unbekannte Nachricht übersprungen");\n\
      return;\n\
    }\n\
\n\
    const baseData = {\n\
      type: "message",\n\
      messageId: message.id || `generated-${Date.now()}`,\n\
      fromId: talker ? talker.id : "",\n\
      fromName: talker ? (await talker.name() || "") : "",\n\
      roomId: room ? room.id : "",\n\
      roomTopic: room ? (await room.topic() || "") : "",\n\
      messageType: messageType,\n\
      timestamp: timestamp\n\
    };\n\
\n\
    if (message.type() === types.Message.Image || \n\
        (message.type() === types.Message.Text && await message.toFileBox())) {\n\
      try {\n\
        const fileBox = await message.toFileBox();\n\
        const buffer = await fileBox.toBuffer();\n\
        \n\
        if (!buffer || buffer.length === 0) {\n\
          throw new Error("Leerer Datei-Buffer erhalten");\n\
        }\n\
\n\
        const fileName = `message-${message.id}-${fileBox.name || "image.jpg"}`.replace(/[^a-zA-Z0-9.-]/g, "_");\n\
        console.log(`[Image] Verarbeite ${fileName} (${buffer.length} Bytes)`);\n\
        \n\
        const s3Url = await uploadToS3(fileName, buffer, "image/jpeg");\n\
        \n\
        await sendToWebhook({\n\
          ...baseData,\n\
          subType: "image",\n\
          text: s3Url,\n\
          fileName: fileName,\n\
          fileSize: buffer.length,\n\
          s3Url: s3Url,\n\
          originalName: fileBox.name\n\
        });\n\
        \n\
        console.log("[Image] Verarbeitung abgeschlossen");\n\
\n\
      } catch (error) {\n\
        console.error("[Image] Verarbeitungsfehler:", error);\n\
        await sendToWebhook({\n\
          ...baseData,\n\
          subType: "error",\n\
          error: `Bildverarbeitungsfehler: ${error.message}`,\n\
          errorTimestamp: new Date().toISOString()\n\
        });\n\
      }\n\
    } else {\n\
      await sendToWebhook({\n\
        ...baseData,\n\
        subType: "text",\n\
        text: message.text() || ""\n\
      });\n\
    }\n\
\n\
  } catch (error) {\n\
    console.error("[Message] Allgemeiner Fehler:", error);\n\
    try {\n\
      await sendToWebhook({\n\
        type: "error",\n\
        error: error.toString(),\n\
        timestamp: new Date().toISOString(),\n\
        messageId: message?.id || "unknown"\n\
      });\n\
    } catch (webhookError) {\n\
      console.error("[Message] Fehler beim Senden des Fehlerberichts:", webhookError);\n\
    }\n\
  }\n\
});\n\
\n\
// Fehlerbehandlung\n\
bot.on("error", async (error) => {\n\
  console.error("[Bot] Fehler:", error);\n\
  try
 await sendToWebhook({\n\
      type: "error",\n\
      error: error.toString(),\n\
      stack: error.stack,\n\
      timestamp: new Date().toISOString()\n\
    });\n\
  } catch (webhookError) {\n\
    console.error("[Bot] Fehler beim Senden des Fehlerberichts:", webhookError);\n\
  }\n\
});\n\
\n\
// Logout-Handler\n\
bot.on("logout", async (user, reason) => {\n\
  console.log(`[Logout] ${user} ausgeloggt, Grund: ${reason}`);\n\
  try {\n\
    await sendToWebhook({\n\
      type: "logout",\n\
      user: user.toString(),\n\
      reason: reason,\n\
      timestamp: new Date().toISOString()\n\
    });\n\
  } catch (error) {\n\
    console.error("[Logout] Webhook-Fehler:", error);\n\
  }\n\
});\n\
\n\
// Bot-Startsequenz\n\
async function startBot() {\n\
  try {\n\
    console.log("[Bot] Startvorgang beginnt...");\n\
    await bot.start();\n\
    console.log("[Bot] Erfolgreich gestartet");\n\
  } catch (error) {\n\
    console.error("[Bot] Startfehler:", error);\n\
    process.exit(1);\n\
  }\n\
}\n\
\n\
startBot();' > /bot/mybot.js

# Ausführbar machen
RUN chmod +x /bot/mybot.js

# Container-Start
ENTRYPOINT ["node"]
CMD ["mybot.js"]

# Labels
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
