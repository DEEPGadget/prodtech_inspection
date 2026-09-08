#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <interval> <duration>"
  exit 1
fi

interval=$1
duration=$2
end_time=$((SECONDS + duration))

echo "⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣿⣿⠿⠿⠿⠤⠤⠤⠽⠿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣿⣏⣉⣉⣉⣉⣉⣉⣉⣉⣉⣙⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣓⣒⣒⣶⣿⣿⣿⣿⣿⣶⣶⣶⣾⣿⣿⣿⣿⣿⣿⣿⡟⠉⣀⣈⠙⠇⢸⠋⢉⣀⣈⠙⢿⡟⠉⣀⣀⠉⠻⡿⠋⢉⣀⣈⠙⢿⣿⣿⣿⡿⠋⢉⣀⣈⠙⢿⡿⠋⣁⣀⡉⠛⣿⠛⢉⣀⣈⠛⠀⡿⠋⣁⣀⡈⠙⣿⠟⠉⣀⣀⠉⠻⡇⢈⣉⣉⣉⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣭⣭⣭⣿⣿⣿⣭⣭⣭⣭⣭⣭⣭⣿⣿⣿⣿⣿⣿⡿⠀⣾⣿⣿⣷⠀⠀⠀⠛⠛⠛⠃⠈⠀⠛⠛⠛⠓⠀⠁⢰⣿⣿⣿⡇⠈⣿⣿⣿⡇⢰⣿⣿⣿⡇⠈⠀⢸⣿⣿⣿⡄⠀⢠⣿⣿⣿⣧⠀⠁⣼⣿⣿⣿⡆⠈⠀⠚⠛⠛⠓⠀⠁⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⡶⠶⠶⢿⣿⣿⣶⣶⣶⡶⠶⠶⠶⣿⣿⣿⣿⣿⣿⣿⡀⠻⣿⣿⠟⠀⣀⠘⢿⣿⣿⠟⢳⡀⠻⣿⣿⠟⠛⠂⠘⢿⣿⣿⠇⢠⣿⣿⣿⡇⠘⢿⣿⣿⠇⠀⡀⠸⣿⣿⡿⠁⢀⠈⢿⣿⣿⠏⢀⡄⠹⢿⣿⡿⠃⢀⠀⢻⣿⣿⡿⠛⡆⢸⣿⡿⠉⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣿⣛⣛⣛⣛⣛⣛⣛⣛⣛⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣤⣀⣀⣤⣾⣿⣦⣄⣀⣀⣴⣿⣷⣤⣀⣀⣤⣾⡇⢰⣤⣀⣠⣴⣿⣿⣿⣿⣿⣦⣄⣀⣤⡆⠀⣿⣦⣀⣀⣴⣧⣼⣷⣤⣀⣀⣴⣿⣿⣦⣄⣀⣤⡆⢸⣷⣤⣀⣀⣤⣾⣷⣄⣀⣠⣴⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣿⣿⣶⣶⠶⠶⠶⠶⠶⠶⣶⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠁⢸⣿⣿⣿⣿⣿⣿⣿⣿⣷⣀⠙⠛⠛⢁⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⡈⠙⠛⠋⢀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "⣿⣿⣿⣿⣿⣿⣿⣿⣿⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿"
echo "****************************************************************************************************"
echo "*Recording GPU, CPU information....                                                                *"

#log.txt reset
log_file="GPU_CPU_log.txt"
echo "Timestamp,NVME(C),Memory used(MB),GPU and CPU Usage Log" > "$log_file"

#check CPU model (AMD,Intel)
is_amd=$(lscpu | grep -i 'amd' | wc -l)

#Run script
while [ $SECONDS -lt $end_time ]; do
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  #Get M2 temp
  nvme_temp=$(sudo nvme smart-log /dev/nvme0 | grep "^temperature" | awk '{print $3}')

  #Get Memory used
  total_memory=$(free -m | awk '/^Mem:/ {print $2}')
  used_memory=$(free -m | awk '/^Mem:/ {print $3}')
  #Get GPU temp, Util
  gpu_info=""
  gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
  for ((i=0; i<gpu_count; i++)); do
    gpu_data=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits --id=$i)
    temp=$(echo "$gpu_data" | awk -F',' '{print $1}')
    power_draw=$(echo "$gpu_data" | awk -F',' '{print $2}')
    power_limit=$(echo "$gpu_data" | awk -F',' '{print $3}')
    gpu_info+="GPU${i}, ${temp}C,${power_draw}W /${power_limit}W "
  done

  #Get CPU temp 
  if [ "$is_amd" -gt 0 ]; then
    # AMD CPU: Tctl
    cpu_temp=$(sensors | grep 'Tctl' | awk '{printf "Tctl, %s ", $2}')
  else
    # Intel CPU: Package id 
    cpu_temp=$(sensors | grep -E 'Package id [0-9]+' | awk '{printf "%s, %s ", $1, $4}')
  fi

  #save log
  echo "$timestamp,$nvme_temp,$used_memory $gpu_info $cpu_temp" >> "$log_file"

  #sleep interval time
  sleep "$interval"
done
echo "****************************************************************************************************"
echo "****************************************************************************************************"
echo "****************************************************************************************************"
echo "****************************************************************************************************"
echo "*Recording GPU, CPU information completed. Check $log_file for results.                            *"
