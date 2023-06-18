wget https://raw.githubusercontent.com/obace/gj/main/gua.sh && chmod +x gua.sh

bash gua.sh

apt install vim -y

vim /etc/crontab

00 04 * * * root /root/gua.sh

service cron restart
