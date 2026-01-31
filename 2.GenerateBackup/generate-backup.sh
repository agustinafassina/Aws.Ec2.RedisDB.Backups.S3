#!/bin/bash
set -euo pipefail

# --- Config (override via env or args) ---
ENVIRONMENT="${1:-${ENVIRONMENT:-prd}}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_DUMP_FILE="${REDIS_DATA_DIR}/dump.rdb"
BACKUP_S3_BASE="${BACKUP_S3_BASE:-s3://backups/folder-name}"
REMOVE_LOCAL_AFTER_UPLOAD="${REMOVE_LOCAL_AFTER_UPLOAD:-true}"

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
DATE_FILES="$(date +%F)"
BACKUP_FILE="/tmp/redis-backup-${DATE_FILES}-${TIMESTAMP}.rdb"
BACKUP_S3_PATH="${BACKUP_S3_BASE}/${ENVIRONMENT}/${TIMESTAMP}/"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# --- Validations ---
if [[ ! -f "$REDIS_DUMP_FILE" ]]; then
  log "ERROR: Redis dump not found at $REDIS_DUMP_FILE"
  exit 1
fi

if ! command -v aws &>/dev/null; then
  log "ERROR: AWS CLI not found. Install with: sudo snap install aws-cli --classic"
  exit 1
fi

# --- Backup ---
log "Stopping Redis..."
sudo systemctl stop redis

cleanup_on_fail() {
  log "WARNING: Restarting Redis after failure..."
  sudo systemctl start redis
}
trap cleanup_on_fail ERR

log "Creating local backup..."
sudo cp "$REDIS_DUMP_FILE" "$BACKUP_FILE"
sudo chown "$(whoami):$(whoami)" "$BACKUP_FILE"

log "Starting Redis..."
sudo systemctl start redis
trap - ERR

log "Uploading to S3: $BACKUP_S3_PATH"
if ! aws s3 cp "$BACKUP_FILE" "$BACKUP_S3_PATH"; then
  log "ERROR: S3 upload failed. Local backup kept at $BACKUP_FILE"
  exit 1
fi

if [[ "$REMOVE_LOCAL_AFTER_UPLOAD" == "true" ]]; then
  rm -f "$BACKUP_FILE"
  log "Local backup removed."
fi

log "Backup completed: $BACKUP_S3_PATH"
