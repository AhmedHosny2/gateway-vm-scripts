#!/usr/bin/env pwsh

# ============================================
# Script to Configure Multipass VM, Host Mapping, and NGINX Setup
# ============================================

# Define Configuration Variables
$vmName = "agent"
$subnet = "10.1.0.0"
$prefixLength = 16  # Corresponds to 255.255.0.0
$netmask = "255.255.0.0"  # Define the netmask for the route
$vmInterface = "vx"         # Replace with your VM's internal interface name
$hostInterface = "enp0s1"   # Replace with your host's external interface name
$mappingHostname = "server.local"
$hostsFilePath = "/etc/hosts"

# Define NGINX Configuration
$nginxConfig = @"
server {
    listen 80 default_server;
    server_name _;

    location / {
        # server's IP 
        proxy_pass http://10.1.0.123:3000; 
        proxy_http_version 1.1;

        # Preserve the original client IP
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # Preserve the original Host header
        proxy_set_header Host \$host;
    }
}
"@

# Define update_srv_ip.sh Script Content
$updateSrvIpScript = @"
#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Function to retrieve the server's IP using vx and the owner name
get_srv_ip() {
    local vm_owner="\$1"  # The owner name to filter by

    echo "🔍 Retrieving srv IP for owner '\$vm_owner'..." >&2

    # Run the vx command to retrieve IPs and filter by the owner
    # Capture only the first IP match
    local ip_address
    ip_address=\$(sudo vx info | grep "\$vm_owner" | grep -oE '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)

    if [[ -n "\$ip_address" ]]; then
        echo "✅ Retrieved srv IP: \$ip_address" >&2
        echo "\$ip_address"
    else
        echo "⚠️ Unable to retrieve srv IP for owner '\$vm_owner'." >&2
        return 1
    fi
}

# Function to update NGINX configuration with the new IP
update_nginx_config() {
    local new_ip="\$1"
    local nginx_config="/etc/nginx/sites-available/default"

    echo "🔧 Updating NGINX configuration with new IP: \$new_ip..." >&2

    # Backup the original NGINX configuration
    sudo cp "\$nginx_config" "\${nginx_config}.bak"

    # Use sed to replace the existing IP in the proxy_pass line
    # This assumes the proxy_pass line follows the exact format:
    # proxy_pass http://10.x.x.x:port;
    sudo sed -i "s|proxy_pass http://10\\.[0-9]\\{1,3\\}\\.[0-9]\\{1,3\\}\\.[0-9]\\{1,3\\}:[0-9]\\{1,5\\};|proxy_pass http://\$new_ip:3000;|g" "\$nginx_config"

    echo "✅ NGINX configuration updated successfully." >&2
}

# Function to reload NGINX service
reload_nginx() {
    echo "🔄 Reloading NGINX service..." >&2
    sudo nginx -t && sudo systemctl reload nginx
    echo "✅ NGINX reloaded successfully." >&2
}

# Main execution block
main() {
    local vm_owner="ahmed.ho-1"  # Replace with the actual VM owner name

    # Retrieve the server IP
    srv_ip=\$(get_srv_ip "\$vm_owner")

    if [[ -n "\$srv_ip" ]]; then
        echo "srv_ip='\$srv_ip'" >&2  # Debugging: Show the retrieved IP
        update_nginx_config "\$srv_ip"  # Update NGINX configuration
        reload_nginx  # Reload NGINX to apply changes
    else
        echo "⚠️ Failed to retrieve a valid server IP address. Exiting." >&2
        exit 1
    fi
}

# Execute the main function
main
"@

# ============================================
# Function Definitions
# ============================================

# Function to check if the script is running as root
function Test-Admin {
    try {
        $uid = sudo id -u
        return ($uid -eq 0)
    }
    catch {
        Write-Host "⚠️ Unable to determine if the script is running as root."
        return $false
    }
}

# Function to wait until the VM is running
function Wait-ForVM {
    Write-Host "⏳ Waiting for the VM '$vmName' to fully start..."
    do {
        $status = (multipass info $vmName | Select-String -Pattern "State" -SimpleMatch | ForEach-Object { $_ -replace "State:\s*", "" }).Trim()
        Start-Sleep -Seconds 2
    } while ($status -ne "Running")
    Write-Host "✅ VM '$vmName' is running."
}

# Function to get the IP address of the VM
function Get-MultipassVMIPAddress {
    Write-Host "🔍 Retrieving the IP address of the VM..."
    $ip = ""
    while ([string]::IsNullOrWhiteSpace($ip)) {
        Start-Sleep -Seconds 2
        $vmInfo = multipass info $vmName | Select-String -Pattern "IPv4" -SimpleMatch
        if ($vmInfo) {
            $ip = $vmInfo -replace "IPv4:\s*", ""
        }
    }
    Write-Host "✅ VM '$vmName' IP Address: $ip"
    return $ip
}

# Function to add iptables rules individually
function Add-IptablesRules {
    Write-Host "🔧 Adding iptables rules to VM '$vmName'..."

    # Define each iptables command individually
    $iptablesCommands = @(
        "sudo iptables -I FORWARD -p icmp -j ACCEPT",
        "sudo iptables -I FORWARD -p tcp --dport 80 -j ACCEPT",
        "sudo iptables -I FORWARD -p tcp -d 10.1.0.113 --dport 80 -j ACCEPT",
        "sudo iptables -I FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT",
        "sudo iptables -t nat -I POSTROUTING -o $vmInterface -j MASQUERADE",
        "sudo iptables -t nat -I PREROUTING -p udp --dport 8554 -j DNAT --to-destination 172.23.208.1",
        "sudo iptables -I INPUT -i $vmInterface -s 10.1.0.0/16 -j ACCEPT",
        "sudo iptables -I INPUT -i $vmInterface -d 10.1.0.0/16 -j ACCEPT",
        "sudo iptables -I FORWARD -i $vmInterface -s 10.1.0.0/16 -d 10.1.0.0/16 -j ACCEPT",
        "sudo iptables -I FORWARD -i $vmInterface -o $hostInterface -j ACCEPT",
        "sudo iptables -I FORWARD -i $hostInterface -o $vmInterface -j ACCEPT"
    )

    foreach ($cmd in $iptablesCommands) {
        try {
            multipass exec $vmName -- bash -c "$cmd"
        }
        catch {
            Write-Host "⚠️ Failed to add iptables rule: $cmd. Error: $_"
        }
    }

    # Enable IP forwarding
    try {
        $ipForwarding = multipass exec $vmName -- bash -c "sysctl -n net.ipv4.ip_forward"
        if ($ipForwarding -ne "1") {
            Write-Host "🔄 Enabling IP forwarding on VM '$vmName'..."
            multipass exec $vmName -- sudo sysctl -w net.ipv4.ip_forward=1
            Write-Host "✅ IP forwarding enabled."
        }
        else {
            Write-Host "🟢 IP forwarding is already enabled on VM '$vmName'."
        }
    }
    catch {
        Write-Host "⚠️ Failed to check or enable IP forwarding. Error: $_"
    }

    # Save iptables rules to ensure persistence
    try {
        Write-Host "💾 Saving iptables rules for persistence..."
        multipass exec $vmName -- sudo mkdir -p /etc/iptables
        multipass exec $vmName -- sudo bash -c "iptables-save > /etc/iptables/rules.v4"
        Write-Host "✅ iptables rules saved successfully."
    }
    catch {
        Write-Host "⚠️ Failed to save iptables rules. Error: $_"
    }

    Write-Host "🎉 All iptables rules have been applied to VM '$vmName'."
}

# Function to retrieve srv IP from agent_public_ip:8080
function Get-SrvIP {
    param(
        [string]$vmOwner
    )
    try {
        Write-Host "🔍 Retrieving srv IP for owner '$vmOwner'..."
        $ip = multipass exec $vmName -- sudo vx info | Select-String -Pattern $vmOwner | ForEach-Object {
            $_ -match '10\.\d{1,3}\.\d{1,3}\.\d{1,3}' | Out-Null
            $Matches[0]
        }
        if ($ip) {
            Write-Host "✅ Retrieved srv IP: $ip"
            return $ip
        }
        else {
            Write-Host "⚠️ Unable to retrieve srv IP for owner '$vmOwner'."
            return ""
        }
    }
    catch {
        Write-Host "⚠️ Failed to retrieve srv IP. Error: $_"
        return ""
    }
}

# Function to update /etc/hosts with server.local -> VM IP
function Update-Hosts {
    param (
        [string]$SrvIP,
        [string]$Hostname
    )

    if (-not (Test-Path $hostsFilePath)) {
        Write-Host "⚠️ Hosts file not found at $hostsFilePath."
        return
    }

    try {
        # Remove all existing entries for the hostname
        Write-Host "🔄 Removing all existing entries for '$Hostname' from $hostsFilePath..."
        sudo sed -i "/\b$Hostname\b/d" $hostsFilePath
        Write-Host "✅ Removed existing entries for '$Hostname'."

        # Add the new mapping
        $entry = "$SrvIP`t$Hostname"
        Write-Host " Adding new mapping '$Hostname' -> '$SrvIP' to $hostsFilePath..."
        echo "$entry" | sudo tee -a $hostsFilePath > /dev/null
        Write-Host "✅ Added new mapping '$Hostname' -> '$SrvIP' to $hostsFilePath."
    }
    catch {
        Write-Host "⚠️ Failed to update /etc/hosts. Error: $_"
    }
}

# Function to install and configure NGINX on the VM
function Configure-Nginx {
    Write-Host "🚀 Installing and configuring NGINX on VM '$vmName'..."

    try {
        # Update package lists
        Write-Host "🔄 Updating package lists..."
        multipass exec $vmName -- sudo apt-get update -y

        # Install NGINX
        Write-Host "🔧 Installing NGINX..."
        multipass exec $vmName -- sudo apt-get install -y nginx

        # Start and enable NGINX service
        Write-Host "🔄 Starting and enabling NGINX service..."
        multipass exec $vmName -- sudo systemctl enable nginx
        multipass exec $vmName -- sudo systemctl start nginx

        # Check NGINX status
        Write-Host "📋 Checking NGINX status..."
        multipass exec $vmName -- systemctl status nginx --no-pager

        # Configure NGINX default site
        Write-Host "📝 Configuring NGINX default site..."
        multipass exec $vmName -- sudo bash -c "cat > /etc/nginx/sites-available/default" <<< "$nginxConfig"

        # Reload NGINX to apply configuration
        Write-Host "🔄 Reloading NGINX to apply new configuration..."
        multipass exec $vmName -- sudo nginx -t && sudo systemctl reload nginx

        Write-Host "✅ NGINX installed and configured successfully."
    }
    catch {
        Write-Host "⚠️ Failed to install or configure NGINX. Error: $_"
    }
}

# Function to deploy update_srv_ip.sh and set up cron job
function Setup-AutoUpdateScript {
    Write-Host "🚀 Setting up auto-update script on VM '$vmName'..."

    try {
        # Create the update_srv_ip.sh script on the VM
        Write-Host "📝 Creating update_srv_ip.sh script..."
        multipass exec $vmName -- sudo bash -c "cat > /usr/local/bin/update_srv_ip.sh" <<< "$updateSrvIpScript"

        # Make the script executable
        Write-Host "🔧 Making update_srv_ip.sh executable..."
        multipass exec $vmName -- sudo chmod +x /usr/local/bin/update_srv_ip.sh

        # Execute the script once to ensure it's working
        Write-Host "🚀 Executing update_srv_ip.sh script..."
        multipass exec $vmName -- sudo /usr/local/bin/update_srv_ip.sh

        # Set up cron job to run the script every 10 minutes
        Write-Host "🕒 Setting up cron job for update_srv_ip.sh..."
        $cronJob = "*/10 * * * * /bin/bash /usr/local/bin/update_srv_ip.sh >> /var/log/update_srv_ip.log 2>&1"
        multipass exec $vmName -- sudo bash -c "(crontab -l 2>/dev/null; echo `"$cronJob`") | crontab -"

        Write-Host "✅ Auto-update script and cron job set up successfully."
    }
    catch {
        Write-Host "⚠️ Failed to set up auto-update script or cron job. Error: $_"
    }
}

# ============================================
# Main Script Execution
# ============================================
Write-Host "🚀 Configuring Multipass VM, Host Mapping, and NGINX Setup..."

# Ensure the script is running with root privileges
if (-not (Test-Admin)) {    
    # Notify the user to rerun the script with sudo and exit
    Write-Host "⚠️ This script requires elevated privileges to configure the VM and network settings."
    Write-Host "🔄 Please rerun the script using 'sudo' and try again."
    exit 1
}

# Uncomment the following line if you encounter Multipass authentication issues
# multipass auth

# Start the VM
Write-Host "🚀 Starting the VM '$vmName'..."
multipass start $vmName

# Wait for the VM to be running
Wait-ForVM

# Retrieve the IP address of the VM
$ipAddress = Get-MultipassVMIPAddress

# Add the network route if it doesn't exist
Write-Host "Adding route to $subnet/$prefixLength via $ipAddress..."
sudo route delete 10.1/16 2>$null
sudo route delete 10.1.0.0/16 2>$null
sudo route -n add -net $subnet -netmask $netmask $ipAddress

# Add iptables rules to the VM
Add-IptablesRules

# Retrieve srv IP from agent_public_ip:8080
$srvIP = Get-SrvIP -vmOwner "ahmed.ho-1"

if ($ipAddress) {
    # Update /etc/hosts with the new mapping only if the IP is different
    Update-Hosts -SrvIP $ipAddress -Hostname $mappingHostname
}
else {
    Write-Host "⚠️ Failed to retrieve VM IP address. Skipping hosts file update."
}

# Install and configure NGINX on the VM
Configure-Nginx

# Set up the auto-update script and cron job on the VM
Setup-AutoUpdateScript

Write-Host "🎉 All changes have been applied to VM '$vmName' successfully."