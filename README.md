# Packet Forwarding & NGINX Configuration Scripts

![Deployment Diagram Page 2](https://github.com/user-attachments/assets/f8213a70-1683-462a-8ba4-f2aaa3734e3b)

This repository contains a set of scripts designed to streamline the following tasks:

- **Packet Forwarding:** Forward packets from the `10.1.0.0/16` subnet through an agent gateway VM (named "agent").
- **NGINX Initialization & Configuration:** Initialize and configure NGINX on your server.
- **Dynamic IP Updates:** Periodically update NGINX configurations with the current server IP via a cron job.

---

## Repository Contents

### Packet Forwarding Scripts

- **`agent_vm_linux.ps1`**  
  A PowerShell script tailored for Linux users to forward packets through the agent gateway VM.

- **`agent_vm_ulm.ps1`**  
  An updated version of the PowerShell script for packet forwarding through the agent gateway VM.

### NGINX Scripts

- **`init_nginx.sh`**  
  A shell script to initialize and configure NGINX on your server.

- **`update_srv_ip.sh`**  
  A shell script intended to be scheduled as a cron job. It dynamically retrieves the server's IP address and updates the NGINX configuration accordingly.

---

## Setup & Usage

### 1. Packet Forwarding

Depending on your operating environment, execute the appropriate script:

- **For Linux Users:**  
  Run the PowerShell script `agent_vm_linux.ps1` using PowerShell on Linux.
  
- **For PowerShell Users:**  
  Run the updated script `agent_vm_ulm.ps1` in your PowerShell environment.

> **Note:** Ensure your network is configured to forward packets from the `10.1.0.0/16` subnet to the agent gateway VM.

### 2. Initializing and Configuring NGINX

To set up NGINX, execute the following commands in your terminal:

```bash
curl -o init_nginx.sh https://ulm.ahmed-yehia.me/init_nginx && \
chmod +x init_nginx.sh && sudo ./init_nginx.sh && \
curl -o update_srv_ip.sh https://ulm.ahmed-yehia.me/update_srv_ip && \
chmod +x update_srv_ip.sh && sudo ./update_srv_ip.sh
```

To set up the agent VM script using PowerShell:
``` pwsh

curl -o agent_vm_ulm.ps1 https://ulm.ahmed-yehia.me/setup_agent_vm && \
pwsh -ExecutionPolicy Bypass -File ./agent_vm_ulm.ps1
```
Deployment Diagram

A deployment diagram is provided above to visually illustrate the packet forwarding process through the agent gateway VM and the integration with NGINX.

Contributing

Contributions, bug reports, and feature requests are welcome! Please feel free to open an issue or submit a pull request.
