# Aws.Ec2.RedisDB.Backups.S3
This repository contains several scripts to install RedisDB on EC2 instances, generate backups, and restore them, storing the backups securely in an S3 bucket. The scripts enable automated backup and restore processes, ensuring data security and facilitating recovery when needed. The process covers the entire lifecycle—from installing RedisDB on EC2, creating backups, to restoring them as required.

### Folder structure
0. Create Ec2: https://aws.amazon.com/ec2/?trk=e43d45a7-c478-45ae-b18c-db213b4c4627&sc_channel=ps&ef_id=Cj0KCQjw58PGBhCkARIsADbDilw1hdRup--OtvoGyxbBNE-rylwfAEQBdJjqXM1-TIviY_QAeZuuDbcaAttVEALw_wcB:G:s&s_kwcid=AL!4422!3!494972673535!p!!g!!aws%20ec2!12196406589!115425120645&gad_campaignid=12196406589&gbraid=0AAAAADjHtp9PI19GVrEQNyPDW6ExrSN3h&gclid=Cj0KCQjw58PGBhCkARIsADbDilw1hdRup--OtvoGyxbBNE-rylwfAEQBdJjqXM1-TIviY_QAeZuuDbcaAttVEALw_wcB
- The EC2 instance must have a minimum volume of 30
- The EC2 instance must have a minimum size of t3.micro
1. InstallRedisDB.Ec2: Scripts and steps to install RedisDB on EC2 instances.
2. GenerateBackup: Scripts and information to generate and store backups in S3.
  - Crontab in ubuntu: https://github.com/agustinafassina/Crontab.Script
    - For the QA environment, it could be every two days or once a week.
      - Every friday to 5 AM: 0 5 * * 5 /generate-backup.sh
    - For the prod environment, it should be every day.
      - Every day to 5 AM: 0 5 * * * /generate-backup.sh:
3. RestoreBackup: Scripts and procedures to restore backups from S3 to EC2.
