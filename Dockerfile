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

# Bot-Skript erstellen
RUN echo 'import { WechatyBuilder } from "wechaty";\n\
import { types } from "wechaty-puppet";\n\
import qrcode from "qrcode-terminal";\n\
import fetch from "node-fetch";\n\
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";\n\
\n\
// Bot Konfiguration\n\
const botConfig = {\n\
  name: process.env.BOT_NAME || "padlocal-bot",\n\
  puppet: "wechaty-puppet-padlocal",\n\
  puppetOptions: {\n\
    token: process.env.PADLOCAL_TOKEN,\n\
    timeout: 30000,\n\
    uniqueId: process.env.BOT_ID || `bot-${Date.now()}`\n\
  }\n\
};\n\
\n\
// Service Konfiguration\n\
const serviceConfig = {\n\
  webhook: { url: process.env.N8N_WEBHOOK_URL, required: true },\n\
  s3: {\n\
    endpoint: process.env.S3_ENDPOINT,\n\
    accessKey: process.env.S3_ACCESS_KEY,\n\
    secretKey: process.env.S3_SECRET_KEY,\n\
    bucket: process.env.S3_BUCKET || "wechaty-files",\n\
    required: true\n\
  }\n\
};\n\
\n\
// Konfiguration validieren\n\
function validateConfig() {\n\
  const missingVars = [];\n\
  Object.entries(serviceConfig).forEach(([service, conf]) => {\n\
    Object.entries(conf).forEach(([key, value]) => {\n\
      if (conf.required && !value && key !== "required") {\n\
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`);\n\
      }\n\
    });\n\
  });\n\
  if (!botConfig.puppetOptions.token) {\n\
    missingVars.push("PADLOCAL_TOKEN");\n\
  }\n\
  if (missingVars.length > 0) {\n\
    console.error(`[Config] Fehlende Umgebungsvariablen: ${missingVars.join(", ")}`);\n\
    process.exit(1);\n\
  }\n\
}\n\
\n\
validateConfig();\n\
\n\
// S3 Client initialisieren\n\
const s3 = new S3Client({\n\
  endpoint: serviceConfig.s3.endpoint,\n\
  region: "us-east-1",\n\
  credentials: {\n\
    accessKeyId: serviceConfig.s3.accessKey,\n\
    secretAccessKey: serviceConfig.s3.secretKey,\n\
  },\n\
  forcePathStyle: true,\n\
});\n\
\n\
// Upload Funktion\n\
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") {\n\
  try {\n\
    const cmd = new PutObjectCommand({\n\
      Bucket: serviceConfig.s3.bucket,\n\
      Key: fileName,\n\
      Body: fileBuffer,\n\
      ContentType: contentType,\n\
      Metadata: {\n\
        "upload-timestamp": new Date().toISOString(),\n\
        "bot-id": botConfig.puppetOptions.uniqueId\n\
      }\n\
    });\n\
    await s3.send(cmd);\n\
    return `${serviceConfig.s3.endpoint}/${serviceConfig.s3.bucket}/${fileName}`;\n\
  } catch (error) {\n\
    console.error("[S3] Upload error:", error);\n\
    throw error;\n\
  }\n\
}\n\
\n\
// Webhook Funktion\n\
async function sendToWebhook(data) {\n\
  const cleanData = JSON.parse(JSON.stringify(data, (k, v) => v === null ? "" : v));\n\
  try {\n\
    const response = await fetch(serviceConfig.webhook.url, {\n\
      method: "POST",\n\
      headers: { \n\
        "Content-Type": "application/json",\n\
        "X-Bot-ID": botConfig.puppetOptions.uniqueId\n\
      },\n\
      body: JSON.stringify(cleanData),\n\
    });\n\
    if (!response.ok) throw new Error(`HTTP ${response.status}`);\n\
  } catch (error) {\n\
    console.error("[Webhook] Error:", error);\n\
    throw error;\n\
  }\n\
}\n\
\n\
// Bot initialisieren\n\
const bot = WechatyBuilder.build(botConfig);\n\
\n\
// Graceful Shutdown\n\
async function shutdown(signal) {\n\
  console.log(`[Bot] ${signal} empfangen, stoppe Bot...`);\n\
  try {\n\
    await bot.stop();\n\
    console.log("[Bot] Erfolgreich gestoppt");\n\
    process.exit(0);\n\
  } catch (error) {\n\
    console.error("[Bot] Fehler beim Stoppen:", error);\n\
    process.exit(1);\n\
  }\n\
}\n\
\n\
process.on("SIGTERM", () => shutdown("SIGTERM"));\n\
process.on("SIGINT", () => shutdown("SIGINT"));\n\
\n\
// Event Handler\n\
bot.on("scan", (qrcodeUrl, status) => {\n\
  if (status === 2) {\n\
    console.log("[QR] Scan to login:");\n\
    qrcode.generate(qrcodeUrl, { small: true });\n\
  }\n\
});\n\
\n\
bot.on("login", async (user) => {\n\
  console.log(`[Login] ${user}`);\n\
  await sendToWebhook({ \n\
    type: "login", \n\
    user: user.toString(),\n\
    botId: botConfig.puppetOptions.uniqueId,\n\
    timestamp: new Date().toISOString()\n\
  });\n\
});\n\
\n\
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
    console.log("[Message] Eingehende Nachricht:", {\n\
      id: message.id,\n\
      type: messageType,\n\
      talker: talker ? `${talker.id} (${await talker.name()})` : "unbekannt",\n\
      room: room ? `${room.id} (${await room.topic()})` : "direkt"\n\
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
      timestamp: timestamp,\n\
      botId: botConfig.puppetOptions.uniqueId\n\
    };\n\
\n\
if (message.type() === types.Message.Image || 
    (message.type() === types.Message.Text && await message.toFileBox())) {
  try {
    const fileBox = await message.toFileBox();
    const buffer = await fileBox.toBuffer();
    
    if (!buffer || buffer.length === 0) {
      throw new Error("Leerer Datei-Buffer erhalten");
    }

    // Eindeutige Message-ID sicherstellen
    const messageId = message.id || `generated-${Date.now()}`;
    
    // Verbesserte Dateinamen-Generierung - ohne Doppelung
    const originalName = fileBox.name || `image-${messageId}.jpg`;
    const fileName = `message-${messageId}-${originalName.replace(/message-.*-/, '')}`
      .replace(/[^a-zA-Z0-9.-]/g, "_");

    const fileInfo = {
      originalName: originalName.replace(/message-.*-/, ''), // Entferne potenzielle message-prefix
      mimeType: fileBox.mediaType || "image/jpeg",
      size: buffer.length,
      timestamp: Date.now(),
      messageId: messageId
    };

    console.log(`[Image] Verarbeite ${fileName}`, fileInfo);
    
    const s3Url = await uploadToS3(fileName, buffer, fileInfo.mimeType);
    
    // Webhook Payload mit bereinigten Daten
    const webhookData = {
      ...baseData,
      subType: "image",
      text: "",  // Text-Feld leer lassen, da wir s3_url haben
      file_id: messageId,
      file_name: fileInfo.originalName,
      file_size: fileInfo.size || 0,
      message_type: "image",
      s3_url: s3Url,
      mime_type: fileInfo.mimeType || "image/jpeg",
      created_at: timestamp
    };

    // Prüfe auf undefined/null Werte vor dem Senden
    Object.keys(webhookData).forEach(key => {
      if (webhookData[key] === undefined || webhookData[key] === null) {
        console.warn(`[Warning] Undefined/null value for ${key}, setting to empty string`);
        webhookData[key] = "";
      }
    });

    await sendToWebhook(webhookData);
    
    console.log("[Image] Verarbeitung abgeschlossen:", {
      messageId: messageId,
      fileName: fileName,
      size: fileInfo.size,
      url: s3Url
    });

  } catch (error) {
    console.error("[Image] Verarbeitungsfehler:", error);
    await sendToWebhook({
      ...baseData,
      subType: "error",
      error: `Bildverarbeitungsfehler: ${error.message}`,
      errorTimestamp: new Date().toISOString()
    });
  }
}
    } else {\n\
      await sendToWebhook({\n\
        ...baseData,\n\
        subType: "text",\n\
        text: message.text() || "",\n\
        message_type: "text",\n\
        created_at: timestamp\n\
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
        messageId: message?.id || "unknown",\n\
        botId: botConfig.puppetOptions.uniqueId\n\
      });\n\
    } catch (webhookError) {\n\
      console.error("[Message] Fehler beim Senden des Fehlerberichts:", webhookError);\n\
    }\n\
  }\n\
});\n\
\n\
// Event Handler für Fehler\n\
bot.on("error", async (error) => {\n\
  console.error("[Bot] Error:", error);\n\
  await sendToWebhook({\n\
    type: "error",\n\
    error: error.toString(),\n\
    botId: botConfig.puppetOptions.uniqueId,\n\
    timestamp: new Date().toISOString()\n\
  });\n\
});\n\
\n\
// Bot starten\n\
console.log(`[Bot] Starting... (ID: ${botConfig.puppetOptions.uniqueId})`);\n\
bot.start()\n\
  .then(() => console.log("[Bot] Started successfully"))\n\
  .catch(e => {\n\
    console.error("[Bot] Start failed:", e);\n\
    process.exit(1);\n\
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
