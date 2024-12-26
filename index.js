const express = require('express');
const { spawn } = require('child_process');
const app = express();
const port = 3000;

// Endpoint to execute the PowerShell script
app.post('/execute-script', (req, res) => {
    const scriptPath = './script.ps1';

    // Spawn a PowerShell process
    const ps = spawn('pwsh', ['-NoProfile', '-Command', `& { . '${scriptPath}' }`]);

    // Set response headers for streaming
    res.setHeader('Content-Type', 'text/plain');
    res.setHeader('Transfer-Encoding', 'chunked');

    // Stream stdout data to the client
    ps.stdout.on('data', (data) => {
        res.write(data.toString());
    });

    // Stream stderr data to the client
    ps.stderr.on('data', (data) => {
        res.write(`ERROR: ${data.toString()}`);
    });

    // End the response when the process finishes
    ps.on('close', (code) => {
        res.write(`\nProcess exited with code ${code}`);
        res.end();
    });
});

app.listen(port, () => {
    console.log(`PowerShell API running at http://localhost:${port}`);
});