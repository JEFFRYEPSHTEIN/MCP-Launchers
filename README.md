# MCP Launchers for Windows

PowerShell commands for starting, checking, and stopping four locally installed MCP servers: Filesystem, Blender, Roblox Studio, and Rojo. The scripts open a temporary HTTPS tunnel so a remote MCP client such as Notion can reach a server on this PC.

> [!IMPORTANT]
> **Choose your working folder before connecting a client and starting work.** Filesystem needs an allowed folder; Rojo needs the folder containing your project's `default.project.json`. The `projectDirectory` in the server map is the MCP installation folder. Read [Choose or change a working folder](WORKING-FOLDERS.md) before running `Start All`.
>
> **Перед началом работы обязательно выберите свою рабочую папку.** Её можно задать сразу и сменить позже, применив настройки сервера. [Инструкция на русском](WORKING-FOLDERS.md).

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

### Choose the working folder

Configure the installed servers before connecting a client:

| Server | Working-folder setting |
| --- | --- |
| Filesystem | `allowedDirectory` in the installed server's `.runtime/config.json`: the existing folder the client may read and edit. |
| Rojo | `projectRoot` in that server's `.runtime/config.json`: the existing folder containing `default.project.json`. With the optional ARC profile, choose `projectRoot` and `rojoExecutable` in this launcher's `.runtime/arc-command-settings.json` and apply them with `.\Arc-Commands.ps1 Mcp`. |

You can choose your own folder during setup or change it later. There is no automatic folder picker. A running Filesystem server needs a stop/edit/start cycle; the ARC `Mcp` command applies a Rojo profile change using the server's supported shutdown and startup. After applying a change, check the selected folder with `Status` and update the client URL if the temporary hostname changed. Keep the existing server token. Follow the complete steps in [WORKING-FOLDERS.md](WORKING-FOLDERS.md).

## Start and connect

After selecting the working folders, from PowerShell in this folder run:

```powershell
.\MCP-Commands.ps1 Start All
```

Without an ARC profile, you can also double-click `Start-All.cmd`. When using the ARC profile, use the command above so Rojo receives the chosen project settings.

Copy the current `/mcp` URL printed for each server into a separate custom MCP connection in your client. Each server has a different Bearer token; details are below. A temporary HTTPS hostname can change after a restart, so update that server's URL in the client when it changes. Never publish a token or `connection.md` file.

## Get a Bearer token for Notion

The token belongs to the installed MCP server. This launcher does not issue a GitHub token or create a shared MCP key. Start all servers with `Start-All.cmd` or run `./MCP-Commands.ps1 Start Filesystem` (replace `Filesystem` with `Blender`, `Roblox-Studio`, or `Rojo`). The output includes `Key/settings file:` followed by the path to that server's `connection.md`. Open that file and copy its token value. Use a separate token for each server.

In Notion, add the server's printed `/mcp` URL as a custom MCP connection. Configure header-based authentication with the header name `Authorization` and value `Bearer <token>`. If Notion shows separate fields for token and prefix, paste only the token into the token field and set the prefix to `Bearer`. Do not put the token in OAuth scopes. Notion's custom MCP setup supports header-based API-key or Bearer authentication ([Notion guide](https://www.notion.com/help/mcp-connections-for-custom-agents)).

Restarting a tunnel can change the URL; it does not by itself change the server token. Update the URL in Notion and keep using that server's existing token. If a token must be rotated, follow the installed MCP server's own instructions and reconnect Notion with the replacement. Never use a GitHub personal access token here, and never commit an MCP token, `.runtime/`, or `connection.md` to GitHub.

### Copy a token with one command

For a token with no path entry, double-click the matching file in the repository root:

| MCP server | File |
| --- | --- |
| Filesystem | `Token-Filesystem.cmd` |
| Blender | `Token-Blender.cmd` |
| Roblox Studio | `Token-Roblox-Studio.cmd` |
| Rojo | `Token-Rojo.cmd` |
| Separate CMD / PC Control MCP | `Token-CMD.cmd` |

Each file copies only its server's existing token and keeps the result window open. Run the one you need, then paste into the client's Token field. The four standard servers use your private `.runtime/servers.json`; CMD uses its separate token store described below. From a terminal you can add `-Header`, for example `Token-Rojo.cmd -Header`, to copy the complete Authorization header, or `-Show` to explicitly print the value.

Double-click `Get-MCP-Token.cmd`, paste the full path to `blender.exe`, `RobloxStudioBeta.exe`, `rojo.exe`, or an installed MCP server folder, and press Enter. The existing token for that configured MCP is copied to the clipboard. Paste it into your client's token field.

From PowerShell in this repository, pass the path directly:

```powershell
.\Get-MCP-Token.ps1 'C:\path with spaces\to\blender.exe'
.\Get-MCP-Token.ps1 'C:\path\to\filesystem-mcp'
.\Get-MCP-Token.ps1 -Server Roblox-Studio
.\Get-MCP-Token.ps1 -Server Rojo -Header
```

`-Header` copies the full `Authorization: Bearer <token>` header. Use `-Server Filesystem`, `Blender`, `Roblox-Studio`, or `Rojo` to choose a server directly. Known program names select the corresponding server in your private map; the token is read from that MCP server's `.runtime/config.json`. The supplied program is never run. A shared `node.exe` does not identify one MCP, so supply its server folder or `-Server`.

Retrieval works while the MCP is stopped and does not change its token. By default the secret goes only to the clipboard. Add `-Show` only when you want to print the token or capture it into a PowerShell variable:

```powershell
$token = .\Get-MCP-Token.ps1 -Server Blender -Show
```

For a different server map, add `-MappingPath 'C:\path\to\private-servers.json'`. If script execution is blocked, use `Get-MCP-Token.cmd` or `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-MCP-Token.ps1 -Server Blender`. No tokens are included in these scripts or written to repository files.

### Separate CMD / PC Control MCP

If you also installed the separate CMD / PC Control MCP, copy its existing token with:

```powershell
.\Token-CMD.cmd
```

For a nonstandard token file, use `.\Token-CMD.cmd -TokenFilePath 'C:\path\to\private\token.json'`. The underlying `Get-CMD-MCP-Token.ps1` also accepts `-Header` and `-Show`. It reads the existing token without running or installing that server. The equivalent direct PowerShell command is:

```powershell
$cmdDataDirectory = if ($env:PC_MCP_DATA_DIR) { $env:PC_MCP_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'PcControlMcp' }
(Get-Content -LiteralPath (Join-Path $cmdDataDirectory 'token.json') -Raw | ConvertFrom-Json).token | Set-Clipboard
```

The token must already have been created by that server's setup. If its data directory was set with a launch argument, assign that directory to `$cmdDataDirectory` instead. This repository's launcher and `Get-MCP-Token.ps1` support the four servers listed above; CMD / PC Control uses its own launch scripts and private token store. Keep its `token.json` out of GitHub as well.

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
