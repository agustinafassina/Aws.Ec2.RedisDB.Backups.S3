#!/bin/bash
set -euo pipefail

REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_DUMP_FILE="${REDIS_DATA_DIR}/dump.rdb"
BACKUPS_DIR="${BACKUPS_DIR:-/backups}"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

usage() {
  echo "Usage: $0 <S3_URI_OR_LOCAL_FOLDER> [BACKUP_FILENAME]"
  echo "  S3 example:    $0 s3://my-bucket/backups/prd/20250131120000/"
  echo "  Local example: $0 /backups/20250131120000 redis-backup-2025-01-31.rdb"
  exit 1
}

[[ $# -ge 1 ]] || usage

SOURCE="$1"
BACKUP_FILENAME="${2:-}"

# --- Create backups dir ---
RESTORE_DIR="$BACKUPS_DIR/$(date +%Y%m%d%H%M%S)"
mkdir -p "$RESTORE_DIR"

# --- Download from S3 if URI looks like s3:// ---
if [[ "$SOURCE" == s3://* ]]; then
  log "Downloading from S3: $SOURCE"
  aws s3 cp "$SOURCE" "$RESTORE_DIR/" --recursive
  # Use first .rdb found if not specified
  if [[ -z "$BACKUP_FILENAME" ]]; then
    BACKUP_FILENAME="$(find "$RESTORE_DIR" -maxdepth 1 -name "*.rdb" -print -quit)"
    BACKUP_FILENAME="${BACKUP_FILENAME##*/}"
  fi
else
  # Local folder: copy or use as path
  if [[ -d "$SOURCE" ]]; then
    if [[ -n "$BACKUP_FILENAME" ]]; then
      cp "$SOURCE/$BACKUP_FILENAME" "$RESTORE_DIR/"
    else
      cp "$SOURCE"/*.rdb "$RESTORE_DIR/" 2>/dev/null || true
      BACKUP_FILENAME="$(find "$RESTORE_DIR" -maxdepth 1 -name "*.rdb" -print -quit)"
      BACKUP_FILENAME="${BACKUP_FILENAME##*/}"
    fi
  else
    log "ERROR: Not a directory or S3 URI: $SOURCE"
    usage
  fi
fi

RESTORE_FILE="$RESTORE_DIR/$BACKUP_FILENAME"
if [[ -z "$BACKUP_FILENAME" ]] || [[ ! -f "$RESTORE_FILE" ]]; then
  log "ERROR: Backup file not found: $RESTORE_FILE"
  exit 1
fi

# --- Restore ---
log "Stopping Redis..."
sudo systemctl stop redis

# Backup current dump if present
if [[ -f "$REDIS_DUMP_FILE" ]]; then
  sudo mv "$REDIS_DUMP_FILE" "${REDIS_DUMP_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

log "Restoring from $RESTORE_FILE..."
sudo cp "$RESTORE_FILE" "$REDIS_DUMP_FILE"
sudo chown redis:redis "$REDIS_DUMP_FILE" 2>/dev/null || true

log "Starting Redis..."
sudo systemctl start redis

log "Restore complete. RDB: $REDIS_DUMP_FILE (from $RESTORE_FILE)"
log "Optional: remove temporary dir with: rm -rf $RESTORE_DIR"
