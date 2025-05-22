#!/bin/zsh

# Get all instances with names matching the pattern 'ws-*'
instances=($(gcloud compute instances list --filter="name~^ws-.*" --format="value(name,zone)"))

# Loop through each instance (process two elements at a time)
for ((i=1; i<=${#instances}; i+=2)); do
  instance_name=${instances[i]}
  instance_zone=${instances[i+1]}
  
  echo "Modifying instance: $instance_name in zone: $instance_zone"
  
  # Disable connecting to serial ports
  gcloud compute instances add-metadata "$instance_name" --zone="$instance_zone" \
    --metadata=serial-port-enable=FALSE
  
  # Turn on secure boot and disable integrity monitoring
  gcloud compute instances update "$instance_name" --zone="$instance_zone" \
    --shielded-secure-boot \
    --no-shielded-integrity-monitoring
  
  # Disable vTPM
  gcloud compute instances update "$instance_name" --zone="$instance_zone" \
    --no-shielded-vtpm
  
  # Block project-wide SSH keys
  gcloud compute instances add-metadata "$instance_name" --zone="$instance_zone" \
    --metadata=block-project-ssh-keys=TRUE
  
  # Delete any manually added SSH keys
  gcloud compute instances remove-metadata "$instance_name" --zone="$instance_zone" \
    --keys=ssh-keys
  
  # Set access scopes to compute engine default service account with default access
  gcloud compute instances set-service-account "$instance_name" --zone="$instance_zone" \
    --scopes=default
  
  # Enable 'Customer Managed Encryption Key (CMEK) revocation policy'
  # This typically requires a CMEK to be already configured
  # The flag --disk-kms-key would be needed during instance creation or disk attachment
  # For existing instances with attached disks, this requires more complex handling
  # If this is needed, consider consulting Google Cloud documentation for specific details
  
  # Add metadata "enable-oslogin: TRUE"
  gcloud compute instances add-metadata "$instance_name" --zone="$instance_zone" \
    --metadata=enable-oslogin=TRUE

  echo "Successfully modified instance: $instance_name"
  echo "----------------------------------------"
done

echo "All matching instances have been modified."g