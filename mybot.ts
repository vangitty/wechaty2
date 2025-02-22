import { WechatyBuilder } from "wechaty";
import { types } from "wechaty-puppet";
import qrcode from "qrcode-terminal";
import fetch from "node-fetch";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

// Konfiguration
const config = {
  webhook: {
    url: process.env.N8N_WEBHOOK_URL,
    required: true
  },
  s3: {
    endpoint: process.env.S3_ENDPOINT,
    accessKey: process.env.S3_ACCESS_KEY,
    secretKey: process.env.S3_SECRET_KEY,
    bucket: process.env.S3_BUCKET || "wechaty-files",
    required: true
  }
};

// Konfigurationsvalidierung
function validateConfig() {
  const missingVars = [];
  Object.entries(config).forEach(([service, conf]) => {
    Object.entries(conf).forEach(([key, value]) => {
      if (conf.required && !value && key !== "required") {
        missingVars.push(`${service.toUpperCase()}_${key.toUpperCase()}`);
      }
    });
  });

  if (missingVars.length > 0) {
    console.error(`[Config] Fehlende erforderliche Umgebungsvariablen: ${missingVars.join(", ")}`);
    process.exit(1);
  }
}

validateConfig();

// S3 Client Initialisierung
const s3 = new S3Client({
  endpoint: config.s3.endpoint,
  region: "us-east-1",
  credentials: {
    accessKeyId: config.s3.accessKey,
    secretAccessKey: config.s3.secretKey,
  },
  forcePathStyle: true,
});

// S3 Upload Funktion
async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream", retries = 3) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      console.log(`[S3] Upload-Versuch ${attempt} für ${fileName} (${fileBuffer.length} Bytes)`);
      
      const cmd = new PutObjectCommand({
        Bucket: config.s3.bucket,
        Key: fileName,
        Body: fileBuffer,
        ContentType: contentType,
        Metadata: {
          'upload-timestamp': new Date().toISOString(),
          'upload-attempt': attempt.toString()
        }
      });

      await s3.send(cmd);
      const fileUrl = `${config.s3.endpoint}/${config.s3.bucket}/${fileName}`;
      console.log(`[S3] Upload erfolgreich: ${fileUrl}`);
      return fileUrl;

    } catch (error) {
      console.error(`[S3] Upload-Fehler (Versuch ${attempt}):`, error);
      if (attempt === retries) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * attempt));
    }
  }
}

// Webhook Funktion
async function sendToWebhook(data, retries = 3) {
  const cleanData = JSON.parse(JSON.stringify(data, (key, value) => {
    if (value === null || value === undefined) return '';
    return value;
  }));

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      console.log(`[Webhook] Sende Daten (Versuch ${attempt}):`, cleanData);
      
      const response = await fetch(config.webhook.url, {
        method: "POST",
        headers: { 
          "Content-Type": "application/json",
          "X-Retry-Attempt": attempt.toString()
        },
        body: JSON.stringify(cleanData),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${await response.text()}`);
      }

      console.log(`[Webhook] Erfolgreich gesendet (Versuch ${attempt})`);
      return;

    } catch (error) {
      console.error(`[Webhook] Fehler (Versuch ${attempt}):`, error);
      if (attempt === retries) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * attempt));
    }
  }
}

// Bot Initialisierung
const bot = WechatyBuilder.build({
  name: "padlocal-bot",
  puppet: "wechaty-puppet-padlocal",
  puppetOptions: {
    timeout: 30000,
  }
});

// Event Handler
bot.on("scan", (qrcodeUrl, status) => {
  if (status === 2) {
    console.log("[QR] Scannen zum Einloggen:");
    qrcode.generate(qrcodeUrl, { small: true });
  }
  console.log(`[QR] Status: ${status}`);
});

bot.on("login", async (user) => {
  try {
    console.log(`[Login] ${user} eingeloggt`);
    await sendToWebhook({ 
      type: "login", 
      user: user.toString(),
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error("[Login] Webhook-Fehler:", error);
  }
});

// Nachrichtenverarbeitung
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

    console.log("[Message] Rohdaten:", {
      messageId: message.id,
      messageType,
      talker: talker ? { id: talker.id, name: await talker.name() } : null,
      room: room ? { id: room.id, topic: await room.topic() } : null
    });

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

        const fileName = `message-${message.id}-${fileBox.name || "image.jpg"}`.replace(/[^a-zA-Z0-9.-]/g, '_');
        console.log(`[Image] Verarbeite ${fileName} (${buffer.length} Bytes)`);
        
        const s3Url = await uploadToS3(fileName, buffer, "image/jpeg");
        
        await sendToWebhook({
          ...baseData,
          subType: "image",
          text: s3Url,
          fileName: fileName,
          fileSize: buffer.length,
          s3Url: s3Url,
          originalName: fileBox.name
        });
        
        console.log("[Image] Verarbeitung abgeschlossen");

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
      await sendToWebhook({
        ...baseData,
        subType: "text",
        text: message.text() || ''
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

// Fehlerbehandlung
bot.on("error", async (error) => {
  console.error("[Bot] Fehler:", error);
  try {
    await sendToWebhook({
      type: "error",
      error: error.toString(),
      stack: error.stack,
      timestamp: new Date().toISOString()
    });
  } catch (webhookError) {
    console.error("[Bot] Fehler beim Senden des Fehlerberichts:", webhookError);
  }
});

// Logout Handler
bot.on("logout", async (user, reason) => {
  console.log(`[Logout] ${user} ausgeloggt, Grund: ${reason}`);
  try {
    await sendToWebhook({
      type: "logout",
      user: user.toString(),
      reason: reason,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error("[Logout] Webhook-Fehler:", error);
  }
});

// Bot Start
async function startBot() {
  try {
    console.log("[Bot] Startvorgang beginnt...");
    await bot.start();
    console.log("[Bot] Erfolgreich gestartet");
  } catch (error) {
    console.error("[Bot] Startfehler:", error);
    process.exit(1);
  }
}

startBot();
