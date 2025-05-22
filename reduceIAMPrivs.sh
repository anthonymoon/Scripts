#!/bin/bash

# Script to run IAM recommender for service accounts and apply removal recommendations
# This script identifies and applies recommendations to reduce excessive permissions

set -e  # Exit immediately if a command exits with a non-zero status

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ID="prod-liv-gunpowder"
RECOMMENDER_ID="google.iam.policy.Recommender"
RECOMMENDATION_TYPE="REMOVE_ROLE"
DRY_RUN=true  # Set to false to actually apply the recommendations

# Function to print information
print_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to print success
print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to print warning
print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print error
print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if gcloud is installed
check_gcloud() {
  if ! command -v gcloud &> /dev/null; then
    print_error "gcloud CLI is not installed. Please install it and try again."
    exit 1
  fi
}

# Function to check if user is authenticated
check_auth() {
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
    print_error "Not authenticated with gcloud. Please run 'gcloud auth login' and try again."
    exit 1
  fi
}

# Function to check if the project exists and is accessible
check_project() {
  if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
    print_error "Project $PROJECT_ID does not exist or you don't have access to it."
    exit 1
  fi
}

# Function to enable required APIs if they're not already enabled
enable_apis() {
  print_info "Checking and enabling required APIs..."

  # Check and enable recommender API
  if ! gcloud services list --project="$PROJECT_ID" --filter="name:recommender.googleapis.com" | grep -q "recommender.googleapis.com"; then
    print_info "Enabling Recommender API..."
    gcloud services enable recommender.googleapis.com --project="$PROJECT_ID"
  fi
}

# Function to get all service accounts in the project
get_service_accounts() {
  print_info "Getting service accounts for project $PROJECT_ID..."
  gcloud iam service-accounts list --project="$PROJECT_ID" --format="value(email)" | grep -v "^$"
}

# Function to get IAM recommendations for a service account
get_recommendations() {
  local service_account=$1
  print_info "Getting IAM recommendations for $service_account..."

  # The service account needs to be properly formatted for the recommender API
  local formatted_sa="//iam.googleapis.com/projects/$PROJECT_ID/serviceAccounts/$service_account"

  gcloud recommender recommendations list \
    --project="$PROJECT_ID" \
    --location="global" \
    --recommender="$RECOMMENDER_ID" \
    --filter="targetResources:$formatted_sa AND recommenderSubtype:$RECOMMENDATION_TYPE" \
    --format="value(name)" 2>/dev/null || true
}

# Function to apply a recommendation
apply_recommendation() {
  local recommendation_name=$1

  # Verify this is a valid recommendation ID before proceeding
  if [[ ! "$recommendation_name" =~ ^projects/.*/locations/.*/recommenders/.*/recommendations/.* ]]; then
    print_warning "Invalid recommendation format: $recommendation_name - skipping"
    return 1
  fi

  print_info "Applying recommendation: $recommendation_name"

  if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN MODE: Would apply recommendation $recommendation_name"
    gcloud recommender recommendations describe "$recommendation_name" \
      --project="$PROJECT_ID" \
      --location="global" \
      --recommender="$RECOMMENDER_ID" \
      --format=json 2>/dev/null || print_error "Could not retrieve recommendation details"
  else
    gcloud recommender recommendations apply "$recommendation_name" \
      --project="$PROJECT_ID" \
      --location="global" \
      --recommender="$RECOMMENDER_ID" \
      --etag="$(gcloud recommender recommendations describe "$recommendation_name" \
                 --project="$PROJECT_ID" \
                 --location="global" \
                 --recommender="$RECOMMENDER_ID" \
                 --format="value(etag)")"

    if [ $? -eq 0 ]; then
      print_success "Successfully applied recommendation: $recommendation_name"
    else
      print_error "Failed to apply recommendation: $recommendation_name"
    fi
  fi
}

# Main function
main() {
  local total_recommendations=0
  local applied_recommendations=0

  # Initial checks
  check_gcloud
  check_auth
  check_project
  enable_apis

  print_info "Starting IAM privilege reduction for service accounts in project $PROJECT_ID"
  if [ "$DRY_RUN" = true ]; then
    print_warning "Running in DRY RUN mode. Recommendations will be displayed but not applied."
    print_warning "To apply recommendations, set DRY_RUN=false in the script."
  fi

  # Get all service accounts and store in an array
  mapfile -t service_accounts < <(get_service_accounts)

  # Process each service account
  for sa in "${service_accounts[@]}"; do
    # Skip empty lines
    [ -z "$sa" ] && continue

    print_info "Processing service account: $sa"

    # Get recommendations for this service account
    mapfile -t recommendations < <(get_recommendations "$sa")

    # Process recommendations
    for rec in "${recommendations[@]}"; do
      # Skip empty lines
      [ -z "$rec" ] && continue

      total_recommendations=$((total_recommendations + 1))
      if apply_recommendation "$rec"; then
        applied_recommendations=$((applied_recommendations + 1))
      fi
    done
  done

  # Summary
  print_info "IAM privilege reduction completed"
  print_info "Total recommendations found: $total_recommendations"
  if [ "$DRY_RUN" = true ]; then
    print_warning "Recommendations were shown but not applied (DRY RUN mode)"
  else
    print_success "Applied recommendations: $applied_recommendations"
  fi
}

# Execute main function
main
