#!/bin/bash

# Your GitLab server URL
GITLAB_SERVER="https://gitlab.dev.gunpowder.tech"

# Your GitLab access token for authentication
ACCESS_TOKEN="UkFfwz9on_vT_y7g6_1L"

# Create an array of repository paths from the static list
REPO_PATHS=(
  "gunpowder/gunpowder-automate"
  "gunpowder/gunpowder-node"
  "gunpowder/gunpowder-app"
  "gunpowder/auth-vm"
  "gunpowder/terraform-automate"
  "gunpowder/gunpowder-management-control"
  "gunpowder/gunpowder-management-control-node"
  "gunpowder/gunpowder-camproxy"
  "gunpowder/labels-sync-api"
  "gunpowder/gp-usage-api"
  "gunpowder/image-bakery"
  "gunpowder/poc_grafana_2"
  "gunpowder/poc_grafana"
  "gunpowder/budget-api"
  "gunpowder/terraform-image"
  "gunpowder/gunpowder-api-testing"
  "gunpowder/email-dispatcher-api"
  "gunpowder/uptime_loader_job"
  "gunpowder/cloud-monitoring"
  "gunpowder/iap-https-accessors-api"
)

echo "Found ${#REPO_PATHS[@]} repositories to clone"
echo "-------------------------------------------------"

# Confirm before cloning
read -p "Do you want to clone all ${#REPO_PATHS[@]} repositories to the current directory? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Clone repositories
echo "Cloning repositories..."
echo "-------------------------------------------------"

SUCCESS_COUNT=0
FAILED_COUNT=0

for REPO_PATH in "${REPO_PATHS[@]}"; do
    # Extract repo name for the directory name
    REPO_NAME=$(basename "$REPO_PATH")

    # Create clone URL with token embedded for authentication
    CLONE_URL="https://oauth2:${ACCESS_TOKEN}@${GITLAB_SERVER#https://}/${REPO_PATH}.git"

    echo "Cloning: $REPO_NAME ($GITLAB_SERVER/$REPO_PATH)"

    # If directory already exists, show warning and ask about overwriting
    if [ -d "$REPO_NAME" ]; then
        read -p "  Directory '$REPO_NAME' already exists. Skip, Delete and clone, or Pull updates? (s/d/p): " ACTION
        case "$ACTION" in
            [Dd]* )
                echo "  Removing existing directory..."
                rm -rf "$REPO_NAME"
                ;;
            [Pp]* )
                echo "  Pulling latest updates..."
                (cd "$REPO_NAME" && git pull)
                if [ $? -eq 0 ]; then
                    echo "  ✅ Successfully updated $REPO_NAME"
                    SUCCESS_COUNT=$((SUCCESS_COUNT+1))
                else
                    echo "  ❌ Failed to update $REPO_NAME"
                    FAILED_COUNT=$((FAILED_COUNT+1))
                fi
                continue
                ;;
            * )
                echo "  Skipping $REPO_NAME"
                FAILED_COUNT=$((FAILED_COUNT+1))
                continue
                ;;
        esac
    fi

    # Clone the repository
    if git clone "$CLONE_URL" "$REPO_NAME"; then
        echo "  ✅ Successfully cloned $REPO_NAME"
        SUCCESS_COUNT=$((SUCCESS_COUNT+1))
    else
        echo "  ❌ Failed to clone $REPO_NAME"
        FAILED_COUNT=$((FAILED_COUNT+1))
    fi
done

echo "-------------------------------------------------"
echo "Cloning completed:"
echo "  ✅ Successfully cloned/updated: $SUCCESS_COUNT"
echo "  ❌ Failed/Skipped: $FAILED_COUNT"
echo "-------------------------------------------------"
echo "Script completed."
