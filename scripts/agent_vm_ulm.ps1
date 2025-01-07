#!/usr/bin/env pwsh

# ============================================
# Script to Configure Multipass VM, NGINX, and Host Mapping
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
$updateScriptPath = "/home/ubuntu/update_srv_ip.sh"  # Path inside the VM
$cronJob = "*/10 * * * * /bin/bash /home/ubuntu/update_srv_ip.sh >> /var/log/update_srv_ip.log 2>&1"

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
        return $false
    }
}

# Function to wait until the VM is running
function Wait-ForVM {
    do {
        $status = (multipass info $vmName | Select-String -Pattern "State" -SimpleMatch | ForEach-Object { $_ -replace "State:\s*", "" }).Trim()
        Start-Sleep -Seconds 2
    } while ($status -ne "Running")
}

# Function to get the IP address of the VM
function Get-MultipassVMIPAddress {
    $ip = ""
    while ([string]::IsNullOrWhiteSpace($ip)) {
        Start-Sleep -Seconds 2
        $vmInfo = multipass info $vmName | Select-String -Pattern "IPv4" -SimpleMatch
        if ($vmInfo) {
            $ip = $vmInfo -replace "IPv4:\s*", ""
        }
    }
    return $ip
}

# Function to add iptables rules to the VM
function Add-IptablesRules {
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
            & sudo bash -c "$cmd"
        }
        catch {
            Write-Error "Failed to add iptables rule: $cmd. Error: $_"
        }
    }

    # Enable IP forwarding
    try {
        $ipForwarding = multipass exec $vmName -- bash -c "sysctl -n net.ipv4.ip_forward"
        if ($ipForwarding -ne "1") {
            & sudo bash -c "sysctl -w net.ipv4.ip_forward=1"
        }
    }
    catch {
        Write-Error "Failed to check or enable IP forwarding. Error: $_"
    }

    # Save iptables rules to ensure persistence
    try {
        & sudo bash -c "multipass exec $vmName -- sudo mkdir -p /etc/iptables"
        & sudo bash -c "multipass exec $vmName -- sudo bash -c 'iptables-save > /etc/iptables/rules.v4'"
    }
    catch {
        Write-Error "Failed to save iptables rules. Error: $_"
    }
}

# Function to retrieve srv IP from agent_public_ip:8080
function Get-SrvIP {
    param(
        [string]$vmOwner
    )
    try {
        $ip = multipass exec $vmName -- sudo vx info | grep "$vmOwner" | grep -oE '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | Select-Object -First 1
        return $ip
    }
    catch {
        Write-Error "Failed to retrieve srv IP. Error: $_"
        return ""
    }
}

# Function to update /etc/hosts with server.local -> srv IP
function Update-Hosts {
    param (
        [string]$SrvIP,
        [string]$Hostname
    )

    if (-not (Test-Path $hostsFilePath)) {
        Write-Error "Hosts file not found at $hostsFilePath."
        return
    }

    try {
        & sudo sed -i "/\b$Hostname\b/d" $hostsFilePath
        $entry = "$SrvIP`t$Hostname"
        & sudo bash -c "echo '$entry' >> $hostsFilePath"
    }
    catch {
        Write-Error "Failed to update /etc/hosts. Error: $_"
    }
}

# Function to install NGINX on the VM
function Install-Nginx {
    $commands = @(
        "sudo apt-get update",
        "sudo apt-get install -y nginx"
    )

    foreach ($cmd in $commands) {
        try {
            & sudo bash -c "$cmd"
        }
        catch {
            Write-Error "Failed to execute '$cmd'. Error: $_"
            exit 1
        }
    }

    # Check NGINX status
    try {
        multipass exec $vmName -- systemctl status nginx --no-pager
    }
    catch {
        Write-Error "Failed to retrieve NGINX status. Error: $_"
    }
}

# Function to configure NGINX on the VM
function Configure-Nginx {
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

    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempFile -Value $nginxConfig

        multipass transfer ${tempFile} ${vmName}:/home/ubuntu/default_nginx.conf
        multipass exec $vmName -- sudo mv /home/ubuntu/default_nginx.conf /etc/nginx/sites-available/default
        multipass exec $vmName -- sudo chmod 644 /etc/nginx/sites-available/default
        Remove-Item $tempFile
    }
    catch {
        Write-Error "Failed to upload NGINX configuration. Error: $_"
        exit 1
    }

    # Test and restart NGINX
    try {
        multipass exec $vmName -- sudo nginx -t
        multipass exec $vmName -- sudo systemctl restart nginx
    }
    catch {
        Write-Error "NGINX configuration test or restart failed. Error: $_"
        exit 1
    }
}

# Function to create update_srv_ip.sh on the VM
function Create-UpdateScript {
    $updateScriptContent = @"
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
    sudo sed -i "s|proxy_pass http://10\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\};|proxy_pass http://\$new_ip:3000;|g" "\$nginx_config"

    echo "✅ NGINX configuration updated successfully." >&2
}

# Function to reload NGINX service
reload_nginx() {
    echo "🔄 Reloading NGINX service..." >&2
    sudo nginx -t && sudo systemctl reload nginx
    echo "✅ NGINX reloaded successfully." >&2
}

# Main execution block for update_srv_ip.sh
main() {
    local vm_owner="ahmed.ho-1"  # Replace with the actual VM owner name

    # Retrieve the server IP
    srv_ip=\$(get_srv_ip "\$vm_owner")

    if [[ -n "\$srv_ip" ]]; then
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

    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempFile -Value $updateScriptContent

        multipass transfer ${tempFile} ${vmName}:/home/ubuntu/update_srv_ip.sh
        multipass exec $vmName -- sudo chmod +x /home/ubuntu/update_srv_ip.sh
        Remove-Item $tempFile
    }
    catch {
        Write-Error "Failed to upload 'update_srv_ip.sh' script. Error: $_"
        exit 1
    }
}

# Function to set up cron job on the VM
function Setup-CronJob {
    try {
        $existingCron = multipass exec $vmName -- crontab -l 2>$null | Select-String -Pattern "update_srv_ip.sh"
        if (-not $existingCron) {
            & sudo bash -c "echo '$cronJob' | multipass exec $vmName -- bash -c 'crontab -l | { cat; echo \"$cronJob\"; } | crontab -'"
        }
    }
    catch {
        Write-Error "Failed to set up cron job. Error: $_"
        exit 1
    }
}

# ============================================
# Main Script Execution
# ============================================
if (-not (Test-Admin)) {    
    Write-Error "This script requires elevated privileges to configure the VM and network settings."
    exit 1
}

# Start the VM
multipass start $vmName

# Wait for the VM to be running
Wait-ForVM

# Retrieve the IP address of the VM
$ipAddress = Get-MultipassVMIPAddress

# Add the network route
& sudo route delete "10.1/16" 2>$null
& sudo route delete "10.1.0.0/16" 2>$null
& sudo route -n add -net "$subnet" -netmask "$netmask" "$ipAddress"

# Add iptables rules to the VM
Add-IptablesRules

# Install and configure NGINX on the VM
Install-Nginx
Configure-Nginx

# Create the update_srv_ip.sh script on the VM
Create-UpdateScript

# Run the update_srv_ip.sh script immediately
multipass exec $vmName -- bash -c "/home/ubuntu/update_srv_ip.sh"

# Set up cron job to run update_srv_ip.sh every 10 minutes
Setup-CronJob

# Retrieve srv IP from agent_public_ip:8080
$srvIP = Get-SrvIP -vmOwner "ahmed.ho-1"

if ($srvIP) {
    # Update /etc/hosts with the new mapping
    Update-Hosts -SrvIP $srvIP -Hostname $mappingHostname
}