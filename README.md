wget https://raw.githubusercontent.com/obace/gj/main/gua.sh && chmod +x gua.sh   &&  bash gua.sh

apt install vim -y

vim /etc/crontab

0 0 * * 0 root /root/gua.sh

service cron restart
