# InstallRedisDB.Ec2
Scripts and step-by-step instructions to install RedisDB on EC2 instances. These scripts facilitate quick and reliable deployment of RedisDB servers, ensuring consistent setup across environments.

<img src="images/aws.png" alt="Aws" width="800" height="450">

### Requirenment 📝
- Aws account
- Import the public key used by the package management system

### Steps to create the instance 👣
- From Aws / EC2 / With the region selected.
- Create new instance -> Launch instances.
- Create new instance
- Select Quick Start -> Ubuntu and Ubuntu Server 24.04
- Ubuntu 24.04–8gb
<img src="images/ubuntu-detail.png" alt="Aws" width="800" height="450">

### Steps to install Redis 👣
1. Connect to the instance and redis install
```
sudo apt install redis-server
```

2. Redis validate
```
redis-cli -h
redis-cli --version
```

3. Change in the redis.conf
```
# Open the file with vim and write
sudo vim /etc/redis/redis.conf

# In #### GENERAL #### modify 'supervided no' by:
supervised systemd

# In #### NETWORK ####
bind 127.0.0.1 ::1 to bind 0.0.0.0

```

4. Add a user (cuando arranca el servicio) /etc/redis/redis.conf
```
# In #### SECURITY #### add:
user newuser on >withPassword ~* +@all
```

5. Redis restart
```
sudo systemctl restart redis
```

8. Add your ip in the security group that has the associated instance.
9. If you already uploaded the IP, you can test the connection to the instance.


#### How to test if the instance and Redis are working correctly? ⁉️
1. Download redis insight to connect to the database.
2. With your Public IPv4 DNS
