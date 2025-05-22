sudo lscpu -e |awk '{print $9}' |grep -c "3300.0000"
