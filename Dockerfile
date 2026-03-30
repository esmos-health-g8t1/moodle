ARG PHP_VERSION=${PHP_VERSION:-8.3}

# --- Stage 1: Build/Download Stage ---
FROM debian:trixie-slim AS builder
RUN echo ">>> BUILD START: $(date)"
ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_GIT_REPO="https://github.com/moodle/moodle.git"
ENV MOODLE_VERSION="MOODLE_501_STABLE"

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates jq curl \
    && rm -rf /var/lib/apt/lists/*

# Pre-clone Moodle Core
RUN mkdir -p ${MOODLE_DIR} \
    && git clone --depth 1 --branch ${MOODLE_VERSION} ${MOODLE_GIT_REPO} ${MOODLE_DIR} \
    && rm -rf ${MOODLE_DIR}/.git

# Pre-install Plugins from plugins.json
COPY plugins.json* /tmp/plugins.json
RUN if [ -f /tmp/plugins.json ] && [ "$(cat /tmp/plugins.json)" != "[]" ]; then \
    cat /tmp/plugins.json | jq -c '.[]' | while read i; do \
        GIT_URL=$(echo "$i" | jq -r '.giturl'); \
        GIT_BRANCH=$(echo "$i" | jq -r '.branch // "master"'); \
        INSTALL_PATH=$(echo "$i" | jq -r '.installpath'); \
        echo ">>> Baking Plugin: $INSTALL_PATH from $GIT_URL"; \
        mkdir -p "${MOODLE_DIR}/$INSTALL_PATH"; \
        git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "${MOODLE_DIR}/$INSTALL_PATH"; \
        rm -rf "${MOODLE_DIR}/$INSTALL_PATH/.git"; \
    done; \
    fi

# 🛠 BUGFIX: HACK FOR WEBHOOKS PLUGIN (Moodle 4.x & PHP 8 Compatibility)
RUN if [ -d "${MOODLE_DIR}/local/webhooks" ]; then \
    echo ">>> Applying Webhooks permanent patches..."; \
    # 1. XMLDB Path Error (\ddl_exception [ddlxmlfileerror])
    # Complete removal of PATH attribute allows Moodle 4.x to auto-calculate the path during install.
    sed -i 's/PATH="[^"]*"//g' "${MOODLE_DIR}/local/webhooks/db/install.xml"; \
    # 2. Webhook Reliability (Moodle 4.x internal event observers)
    # Fix from PR #37: Set internal => false to ensure webhooks fire after DB commit.
    if [ -f "${MOODLE_DIR}/local/webhooks/db/events.php" ]; then \
        sed -i "s/'internal' => true,/'internal' => false,/g" "${MOODLE_DIR}/local/webhooks/db/events.php"; \
    fi; \
    # 3. PHP 8.x Array Type-Safety (ArgumentCountError/TypeError)
    # Patch for classes/webhooks_table.php (Prevents crashes on PHP 8.3+)
    if [ -f "${MOODLE_DIR}/local/webhooks/classes/webhooks_table.php" ]; then \
        sed -i 's/"{local_webhooks_service}", "1"/"{local_webhooks_service}", "1=1"/g' "${MOODLE_DIR}/local/webhooks/classes/webhooks_table.php"; \
        sed -i 's/return count($eventlist);/return $eventlist ? count($eventlist) : 0;/g' "${MOODLE_DIR}/local/webhooks/classes/webhooks_table.php"; \
    fi; \
    fi

# --- Stage 2: Final Runtime Stage ---
FROM php:${PHP_VERSION}-fpm-trixie

LABEL maintainer="Esdras Caleb"

ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# 1. Dependências de Sistema e MS SQL Server (Removed git/jq from runtime for security/size)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg2 curl ca-certificates lsb-release nginx supervisor \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev unixodbc-dev zlib1g-dev libssl-dev libmemcached-dev  \
    graphviz aspell ghostscript poppler-utils \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18 \
    && rm -rf /var/lib/apt/lists/*

# 2. Instalação de Extensões PHP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    && pecl install sqlsrv pdo_sqlsrv memcached apcu \
    && docker-php-ext-enable sqlsrv pdo_sqlsrv memcached apcu

# 3. Estrutura e Arquivos
RUN mkdir -p $MOODLE_DATA /var/log/supervisor $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 777 $MOODLE_DATA

# Copy pre-baked Moodle code from builder stage
COPY --from=builder --chown=www-data:www-data ${MOODLE_DIR} ${MOODLE_DIR}

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY plugins.json* /usr/local/bin/default_plugins.json
RUN sed -i -e 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

# Security: Ensure moodle dir permissions are tight but functional
RUN chmod -R 755 $MOODLE_DIR
RUN echo ">>> BUILD FINISH: $(date)"

ENTRYPOINT ["entrypoint.sh"]