#!/bin/bash
# Variables
# Step 1: Stop RedisDB service (optional, to prevent conflicts)
echo "Stopping RedisDB service..."
sudo systemctl stop redis

aws s3 cp s3://backup /backups/01032025200001 --recursive

cp /backups/01032025200001redis-backup-2025-10-06.rdb /var/lib/redis/dump.rdb

# Step 4: Start RedisDB service
echo "Starting RedisDB service..."
sudo systemctl start redis

echo "Restoration complete."