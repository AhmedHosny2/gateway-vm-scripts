const express = require('express');
const path = require('path');
const fs = require('fs').promises;

const app = express();
const port = 3000;

// Endpoint to serve the PowerShell script
app.get('/download', async (req, res) => {
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


// Default route
app.get('/', (req, res) => {
    res.send('PowerShell Hosting Server is running locally.');
});

app.listen(port, () => {
    console.log(`Server is running at http://localhost:${port}`);
});