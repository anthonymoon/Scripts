#!/bin/bash

input_file="paste.txt"
output_file="expanded_files.txt"
snapshot_base="/mnt/storage/.snapshots/@GMT-2025.05.11-00.00.00/WOZ/Production/vendors/SPHERE/from_Sphere/PlatesToWkea-2"

> "$output_file"  # Clear output file

while IFS= read -r line; do
  # Extract the base part of the filename and the range
  base=$(echo "$line" | sed -E 's/(.*)\.[0-9]+ to [0-9]+\.exr/\1/')
  start=$(echo "$line" | sed -E 's/.*\.([0-9]+) to [0-9]+\.exr/\1/')
  end=$(echo "$line" | sed -E 's/.*\.[0-9]+ to ([0-9]+)\.exr/\1/')
  
  # Extract the subdirectory name from the 4th underscore-separated field
  subdir=$(echo "$base" | cut -d'_' -f4)
  
  # Generate individual filenames and write to output file with zero padding to 8 digits
  for ((i=start; i<=end; i++)); do
    # Format the number with leading zeros to ensure 8 digits
    padded_num=$(printf "%08d" $i)
    full_path="${snapshot_base}/${subdir}/v001/main_exr/18024x17592/${base}.${padded_num}.exr"
    echo "$full_path" >> "$output_file"
  done
done < "$input_file"

echo "Expanded file list saved to $output_file"