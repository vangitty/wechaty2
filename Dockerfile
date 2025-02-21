FROM debian:bookworm
LABEL maintainer="Huan LI (李卓桓) <zixia@zixia.net>"

ENV DEBIAN_FRONTEND=noninteractive
ENV WECHATY_DOCKER=1
ENV LC_ALL=C.UTF-8
ENV NODE_ENV=production
ENV NPM_CONFIG_LOGLEVEL=warn

# 1) Systempakete
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    bash \
    build-essential \
    git \
    python3 \
    python3-pip \
    ffmpeg \
    jq \
    gnupg2 \
    tzdata \
    vim \
    # ... was auch immer Sie brauchen ...
 && rm -rf /var/lib/apt/lists/*

# 2) Node.js 20 installieren
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /bot

# 3) package.json mit korrekter Syntax & "type": "module"
RUN cat << 'EOF' > /bot/package.json
{
  "name": "wechaty-bot",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "wechaty": "^1.20.2",
    "wechaty-puppet-padlocal": "^1.20.1",
    "qrcode-terminal": "^0.12.0",
    "node-fetch": "^3.3.0",
    "@aws-sdk/client-s3": "^3.300.0"
  }
}
EOF

# 4) NPM install
RUN npm install

# 5) mybot.js als Here-Doc
RUN cat << 'EOF' > /bot/mybot.js
import { WechatyBuilder, Message } from "wechaty";
import qrcode from "qrcode-terminal";
import fetch from "node-fetch";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

const WEBHOOK_URL = process.env.N8N_WEBHOOK_URL || "";
const S3_ENDPOINT = process.env.S3_ENDPOINT || "";
const S3_ACCESS_KEY = process.env.S3_ACCESS_KEY || "";
const S3_SECRET_KEY = process.env.S3_SECRET_KEY || "";
const S3_BUCKET = process.env.S3_BUCKET || "wechaty-files";

// Falls gewünscht, noch prüfen, ob Variablen gesetzt...
if (!WEBHOOK_URL) {
  console.error("N8N_WEBHOOK_URL not set!");
  process.exit(1);
}

const s3 = new S3Client({
  endpoint: S3_ENDPOINT,
  region: "us-east-1",
  credentials: {
    accessKeyId: S3_ACCESS_KEY,
    secretAccessKey: S3_SECRET_KEY,
  },
  forcePathStyle: true,
});

async function uploadToS3(fileName, fileBuffer, contentType="application/octet-stream") {
  const cmd = new PutObjectCommand({
    Bucket: S3_BUCKET,
    Key: fileName,
    Body: fileBuffer,
    ContentType: contentType
  });
  await s3.send(cmd);
  // Evtl. "public-read" + Bucket Policy, wenn öffentlich
  return `${S3_ENDPOINT}/${S3_BUCKET}/${fileName}`;
}

async function sendToWebhook(data) {
  try {
    console.log("Sending to webhook:", WEBHOOK_URL);
    const response = await fetch(WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    if (!response.ok) {
      const txt = await response.text();
      throw new Error(`Webhook error: ${response.status} => ${txt}`);
    }
    console.log("Successfully sent to webhook");
  } catch (err) {
    console.error("Error sending to webhook:", err);
  }
}

const bot = WechatyBuilder.build({
  name: "padlocal-bot",
  puppet: "wechaty-puppet-padlocal"
});

bot.on("scan", (qrcodeUrl, status) => {
  if (status === 2) {
    console.log("Scan QR Code to login:");
    qrcode.generate(qrcodeUrl, { small: true }, ascii => {
      console.log(ascii);
    });
  }
});

bot.on("login", async user => {
  console.log(`User ${user} logged in`);
  await sendToWebhook({ type: "login", user: user.toString() });
});

bot.on("message", async (message) => {
  try {
    const from = message.from();
    const room = message.room();
    const timestamp = message.date().toISOString();

    if (message.type() === Message.Type.Image) {
      const fileBox = await message.toFileBox();
      const buffer = await fileBox.toBuffer();
      const fileName = fileBox.name || `image-${Date.now()}.jpg`;

      const s3Url = await uploadToS3(fileName, buffer, "image/jpeg");
      await sendToWebhook({
        type: "message",
        subType: "image",
        fromId: from?.id,
        fromName: from?.name(),
        roomId: room?.id,
        roomTopic: room ? await room.topic() : null,
        timestamp,
        s3Url,
      });
    } else if (message.type() === Message.Type.Attachment) {
      const fileBox = await message.toFileBox();
      const buffer = await fileBox.toBuffer();
      const fileName = fileBox.name || `file-${Date.now()}`;

      const s3Url = await uploadToS3(fileName, buffer, "application/octet-stream");
      await sendToWebhook({
        type: "message",
        subType: "attachment",
        fromId: from?.id,
        fromName: from?.name(),
        roomId: room?.id,
        roomTopic: room ? await room.topic() : null,
        timestamp,
        s3Url,
      });
    } else {
      // Normale Textnachricht
      await sendToWebhook({
        type: "message",
        subType: "text",
        fromId: from?.id,
        fromName: from?.name(),
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

bot.on("error", async error => {
  console.error("Bot error:", error);
  await sendToWebhook({ type: "error", error: error.toString() });
});

bot.start()
  .then(() => console.log("Bot started successfully"))
  .catch(e => console.error("Bot start failed:", e));
EOF

RUN chmod +x /bot/mybot.js

ENTRYPOINT ["node"]
CMD ["mybot.js"]

