#!/bin/bash

# Script to list all GCS buckets and sort them by number of IAM bindings
# Usage: ./list-buckets-by-iam-grants.sh [PROJECT_ID]

# Set default project or use provided argument
PROJECT_ID=${1:-$(gcloud config get-value project)}
if [ -z "$PROJECT_ID" ]; then
  echo "No project ID specified or found. Please provide a project ID as an argument or set a default project."
  exit 1
fi

echo "Listing buckets in project: $PROJECT_ID"
echo "------------------------------------"
echo "Bucket Name | IAM Bindings Count"
echo "------------------------------------"

# Get all buckets
BUCKETS=$(gcloud storage ls --project=$PROJECT_ID 2>/dev/null | grep "gs://" | sed 's/gs:\/\///' | sed 's/\///')

# Check if any buckets exist
if [ -z "$BUCKETS" ]; then
  echo "No buckets found in project $PROJECT_ID"
  exit 0
fi

# Temporary file to store results
TEMP_FILE=$(mktemp)

# Process each bucket
for BUCKET in $BUCKETS; do
  # Get IAM policy for bucket
  POLICY=$(gcloud storage buckets get-iam-policy gs://$BUCKET --format=json 2>/dev/null)
  
  # Count bindings if policy exists
  if [ $? -eq 0 ] && [ ! -z "$POLICY" ]; then
    # Count the number of bindings
    COUNT=$(echo $POLICY | jq '.bindings | length')
    
    # Count members in each binding and sum them
    TOTAL_MEMBERS=$(echo $POLICY | jq '[.bindings[].members | length] | add')
    
    # If jq returned null for total members, set to 0
    if [[ "$TOTAL_MEMBERS" == "null" ]]; then
      TOTAL_MEMBERS=0
    fi
    
    # Store result in format suitable for sorting
    echo "$BUCKET $TOTAL_MEMBERS" >> $TEMP_FILE
  else
    # Bucket has no IAM policy or error occurred
    echo "$BUCKET 0" >> $TEMP_FILE
  fi
done

# Sort by number of IAM bindings (highest first) and format output
sort -k2 -nr $TEMP_FILE | while read BUCKET COUNT; do
  printf "%-40s | %s\n" "$BUCKET" "$COUNT"
done

# Clean up
rm $TEMP_FILE

echo "------------------------------------"
echo "Note: The count represents the total number of members across all role bindings."