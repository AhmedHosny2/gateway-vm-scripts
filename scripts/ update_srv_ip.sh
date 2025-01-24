#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Function to handle errors
error_exit() {
    echo "❌ Error: $1" >&2
    exit 1
}

# Function to retrieve the server's IP using vx and the owner name
get_srv_ip() {
    local vm_owner="$1"  # The owner name to filter by

    echo "🔍 Retrieving srv IP for owner '$vm_owner'..." >&2

    # Ensure the vx command exists
    if ! command -v vx &>/dev/null; then
        error_exit "'vx' command not found. Please install it before running this script."
    fi

    # Run the vx command to retrieve IPs and filter by the owner
    # Capture only the first IP match
    local ip_address
    ip_address=$(sudo vx info | grep "$vm_owner" | grep -oE '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)

    if [[ -n "$ip_address" ]]; then
        echo "✅ Retrieved srv IP: $ip_address" >&2
        echo "$ip_address"
    else
        echo "⚠️ Unable to retrieve srv IP for owner '$vm_owner'." >&2
        return 1
    fi
}

# Function to update NGINX configuration with the new IP
update_nginx_config() {
    local new_ip="$1"
    local nginx_config="/etc/nginx/sites-available/default"

    echo "🔧 Updating NGINX configuration with new IP: $new_ip..." >&2

    # Backup the NGINX configuration if not already backed up
    if [[ ! -f "${nginx_config}.bak" ]]; then
        sudo cp "$nginx_config" "${nginx_config}.bak" || error_exit "Failed to backup NGINX configuration."
        echo "💾 NGINX configuration backed up."
    fi

    # Use sed to replace the existing IP in the proxy_pass line
    # This assumes the proxy_pass line follows the exact format:
    # proxy_pass http://10.x.x.x:port;
    sudo sed -i "s|proxy_pass http://10\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\};|proxy_pass http://$new_ip:3000;|g" "$nginx_config" || error_exit "Failed to update NGINX configuration."

    echo "✅ NGINX configuration updated successfully." >&2
}

# Function to reload NGINX service
reload_nginx() {
    echo "🔄 Reloading NGINX service..." >&2
    sudo nginx -t && sudo systemctl reload nginx || error_exit "Failed to reload NGINX."
    echo "✅ NGINX reloaded successfully." >&2
}

# Function to set up a cron job to run this script every 10 minutes
setup_cron_job() {
    local script_path="$1"
    local cron_job="*/10 * * * * $script_path >> /var/log/update_srv_ip.log 2>&1"

    echo "🗓️ Setting up a cron job to run update_srv_ip.sh every 10 minutes..." >&2

    # Check if the cron job already exists to prevent duplicates
    if sudo crontab -l 2>/dev/null | grep -F "$cron_job" >/dev/null 2>&1; then
        echo "🕒 Cron job already exists. Skipping addition." >&2
    else
        (sudo crontab -l 2>/dev/null; echo "$cron_job") | sudo crontab - || error_exit "Failed to set up cron job."
        echo "✅ Cron job added successfully." >&2
    fi
}

# Main execution block
main() {
    local vm_owner="ahmed.ho-1"  # Replace with the actual VM owner name
    local script_path="/usr/local/bin/update_srv_ip.sh"

    # Retrieve the server IP
    srv_ip=$(get_srv_ip "$vm_owner")

    if [[ -n "$srv_ip" ]]; then
        echo "srv_ip='$srv_ip'" >&2  # Debugging: Show the retrieved IP
        update_nginx_config "$srv_ip"  # Update NGINX configuration
        reload_nginx  # Reload NGINX to apply changes
    else
        echo "⚠️ Failed to retrieve a valid server IP address. Exiting." >&2
        exit 1
    fi

    # Set up the cron job
    setup_cron_job "$script_path"
}

# Execute the main function
main