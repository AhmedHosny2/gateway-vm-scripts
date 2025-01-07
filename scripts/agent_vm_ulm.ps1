#!/usr/bin/env pwsh

# ============================================
# Script to Configure Multipass VM and Host Mapping
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
        $ip = multipass exec $vmName -- sudo vx info | grep "$vmOwner" | grep -oE '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
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



# ============================================
# Main Script Execution
# ============================================
Write-Host "🚀 Configuring Multipass VM and Host Mapping..."
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

Write-Host "🎉 All changes have been applied to VM '$vmName' successfully."