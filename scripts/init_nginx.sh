#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Function to handle errors
error_exit() {
    echo "❌ Error: $1" >&2
    exit 1
}

# Step 1: Update Package Lists and Install NGINX
echo "🔄 Updating package lists..."
sudo apt-get update || error_exit "Failed to update package lists."

echo "🚀 Installing NGINX..."
sudo apt-get install -y nginx || error_exit "Failed to install NGINX."

# Step 2: Configure NGINX with Dummy Settings
NGINX_CONFIG="/etc/nginx/sites-available/default"

echo "📝 Configuring NGINX with dummy data..."

# Backup the original NGINX configuration if not already backed up
if [[ ! -f "${NGINX_CONFIG}.bak" ]]; then
    sudo cp "$NGINX_CONFIG" "${NGINX_CONFIG}.bak" || error_exit "Failed to backup NGINX configuration."
    echo "💾 Original NGINX configuration backed up."
fi

# Write the dummy configuration
sudo tee "$NGINX_CONFIG" > /dev/null <<EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    location / {
        # Dummy server IP (will be updated later)
        proxy_pass http://10.1.0.123:3000;
        proxy_http_version 1.1;

        # Preserve the original client IP
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # Preserve the original Host header
        proxy_set_header Host \$host;
        # Preserve the original scheme
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

echo "✅ NGINX configured with dummy data."

# Test the NGINX configuration
echo "🔧 Testing NGINX configuration..."
sudo nginx -t || error_exit "NGINX configuration test failed."

# Restart NGINX to apply changes
echo "🔄 Restarting NGINX..."
sudo systemctl restart nginx || error_exit "Failed to restart NGINX."

# Enable NGINX to start on boot
echo "🔧 Enabling NGINX to start on boot..."
sudo systemctl enable nginx || error_exit "Failed to enable NGINX service."

echo "✅ NGINX is up and running with the dummy configuration."