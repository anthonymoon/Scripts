#!/bin/bash
# GCP CIS Compliance - Log Metric Filters and Alerts Setup
# This script creates log metric filters and alerting policies for security-critical operations
# as recommended by the CIS Google Cloud Platform Foundation Benchmark

set -e

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    handle_error "gcloud CLI is not installed. Please install it first."
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    handle_error "jq is not installed. Please install it first."
fi

# Check if user is authenticated
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
    handle_error "Not authenticated with gcloud. Please run 'gcloud auth login' first."
fi

# Get the current project ID
PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ]; then
    handle_error "No project selected. Please run 'gcloud config set project YOUR_PROJECT_ID' first."
fi

echo "Setting up log metric filters and alerts for project: $PROJECT_ID"

# Function to create log metric filter
create_metric_filter() {
    local metric_name=$1
    local filter=$2
    local description=$3

    echo "Creating log metric filter: $metric_name"
    
    # Check if the metric already exists
    if gcloud logging metrics list --filter="name:$metric_name" --format="value(name)" | grep -q "$metric_name"; then
        echo "Log metric filter '$metric_name' already exists. Updating..."
        if ! gcloud logging metrics update "$metric_name" \
            --description="$description" \
            --log-filter="$filter"; then
            handle_error "Failed to update log metric filter '$metric_name'"
        fi
    else
        echo "Creating new log metric filter '$metric_name'..."
        if ! gcloud logging metrics create "$metric_name" \
            --description="$description" \
            --log-filter="$filter"; then
            handle_error "Failed to create log metric filter '$metric_name'"
        fi
    fi
}

# Function to create alerting policy
create_alert_policy() {
    local metric_name=$1
    local policy_name=$2
    local description=$3
    local notification_channels=$4
    
    echo "Creating alert policy: $policy_name"
    
    # Verify the metric exists
    if ! gcloud logging metrics list --filter="name:$metric_name" --format="value(name)" | grep -q "$metric_name"; then
        handle_error "Metric '$metric_name' does not exist. Cannot create alert policy."
    fi
    
    # Check if alert policy with the same display name already exists
    if gcloud alpha monitoring policies list --format="json" | jq -r ".[] | select(.displayName == \"$policy_name\") | .name" | grep -q .; then
        echo "Alert policy '$policy_name' already exists. Skipping..."
        return
    fi
    
    # Create JSON file for the alert policy
    cat > /tmp/alert_policy.json << EOF
{
  "displayName": "$policy_name",
  "documentation": {
    "content": "$description",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "$policy_name condition",
      "conditionThreshold": {
        "filter": "resource.type=\"global\" AND metric.type=\"logging.googleapis.com/user/$metric_name\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "604800s"
  },
  "combiner": "OR"
}
EOF

    # Add notification channels if provided
    if [ ! -z "$notification_channels" ]; then
        # Create temporary file for the modified JSON
        TMP_FILE=$(mktemp)
        # Add notification channels to the JSON
        if ! jq ".notificationChannels = $notification_channels" /tmp/alert_policy.json > "$TMP_FILE"; then
            handle_error "Failed to add notification channels to alert policy JSON"
        fi
        mv "$TMP_FILE" /tmp/alert_policy.json
    fi

    # Create the alert policy
    if ! gcloud alpha monitoring policies create --policy-from-file=/tmp/alert_policy.json; then
        handle_error "Failed to create alert policy '$policy_name'"
    fi
    
    # Clean up
    rm -f /tmp/alert_policy.json
}

# Function to create email notification channel
create_email_channel() {
    local email="alerts@gunpowder.tech"
    local channel_name="CIS-Alerts"
    
    echo "Creating notification channel for: $email"
    
    # Check if channel already exists
    if gcloud alpha monitoring channels list --format="json" | jq -r ".[] | select(.displayName == \"$channel_name\") | .name" | grep -q .; then
        echo "Notification channel '$channel_name' already exists. Skipping..."
        return
    fi
    
    # Create JSON file for the notification channel
    cat > /tmp/notification_channel.json << EOF
{
  "displayName": "$channel_name",
  "type": "email",
  "labels": {
    "email_address": "$email"
  }
}
EOF
    
    # Create the notification channel
    if ! gcloud alpha monitoring channels create --channel-content-from-file=/tmp/notification_channel.json; then
        handle_error "Failed to create notification channel for '$email'"
    fi
    
    # Clean up
    rm -f /tmp/notification_channel.json
}

echo "=== Setting up notification channel ==="

# Create notification channel
create_email_channel

# Get the notification channel
NOTIFICATION_CHANNEL=$(gcloud alpha monitoring channels list --format="json" | jq -r ".[] | select(.displayName == \"CIS-Alerts\") | .name")
if [ -z "$NOTIFICATION_CHANNEL" ]; then
    handle_error "Failed to get notification channel"
fi

# Format the notification channel as a JSON array
NOTIFICATION_CHANNELS="[\"$NOTIFICATION_CHANNEL\"]"

# 1. Audit Configuration Changes
echo "=== Setting up Audit Configuration Changes monitoring ==="
FILTER_AUDIT_CONFIG='protoPayload.methodName="SetIamPolicy" AND protoPayload.serviceData.policyDelta.auditConfigDeltas:*'
create_metric_filter "audit_config_changes" "$FILTER_AUDIT_CONFIG" "CIS Metric for Audit Configuration Changes"
create_alert_policy "audit_config_changes" "CIS Alert - Audit Configuration Changes" "Alert for audit configuration changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 2. Cloud Storage IAM Permission Changes
echo "=== Setting up Cloud Storage IAM Permission Changes monitoring ==="
FILTER_STORAGE_IAM='resource.type="gcs_bucket" AND protoPayload.methodName="storage.setIamPermissions"'
create_metric_filter "storage_iam_changes" "$FILTER_STORAGE_IAM" "CIS Metric for Cloud Storage IAM Permission Changes"
create_alert_policy "storage_iam_changes" "CIS Alert - Cloud Storage IAM Changes" "Alert for Cloud Storage IAM permission changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 3. Custom Role Changes
echo "=== Setting up Custom Role Changes monitoring ==="
FILTER_CUSTOM_ROLE='resource.type="iam_role" AND (protoPayload.methodName="google.iam.admin.v1.CreateRole" OR protoPayload.methodName="google.iam.admin.v1.DeleteRole" OR protoPayload.methodName="google.iam.admin.v1.UpdateRole")'
create_metric_filter "custom_role_changes" "$FILTER_CUSTOM_ROLE" "CIS Metric for Custom Role Changes"
create_alert_policy "custom_role_changes" "CIS Alert - Custom Role Changes" "Alert for custom role changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 4. VPC Network Firewall Rule Changes
echo "=== Setting up VPC Network Firewall Rule Changes monitoring ==="
FILTER_FIREWALL_CHANGES='resource.type="gce_firewall_rule" AND (protoPayload.methodName:"compute.firewalls.patch" OR protoPayload.methodName:"compute.firewalls.insert" OR protoPayload.methodName:"compute.firewalls.delete")'
create_metric_filter "firewall_rule_changes" "$FILTER_FIREWALL_CHANGES" "CIS Metric for VPC Network Firewall Rule Changes"
create_alert_policy "firewall_rule_changes" "CIS Alert - Firewall Rule Changes" "Alert for VPC network firewall rule changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 5. VPC Network Changes
echo "=== Setting up VPC Network Changes monitoring ==="
FILTER_NETWORK_CHANGES='resource.type=gce_network AND (protoPayload.methodName:"compute.networks.insert" OR protoPayload.methodName:"compute.networks.patch" OR protoPayload.methodName:"compute.networks.delete" OR protoPayload.methodName:"compute.networks.removePeering" OR protoPayload.methodName:"compute.networks.addPeering")'
create_metric_filter "network_changes" "$FILTER_NETWORK_CHANGES" "CIS Metric for VPC Network Changes"
create_alert_policy "network_changes" "CIS Alert - VPC Network Changes" "Alert for VPC network changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 6. VPC Network Route Changes
echo "=== Setting up VPC Network Route Changes monitoring ==="
FILTER_ROUTE_CHANGES='resource.type="gce_route" AND (protoPayload.methodName:"compute.routes.delete" OR protoPayload.methodName:"compute.routes.insert")'
create_metric_filter "route_changes" "$FILTER_ROUTE_CHANGES" "CIS Metric for VPC Network Route Changes"
create_alert_policy "route_changes" "CIS Alert - VPC Network Route Changes" "Alert for VPC network route changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 7. SQL Instance Configuration Changes
echo "=== Setting up SQL Instance Configuration Changes monitoring ==="
FILTER_SQL_CHANGES='protoPayload.methodName:"cloudsql.instances.update" OR protoPayload.methodName:"cloudsql.instances.create" OR protoPayload.methodName:"cloudsql.instances.delete"'
create_metric_filter "sql_instance_changes" "$FILTER_SQL_CHANGES" "CIS Metric for SQL Instance Configuration Changes"
create_alert_policy "sql_instance_changes" "CIS Alert - SQL Instance Changes" "Alert for SQL instance configuration changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

# 8. Project Ownership Assignments/Changes
echo "=== Setting up Project Ownership Assignments/Changes monitoring ==="
FILTER_PROJECT_OWNERSHIP='resource.type="project" AND protoPayload.methodName="SetIamPolicy" AND protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/owner"'
create_metric_filter "project_ownership_changes" "$FILTER_PROJECT_OWNERSHIP" "CIS Metric for Project Ownership Assignments/Changes"
create_alert_policy "project_ownership_changes" "CIS Alert - Project Ownership Changes" "Alert for project ownership assignments/changes as per CIS recommendations" "$NOTIFICATION_CHANNELS"

echo "=== Summary ==="
echo "Created the following log metric filters:"
if ! gcloud logging metrics list --format="table(name,description,filter)" | grep "CIS Metric"; then
    echo "No log metric filters found or error occurred while listing them."
fi

echo "Created the following alert policies:"
if ! gcloud alpha monitoring policies list --format="table(displayName)" | grep "CIS Alert"; then
    echo "No alert policies found or error occurred while listing them."
fi

echo "=== Script completed successfully ==="
echo "Note: You may need to verify the filters and alerts in the Google Cloud Console to ensure they meet your specific requirements."
echo "All alerts will be sent to the notification channels created for the users."