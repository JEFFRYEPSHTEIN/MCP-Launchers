# Commands for a Rojo project

These optional commands build and open a Roblox project, or configure this launcher's Rojo MCP server to use that project. They require a local profile at `.runtime/arc-command-settings.json`.

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
