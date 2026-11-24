#!/bin/bash
set -euo pipefail

# AWS CLI installed via snap lives in /snap/bin (not in PATH under cron/sudo).
export PATH="/snap/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# --- Optional config file (same one used by generate-backup.sh) ---
CONFIG_FILE="${CONFIG_FILE:-/etc/redis-backup.env}"
if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi

REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_DUMP_FILE="${REDIS_DATA_DIR}/dump.rdb"
REDIS_CONF="${REDIS_CONF:-/etc/redis/redis.conf}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_USER="${REDIS_USER:-}"
START_TIMEOUT="${START_TIMEOUT:-120}"
BACKUPS_DIR="${BACKUPS_DIR:-$HOME/redis-restores}"   # user-writable, no root needed
ASSUME_YES="${ASSUME_YES:-false}"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

usage() {
  echo "Usage: $0 <S3_URI_OR_LOCAL_FOLDER> [BACKUP_FILENAME]"
  echo "  S3 example:    $0 s3://my-bucket/redis/prd/20250131120000/"
  echo "  Local example: $0 ~/redis-restores/20250131120000 redis-backup-2025-01-31-20250131120000.rdb"
  echo "  Env: ASSUME_YES=true to skip the confirmation prompt"
  exit 1
}

[[ $# -ge 1 ]] || usage

SOURCE="$1"
BACKUP_FILENAME="${2:-}"

REDIS_CLI=(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --no-auth-warning)
[[ -n "$REDIS_USER" ]] && REDIS_CLI+=(--user "$REDIS_USER")
redis_cmd() { "${REDIS_CLI[@]}" "$@"; }
redis_up() { [[ "$(redis_cmd PING 2>&1)" == "PONG" ]]; }
total_keys() {
  redis_cmd INFO keyspace | tr -d '\r' \
    | awk -F'[=,]' '/^db[0-9]+:keys=/ {sum += $2} END {print sum + 0}'
}

# --- Get the backup file ---
RESTORE_DIR="$BACKUPS_DIR/$(date +%Y%m%d%H%M%S)"
mkdir -p "$RESTORE_DIR"

if [[ "$SOURCE" == s3://* ]]; then
  log "Downloading from S3: $SOURCE"
  aws s3 cp "$SOURCE" "$RESTORE_DIR/" --recursive --only-show-errors
elif [[ -d "$SOURCE" ]]; then
  if [[ -n "$BACKUP_FILENAME" ]]; then
    cp "$SOURCE/$BACKUP_FILENAME" "$RESTORE_DIR/"
  else
    cp "$SOURCE"/*.rdb "$RESTORE_DIR/" 2>/dev/null || true
  fi
else
  log "ERROR: Not a directory or S3 URI: $SOURCE"
  usage
fi

# Use first .rdb found if not specified
if [[ -z "$BACKUP_FILENAME" ]]; then
  BACKUP_FILENAME="$(find "$RESTORE_DIR" -maxdepth 1 -name "*.rdb" -print -quit)"
  BACKUP_FILENAME="${BACKUP_FILENAME##*/}"
fi

RESTORE_FILE="$RESTORE_DIR/$BACKUP_FILENAME"
if [[ -z "$BACKUP_FILENAME" ]] || [[ ! -s "$RESTORE_FILE" ]]; then
  fail "Backup file not found or empty: $RESTORE_FILE"
fi

# --- Integrity check ---
if command -v redis-check-rdb &>/dev/null; then
  log "Checking RDB integrity..."
  redis-check-rdb "$RESTORE_FILE" >/dev/null || fail "redis-check-rdb reported a corrupt file: $RESTORE_FILE"
else
  log "WARNING: redis-check-rdb not found, skipping integrity check"
fi

# --- AOF check: with appendonly enabled Redis loads the AOF and IGNORES dump.rdb ---
AOF_ENABLED="no"
# Validation after the restore needs redis-cli access: fail now instead of rolling back later.
if systemctl is-active --quiet redis && ! redis_up; then
  fail "Redis is running but PING failed: check REDIS_USER / REDISCLI_AUTH in $CONFIG_FILE"
fi
if redis_up; then
  [[ "$(redis_cmd INFO persistence | tr -d '\r' | awk -F: '$1=="aof_enabled" {print $2}')" == "1" ]] && AOF_ENABLED="yes"
elif sudo grep -Eq '^[[:space:]]*appendonly[[:space:]]+yes' "$REDIS_CONF" 2>/dev/null; then
  AOF_ENABLED="yes"
fi
if [[ "$AOF_ENABLED" == "yes" ]]; then
  fail "AOF (appendonly yes) is enabled: Redis would ignore the restored RDB. See README 'Restore with AOF enabled'."
fi

# --- Confirmation ---
if [[ "$ASSUME_YES" != "true" ]]; then
  [[ -t 0 ]] || fail "Non-interactive run: set ASSUME_YES=true to confirm the restore"
  read -r -p "This will STOP Redis and REPLACE $REDIS_DUMP_FILE with $BACKUP_FILENAME. Continue? [y/N] " answer
  [[ "$answer" =~ ^[yYsS]$ ]] || { log "Aborted."; exit 1; }
fi

# --- Restore ---
log "Stopping Redis..."
sudo systemctl stop redis

PREV_DUMP=""
if sudo test -f "$REDIS_DUMP_FILE"; then
  PREV_DUMP="${REDIS_DUMP_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp -p "$REDIS_DUMP_FILE" "$PREV_DUMP"
  log "Current dump saved to $PREV_DUMP"
fi

rollback() {
  log "Rolling back to the previous dump..."
  sudo systemctl stop redis || true
  if [[ -n "$PREV_DUMP" ]]; then
    sudo cp -p "$PREV_DUMP" "$REDIS_DUMP_FILE"
  else
    sudo rm -f "$REDIS_DUMP_FILE"
  fi
  sudo systemctl start redis || true
  fail "Restore failed, previous state restored. Check: sudo journalctl -u redis -n 50"
}

log "Restoring from $RESTORE_FILE..."
sudo cp "$RESTORE_FILE" "$REDIS_DUMP_FILE"
sudo chown redis:redis "$REDIS_DUMP_FILE" 2>/dev/null || true
sudo chmod 660 "$REDIS_DUMP_FILE"

log "Starting Redis..."
sudo systemctl start redis || rollback

# --- Validation: wait until the dataset is loaded (PING returns LOADING while loading) ---
DEADLINE=$(( $(date +%s) + START_TIMEOUT ))
until redis_up; do
  if [[ "$(date +%s)" -ge "$DEADLINE" ]] || ! systemctl is-active --quiet redis; then
    log "ERROR: Redis did not become ready within ${START_TIMEOUT}s"
    rollback
  fi
  sleep 2
done

KEYS="$(total_keys)"
log "Redis is up. Keys loaded: $KEYS"
[[ "$KEYS" -gt 0 ]] || log "WARNING: 0 keys loaded. Verify that this is the expected backup."

log "Restore complete. RDB: $REDIS_DUMP_FILE (from $RESTORE_FILE)"
[[ -n "$PREV_DUMP" ]] && log "Previous dump kept at $PREV_DUMP (delete it once validated)"
log "Optional: remove temporary dir with: rm -rf $RESTORE_DIR"
