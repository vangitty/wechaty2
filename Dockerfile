import { WechatyBuilder } from "wechaty";
import { types } from "wechaty-puppet";
import qrcode from "qrcode-terminal";
import fetch from "node-fetch";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

// ------------------------------------------------------------------------
// 1) ENV Variablen aus Docker/Coolify
// ------------------------------------------------------------------------
const WEBHOOK_URL = process.env.N8N_WEBHOOK_URL;
const S3_ENDPOINT = process.env.S3_ENDPOINT;
const S3_ACCESS_KEY = process.env.S3_ACCESS_KEY;
const S3_SECRET_KEY = process.env.S3_SECRET_KEY;
const S3_BUCKET = process.env.S3_BUCKET || "wechaty-files";

if (!WEBHOOK_URL) {
  console.error("N8N_WEBHOOK_URL is not set!");
  process.exit(1);
}

// ------------------------------------------------------------------------
// 2) S3 Client initialisieren
// ------------------------------------------------------------------------
const s3 = new S3Client({
  endpoint: S3_ENDPOINT,
  region: "us-east-1",
  credentials: {
    accessKeyId: S3_ACCESS_KEY,
    secretAccessKey: S3_SECRET_KEY,
  },
  forcePathStyle: true,
});

async function uploadToS3(fileName, fileBuffer, contentType = "application/octet-stream") {
  try {
    console.log(`Uploading file ${fileName} to S3...`);
    const cmd = new PutObjectCommand({
      Bucket: S3_BUCKET,
      Key: fileName,
      Body: fileBuffer,
      ContentType: contentType
    });
    await s3.send(cmd);
    const fileUrl = `${S3_ENDPOINT}/${S3_BUCKET}/${fileName}`;
    console.log(`File uploaded successfully. URL: ${fileUrl}`);
    return fileUrl;
  } catch (error) {
    console.error("Error uploading to S3:", error);
    throw error;
  }
}

// ------------------------------------------------------------------------
// 3) Webhook-POST
// ------------------------------------------------------------------------
async function sendToWebhook(data) {
  try {
    console.log("Sending to webhook:", WEBHOOK_URL);
    const response = await fetch(WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    if (!response.ok) {
      const textResponse = await response.text();
      throw new Error(`HTTP Error ${response.status} => ${textResponse}`);
    }
    console.log("Successfully sent to webhook");
  } catch (error) {
    console.error("Error sending to webhook:", error);
  }
}

// ------------------------------------------------------------------------
// 4) WeChaty Bot aufsetzen
// ------------------------------------------------------------------------
const bot = WechatyBuilder.build({
  name: "padlocal-bot",
  puppet: "wechaty-puppet-padlocal"
});

bot.on("scan", (qrcodeUrl, status) => {
  if (status === 2) {
    console.log("Scan QR Code to login:");
    qrcode.generate(qrcodeUrl, { small: true }, (ascii) => {
      console.log(ascii);
    });
  }
});

bot.on("login", async (user) => {
  console.log(`User ${user} logged in`);
  await sendToWebhook({ type: "login", user: user.toString() });
});

// ------------------------------------------------------------------------
// 5) Message Handler (Text / Image / Attachment)
// ------------------------------------------------------------------------
bot.on("message", async (message) => {
  try {
    const room = message.room();
    const talker = message.talker();  // Using talker() instead of from()
    const messageType = message.type();
    const timestamp = message.date().toISOString();

    console.log(`Received message type: ${messageType} from ${talker?.name()}`);

    // Skip unsupported message types (like type 51)
    if (messageType === types.Message.Unknown) {
      console.log("Skipping unsupported message type");
      return;
    }

    // Check: Image?
    if (messageType === types.Message.Image) {
      console.log("Processing image message...");
      const fileBox = await message.toFileBox();
      const buffer = await fileBox.toBuffer();
      const fileName = fileBox.name || `image-${Date.now()}.jpg`;

      const s3Url = await uploadToS3(fileName, buffer, "image/jpeg");

      await sendToWebhook({
        type: "message",
        subType: "image",
        fromId: talker?.id,
        fromName: talker?.name(),
        text: "",
        roomId: room?.id,
        roomTopic: room ? await room.topic() : null,
        timestamp,
        s3Url,
      });

    // Check: Attachment?
    } else if (messageType === types.Message.Attachment) {
      console.log("Processing attachment message...");
      const fileBox = await message.toFileBox();
      const buffer = await fileBox.toBuffer();
      const fileName = fileBox.name || `file-${Date.now()}`;

      const s3Url = await uploadToS3(fileName, buffer, "application/octet-stream");

      await sendToWebhook({
        type: "message",
        subType: "attachment",
        fromId: talker?.id,
        fromName: talker?.name(),
        text: "",
        roomId: room?.id,
        roomTopic: room ? await room.topic() : null,
        timestamp,
        s3Url,
      });

    } else if (messageType === types.Message.Text) {
      // Text message
      console.log("Processing text message...");
      await sendToWebhook({
        type: "message",
        subType: "text",
        fromId: talker?.id,
        fromName: talker?.name(),
        text: message.text(),
        roomId: room?.id,
        roomTopic: room ? await room.topic() : null,
        timestamp,
      });
    }
  } catch (err) {
    console.error("Error processing message:", err);
  }
});

bot.on("error", async (error) => {
  console.error("Bot error:", error);
  await sendToWebhook({ type: "error", error: error.toString() });
});

// ------------------------------------------------------------------------
// 6) Bot starten
// ------------------------------------------------------------------------
bot.start()
  .then(() => console.log("Bot started successfully"))
  .catch((e) => console.error("Bot start failed:", e));

# -------------------------------------------------------
# 6) Ausführbar machen
# -------------------------------------------------------
RUN chmod +x /bot/mybot.js

# -------------------------------------------------------
# 7) Container-Start: node /bot/mybot.js
# -------------------------------------------------------
ENTRYPOINT ["node"]
CMD ["mybot.js"]

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

