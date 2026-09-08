#!/bin/bash

# Input and output file paths
input_file="GPU_CPU_log.txt"
output_file="output.csv"

# Initialize output file with a basic header
echo -n "Timestamp,NVME(C),Memory used(MB)" > "$output_file"

# Detect the number of GPUs from the first data line of the log itself, so the
# header always matches the data (falls back to nvidia-smi for an empty log).
# NOTE: GPU[0-9]+ — a single [0-9] silently drops GPU10 and above.
first_data=$(sed -n '2p' "$input_file")
gpu_count=$(echo "$first_data" | grep -oE "GPU[0-9]+," | wc -l)
if [ "$gpu_count" -eq 0 ]; then
  gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
fi

for ((i=0; i<gpu_count; i++)); do
    echo -n ",GPU${i}_Temp,GPU${i}_Util" >> "$output_file"
done

# Add CPU Package headers
echo ",CPU Package1 Temp(C),CPU Package2 Temp(C)" >> "$output_file"


cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}')

# Process each line in the input file
tail -n +2 "$input_file" | while IFS= read -r line; do
  # Extract basic fields
  timestamp=$(echo "$line" | awk -F',' '{print $1}')
  nvme=$(echo "$line" | awk -F',' '{print $2}')
  memory=$(echo "$line" | awk -F',' '{print $3}' | awk '{print $1}')

  # Start building the line with timestamp, NVME, and memory
  output_line="$timestamp,$nvme,$memory"

  # Extract GPU information dynamically
  gpu_data=$(echo "$line" | grep -oE "GPU[0-9]+, [0-9]*C, [0-9.]*W / [0-9.]*W")
  while read -r gpu_info; do
    gpu_temp=$(echo "$gpu_info" | awk '{print $2}' | sed 's/C,//')
    gpu_power=$(echo "$gpu_info" | awk '{print $3$4$5}')  # Remove spaces around power values
    output_line+=",${gpu_temp},${gpu_power}"
  done <<< "$gpu_data"

  # Add CPU temperatures based on vendor
  if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    # Intel CPU: use Package temperatures
    cpu_pkg1=$(echo "$line" | grep -o "Package, +[0-9.]*°C" | awk 'NR==1 {print $2}' | sed 's/+//;s/°C//')
    cpu_pkg2=$(echo "$line" | grep -o "Package, +[0-9.]*°C" | awk 'NR==2 {print $2}' | sed 's/+//;s/°C//')
    output_line+=",${cpu_pkg1},${cpu_pkg2}"
  elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    # AMD CPU: use Tctl temperatures
    cpu_tctl1=$(echo "$line" | grep -o "Tctl, +[0-9.]*°C" | awk 'NR==1 {print $2}' | sed 's/+//;s/°C//')
    cpu_tctl2=$(echo "$line" | grep -o "Tctl, +[0-9.]*°C" | awk 'NR==2 {print $2}' | sed 's/+//;s/°C//')
    output_line+=",${cpu_tctl1},${cpu_tctl2}"
  else
    # Unknown vendor: keep the column count aligned with the header
    output_line+=",,"
  fi

  # Append to output file
  echo "$output_line" >> "$output_file"
done

echo "Data extraction complete. Check output.csv for results."

