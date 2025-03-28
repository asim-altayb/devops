#!/bin/bash
# Meilisearch Automated Installation Script for Ubuntu 22.04
# This script handles the complete setup without requiring user interaction

set -euo pipefail

# Configuration - all variables can be overridden via environment variables
export DEBIAN_FRONTEND=noninteractive
MEILI_MASTER_KEY=${MEILI_MASTER_KEY:-$(openssl rand -base64 32)}
MEILI_HTTP_ADDR=${MEILI_HTTP_ADDR:-0.0.0.0:7700}
MEILI_DATA_PATH=${MEILI_DATA_PATH:-/meilisearch/data}
MEILI_BACKUP_PATH=${MEILI_BACKUP_PATH:-/meilisearch/backups}
MEILI_LOG_PATH=${MEILI_LOG_PATH:-/var/log/meilisearch}
MEILI_CONFIG_PATH=${MEILI_CONFIG_PATH:-/etc/meilisearch}
MEILI_EBS_DEVICE=${MEILI_EBS_DEVICE:-/dev/sdf}

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Logging functions
log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Verify we're running as root
if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root"
fi

# Display configuration
log "Starting Meilisearch automated installation"
log "Configuration:"
log "  - Data path: $MEILI_DATA_PATH"
log "  - Backup path: $MEILI_BACKUP_PATH"
log "  - Log path: $MEILI_LOG_PATH"
log "  - Config path: $MEILI_CONFIG_PATH"
log "  - HTTP Address: $MEILI_HTTP_ADDR"
log "  - EBS Device: $MEILI_EBS_DEVICE"

# System update and package installation
log "Updating system packages..."
apt-get update -qy && apt-get upgrade -qy

log "Installing required packages..."
apt-get install -qy --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common \
  openssl \
  xfsprogs

# Docker installation
if ! command -v docker &>/dev/null; then
  log "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null
  add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >/dev/null
  apt-get update -qy
  apt-get install -qy --no-install-recommends docker-ce docker-ce-cli containerd.io
fi

# Enable and start Docker
systemctl enable --now docker >/dev/null

# Create required directories
log "Creating directories..."
mkdir -p "$MEILI_DATA_PATH" "$MEILI_BACKUP_PATH" "$MEILI_LOG_PATH" "$MEILI_CONFIG_PATH"
chmod -R 755 /meilisearch

# EBS volume setup
if [ -e "$MEILI_EBS_DEVICE" ]; then
  if ! grep -qs "$MEILI_DATA_PATH" /proc/mounts; then
    log "Setting up EBS volume..."
    if ! blkid "$MEILI_EBS_DEVICE"; then
      mkfs -t xfs -q "$MEILI_EBS_DEVICE" || true
    fi
    mount "$MEILI_EBS_DEVICE" "$MEILI_DATA_PATH"
    grep -q "$MEILI_DATA_PATH" /etc/fstab || \
      echo "$MEILI_EBS_DEVICE $MEILI_DATA_PATH xfs defaults,nofail 0 2" >> /etc/fstab
  fi
else
  warn "EBS device $MEILI_EBS_DEVICE not found. Using root volume for data."
fi

# Meilisearch configuration
log "Creating Meilisearch configuration..."
cat > "$MEILI_CONFIG_PATH/config.env" << EOF
# Meilisearch Configuration
MEILI_ENV=production
MEILI_MASTER_KEY=$MEILI_MASTER_KEY
MEILI_HTTP_ADDR=$MEILI_HTTP_ADDR
MEILI_NO_ANALYTICS=true
MEILI_DB_PATH=/meili_data
MEILI_MAX_INDEX_SIZE=107374182400
EOF

# Backup script
log "Creating backup script..."
cat > /usr/local/bin/meilisearch-backup.sh << EOF
#!/bin/bash
# Meilisearch backup script

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=$MEILI_BACKUP_PATH
LOG_FILE=$MEILI_LOG_PATH/backup.log

log() {
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> \$LOG_FILE
}

log "Starting backup..."
docker stop meilisearch || true
tar -czf "\$BACKUP_DIR/meilisearch_\$TIMESTAMP.tar.gz" "$MEILI_DATA_PATH"
docker start meilisearch || true
find "\$BACKUP_DIR" -name "meilisearch_*.tar.gz" -type f -mtime +7 -delete
log "Backup completed: meilisearch_\$TIMESTAMP.tar.gz"
EOF

chmod +x /usr/local/bin/meilisearch-backup.sh

# Health check script
log "Creating health check script..."
cat > /usr/local/bin/meilisearch-healthcheck.sh << EOF
#!/bin/bash
# Meilisearch health check script

LOG_FILE=$MEILI_LOG_PATH/health.log
HEALTH_URL="http://localhost:7700/health"

log() {
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> \$LOG_FILE
}

log "Running health check..."

if ! systemctl is-active --quiet docker; then
  log "Starting Docker service..."
  systemctl start docker
  sleep 5
fi

if ! docker ps -a | grep -q meilisearch; then
  log "ERROR: Meilisearch container does not exist."
  exit 1
fi

if ! docker ps | grep -q meilisearch; then
  log "Starting Meilisearch container..."
  docker start meilisearch
  sleep 10
fi

if ! curl -s -o /dev/null "\$HEALTH_URL"; then
  log "Restarting Meilisearch container..."
  docker restart meilisearch
fi
EOF

chmod +x /usr/local/bin/meilisearch-healthcheck.sh

# Cron jobs
log "Setting up cron jobs..."
cat > /etc/cron.d/meilisearch << EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/15 * * * * root /usr/local/bin/meilisearch-healthcheck.sh > /dev/null 2>&1
0 2 * * * root /usr/local/bin/meilisearch-backup.sh > /dev/null 2>&1
EOF

# Launch Meilisearch
log "Starting Meilisearch container..."
docker pull -q getmeili/meilisearch:latest
docker run -d \
  --name meilisearch \
  --restart always \
  -p 7700:7700 \
  -v "$MEILI_DATA_PATH:/meili_data" \
  -v "$MEILI_CONFIG_PATH/config.env:/etc/meili/config.env" \
  --env-file "$MEILI_CONFIG_PATH/config.env" \
  getmeili/meilisearch:latest >/dev/null

# Verification
log "Verifying installation..."
sleep 10
if curl -s "http://localhost:7700/health" >/dev/null; then
  log "Meilisearch is running successfully!"
else
  warn "Meilisearch may not be running properly. Check logs with 'docker logs meilisearch'"
fi

# Store master key securely
echo "MEILI_MASTER_KEY=$MEILI_MASTER_KEY" > "$MEILI_CONFIG_PATH/master_key.txt"
chmod 600 "$MEILI_CONFIG_PATH/master_key.txt"

log "Installation completed successfully!"
log "Access Meilisearch at: http://$(curl -s ifconfig.me):7700"
log "Master key stored in: $MEILI_CONFIG_PATH/master_key.txt"
