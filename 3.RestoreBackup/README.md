# RestoreBackup
Script to restore a RedisDB backup (RDB) from S3 or from a local folder into the EC2 instance.

## What `restore-backup.sh` does 🔍
1. Downloads the backup from S3 (or copies it from a local folder) into `~/redis-restores/<timestamp>/`.
2. Checks the file integrity with `redis-check-rdb`.
3. Aborts if **AOF** is enabled (Redis would ignore the restored RDB, see below).
4. Asks for confirmation (skip it with `ASSUME_YES=true`).
5. Stops Redis, saves the current `dump.rdb` as `dump.rdb.bak.<timestamp>` and copies the backup in place.
6. Starts Redis, waits until the dataset is loaded and prints the number of keys.
7. If Redis fails to start or does not become ready, it **rolls back** to the previous dump automatically.

## Requirements 📝
- AWS CLI with read access to the bucket: `s3:GetObject` on `arn:aws:s3:::my-bucket/redis/*` and `s3:ListBucket` on `arn:aws:s3:::my-bucket` (see [2.GenerateBackup](../2.GenerateBackup/README.md)).
- `/etc/redis-backup.env` with `REDIS_USER` / `REDISCLI_AUTH`, used to validate Redis after the restore.

## Steps to restore a database 👣
1. Find the backup to restore
```
aws s3 ls s3://my-bucket/redis/prd/
aws s3 ls s3://my-bucket/redis/prd/20250131050001/
```

2. Run the restore
```
chmod +x restore-backup.sh

# From S3 (uses the first .rdb in the folder)
./restore-backup.sh s3://my-bucket/redis/prd/20250131050001/

# From a local folder, with a specific file
./restore-backup.sh ~/redis-restores/20250131120000 redis-backup-2025-01-31-20250131050001.rdb

# Non-interactive
ASSUME_YES=true ./restore-backup.sh s3://my-bucket/redis/prd/20250131050001/
```

3. Validate the data from your application. When everything is correct, remove the temporary files:
```
rm -rf ~/redis-restores/<timestamp>
sudo rm /var/lib/redis/dump.rdb.bak.<timestamp>
```

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUPS_DIR` | `~/redis-restores` | Where the backup is downloaded |
| `REDIS_DATA_DIR` | `/var/lib/redis` | Directory that holds `dump.rdb` |
| `REDIS_CONF` | `/etc/redis/redis.conf` | Used to detect AOF when Redis is stopped |
| `START_TIMEOUT` | `120` | Seconds to wait for Redis to load the dataset |
| `ASSUME_YES` | `false` | Skip the confirmation prompt |

## Restore with AOF enabled ⚠️
If `appendonly yes` is set, Redis loads the AOF on startup and **ignores `dump.rdb`**. To restore an RDB in that case:
```
# 1. Disable AOF temporarily in /etc/redis/redis.conf
appendonly no

# 2. Run the restore
./restore-backup.sh s3://my-bucket/redis/prd/20250131050001/

# 3. Rebuild the AOF from the loaded data and wait until it finishes
redis-cli --user appuser --pass StrongAppPassword CONFIG SET appendonly yes
redis-cli --user appuser --pass StrongAppPassword INFO persistence | grep aof_rewrite_in_progress   # wait for 0

# 4. Set "appendonly yes" again in /etc/redis/redis.conf so it survives restarts
```
