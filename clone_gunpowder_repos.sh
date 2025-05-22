#!/bin/bash

# Script to clone all repositories from gunpowder-tech using GitHub CLI
# Usage: ./clone_gunpowder_repos.sh

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
  echo "Error: GitHub CLI (gh) is not installed or not in PATH."
  echo "Please install it from: https://cli.github.com/"
  exit 1
fi

# Verify gh is authenticated
if ! gh auth status &> /dev/null; then
  echo "Error: You need to authenticate with GitHub CLI first."
  echo "Run 'gh auth login' to authenticate."
  exit 1
fi

# Create a directory for all repositories
MAIN_DIR="~/Projects/gp"
mkdir -p "$MAIN_DIR"
cd "$MAIN_DIR" || exit

# List of repositories to clone
REPOS=(
  "gunpowder-packer"
  "scripts-woz"
  "scripts-afterpartyvfx-production"
  "sofi-scripts"
  "gunpowder-tools"
  "gunpowder-terraform"
  "gunpowder-resilio"
  "scripts-livgolf"
  "scripts-noise"
  "msg-edit-ansible"
  "deadline-web"
  "scripts-refik"
  "scripts-exp-fte"
  "gunpowder-master-ansible"
  "gunpowder-woz-poc-ansible"
  "afterpartyvfx-terraform"
  "scripts-afterparty"
  "sonic3-repo"
  "scripts-mayda"
  "scripts-sofi"
  "gp-log-website"
  "scripts-prodigious"
  "scripts-publicis"
  "scripts-vizco"
  "ravel-terraform"
  "woz-terraform"
  "gunpowder-test"
  "scripts-sesame"
  "slack-vertex"
  "scripts-floating-rock"
  "scripts-pilot"
  "awsReboot"
  "gunpowder-floating-rock-ansible"
  "superbloom-terraform"
  "sarofsky-terraform"
  "ignite-terraform"
  "deadline-local-install"
  "gunpowder-googledevstudios-ansible"
  "harbor-terraform"
  "bealine-aws"
  "bealine"
  "dd-startup"
  "dd-knfsd"
  "houdini-license-prometheus"
  "deadline-gcp-render-cost-calculator"
  "faceswap-to-nuke"
  "d2-knfsd"
  "teradici-on-off"
  "stageglass-terraform"
  "nfs_mount"
  "gunpowder-knfsd"
  "pcoip-docker"
  "ignite-project-create"
  "auto-logout-systemd"
  "ignite-scripts"
  "gunpowder-nightshift-ansible"
  "gunpowder-cbs-ansible"
  "ndi-test-patterns-python"
  "ndi-access-manager-python"
  "ndi-screencapture-python"
  "ndi-monitor-python"
  "pcoip-login-page"
  "gunpowder-sofi-ansible"
  "aws-shutdown"
  "ansible-collections-test"
  "start-loop"
  "setPoolsGroupsLimits"
  "maya_virus"
  "gcp-shutdown"
  "houdini_license_usage"
  "pcoip-tweak"
  "ndi-to-rtmp-python"
  "pcoip-agent-settings-ui-minimal"
  "msrsync"
  "slate_creator_v2"
  "ndi-router-python"
  "mac_permissions_corrector"
  "ffmpeg-with-ndi"
  "pcoip-agent-settings-ui"
  "outpost-vfx"
  "pcoip-os"
)

# Total number of repositories to clone
TOTAL=${#REPOS[@]}
COUNTER=0
FAILED=()

echo "Starting to clone $TOTAL repositories from gunpowder-tech using GitHub CLI..."
echo "============================================================"

for REPO in "${REPOS[@]}"; do
  COUNTER=$((COUNTER+1))
  echo "[$COUNTER/$TOTAL] Cloning $REPO..."

  # Clone the repository using GitHub CLI
  if gh repo clone "gunpowder-tech/$REPO" "$REPO"; then
    echo "✅ Successfully cloned $REPO"
  else
    echo "❌ Failed to clone $REPO"
    FAILED+=("$REPO")
  fi

  echo "------------------------------------------------------------"
done

# Summary
echo "============================================================"
echo "Cloning completed!"
echo "Successfully cloned: $((COUNTER-${#FAILED[@]}))/$TOTAL repositories"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed to clone the following repositories:"
  for REPO in "${FAILED[@]}"; do
    echo "- $REPO"
  done
  echo "Please check your GitHub CLI authentication and access permissions."
fi

echo "All repositories have been cloned to: $(pwd)"
