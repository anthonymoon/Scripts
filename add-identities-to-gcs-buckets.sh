#!/bin/bash

# Script to add identities to Google Cloud Storage buckets
# This script adds IAM roles to specified identities on GCS buckets
# Default role is roles/storage.objectUser if not specified
# Supports comma-separated lists for buckets and members

# Function to display help message
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -b, --bucket BUCKET_NAMES    GCS bucket name(s) without gs:// prefix"
    echo "                               (comma-separated for multiple buckets)"
    echo "  -m, --member MEMBERS         Member(s) to add (e.g., user:user@example.com,"
    echo "                               serviceAccount:sa@project.iam.gserviceaccount.com)"
    echo "                               (comma-separated for multiple members)"
    echo "  -r, --role ROLE              IAM role to assign (e.g., roles/storage.objectViewer,"
    echo "                               roles/storage.objectCreator)"
    echo "                               Default: roles/storage.objectUser if not specified"
    echo "  -p, --project PROJECT_ID     Project ID (optional, uses default if not specified)"
    echo "  -f, --file FILE              Path to CSV file with bucket,member,role entries"
    echo "  -c, --condition CONDITION    IAM condition in JSON format (optional)"
    echo "  -h, --help                   Display this help message"
    echo
    echo "Examples:"
    echo "  $0 --bucket my-bucket --member user:john@example.com --role roles/storage.objectViewer"
    echo "  $0 --bucket my-bucket --member user:john@example.com"
    echo "  $0 --bucket bucket1,bucket2 --member user:john@example.com,user:jane@example.com"
    echo "  $0 --file identities.csv"
    echo
    echo "CSV file format:"
    echo "bucket_name,member,role"
    echo "my-bucket,user:john@example.com,roles/storage.objectViewer"
    echo "my-bucket,serviceAccount:sa@project.iam.gserviceaccount.com,"
    echo "^ Empty role will use the default (roles/storage.objectUser)"
    exit 1
}

# Function to validate member format
validate_member() {
    local member=$1
    
    # Check if member starts with one of the valid prefixes
    if [[ ! $member =~ ^(user:|serviceAccount:|group:|domain:|projectOwner:|projectEditor:|projectViewer:|allUsers|allAuthenticatedUsers) ]]; then
        echo "Error: Invalid member format. Member must start with user:, serviceAccount:, group:, domain:, etc."
        exit 1
    fi
}

# Function to add a member to a bucket
add_member_to_bucket() {
    local bucket=$1
    local member=$2
    local role=$3
    local project=$4
    local condition=$5
    
    # Ensure bucket name doesn't have gs:// prefix
    bucket=${bucket#gs://}
    
    # Validate member format
    validate_member "$member"
    
    # Set default role if not specified
    if [[ -z "$role" ]]; then
        role="roles/storage.objectUser"
        echo "No role specified, using default role: $role"
    fi
    
    # Build command
    local cmd="gcloud storage buckets add-iam-policy-binding gs://$bucket"
    
    # Add project if specified
    if [[ -n "$project" ]]; then
        cmd="$cmd --project=$project"
    fi
    
    # Add member and role
    cmd="$cmd --member=$member --role=$role"
    
    # Add condition if specified
    if [[ -n "$condition" ]]; then
        cmd="$cmd --condition=$condition"
    fi
    
    # Execute command
    echo "Executing: $cmd"
    if eval "$cmd"; then
        echo "Successfully added $member with role $role to bucket $bucket"
    else
        echo "Failed to add $member with role $role to bucket $bucket"
    fi
}

# Function to process a CSV file
process_csv_file() {
    local file=$1
    local project=$2
    local condition=$3
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "Error: File $file does not exist."
        exit 1
    fi
    
    # Process each line in the CSV file
    # Skip header line if it exists
    local first_line=true
    while IFS=, read -r bucket member role; do
        # Skip header line
        if [ "$first_line" = true ]; then
            first_line=false
            # If the first line doesn't look like a header (contains 'bucket' or 'member'), process it
            if [[ ! $bucket =~ bucket|member|role ]]; then
                add_member_to_bucket "$bucket" "$member" "$role" "$project" "$condition"
            fi
            continue
        fi
        
        # Skip empty lines or lines with empty bucket or member
        if [ -z "$bucket" ] || [ -z "$member" ]; then
            continue
        fi
        
        # Role can be empty, the add_member_to_bucket function will use the default
        add_member_to_bucket "$bucket" "$member" "$role" "$project" "$condition"
    done < "$file"
}

# Process command line arguments
BUCKET=""
MEMBER=""
ROLE=""
PROJECT=""
FILE=""
CONDITION=""

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--bucket)
            BUCKET="$2"
            shift 2
            ;;
        -m|--member)
            MEMBER="$2"
            shift 2
            ;;
        -r|--role)
            ROLE="$2"
            shift 2
            ;;
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        -f|--file)
            FILE="$2"
            shift 2
            ;;
        -c|--condition)
            CONDITION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Function to process a single bucket and member combination
process_bucket_member() {
    local bucket="$1"
    local member="$2"
    local role="$3"
    local project="$4"
    local condition="$5"
    
    add_member_to_bucket "$bucket" "$member" "$role" "$project" "$condition"
}

# Check if required arguments are provided
if [ -n "$FILE" ]; then
    process_csv_file "$FILE" "$PROJECT" "$CONDITION"
elif [ -n "$BUCKET" ] && [ -n "$MEMBER" ]; then
    # Handle comma-separated buckets and members
    IFS=',' read -ra BUCKETS <<< "$BUCKET"
    IFS=',' read -ra MEMBERS <<< "$MEMBER"
    
    # Create a matrix of all bucket-member combinations
    for bucket in "${BUCKETS[@]}"; do
        for member in "${MEMBERS[@]}"; do
            process_bucket_member "$bucket" "$member" "$ROLE" "$PROJECT" "$CONDITION"
        done
    done
else
    echo "Error: Missing required arguments. At minimum, specify bucket and member."
    show_help
fi