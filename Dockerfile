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
COPY package.json /bot/package.json

# Dependencies installieren
RUN npm install

# Bot-Skript erstellen
COPY mybot.js /bot/mybot.js

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
