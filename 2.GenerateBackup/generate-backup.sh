#!/bin/bash
set -euo pipefail

# cron runs with a minimal PATH (/usr/bin:/bin); the AWS CLI installed via snap lives in /snap/bin.
export PATH="/snap/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# --- Optional config file (keeps secrets out of the crontab) ---
# See redis-backup.env.example. Install it as /etc/redis-backup.env (chmod 600).
CONFIG_FILE="${CONFIG_FILE:-/etc/redis-backup.env}"
if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi

# --- Config (override via env, config file or args) ---
ENVIRONMENT="${1:-${ENVIRONMENT:-prd}}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
REDIS_DUMP_FILE="${REDIS_DATA_DIR}/dump.rdb"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_USER="${REDIS_USER:-}"        # ACL user; password goes in REDISCLI_AUTH (read by redis-cli)
BGSAVE_TIMEOUT="${BGSAVE_TIMEOUT:-600}"
BACKUP_S3_BASE="${BACKUP_S3_BASE:-s3://backups/folder-name}"
REMOVE_LOCAL_AFTER_UPLOAD="${REMOVE_LOCAL_AFTER_UPLOAD:-true}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"       # Slack / Teams / Discord incoming webhook
ALERT_SNS_TOPIC_ARN="${ALERT_SNS_TOPIC_ARN:-}"   # requires sns:Publish on the topic

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
DATE_FILES="$(date +%F)"
BACKUP_FILE="/tmp/redis-backup-${DATE_FILES}-${TIMESTAMP}.rdb"
BACKUP_S3_PATH="${BACKUP_S3_BASE}/${ENVIRONMENT}/${TIMESTAMP}/"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# --- Failure alerts ---
LAST_ERROR="unexpected error (see log)"
fail() { LAST_ERROR="$*"; log "ERROR: $*"; exit 1; }

json_escape() {
  local bs='\' q='"' s="$1"
  # Quoted pattern/replacement: behaves the same in bash 4.x and 5.2+ (patsub_replacement).
  s="${s//"$bs"/"$bs$bs"}"
  s="${s//"$q"/"$bs$q"}"
  printf '%s' "${s//$'\n'/ }"
}

notify_failure() {
  local msg="$1" esc
  if [[ -n "$ALERT_WEBHOOK_URL" ]]; then
    esc="$(json_escape "$msg")"
    # "text" is used by Slack/Teams, "content" by Discord.
    curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
      --data "{\"text\":\"${esc}\",\"content\":\"${esc}\"}" "$ALERT_WEBHOOK_URL" >/dev/null \
      || log "WARNING: webhook alert failed"
  fi
  if [[ -n "$ALERT_SNS_TOPIC_ARN" ]]; then
    aws sns publish --topic-arn "$ALERT_SNS_TOPIC_ARN" --subject "Redis backup failed" \
      --message "$msg" >/dev/null || log "WARNING: SNS alert failed"
  fi
}

on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    notify_failure "Redis backup FAILED on $(hostname) (env=${ENVIRONMENT}, exit=${rc}): ${LAST_ERROR}"
  fi
}
trap on_exit EXIT

# --- Redis helpers ---
REDIS_CLI=(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --no-auth-warning)
[[ -n "$REDIS_USER" ]] && REDIS_CLI+=(--user "$REDIS_USER")
redis_cmd() { "${REDIS_CLI[@]}" "$@"; }
persistence_field() { redis_cmd INFO persistence | tr -d '\r' | awk -F: -v k="$1" '$1==k {print $2}'; }

# --- Validations ---
for bin in aws redis-cli; do
  command -v "$bin" &>/dev/null || fail "'$bin' not found in PATH ($PATH)"
done

if [[ "$(redis_cmd PING 2>&1)" != "PONG" ]]; then
  fail "Cannot reach Redis at $REDIS_HOST:$REDIS_PORT (check REDIS_USER / REDISCLI_AUTH)"
fi

# --- Snapshot with BGSAVE (no downtime) ---
log "Waiting for any running background save to finish..."
while [[ "$(persistence_field rdb_bgsave_in_progress)" == "1" ]]; do sleep 2; done

LAST_SAVE="$(redis_cmd LASTSAVE)"
# LASTSAVE has 1s resolution: make sure the new save gets a later timestamp.
if [[ "$LAST_SAVE" -ge "$(date +%s)" ]]; then sleep 1; fi

log "Triggering BGSAVE..."
BGSAVE_OUT="$(redis_cmd BGSAVE 2>&1)"
[[ "$BGSAVE_OUT" == Background* ]] || fail "BGSAVE failed: $BGSAVE_OUT"

DEADLINE=$(( $(date +%s) + BGSAVE_TIMEOUT ))
while [[ "$(redis_cmd LASTSAVE)" -le "$LAST_SAVE" ]]; do
  [[ "$(date +%s)" -lt "$DEADLINE" ]] || fail "BGSAVE did not finish within ${BGSAVE_TIMEOUT}s"
  sleep 2
done

[[ "$(persistence_field rdb_last_bgsave_status)" == "ok" ]] \
  || fail "Last BGSAVE status is not ok (check the Redis log)"
log "BGSAVE completed."

# --- Local copy ---
# Redis writes the RDB to a temp file and renames it, so copying it now is safe.
log "Creating local backup..."
sudo cp "$REDIS_DUMP_FILE" "$BACKUP_FILE" || fail "Cannot copy $REDIS_DUMP_FILE"
sudo chown "$(id -un):$(id -gn)" "$BACKUP_FILE"

# --- Integrity check ---
if command -v redis-check-rdb &>/dev/null; then
  log "Checking RDB integrity..."
  redis-check-rdb "$BACKUP_FILE" >/dev/null || fail "redis-check-rdb reported a corrupt file: $BACKUP_FILE"
else
  log "WARNING: redis-check-rdb not found, skipping integrity check"
fi
[[ -s "$BACKUP_FILE" ]] || fail "Backup file is empty: $BACKUP_FILE"
log "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"

# --- Upload (AWS CLI v2 validates checksums on upload) ---
log "Uploading to S3: $BACKUP_S3_PATH"
aws s3 cp "$BACKUP_FILE" "$BACKUP_S3_PATH" --only-show-errors \
  || fail "S3 upload failed. Local backup kept at $BACKUP_FILE"

if [[ "$REMOVE_LOCAL_AFTER_UPLOAD" == "true" ]]; then
  rm -f "$BACKUP_FILE"
  log "Local backup removed."
fi

log "Backup completed: $BACKUP_S3_PATH"
