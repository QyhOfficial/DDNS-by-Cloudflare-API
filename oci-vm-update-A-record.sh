#!/bin/bash

# Log file path
LOG_FILE="/var/log/cloudflare-dns-update.log"

# Remove old log file and create a new one
rm -f "$LOG_FILE"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
echo "$(date): Script started, preparing to update Cloudflare DNS record." >> "$LOG_FILE"

# Check dependencies (curl and jq)
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo "$(date): Error: curl or jq not found. Please install them first." >> "$LOG_FILE"
    exit 1
fi

# --- Cloudflare Configuration ---
# Cloudflare API token (read from environment variable)
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:?Error: CLOUDFLARE_API_TOKEN environment variable is not set}"
# Domain name (read from environment variable)
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:?Error: CLOUDFLARE_ZONE_NAME environment variable is not set}"
# A record name to update (e.g. www, blog, @)
CLOUDFLARE_RECORD_NAME="oci"

# Look up Cloudflare Zone ID
echo "$(date): Looking up Cloudflare Zone ID..." >> "$LOG_FILE"
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE_NAME}" \
     -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$ZONE_ID" ]; then
    echo "$(date): Error: Failed to find Cloudflare Zone ID. Please check the domain name." >> "$LOG_FILE"
    exit 1
fi
echo "$(date): Found Zone ID: ${ZONE_ID}" >> "$LOG_FILE"

# Get the VM's current public IP address via OCI Instance Metadata Service v2 (IMDS v2)
echo "$(date): Fetching current public IP address from OCI IMDS v2..." >> "$LOG_FILE"
VNIC_INFO=$(curl -s -H "Authorization: Bearer Oracle" \
     "http://169.254.169.254/opc/v2/vnics/")
CURRENT_IP=$(echo "$VNIC_INFO" | jq -r '.[0].publicIp')

if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" == "null" ]; then
    echo "$(date): Error: Failed to retrieve public IP from OCI IMDS. Is this running on an OCI instance with a public IP?" >> "$LOG_FILE"
    exit 1
fi
echo "$(date): Current IP address: ${CURRENT_IP}" >> "$LOG_FILE"

# Look up DNS record ID
echo "$(date): Looking up DNS record ID..." >> "$LOG_FILE"
RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${CLOUDFLARE_RECORD_NAME}.${CLOUDFLARE_ZONE_NAME}" \
     -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
     -H "Content-Type: application/json")
RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id // empty')

if [ -z "$RECORD_ID" ]; then
    # Record does not exist, create it
    echo "$(date): DNS record not found, creating new record..." >> "$LOG_FILE"
    CREATE_STATUS=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
         -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data '{"type":"A", "name":"'${CLOUDFLARE_RECORD_NAME}'", "content":"'${CURRENT_IP}'", "ttl":1, "proxied":false}' | jq -r '.success')

    if [ "$CREATE_STATUS" == "true" ]; then
        echo "$(date): Successfully created ${CLOUDFLARE_RECORD_NAME}.${CLOUDFLARE_ZONE_NAME} with IP ${CURRENT_IP}." >> "$LOG_FILE"
    else
        echo "$(date): Record creation failed." >> "$LOG_FILE"
        exit 1
    fi
else
    echo "$(date): Found record ID: ${RECORD_ID}" >> "$LOG_FILE"

    # Get the old IP address from the query result
    OLD_IP=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].content')
    echo "$(date): Old IP on Cloudflare: ${OLD_IP}" >> "$LOG_FILE"

    # Skip update if IP has not changed
    if [ "$CURRENT_IP" == "$OLD_IP" ]; then
        echo "$(date): IP address unchanged, no update needed. Exiting." >> "$LOG_FILE"
        exit 0
    fi

    # Update Cloudflare DNS A record
    echo "$(date): IP address changed, updating DNS record..." >> "$LOG_FILE"
    UPDATE_STATUS=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
         -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data '{"type":"A", "name":"'${CLOUDFLARE_RECORD_NAME}'", "content":"'${CURRENT_IP}'", "ttl":1, "proxied":false}' | jq -r '.success')

    if [ "$UPDATE_STATUS" == "true" ]; then
        echo "$(date): Successfully updated ${CLOUDFLARE_RECORD_NAME}.${CLOUDFLARE_ZONE_NAME} to ${CURRENT_IP}." >> "$LOG_FILE"
    else
        echo "$(date): Update failed." >> "$LOG_FILE"
        exit 1
    fi
fi
