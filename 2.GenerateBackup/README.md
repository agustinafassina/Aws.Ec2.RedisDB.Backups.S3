# GenerateBackup
Scripts and instructions to create automated daily backups of RedisDB. The script triggers a `BGSAVE` (Redis keeps serving traffic, **no downtime**), copies the resulting `dump.rdb` and uploads it to an S3 bucket. It can be scheduled via cron.

## Steps to generate backups 👣
1. Install the AWS CLI on the instance
```
sudo snap install aws-cli --classic
aws --version
```

2. S3 permissions: attach an **IAM Role** to the instance (recommended)

Avoid `aws configure` with access keys on the server: they are long-lived and stored in plain text in `~/.aws/credentials`.
Instead, create an IAM Role for EC2 with a least-privilege policy and attach it to the instance
(EC2 → Instance → Actions → Security → Modify IAM role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadRedisBackups",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::my-bucket/redis/*"
    }
  ]
}
```
To also use `restore-backup.sh` from the same instance, add `s3:GetObject` on the same resource and `s3:ListBucket` on `arn:aws:s3:::my-bucket`.

Verify that the role is active (no `aws configure` needed):
```
aws sts get-caller-identity
```

3. Create the config file `/etc/redis-backup.env` (keeps credentials out of the script and the crontab)
Start from [redis-backup.env.example](redis-backup.env.example) and fill in your values:
```
sudo cp redis-backup.env.example /etc/redis-backup.env
sudo vim /etc/redis-backup.env
sudo chown ubuntu:ubuntu /etc/redis-backup.env
sudo chmod 600 /etc/redis-backup.env
```
`backup` is the least-privilege Redis user created in [1.InstallRedisDB.Ec2](../1.InstallRedisDB.Ec2/README.md) (`+ping +info +bgsave +lastsave`).

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_S3_BASE` | `s3://backups/folder-name` | Bucket/prefix. Final path: `<base>/<env>/<timestamp>/` |
| `REDIS_HOST` / `REDIS_PORT` | `127.0.0.1` / `6379` | Redis address |
| `REDIS_USER` / `REDISCLI_AUTH` | empty | ACL user and password |
| `REDIS_DATA_DIR` | `/var/lib/redis` | Directory that holds `dump.rdb` |
| `BGSAVE_TIMEOUT` | `600` | Max seconds to wait for the snapshot |
| `REMOVE_LOCAL_AFTER_UPLOAD` | `true` | Delete `/tmp` copy after upload |
| `ALERT_WEBHOOK_URL` | empty | Slack / Teams / Discord webhook notified on failure |
| `ALERT_SNS_TOPIC_ARN` | empty | SNS topic notified on failure (needs `sns:Publish`) |
| `CONFIG_FILE` | `/etc/redis-backup.env` | Config file to load |

4. Copy `generate-backup.sh` to the instance and run it
```
chmod +x generate-backup.sh
./generate-backup.sh        # prd
./generate-backup.sh qa     # other environment
```

5. Automate with cron (`crontab -e` as the `ubuntu` user)
```
0 5 * * * /home/ubuntu/generate-backup.sh prd >> /home/ubuntu/redis-backup.log 2>&1
```
The script sets its own `PATH` (including `/snap/bin`), so the snap-installed AWS CLI is found under cron.

## What the script checks ✅
- Redis is reachable and the credentials work (`PING`).
- The `BGSAVE` finishes within `BGSAVE_TIMEOUT` and ends with status `ok`.
- The copied RDB is not empty and passes `redis-check-rdb` (included in `redis-tools`).
- The upload to S3 succeeds (AWS CLI v2 validates checksums on upload).

If any step fails, the script exits with code 1 and sends an alert when `ALERT_WEBHOOK_URL` and/or `ALERT_SNS_TOPIC_ARN` are set.

## Failure alerts 🔔
- **Webhook**: create an incoming webhook in Slack, Teams or Discord and set `ALERT_WEBHOOK_URL`.
- **SNS**: create a topic, subscribe your email and set `ALERT_SNS_TOPIC_ARN`. Add this to the instance role policy:
```json
{
  "Sid": "PublishBackupAlerts",
  "Effect": "Allow",
  "Action": "sns:Publish",
  "Resource": "arn:aws:sns:us-east-1:123456789012:redis-backup-alerts"
}
```

## S3 bucket: security and retention 🪣
By default the backups are kept forever. Recommended bucket configuration:

1. Block public access and enable versioning (protects against accidental deletes/overwrites)
```
aws s3api put-public-access-block --bucket my-bucket \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket my-bucket --versioning-configuration Status=Enabled
```
Objects are encrypted at rest with SSE-S3 by default. Use SSE-KMS if you need key-level access control or auditing.

2. Lifecycle rule per environment: `lifecycle.json`
```json
{
  "Rules": [
    {
      "ID": "redis-prd-30d",
      "Filter": { "Prefix": "redis/prd/" },
      "Status": "Enabled",
      "Expiration": { "Days": 30 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 7 }
    },
    {
      "ID": "redis-qa-7d",
      "Filter": { "Prefix": "redis/qa/" },
      "Status": "Enabled",
      "Expiration": { "Days": 7 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 1 }
    }
  ]
}
```
```
aws s3api put-bucket-lifecycle-configuration --bucket my-bucket --lifecycle-configuration file://lifecycle.json
```
These commands are run once by an admin (from your machine), not by the instance role.
