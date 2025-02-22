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
const config = {\n\
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
function validateConfig() {\n\
  const missingVars = [];\n\
  Object.entries(config).forEach(([service, conf]) => {\n\
    Object.entries(conf).forEach(([key, value]) => {\n\
      if (conf.required && !value && key !== "required") {\n\
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`);\n\
      }\n\
    });\n\
  });\n\
  if (missingVars.length > 0) {\n\
    console.error(`[Config] Fehlende Umgebungsvariablen: ${missingVars.join(", ")}`);\n\
    process.exit(1);\n\
  }\n\
}\n\
\n\
validateConfig();\n\
\n\
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
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") {\n\
  try {\n\
    const cmd = new PutObjectCommand({\n\
      Bucket: config.s3.bucket,\n\
      Key: fileName,\n\
      Body: fileBuffer,\n\
      ContentType: contentType\n\
    });\n\
    await s3.send(cmd);\n\
    return `${config.s3.endpoint}/${config.s3.bucket}/${fileName}`;\n\
  } catch (error) {\n\
    console.error("[S3] Upload error:", error);\n\
    throw error;\n\
  }\n\
}\n\
\n\
async function sendToWebhook(data) {\n\
  const cleanData = JSON.parse(JSON.stringify(data, (k, v) => v === null ? "" : v));\n\
  try {\n\
    const response = await fetch(config.webhook.url, {\n\
      method: "POST",\n\
      headers: { "Content-Type": "application/json" },\n\
      body: JSON.stringify(cleanData),\n\
    });\n\
    if (!response.ok) throw new Error(`HTTP ${response.status}`);\n\
  } catch (error) {\n\
    console.error("[Webhook] Error:", error);\n\
  }\n\
}\n\
\n\
const bot = WechatyBuilder.build({\n\
  name: "padlocal-bot",\n\
  puppet: "wechaty-puppet-padlocal"\n\
});\n\
\n\
bot.on("scan", (qrcodeUrl, status) => {\n\
  if (status === 2) {\n\
    console.log("[QR] Scan to login:");\n\
    qrcode.generate(qrcodeUrl, { small: true });\n\
  }\n\
});\n\
\n\
bot.on("login", async (user) => {\n\
  console.log(`[Login] ${user}`);\n\
  await sendToWebhook({ type: "login", user: user.toString() });\n\
});\n\
\n\
bot.on("message", async (message) => {
  try {
    if (!message) {
      console.error("[Message] Ungültige Nachricht erhalten");
      return;
    }

    const room = message.room();
    const talker = message.talker();
    const messageType = message.type();
    const timestamp = message.date().toISOString();

    // Debug-Logging
    console.log("[Message] Eingehende Nachricht:", {
      id: message.id,
      type: messageType,
      talker: talker ? `${talker.id} (${await talker.name()})` : 'unbekannt',
      room: room ? `${room.id} (${await room.topic()})` : 'direkt'
    });

    // System-Nachrichten filtern (type 51)
    if (messageType === types.Message.Unknown || messageType === 51) {
      console.log("[Message] System- oder unbekannte Nachricht übersprungen");
      return;
    }

    const baseData = {
      type: "message",
      messageId: message.id || `generated-${Date.now()}`,
      fromId: talker ? talker.id : '',
      fromName: talker ? (await talker.name() || '') : '',
      roomId: room ? room.id : '',
      roomTopic: room ? (await room.topic() || '') : '',
      messageType: messageType,
      timestamp: timestamp
    };

    if (message.type() === types.Message.Image || 
        (message.type() === types.Message.Text && await message.toFileBox())) {
      try {
        const fileBox = await message.toFileBox();
        const buffer = await fileBox.toBuffer();
        
        if (!buffer || buffer.length === 0) {
          throw new Error("Leerer Datei-Buffer erhalten");
        }

        // Dateiinformationen extrahieren
        const fileInfo = {
          originalName: fileBox.name,
          mimeType: fileBox.mediaType || "image/jpeg",
          size: buffer.length,
          timestamp: Date.now(),
          messageId: message.id
        };

        // Sicheren Dateinamen generieren
        const fileName = `message-${message.id}-${fileBox.name || "image.jpg"}`
          .replace(/[^a-zA-Z0-9.-]/g, '_');

        console.log(`[Image] Verarbeite ${fileName}`, fileInfo);
        
        const s3Url = await uploadToS3(fileName, buffer, fileInfo.mimeType);
        
        // Erweiterte Webhook-Daten
        await sendToWebhook({
          ...baseData,
          subType: "image",
          text: s3Url,
          file_id: message.id,  // Explizit für die Datenbank
          file_name: fileInfo.originalName,
          file_size: fileInfo.size,
          message_type: "image",
          s3_url: s3Url,
          mime_type: fileInfo.mimeType,
          created_at: timestamp
        });
        
        console.log("[Image] Verarbeitung abgeschlossen:", {
          messageId: message.id,
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
    } else {
      // Text-Nachrichten
      await sendToWebhook({
        ...baseData,
        subType: "text",
        text: message.text() || '',
        message_type: "text",
        created_at: timestamp
      });
    }

  } catch (error) {
    console.error("[Message] Allgemeiner Fehler:", error);
    try {
      await sendToWebhook({
        type: "error",
        error: error.toString(),
        timestamp: new Date().toISOString(),
        messageId: message?.id || 'unknown'
      });
    } catch (webhookError) {
      console.error("[Message] Fehler beim Senden des Fehlerberichts:", webhookError);
    }
  }
});
\n\
bot.on("error", async (error) => {\n\
  console.error("[Bot] Error:", error);\n\
  await sendToWebhook({\n\
    type: "error",\n\
    error: error.toString(),\n\
    timestamp: new Date().toISOString()\n\
  });\n\
});\n\
\n\
console.log("[Bot] Starting...");\n\
bot.start()\n\
  .then(() => console.log("[Bot] Started"))\n\
  .catch(e => console.error("[Bot] Start failed:", e));' > /bot/mybot.js

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
