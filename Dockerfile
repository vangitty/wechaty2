FROM debian:bookworm

# Umgebungsvariablen setzen
ENV DEBIAN_FRONTEND=noninteractive \
    WECHATY_DOCKER=1 \
    LC_ALL=C.UTF-8 \
    NPM_CONFIG_LOGLEVEL=warn

# System-Pakete installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Arbeitsverzeichnis erstellen
WORKDIR /bot

# Package.json erstellen
RUN echo '{"name":"wechaty-bot","version":"1.0.0","type":"module","dependencies":{"wechaty":"^1.20.2","wechaty-puppet-padlocal":"^1.20.1","qrcode-terminal":"^0.12.0","node-fetch":"^3.3.0","@aws-sdk/client-s3":"^3.300.0"}}' > /bot/package.json

# Dependencies installieren
RUN npm install

# Bot-Skript als einzelne Datei erstellen
RUN echo 'import { WechatyBuilder } from "wechaty"; \
import { types } from "wechaty-puppet"; \
import qrcode from "qrcode-terminal"; \
import fetch from "node-fetch"; \
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3"; \
\
const botConfig = { \
  name: process.env.BOT_NAME || "padlocal-bot", \
  puppet: "wechaty-puppet-padlocal", \
  puppetOptions: { \
    token: process.env.PADLOCAL_TOKEN, \
    timeout: 30000, \
    uniqueId: process.env.BOT_ID || `bot-${Date.now()}` \
  } \
}; \
\
const serviceConfig = { \
  webhook: { url: process.env.N8N_WEBHOOK_URL, required: true }, \
  s3: { \
    endpoint: process.env.S3_ENDPOINT, \
    accessKey: process.env.S3_ACCESS_KEY, \
    secretKey: process.env.S3_SECRET_KEY, \
    bucket: process.env.S3_BUCKET || "wechaty-files", \
    required: true \
  } \
}; \
\
function validateConfig() { \
  const missingVars = []; \
  Object.entries(serviceConfig).forEach(([service, conf]) => { \
    Object.entries(conf).forEach(([key, value]) => { \
      if (conf.required && !value && key !== "required") { \
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`); \
      } \
    }); \
  }); \
  if (!botConfig.puppetOptions.token) { \
    missingVars.push("PADLOCAL_TOKEN"); \
  } \
  if (missingVars.length > 0) { \
    console.error(`[Config] Fehlende Umgebungsvariablen: ${missingVars.join(", ")}`); \
    process.exit(1); \
  } \
} \
\
validateConfig(); \
\
const s3 = new S3Client({ \
  endpoint: serviceConfig.s3.endpoint, \
  region: "us-east-1", \
  credentials: { \
    accessKeyId: serviceConfig.s3.accessKey, \
    secretAccessKey: serviceConfig.s3.secretKey, \
  }, \
  forcePathStyle: true, \
}); \
\
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") { \
  try { \
    const cmd = new PutObjectCommand({ \
      Bucket: serviceConfig.s3.bucket, \
      Key: fileName, \
      Body: fileBuffer, \
      ContentType: contentType, \
      Metadata: { \
        "upload-timestamp": new Date().toISOString(), \
        "bot-id": botConfig.puppetOptions.uniqueId \
      } \
    }); \
    await s3.send(cmd); \
    return `${serviceConfig.s3.endpoint}/${serviceConfig.s3.bucket}/${fileName}`; \
  } catch (error) { \
    console.error("[S3] Upload error:", error); \
    throw error; \
  } \
} \
\
async function sendToWebhook(data) { \
  const cleanData = JSON.parse(JSON.stringify(data, (k, v) => v === null ? "" : v)); \
  try { \
    const response = await fetch(serviceConfig.webhook.url, { \
      method: "POST", \
      headers: { \
        "Content-Type": "application/json", \
        "X-Bot-ID": botConfig.puppetOptions.uniqueId \
      }, \
      body: JSON.stringify(cleanData), \
    }); \
    if (!response.ok) throw new Error(`HTTP ${response.status}`); \
  } catch (error) { \
    console.error("[Webhook] Error:", error); \
    throw error; \
  } \
} \
\
const bot = WechatyBuilder.build(botConfig); \
\
bot.on("scan", (qrcodeUrl, status) => { \
  if (status === 2) { \
    console.log("[QR] Scan to login:"); \
    qrcode.generate(qrcodeUrl, { small: true }); \
  } \
}); \
\
bot.on("login", async (user) => { \
  console.log(`[Login] ${user}`); \
  await sendToWebhook({ \
    type: "login", \
    user: user.toString(), \
    botId: botConfig.puppetOptions.uniqueId, \
    timestamp: new Date().toISOString() \
  }); \
}); \
\
bot.on("message", async (message) => { \
  try { \
    if (!message) { \
      console.error("[Message] Ungültige Nachricht erhalten"); \
      return; \
    } \
\
    const room = message.room(); \
    const talker = message.talker(); \
    const messageType = message.type(); \
    const timestamp = message.date().toISOString(); \
\
    console.log("[Message] Eingehende Nachricht:", { \
      id: message.id, \
      type: messageType, \
      talker: talker ? `${talker.id} (${await talker.name()})` : "unbekannt", \
      room: room ? `${room.id} (${await room.topic()})` : "direkt" \
    }); \
\
    if (messageType === types.Message.Unknown || messageType === 51) { \
      console.log("[Message] System- oder unbekannte Nachricht übersprungen"); \
      return; \
    } \
\
    const baseData = { \
      type: "message", \
      messageId: message.id || `generated-${Date.now()}`, \
      fromId: talker ? talker.id : "", \
      fromName: talker ? (await talker.name() || "") : "", \
      roomId: room ? room.id : "", \
      roomTopic: room ? (await room.topic() || "") : "", \
      messageType: messageType, \
      timestamp: timestamp, \
      botId: botConfig.puppetOptions.uniqueId \
    }; \
\
    if (message.type() === types.Message.Image || message.type() === types.Message.Text && await message.toFileBox()) { \
      try { \
        const fileBox = await message.toFileBox(); \
        const buffer = await fileBox.toBuffer(); \
        \
        if (!buffer || buffer.length === 0) { \
          throw new Error("Leerer Datei-Buffer erhalten"); \
        } \
\
        const messageId = message.id || `generated-${Date.now()}`; \
        const originalName = fileBox.name || `image-${messageId}.jpg`; \
        const fileName = `message-${messageId}-${originalName.replace(/message-.*-/, "")}` \
          .replace(/[^a-zA-Z0-9.-]/g, "_"); \
\
        const fileInfo = { \
          originalName: originalName.replace(/message-.*-/, ""), \
          mimeType: fileBox.mediaType || "image/jpeg", \
          size: buffer.length, \
          timestamp: Date.now(), \
          messageId: messageId \
        }; \
\
        console.log(`[Image] Verarbeite ${fileName}`, fileInfo); \
        \
        const s3Url = await uploadToS3(fileName, buffer, fileInfo.mimeType); \
        \
        await sendToWebhook({ \
          ...baseData, \
          subType: "image", \
          text: "", \
          file_id: messageId, \
          file_name: fileInfo.originalName, \
          file_size: fileInfo.size || 0, \
          message_type: "image", \
          s3_url: s3Url, \
          mime_type: fileInfo.mimeType || "image/jpeg", \
          created_at: timestamp \
        }); \
        \
        console.log("[Image] Verarbeitung abgeschlossen:", { \
          messageId: messageId, \
          fileName: fileName, \
          size: fileInfo.size, \
          url: s3Url \
        }); \
\
      } catch (error) { \
        console.error("[Image] Verarbeitungsfehler:", error); \
        await sendToWebhook({ \
          ...baseData, \
          subType: "error", \
          error: `Bildverarbeitungsfehler: ${error.message}`, \
          errorTimestamp: new Date().toISOString() \
        }); \
      } \
    } else { \
      await sendToWebhook({ \
        ...baseData, \
        subType: "text", \
        text: message.text() || "", \
        message_type: "text", \
        created_at: timestamp \
      }); \
    } \
\
  } catch (error) { \
    console.error("[Message] Allgemeiner Fehler:", error); \
    try { \
      await sendToWebhook({ \
        type: "error", \
        error: error.toString(), \
        timestamp: new Date().toISOString(), \
        messageId: message?.id || "unknown", \
        botId: botConfig.puppetOptions.uniqueId \
      }); \
    } catch (webhookError) { \
      console.error("[Message] Fehler beim Senden des Fehlerberichts:", webhookError); \
    } \
  } \
}); \
\
bot.on("error", async (error) => { \
  console.error("[Bot] Error:", error); \
  await sendToWebhook({ \
    type: "error", \
    error: error.toString(), \
    botId: botConfig.puppetOptions.uniqueId, \
    timestamp: new Date().toISOString() \
  }); \
}); \
\
async function shutdown(signal) { \
  console.log(`[Bot] ${signal} empfangen, stoppe Bot...`); \
  try { \
    await bot.stop(); \
    console.log("[Bot] Erfolgreich gestoppt"); \
    process.exit(0); \
  } catch (error) { \
    console.error("[Bot] Fehler beim Stoppen:", error); \
    process.exit(1); \
  } \
} \
\
process.on("SIGTERM", () => shutdown("SIGTERM")); \
process.on("SIGINT", () => shutdown("SIGINT")); \
\
console.log(`[Bot] Starting... (ID: ${botConfig.puppetOptions.uniqueId})`); \
bot.start() \
  .then(() => console.log("[Bot] Started successfully")) \
  .catch(e => { \
    console.error("[Bot] Start failed:", e); \
    process.exit(1); \
  });' > /bot/mybot.js

# Bot ausführbar machen
RUN chmod +x /bot/mybot.js

# Container starten
ENTRYPOINT ["node"]
CMD ["mybot.js"]

# Labels
LABEL maintainer="Huan LI (李卓桓) <zixia@zixia.net>" \
      org.label-schema.license="Apache-2.0" \
      org.label-schema.name="Wechaty" \
      org.label-schema.description="Wechat for Bot"
