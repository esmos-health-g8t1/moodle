#!/bin/bash
set -e

# --- Default Environment Variables ---
: "${MOODLE_DIR:=/var/www/moodle}"
: "${MOODLE_DATA:=/var/www/moodledata}"
: "${CODE_CACHE_DIR:=$MOODLE_DATA/sitecode}"     # Cache do Core
: "${PLUGIN_CACHE_ROOT:=$MOODLE_DATA/plugincode}" # Cache dos Plugins
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=en}"
: "${MOODLE_GIT_REPO:=https://github.com/moodle/moodle.git}"
: "${MOODLE_VERSION:=MOODLE_501_STABLE}"

# --- Versioning Note ---
# Moodle Core and Plugins are now pre-baked into the image via the Dockerfile builder stage.
# SITE_CODE_STATUS and PLUGIN_CODE_STATUS are deprecated in this optimized image.

# --- PHP Defaults ---
: "${PHP_MEMORY_LIMIT:=512M}"
: "${PHP_UPLOAD_MAX_FILESIZE:=100M}"
: "${PHP_POST_MAX_SIZE:=100M}"
: "${PHP_MAX_EXECUTION_TIME:=600}"
: "${PHP_MAX_INPUT_VARS:=5000}"
: "${OPCAHE_STRINGS_BUFFER:=16}"
: "${OPCACHE_MAX_FILES:=20000}"
: "${FASTCGI_BUFFER:=64}"
: "${DB_MAX_CONECTIONS:=200}"
: "${DB_PERSIST:=0}"


# Pega os IDs passados pelo CapRover ou usa o padrão do www-data (33)
PUID=${PUID:-33}
PGID=${PGID:-33}

# Verifica se os IDs são diferentes do padrão do sistema
if [ "$PUID" != "33" ] || [ "$PGID" != "33" ]; then
    echo ">> Alterando o UID do www-data para $PUID e o GID para $PGID..."

    # Altera o ID do grupo e do usuário www-data para os IDs do host
    groupmod -o -g "$PGID" www-data
    usermod -o -u "$PUID" -g www-data www-data

    echo ">> Ajustando as permissões das pastas montadas..."
    chown -R www-data:www-data /var/www/moodle
    chown -R www-data:www-data /var/www/moodledata
fi

# Moodle 5.1+ requer /public, versões anteriores usam a raiz
VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')
if [ "$VERSION_NUM" -ge 501 ]; then
    NGINX_WEB_ROOT="/var/www/moodle/public"
else
    NGINX_WEB_ROOT="/var/www/moodle"
fi
echo "    -> Nginx Root configured to: $NGINX_WEB_ROOT"

# --- Auto-Correction: Upload vs Post ---
# Função auxiliar para converter strings (1G, 500M) em bytes numéricos para comparação
get_bytes() {
    local val=$1
    # Awk detecta a letra, multiplica e retorna o inteiro
    echo "$val" | awk '
        /G/ {printf "%.0f", $1 * 1024 * 1024 * 1024; exit}
        /M/ {printf "%.0f", $1 * 1024 * 1024; exit}
        /K/ {printf "%.0f", $1 * 1024; exit}
        {print $1}
    '
}

BYTES_UPLOAD=$(get_bytes "$PHP_UPLOAD_MAX_FILESIZE")
BYTES_POST=$(get_bytes "$PHP_POST_MAX_SIZE")

if [ "$BYTES_UPLOAD" -gt "$BYTES_POST" ]; then
    echo ">>> WARNING: PHP_UPLOAD_MAX_FILESIZE ($PHP_UPLOAD_MAX_FILESIZE) is larger than PHP_POST_MAX_SIZE ($PHP_POST_MAX_SIZE)."
    echo "    -> Auto-fixing: Setting PHP_POST_MAX_SIZE to match Upload Size."
    PHP_POST_MAX_SIZE="$PHP_UPLOAD_MAX_FILESIZE"
fi

# ----------------------------------------------------------------------
# 0. SERVER Configuration
# ----------------------------------------------------------------------
# Variável Mágica: Porcentagem de RAM para usar (Padrão 75%)
# Se for maquina dedicada, use 90. Se for dividida, use 50.
: "${SERVER_MEMORY_USAGE_PERCENT:=75}"
: "${NGINX_GZIP_LEVEL:=6}"  # Padrão 6 (Equilíbrio). Use 1 para performance máxima de CPU.

# --- 0.1. Cálculos Automáticos (Auto-Tuning) ---

echo ">>> Auto-Tuning PHP & Nginx..."

# Detecta Memória Total em MB
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
echo "    Total RAM detected: ${TOTAL_RAM_MB}MB"

TARGET_RAM_MB=$(awk "BEGIN {print int($TOTAL_RAM_MB * $SERVER_MEMORY_USAGE_PERCENT / 100)}")
echo "    Target RAM (${SERVER_MEMORY_USAGE_PERCENT}%): ${TARGET_RAM_MB}MB"
# Calcula memória alvo
 PM_MAX_CHILDREN=$(awk "BEGIN {print int($TARGET_RAM_MB / 100)}")

# Segurança mínima

if [ "$PM_MAX_CHILDREN" -lt 5 ]; then PM_MAX_CHILDREN=5; fi


PM_START_SERVERS=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.25)}")

if [ "$PM_START_SERVERS" -lt 2 ]; then PM_START_SERVERS=2; fi

PM_MIN_SPARE=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.20)}")

if [ "$PM_MIN_SPARE" -lt 2 ]; then PM_MIN_SPARE=1; fi

PM_MAX_SPARE=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.50)}")

if [ "$PM_MAX_SPARE" -lt 3 ]; then PM_MAX_SPARE=3; fi

# Garante que Max Spare seja pelomenos maior ao Start Servers
if [ "$PM_MAX_SPARE" -lt "$PM_START_SERVERS" ]; then
    PM_MAX_SPARE=$(( PM_START_SERVERS + 1 ))
fi

# Garante que Max Children seja maior que Max Spare (para não travar)
if [ "$PM_MAX_CHILDREN" -lt "$PM_MAX_SPARE" ]; then
    PM_MAX_CHILDREN=$(( PM_MAX_SPARE + 1 ))
fi

if [ "$TARGET_RAM_MB" -le 2048 ]; then
    PM_MAX_REQUESTS=500
else
    PM_MAX_REQUESTS=1000
fi

# Cálculos de Cache (APCu e OPCache)
# Aloca ~5% da RAM alvo para cada cache (ajuste fino)
CACHE_SIZE=$(awk "BEGIN {print int($TARGET_RAM_MB * 0.05)}")
if [ "$CACHE_SIZE" -lt 128 ]; then CACHE_SIZE=128; fi
# Teto para não exagerar em máquinas gigantes
if [ "$CACHE_SIZE" -gt 512 ]; then CACHE_SIZE=512; fi

echo "    Calculated settings:"
echo "    -> pm.max_children = $PM_MAX_CHILDREN"
echo "    -> Cache Size (APCu/OPCache) = ${CACHE_SIZE}M"

# ---  Geração de Arquivos de Configuração ---

#  PHP-FPM Pool (Sobrescreve se AUTO_TUNE=true ou se não existir)
echo "    -> Generating php-fpm pool config..."
#rm -f /usr/local/etc/php-fpm.d/www.conf /usr/local/etc/php-fpm.d/zz-docker.conf

    cat <<EOF > /usr/local/etc/php-fpm.d/zz-docker.conf
[global]
daemonize = no

[www]
pm = dynamic
pm.max_children = $PM_MAX_CHILDREN
pm.start_servers = $PM_START_SERVERS
pm.min_spare_servers = $PM_MIN_SPARE
pm.max_spare_servers = $PM_MAX_SPARE
pm.max_requests = $PM_MAX_REQUESTS

catch_workers_output = yes
decorate_workers_output = no
clear_env = no
EOF

#  OPCache
cat <<EOF > /usr/local/etc/php/conf.d/10-opcache-tuning.ini
opcache.enable=1
opcache.memory_consumption=${CACHE_SIZE}
opcache.interned_strings_buffer=${OPCAHE_STRINGS_BUFFER}
opcache.max_accelerated_files=${OPCACHE_MAX_FILES}
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.enable_cli=1
EOF


#  APCu

cat <<EOF > /usr/local/etc/php/conf.d/20-apcu-tuning.ini
apc.enabled=1
apc.shm_size=${CACHE_SIZE}M
apc.ttl=7200
apc.enable_cli=1
EOF

# Database Tuning (Postgres & MySQL)
cat <<EOF > /usr/local/etc/php/conf.d/20-database-tuning.ini
; --- PostgreSQL Tuning ---
[PostgreSQL]
pgsql.allow_persistent = On

pgsql.auto_reset_persistent = On

pgsql.max_persistent = ${DB_MAX_CONECTIONS}
pgsql.max_links = ${DB_MAX_CONECTIONS}

; --- MySQL/MariaDB Tuning
[MySQLi]
mysqli.allow_persistent = On
mysqli.max_persistent = ${DB_MAX_CONECTIONS}
mysqli.max_links = ${DB_MAX_CONECTIONS}
mysqli.reconnect = On
EOF

#  Configuração Geral PHP (Uploads/Memory)
echo "    -> Generating General PHP config..."
cat <<EOF > /usr/local/etc/php/conf.d/00-general.ini
memory_limit = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size = ${PHP_POST_MAX_SIZE}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
max_input_vars = ${PHP_MAX_INPUT_VARS}
date.timezone = America/Sao_Paulo
EOF

MAX_BUFFER_SIZE=$(awk "BEGIN {print int($FASTCGI_BUFFER * 2)}")
# Nginx Config
echo "    -> Generating Nginx config..."
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /dev/stdout;
    error_log /dev/stderr;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout ${PHP_MAX_EXECUTION_TIME};
    client_body_timeout ${PHP_MAX_EXECUTION_TIME};
    client_header_timeout ${PHP_MAX_EXECUTION_TIME};
    fastcgi_read_timeout ${PHP_MAX_EXECUTION_TIME};
    types_hash_max_size 2048;

    # Upload limits from ENV
    client_max_body_size ${PHP_UPLOAD_MAX_FILESIZE};

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level ${NGINX_GZIP_LEVEL}; # Mais compressão, usa um pouco mais de CPU (ok na sua máquina dedicada)
    gzip_min_length 256;
    gzip_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/x-javascript
        application/xml
        application/xml+rss
        image/svg+xml
        image/x-icon
        font/ttf
        font/opentype;

    # Logs
    access_log /var/log/nginx/access.log;

    server {
        listen 80;
        listen [::]:80;

        server_name _;
        root ${NGINX_WEB_ROOT};
        index index.php index.html;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ (/\.git|/\.env|/vendor/|/node_modules/|composer\.json|/readme|/README|/LICENSE|/COPYING|/tests/|/classes/|/cli/|/\.) {
            deny all;
            return 404;
        }

        location ~ [^/]\.php(/|$) {
            fastcgi_split_path_info ^(.+?\.php)(/.*)$;

            if (!-f \$document_root\$fastcgi_script_name) {
              return 404;
            }

            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include /etc/nginx/mime.types;
            include fastcgi_params;

            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param PATH_INFO \$fastcgi_path_info;

            fastcgi_buffers 4 ${MAX_BUFFER_SIZE}k;
            fastcgi_buffer_size ${FASTCGI_BUFFER}k;
            fastcgi_busy_buffers_size ${MAX_BUFFER_SIZE}k;

            fastcgi_read_timeout ${PHP_MAX_EXECUTION_TIME};
        }

        location /dataroot/ {
            internal;
            alias ${MOODLE_DATA}/; # O caminho real da pasta de dados
        }
    }
}
EOF


# ----------------------------------------------------------------------
# 2. Moodle Core Layer (ALREADY BAKED IN IMAGE)
# ----------------------------------------------------------------------
# Moodle Core is provided via Stage 1 of the Dockerfile.
echo ">>> Using pre-baked Moodle Core..."
mkdir -p "$MOODLE_DIR"

# ----------------------------------------------------------------------
# 3. Generate Config.php (Always Fresh)
# ----------------------------------------------------------------------
echo ">>> Generating config.php..."
cat <<EOF > "$MOODLE_DIR/config.php"
<?php
unset(\$CFG);
global \$CFG;

\$CFG = new stdClass();
\$CFG->dbtype    = '${DB_TYPE:-pgsql}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${DB_HOST:-localhost}';
\$CFG->dbname    = '${DB_NAME:-moodle}';
\$CFG->prefix    = '${DB_PREFIX:-mdl_}';
if (defined('CLI_SCRIPT') && CLI_SCRIPT && '${DB_USER_CRON:-}' && '${DB_PASS_CRON:-}') {
    // Configuração para o CRON (Processos de fundo)
    \$CFG->dbuser = '${DB_USER_CRON}';
    \$CFG->dbpass = '${DB_PASS_CRON}';
} else {
    \$CFG->dbuser    = '${DB_USER:-moodle}';
    \$CFG->dbpass    = '${DB_PASS:-}';
}

\$CFG->dboptions = array (
  'dbport' => '${DB_PORT:-}',
  'dbpersist' => false,
);

\$CFG->wwwroot   = '${MOODLE_URL}';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 0700;

// --- High Performance Optimization: Ephemeral Local Caching ---
// Redirects heavy I/O from slow Azure Files (Standard) to fast local storage (/tmp)
\$CFG->localcachedir = '/tmp/moodle_local_cache';
\$CFG->tempdir       = '/tmp/moodle_temp';
\$CFG->cachedir      = '/tmp/moodle_cache';

\$CFG->xsendfile = 'X-Accel-Redirect';
\$CFG->xsendfilealiases = array(
    '/dataroot/' => \$CFG->dataroot,
);

EOF

# Ensure the local cache directories exist and are writable
mkdir -p /tmp/moodle_local_cache /tmp/moodle_temp /tmp/moodle_cache
chown -R www-data:www-data /tmp/moodle_local_cache /tmp/moodle_temp /tmp/moodle_cache
chmod -R 777 /tmp/moodle_local_cache /tmp/moodle_temp /tmp/moodle_cache

if [ ! -z "$MOODLE_EXTRA_PHP" ]; then echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"; fi
echo "require_once(__DIR__ . '/lib/setup.php');" >> "$MOODLE_DIR/config.php"

# ----------------------------------------------------------------------
# 4. Plugins Layer (ALREADY BAKED IN IMAGE)
# ----------------------------------------------------------------------
# Plugins listed in plugins.json are now pre-baked into the image.
# For runtime dynamic updates, please use the moodle-standard deployment.

# ----------------------------------------------------------------------
# 5. Final Permissions & Web Server
# ----------------------------------------------------------------------
echo ">>> Using pre-baked permissions..."
mkdir -p "$CODE_CACHE_DIR" "$PLUGIN_CACHE_ROOT"
chown -R root:root "$CODE_CACHE_DIR" "$PLUGIN_CACHE_ROOT"
echo ">>> Fixing Nginx temp paths (Crucial for Uploads)..."
# Cria os diretórios caso não existam
mkdir -p /var/lib/nginx/body /var/lib/nginx/fastcgi /var/lib/nginx/proxy
# Garante que o www-data (usuário do Nginx/PHP) seja dono
chown -R www-data:www-data /var/lib/nginx
chmod -R 700 /var/lib/nginx

# ----------------------------------------------------------------------
# 6. Database & Upgrade
# ----------------------------------------------------------------------
echo ">>> Waiting for Database..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

echo ">>> Database Status..."
# Check rápido via PHP para ver se tabelas existem
if su -s /bin/sh www-data -c "php -r 'define(\"CLI_SCRIPT\", true); require(\"$MOODLE_DIR/config.php\"); if (\$DB->get_manager()->table_exists(\"config\")) { exit(0); } else { exit(1); }'" >/dev/null 2>&1; then
    echo ">>> Database exists. Running upgrades..."
    su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/upgrade.php --non-interactive"
else
    echo ">>> Installing Moodle..."
    if su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/install_database.php \
            --lang='$MOODLE_LANG' \
            --adminuser='${MOODLE_ADMIN_USER:-admin}' \
            --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
            --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
            --fullname='${MOODLE_SITE_FULLNAME:-Moodle Site}' \
            --shortname='${MOODLE_SITE_SHORTNAME:-Moodle}' \
            --supportemail='${MOODLE_SUPPORT_EMAIL:-support@example.com}' \
            --agree-license";
      then
          su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/cfg.php --name=noreplyaddress --set='${MOODLE_NOREPLY_EMAIL:-noreply@example.com}'"
          echo ">>> Installation completed successfully!"
      else
          echo "ERROR: Installation failed!"
          exit 1
      fi
fi
su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/purge_caches.php"
echo ">>> Starting Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf