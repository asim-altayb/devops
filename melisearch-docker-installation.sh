#!/bin/bash
# Meilisearch Installation and Configuration Script
# This script handles the complete setup of Meilisearch on Ubuntu 22.04

# Exit immediately if a command exits with a non-zero status
set -e

# Default values (can be overridden with environment variables)
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
NC='\033[0m' # No Color

# Log function
log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
}

warn() {
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Show script settings
log "Meilisearch Installation Started"
log "Settings:"
log "  - Data path: $MEILI_DATA_PATH"
log "  - Backup path: $MEILI_BACKUP_PATH"
log "  - Log path: $MEILI_LOG_PATH"
log "  - Config path: $MEILI_CONFIG_PATH"
log "  - HTTP Address: $MEILI_HTTP_ADDR"
log "  - EBS Device: $MEILI_EBS_DEVICE"

# 1. Update the system
log "Updating system packages..."
apt-get update && apt-get upgrade -y

# 2. Install Docker
log "Installing Docker..."
if ! command -v docker &> /dev/null; then
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl start docker
  systemctl enable docker
  log "Docker installed successfully"
else
  log "Docker is already installed"
fi

# 3. Create required directories
log "Creating directories..."
mkdir -p $MEILI_DATA_PATH
mkdir -p $MEILI_BACKUP_PATH
mkdir -p $MEILI_LOG_PATH
mkdir -p $MEILI_CONFIG_PATH
chmod -R 755 /meilisearch

# 4. Mount EBS volume if available
log "Setting up data volume..."
if [ -e $MEILI_EBS_DEVICE ]; then
  if ! grep -qs "$MEILI_DATA_PATH" /proc/mounts; then
    log "Formatting and mounting EBS volume..."
    mkfs -t xfs $MEILI_EBS_DEVICE || true
    mount $MEILI_EBS_DEVICE $MEILI_DATA_PATH
    echo "$MEILI_EBS_DEVICE $MEILI_DATA_PATH xfs defaults,nofail 0 2" >> /etc/fstab
  else
    log "EBS volume is already mounted"
  fi
else
  warn "EBS device $MEILI_EBS_DEVICE not found. Using root volume for data."
fi

# 5. Create Meilisearch configuration file
log "Creating Meilisearch configuration..."
cat > $MEILI_CONFIG_PATH/config.env << EOF
# Meilisearch Configuration
MEILI_ENV=production
MEILI_MASTER_KEY=$MEILI_MASTER_KEY
MEILI_HTTP_ADDR=$MEILI_HTTP_ADDR
MEILI_NO_ANALYTICS=true
MEILI_DB_PATH=/meili_data
MEILI_MAX_INDEX_SIZE=107374182400
EOF

# 6. Create backup script
log "Creating backup script..."
cat > /usr/local/bin/meilisearch-backup.sh << 'EOF'
#!/bin/bash
# Meilisearch backup script

# Set variables
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=MEILI_BACKUP_PATH_PLACEHOLDER
LOG_FILE=MEILI_LOG_PATH_PLACEHOLDER/backup.log

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

log "Starting backup..."

# Stop Meilisearch container for consistent backup
log "Stopping Meilisearch container..."
docker stop meilisearch

# Create backup
log "Creating backup archive..."
tar -czf $BACKUP_DIR/meilisearch_$TIMESTAMP.tar.gz MEILI_DATA_PATH_PLACEHOLDER

# Restart Meilisearch
log "Restarting Meilisearch container..."
docker start meilisearch

# Clean up old backups (keep last 7)
log "Cleaning up old backups..."
ls -t $BACKUP_DIR/meilisearch_*.tar.gz | tail -n +8 | xargs -r rm -f

log "Backup completed: meilisearch_$TIMESTAMP.tar.gz"
EOF

# Replace placeholders in the backup script
sed -i "s|MEILI_BACKUP_PATH_PLACEHOLDER|$MEILI_BACKUP_PATH|g" /usr/local/bin/meilisearch-backup.sh
sed -i "s|MEILI_LOG_PATH_PLACEHOLDER|$MEILI_LOG_PATH|g" /usr/local/bin/meilisearch-backup.sh
sed -i "s|MEILI_DATA_PATH_PLACEHOLDER|$MEILI_DATA_PATH|g" /usr/local/bin/meilisearch-backup.sh
chmod +x /usr/local/bin/meilisearch-backup.sh

# 7. Create health check script
log "Creating health check script..."
cat > /usr/local/bin/meilisearch-healthcheck.sh << 'EOF'
#!/bin/bash
# Meilisearch health check script

# Set variables
LOG_FILE=MEILI_LOG_PATH_PLACEHOLDER/health.log
HEALTH_URL="http://localhost:7700/health"
MASTER_KEY="MEILI_MASTER_KEY_PLACEHOLDER"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

log "Running health check..."

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
  log "ERROR: Docker service is not running. Attempting to start..."
  systemctl start docker
  sleep 5
fi

# Check if Meilisearch container exists
if ! docker ps -a | grep -q meilisearch; then
  log "ERROR: Meilisearch container does not exist."
  exit 1
fi

# Check if Meilisearch container is running
if ! docker ps | grep -q meilisearch; then
  log "Meilisearch container is not running. Attempting to start..."
  docker start meilisearch
  sleep 10
fi

# Check if Meilisearch is responding
if curl -s -o /dev/null "http://localhost:7700/health"; then
  log "Meilisearch is healthy"
else
  log "Meilisearch is not responding. Restarting container..."
  docker restart meilisearch
fi
EOF

# Replace placeholders in the health check script
sed -i "s|MEILI_LOG_PATH_PLACEHOLDER|$MEILI_LOG_PATH|g" /usr/local/bin/meilisearch-healthcheck.sh
sed -i "s|MEILI_MASTER_KEY_PLACEHOLDER|$MEILI_MASTER_KEY|g" /usr/local/bin/meilisearch-healthcheck.sh
chmod +x /usr/local/bin/meilisearch-healthcheck.sh

# 8. Set up cron jobs
log "Setting up cron jobs..."
cat > /etc/cron.d/meilisearch << EOF
# Meilisearch maintenance tasks
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Health check every 15 minutes
*/15 * * * * root /usr/local/bin/meilisearch-healthcheck.sh > /dev/null 2>&1

# Daily backup at 2 AM
0 2 * * * root /usr/local/bin/meilisearch-backup.sh > /dev/null 2>&1
EOF

# 9. Launch Meilisearch
log "Starting Meilisearch container..."
docker run -d --name meilisearch \
  --restart always \
  -p 7700:7700 \
  -v $MEILI_DATA_PATH:/meili_data \
  -v $MEILI_CONFIG_PATH/config.env:/etc/meili/config.env \
  --env-file $MEILI_CONFIG_PATH/config.env \
  getmeili/meilisearch:latest

# 10. Verify installation
log "Verifying Meilisearch installation..."
sleep 5
if curl -s "http://localhost:7700/health" > /dev/null; then
  log "Meilisearch is running successfully!"
else
  warn "Meilisearch may not be running properly. Check logs with 'docker logs meilisearch'"
fi

# Store master key for reference (in production, consider using a secrets manager)
echo "MEILI_MASTER_KEY=$MEILI_MASTER_KEY" > $MEILI_CONFIG_PATH/master_key.txt
chmod 600 $MEILI_CONFIG_PATH/master_key.txt

log "Installation completed successfully!"
log "Meilisearch is accessible at: http://<server-ip>:7700"
log "Master key is stored in: $MEILI_CONFIG_PATH/master_key.txt"
