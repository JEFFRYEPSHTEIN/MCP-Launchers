# Commands for a Rojo project

These optional commands build and open a Roblox project, or configure this launcher's Rojo MCP server to use that project. They require a local profile at `.runtime/arc-command-settings.json`.

**Choose your project folder before starting.** `projectRoot` selects the Roblox project; `projectDirectory` in the server map selects the installed MCP server. Read [WORKING-FOLDERS.md](WORKING-FOLDERS.md) for folder selection and changes, including the separate Filesystem setting.

Start by copying the example and editing the paths for this PC:

```powershell
New-Item -ItemType Directory .runtime -Force | Out-Null
Copy-Item arc-command-settings.example.json .runtime\arc-command-settings.json
notepad .runtime\arc-command-settings.json
```

Set `projectRoot` to the folder with `default.project.json`, `rojoExecutable` to the Rojo executable, `studioExecutable` to Roblox Studio, `servePort` to an unused local port, and `placeFile` to the Place file you want Studio to open. Keep this profile on your PC; `.runtime/` is ignored by Git.

From the repository folder, run:

```powershell
.\Arc-Commands.ps1 Status
.\Arc-Commands.ps1 Build
.\Arc-Commands.ps1 Studio
.\Arc-Commands.ps1 Mcp
.\Arc-Commands.ps1 Serve
```

`Build` writes a uniquely named file under the project's `build` folder. `Studio` opens the configured `placeFile`; you can instead pass `-PlaceFile 'C:\path\to\place.rbxlx'`. `Mcp` points the local Rojo server to the selected project and prints its current HTTPS URL. Keep the existing Bearer key when updating that MCP connection in your client. `Serve` starts a direct local Rojo session; leave its window open and press Ctrl+C to stop it. For synchronization managed by a connected MCP client, use the `rojo_serve` tool instead.

The local Rojo plugin normally connects to `127.0.0.1` and the configured `servePort`. Connecting synchronizes project files into the Place currently open in Studio.

## Switch to another project

Edit the existing `.runtime/arc-command-settings.json` without copying the example over it. Set `projectRoot` to the new folder containing `default.project.json` and adjust `rojoExecutable` and `placeFile` if needed. Save, then run:

```powershell
.\Arc-Commands.ps1 Mcp
.\MCP-Commands.ps1 Status Rojo
```

`Mcp` applies the new root and CLI, saving a private backup and stopping the verified running MCP through its supported shutdown before a configuration change. It preserves the Bearer key and prints the current HTTPS URL. Check the reported project and update Notion's URL if the hostname changed; start synchronization again when needed.

With the default server map, `MCP-Commands.ps1 Start Rojo`, `Restart Rojo`, and `Start All` apply this profile. `Start-All.cmd` launches the servers directly and does not apply it. The profile takes precedence over a manual change to the Rojo server's `projectRoot` on the next profile-based start. Set Filesystem's allowed folder separately if the client also needs to edit the new project's files.
