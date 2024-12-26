const express = require('express');
const path = require('path');
const fs = require('fs').promises;

const app = express();
const port = 3000;

// Endpoint to serve the PowerShell script
app.get('/api/download', async (req, res) => {
    try {
        const scriptPath = path.join(__dirname, '.', 'scripts', 'agent_vm_ulm.ps1');
        const scriptContent = await fs.readFile(scriptPath, 'utf-8');

        res.setHeader('Content-Disposition', 'attachment; filename=agent_vm_ulm.ps1');
        res.setHeader('Content-Type', 'text/plain');
        res.status(200).send(scriptContent);
    } catch (error) {
        console.error(error);
        res.status(500).json({ error: 'Failed to load script' });
    }
});

// Endpoint to serve the installer script
app.get('/api/installer', async (req, res) => {
    try {
        const installerPath = path.join(__dirname, '..', 'public', 'install_and_run.ps1');
        const installerContent = await fs.readFile(installerPath, 'utf-8');

        res.setHeader('Content-Disposition', 'attachment; filename=install_and_run.ps1');
        res.setHeader('Content-Type', 'text/plain');
        res.status(200).send(installerContent);
    } catch (error) {
        console.error(error);
        res.status(500).json({ error: 'Failed to load installer script' });
    }
});

// Default route
app.get('/', (req, res) => {
    res.send('PowerShell Hosting Server is running locally.');
});

app.listen(port, () => {
    console.log(`Server is running at http://localhost:${port}`);
});