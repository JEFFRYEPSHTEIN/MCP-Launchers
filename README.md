# MCP Launchers for Windows

PowerShell commands for starting, checking, and stopping four locally installed MCP servers: Filesystem, Blender, Roblox Studio, and Rojo. The scripts open a temporary HTTPS tunnel so a remote MCP client such as Notion can reach a server on this PC.

## Requirements

- Windows PowerShell 5.1 or later and Node.js.
- The compatible MCP server projects already installed on this PC. This repository contains launch and management scripts; it does not install Blender, Roblox Studio, Rojo, the MCP servers, or a tunnel provider.
- Network access for the HTTPS tunnel. Your PC must stay on while a remote client uses a local server.

## Configure this PC

Open PowerShell in this folder and create a private server map:

```powershell
New-Item -ItemType Directory .runtime -Force | Out-Null
Copy-Item servers.example.json .runtime\servers.json
notepad .runtime\servers.json
```

In `.runtime\servers.json`, change each `projectDirectory` to the folder containing that MCP server's launcher files. Keep the supplied server IDs and identities aligned with the server's own configuration. Do not put API keys or bearer tokens in this map. Each server keeps its key and connection details in its own private runtime folder.

## Start and connect

Double-click `Start-All.cmd`, or from PowerShell in this folder run:

```powershell
.\MCP-Commands.ps1 Start All
```

Copy the current `/mcp` URL printed for each server into a separate custom MCP connection in your client. Use the matching server's existing Bearer token; the launcher prints the path to its local `connection.md`. A temporary HTTPS hostname can change after a restart, so update that server's URL in the client when it changes. Never publish the token or connection file.

The individual `.cmd` launchers start one service. For Blender, open the scene and enable its MCP add-on. For Roblox Studio, open a Place and enable **Assistant → … → Manage MCP Servers → Enable Studio as MCP server**. Rojo's MCP service and Rojo's Studio synchronization are separate: start synchronization with the `rojo_serve` tool when needed.

## Check and manage

```powershell
.\MCP-Commands.ps1 Status All
.\MCP-Commands.ps1 Links All
.\MCP-Commands.ps1 Restart Blender
.\MCP-Commands.ps1 Stop All
```

`Status` checks HTTPS, authenticates to the MCP server, lists its tools, and makes a read-only application check where supported. An `ATTENTION` result means the gateway answers but its application still needs setup, such as opening a Place in Studio. `Links` only displays currently validated URLs. Stop and restart use each server's supported shutdown API.

Detailed commands and recovery behavior are in [MCP-COMMANDS.md](MCP-COMMANDS.md). Optional project-specific Rojo commands are described in [ARC-COMMANDS.md](ARC-COMMANDS.md); they require a local profile in `.runtime\arc-command-settings.json`.

## Private local files

`.runtime/` holds this PC's server map, settings, reports, and current connection links. Keep it local and out of GitHub. Bearer tokens and `connection.md` files belong to each installed MCP server, not this repository. `.runtime/` and local diagnostics are ignored by Git.
