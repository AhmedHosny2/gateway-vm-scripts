const express = require("express");
const path = require("path");
const fs = require("fs").promises;

const app = express();
const port = 3000;

// Endpoint to serve the PowerShell script
app.get("/setup_agent_vm", async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, ".", "scripts", "agent_vm_ulm.ps1");
    const scriptContent = await fs.readFile(scriptPath, "utf-8");

    res.setHeader(
      "Content-Disposition",
      "attachment; filename=agent_vm_ulm.ps1"
    );
    res.setHeader("Content-Type", "text/plain");
    res.status(200).send(scriptContent);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Failed to load script" });
  }
});

app.get("/init_nginx", async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, ".", "scripts", "init_nginx.sh");
    const scriptContent = await fs.readFile(scriptPath, "utf-8");

    res.setHeader("Content-Disposition", "attachment; filename=init_nginx.sh");
    res.setHeader("Content-Type", "text/plain");
    res.status(200).send(scriptContent);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Failed to load script" });
  }
});

app.get("/update_srv_ip", async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, ".", "scripts", "update_srv_ip.sh");
    const scriptContent = await fs.readFile(scriptPath, "utf-8");

    res.setHeader(
      "Content-Disposition",
      "attachment; filename=update_srv_ip.sh"
    );
    res.setHeader("Content-Type", "text/plain");
    res.status(200).send(scriptContent);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Failed to load script" });
  }
});

// Default route
app.get("/", (req, res) => {
  res.send("PowerShell Hosting Server is running locally.");
});

app.listen(port, () => {
  console.log(`Server is running at http://localhost:${port}`);
});
