apt update -y  &&  apt install -y curl   &&    apt install -y socat  &&    apt install -y vim

wget https://raw.githubusercontent.com/obace/gj/main/gua.sh && chmod +x gua.sh   &&  bash gua.sh

(sudo crontab -l ; echo "0 7 * * 1 sleep \$((RANDOM \% 3600)) && /bin/bash /root/gua.sh") | sudo crontab -
