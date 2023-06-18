wget https://raw.githubusercontent.com/obace/gj/main/gua.sh && chmod +x gua.sh

vim /etc/crontab

00 04 * * * root /root/gua.sh

service cron restart
