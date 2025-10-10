# RestoreBackup
Scripts and procedures to restore RedisDB backups from S3 to EC2 instances. Includes guidance on selecting the correct backup files and restoring the database to a desired state.

## Steps to restore a database 👣
1. Stop the RedisDB service (optional, to prevent conflicts during restore):
```
sudo systemctl stop redis
```

2. Create a directory for the backup:
```
mkdir -p backups/01032025200001
```

3. Download the backup from S3:
```
aws s3 cp s3://backup /backups/01032025200001 --recursive
```

4. Stop RedisDB before restoring (if not already stopped), to ensure a clean restore process:
```
sudo systemctl stop redis
```

5. Restore the database
```
cp /backups/01032025200001/redis-backup-2025-10-06.rdb /var/lib/redis/dump.rdb
```

6. Verify the restored databases and data
7. Restart the RedisDB service:
```
sudo systemctl start redis
```


