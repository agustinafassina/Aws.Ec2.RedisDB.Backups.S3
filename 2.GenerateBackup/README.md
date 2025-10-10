# GenerateBackup
Scripts and instructions to create automated daily backups of RedisDB. These scripts can be scheduled via cron to run daily, generating backups that are securely uploaded and stored in an S3 bucket. The folder includes detailed guidance on setting up the cron job and managing backup files.

## Steps to generate backups 👣
1. Add AWS CLI to the instance
```
sudo snap install aws-cli --classic
```
2. Version review
```
aws --version
```
3. If the instance does not have a role attached, you must add an access key with permissions to push to S3.
```
aws configure
```
4. Modify the script before uploading it
```
vim generate-backup.sh
```
5. Add the script to the instance: generate-backup.sh
6. Have the s3 and bucketname ready
7. If we want an automated process, we can create a cronjob that runs every day and generates a script.


