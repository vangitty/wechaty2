import { WechatyBuilder } from "wechaty";
import { types } from "wechaty-puppet";
import qrcode from "qrcode-terminal";
import fetch from "node-fetch";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

// Bot Konfiguration
const botConfig = {
  name: process.env.BOT_NAME || "padlocal-bot",
  puppet: "wechaty-puppet-padlocal",
  puppetOptions: {
    token: process.env.PADLOCAL_TOKEN,
    timeout: 30000,
    uniqueId: process.env.BOT_ID || `bot-${Date.now()}`
  }
};

// Service Konfiguration
const serviceConfig = {
  webhook: { url: process.env.N8N_WEBHOOK_URL, required: true },
  s3: {
    endpoint: process.env.S3_ENDPOINT,
    accessKey: process.env.S3_ACCESS_KEY,
    secretKey: process.env.S3_SECRET_KEY,
    bucket: process.env.S3_BUCKET || "wechaty-files",
    required: true
  }
};

// MIME-Type Helper
function getMimeType(fileName) {
  const extension = fileName.split('.').pop().toLowerCase();
  const mimeTypes = {
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt': 'text/plain',
    'csv': 'text/csv',
    'zip': 'application/zip',
    'rar': 'application/x-rar-compressed',
    '7z': 'application/x-7z-compressed'
  };
  return mimeTypes[extension] || 'application/octet-stream';
}

// Funktion zur Extraktion des Dateinamens aus URL
function extractFilenameFromUrl(url) {
  // Extrahiere Dateinamen aus der URL
  const filename = url.split('/').pop(); // Nimmt den letzten Teil der URL nach "/"
  return filename;
}

// Konfiguration validieren
function validateConfig() {
  const missingVars = [];
  Object.entries(serviceConfig).forEach(([service, conf]) => {
    Object.entries(conf).forEach(([key, value]) => {
      if (conf.required && !value && key !== "required") {
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`);
      }
    });
  });
  if (!botConfig.puppetOptions.token) {
    missingVars.push("PADLOCAL_TOKEN");
  }
  if (missingVars.length > 0) {
    console.error(`[Config] Fehlende Umgebungsvariablen: ${missingVars.join(", ")}`);
    process.exit(1);
  }
}

validateConfig();

// S3 Client initialisieren
const s3 = new S3Client({
  endpoint: serviceConfig.s3.endpoint,
  region: "us-east-1",
  credentials: {
    accessKeyId: serviceConfig.s3.accessKey,
    secretAccessKey: serviceConfig.s3.secretKey,
  },
  forcePathStyle: true,
});

// Upload Funktion
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") {
  try {
    const cmd = new PutObjectCommand({
      Bucket: serviceConfig.s3.bucket,
      Key: fileName,
      Body: fileBuffer,
      ContentType: contentType,
      Metadata: {
        "upload-timestamp": new Date().toISOString(),
        "bot-id": botConfig.puppetOptions.uniqueId
      }
    });
    await s3.send(cmd);
    return `${serviceConfig.s3.endpoint}/${serviceConfig.s3.bucket}/${fileName}`;
  } catch (error) {
    console.error("[S3] Upload error:", error);
    throw error;
  }
}

// Webhook Funktion
async function sendToWebhook(data) {
  const cleanData = JSON.parse(JSON.stringify(data, (k, v) => v === null ? "" : v));
  try {
    const response = await fetch(serviceConfig.webhook.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Bot-ID": botConfig.puppetOptions.uniqueId
      },
      body: JSON.stringify(cleanData),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } catch (error) {
    console.error("[Webhook] Error:", error);
    throw error;
  }
}

// Bot initialisieren
const bot = WechatyBuilder.build(botConfig);

// Event Handler
bot.on("scan", (qrcodeUrl, status) => {
  if (status === 2) {
    console.log("[QR] Scan to login:");
    qrcode.generate(qrcodeUrl, { small: true });
  }
});

bot.on("login", async (user) => {
  console.log(`[Login] ${user}`);
  await sendToWebhook({
    type: "login",
    user: user.toString(),
    botId: botConfig.puppetOptions.uniqueId,
    timestamp: new Date().toISOString()
  });
});

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

    console.log("[Message] Eingehende Nachricht:", {
      id: message.id,
      type: messageType,
      talker: talker ? `${talker.id} (${await talker.name()})` : "unbekannt",
      room: room ? `${room.id} (${await room.topic()})` : "direkt"
    });

    if (messageType === types.Message.Unknown || messageType === 51) {
      console.log("[Message] System- oder unbekannte Nachricht übersprungen");
      return;
    }

    const baseData = {
      type: "message",
      messageId: message.id || `generated-${Date.now()}`,
      fromId: talker ? talker.id : "",
      fromName: talker ? (await talker.name() || "") : "",
      roomId: room ? room.id : "",
      roomTopic: room ? (await room.topic() || "") : "",
      messageType: messageType,
      timestamp: timestamp,
      botId: botConfig.puppetOptions.uniqueId
    };

    if (message.type() === types.Message.Image || 
        message.type() === types.Message.Attachment ||
        message.type() === types.Message.Video ||
        message.type() === types.Message.Audio ||
        (message.type() === types.Message.Text && await message.toFileBox())) {
      try {
        const fileBox = await message.toFileBox();
        const buffer = await fileBox.toBuffer();
        
        if (!buffer || buffer.length === 0) {
          throw new Error("Leerer Datei-Buffer erhalten");
        }

        const messageId = message.id || `generated-${Date.now()}`;
        const originalName = fileBox.name || 
          (message.type() === types.Message.Image ? `image-${messageId}.jpg` : `file-${messageId}`);
        
        const cleanedName = originalName.replace(/message-.*-/, "").replace(/[^a-zA-Z0-9.-]/g, "_");
        const fileName = `message-${messageId}-${cleanedName}`;

        const fileInfo = {
          originalName: cleanedName,
          mimeType: fileBox.mediaType || getMimeType(originalName),
          size: buffer.length,
          timestamp: Date.now(),
          messageId: messageId
        };

        console.log(`[File] Verarbeite ${fileName}`, fileInfo);
        
        const s3Url = await uploadToS3(fileName, buffer, fileInfo.mimeType);

        let messageType = "file";
        if (fileInfo.mimeType.startsWith("image/")) {
          messageType = "image";
        } else if (fileInfo.mimeType.startsWith("video/")) {
          messageType = "video";
        } else if (fileInfo.mimeType.startsWith("audio/")) {
          messageType = "audio";
        }
        
        await sendToWebhook({
          ...baseData,
          subType: messageType,
          text: "",
          file_id: messageId,
          file_name: fileInfo.originalName,
          file_size: fileInfo.size || 0,
          message_type: messageType,
          s3_url: s3Url,
          mime_type: fileInfo.mimeType,
          created_at: timestamp
        });
        
        console.log("[File] Verarbeitung abgeschlossen:", {
          messageId: messageId,
          fileName: fileName,
          size: fileInfo.size,
          type: messageType,
          url: s3Url
        });

      } catch (error) {
        console.error("[File] Verarbeitungsfehler:", error);
        await sendToWebhook({
          ...baseData,
          subType: "error",
          error: `Dateiverarbeitungsfehler: ${error.message}`,
          errorTimestamp: new Date().toISOString()
        });
      }
    } else {
   // Für Textnachrichten
await sendToWebhook({
  ...baseData,
  subType: "text",
  text: message.text() || "", // Behalte diesen Wert
  extracted_text: message.text() || "", // Füge dieses Feld hinzu
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
        messageId: message?.id || "unknown",
        botId: botConfig.puppetOptions.uniqueId
      });
    } catch (webhookError) {
      console.error("[Message] Fehler beim Senden des Fehlerberichts:", webhookError);
    }
  }
});

// Event Handler für Fehler
bot.on("error", async (error) => {
  console.error("[Bot] Error:", error);
  await sendToWebhook({
    type: "error",
    error: error.toString(),
    botId: botConfig.puppetOptions.uniqueId,
    timestamp: new Date().toISOString()
  });
});

// Graceful Shutdown
async function shutdown(signal) {
  console.log(`[Bot] ${signal} empfangen, stoppe Bot...`);
  try {
    await bot.stop();
    console.log("[Bot] Erfolgreich gestoppt");
    process.exit(0);
  } catch (error) {
    console.error("[Bot] Fehler beim Stoppen:", error);
    process.exit(1);
  }
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Bot starten
console.log(`[Bot] Starting... (ID: ${botConfig.puppetOptions.uniqueId})`);
bot.start()
  .then(() => console.log("[Bot] Started successfully"))
  .catch(e => {
    console.error("[Bot] Start failed:", e);
    process.exit(1);
  });
