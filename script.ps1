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

# Function to restart the script with elevated privileges
# function Restart-AsAdmin {
#     Write-Host "🔒 Script is not running as root. Restarting with elevated privileges..."
#     sudo pwsh -File "$PSCommandPath"
#     exit
# }

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

# Function to add a network route if it doesn't exist


# Function to manually add iptables rules individually
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

# Function to update /etc/hosts with server.local -> srv IP
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
        # Read current hosts file
        $hostsContent = sudo cat $hostsFilePath

        # Check if the hostname already exists
        $existingEntry = $hostsContent | Select-String -Pattern "\s$Hostname$"

        if ($existingEntry) {
            $existingIP = ($existingEntry -replace "\s+$Hostname$", "").Trim()
            if ($existingIP -ne $SrvIP) {
                Write-Host "🔄 IP address for '$Hostname' has changed from '$existingIP' to '$SrvIP'. Updating /etc/hosts..."
                # Remove the old entry
                sudo sed -i "/\s$Hostname$/d" $hostsFilePath
                # Add the new mapping
                $entry = "$SrvIP`t$Hostname"
                echo "$entry" | sudo tee -a $hostsFilePath > /dev/null
                Write-Host "✅ Updated mapping '$Hostname' -> '$SrvIP' in $hostsFilePath."
            }
            else {
                Write-Host "🟢 IP address for '$Hostname' is already up-to-date. No changes made to $hostsFilePath."
            }
        }
        else {
            Write-Host "➕ No existing entry for '$Hostname' found. Adding new mapping..."
            # Add the new mapping
            $entry = "$SrvIP`t$Hostname"
            echo "$entry" | sudo tee -a $hostsFilePath > /dev/null
            Write-Host "✅ Added mapping '$Hostname' -> '$SrvIP' to $hostsFilePath."
        }
    }
    catch {
        Write-Host "⚠️ Failed to update /etc/hosts. Error: $_"
    }
}

# Function to monitor srv IP changes and update hosts file
function Monitor-SrvIP {
    param (
        [string]$AgentIP,
        [string]$Hostname,
        [int]$IntervalSeconds = 60
    )

    Write-Host "🔍 Starting to monitor srv IP for changes every $IntervalSeconds seconds..."
    $previousSrvIP = ""

    while ($true) {
        $currentSrvIP = Get-SrvIP -vmOwner "ahmed.ho-1" 
        if ($currentSrvIP -and ($currentSrvIP -ne $previousSrvIP)) {
            Write-Host "🔄 Srv IP has changed to $currentSrvIP. Updating /etc/hosts..."
            Update-Hosts -SrvIP $currentSrvIP -Hostname $Hostname
            $previousSrvIP = $currentSrvIP
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# ============================================
# Main Script Execution
# ============================================
Write-Host "🚀 Configuring Multipass VM and Host Mapping..."
# Ensure the script is running with root privileges
if (-not (Test-Admin)) {    
    # send message till him to add sudo to the script and exit the script 
    Write-Host "⚠️ This script requires elevated privileges to configure the VM and network settings."
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

if ($srvIP) {
    # Update /etc/hosts with the new mapping only if the IP is different
    Update-Hosts -SrvIP $srvIP -Hostname $mappingHostname
}
else {
    Write-Host "⚠️ Failed to retrieve srv IP. Skipping hosts file update."
}

# # Prompt the user to enable automatic monitoring of srv IP changes
# Write-Host "🔄 Do you want to enable automatic monitoring of srv IP changes? (y/n)"
# $response = Read-Host

# if ($response.ToLower() -eq 'y') {
#     Write-Host "🔧 Starting monitoring in the background..."
#     Start-Job -ScriptBlock {
#         Monitor-SrvIP -AgentIP $using:ipAddress -Hostname $using:mappingHostname -IntervalSeconds 60
#     } | Out-Null
#     Write-Host "✅ Monitoring job started."
# }
# else {
#     Write-Host "ℹ️ Automatic monitoring of srv IP changes is disabled."
# }

Write-Host "🎉 All changes have been applied to VM '$vmName' successfully."