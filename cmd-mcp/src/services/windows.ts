import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const execute = promisify(execFile);
export async function validateCwd(cwd?: string): Promise<string> {
  const directory = cwd ?? os.homedir();
  if (!path.isAbsolute(directory) || directory.includes('\0')) throw new Error('cwd must be an absolute existing directory.');
  if (!(await stat(directory)).isDirectory()) throw new Error('cwd must be a directory.');
  return directory;
}

export async function powershellJson(script: string): Promise<unknown> {
  // Scripts are generated from fixed templates and validated numeric IDs only.
  const encoded = Buffer.from("$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script, 'utf16le').toString('base64');
  const { stdout } = await execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
    { windowsHide: true, encoding: 'utf8', timeout: 15000, maxBuffer: 8 * 1024 * 1024 });
  return JSON.parse(stdout.trim().replace(/^\uFEFF/, ''));
}

export async function processIdentity(pid: number): Promise<string> {
  if (!Number.isInteger(pid) || pid < 1) throw new Error('Invalid process ID.');
  const value = await powershellJson(`(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') | ConvertTo-Json -Compress`);
  if (typeof value !== 'string') throw new Error('Cannot read process identity.');
  return value;
}

export async function stopTree(pid: number): Promise<void> {
  if (!Number.isInteger(pid) || pid < 1) throw new Error('Invalid process ID.');
  await execute('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { windowsHide: true, timeout: 10000, maxBuffer: 64 * 1024 });
}

export async function stopProcess(pid: number, expected: string): Promise<object> {
  if (pid === process.pid) throw new Error('Use the local Stop.ps1 script to stop this MCP server.');
  const actual = await processIdentity(pid);
  if (actual !== expected) throw new Error('Process identity changed. Refresh pc_list_processes before stopping.');
  await stopTree(pid);
  return { pid, stopped: true };
}

export async function listProcesses(offset: number, limit: number): Promise<object> {
  const data = await powershellJson(`$items = @(Get-Process | Sort-Object Id); $page = @($items | Select-Object -Skip ${offset} -First ${limit} | ForEach-Object {
    $started = $null; $cpu = $null;
    try { $started = $_.StartTime.ToUniversalTime().ToString('o') } catch {}
    try { $cpu = $_.CPU } catch {}
    [pscustomobject]@{pid=$_.Id;name=$_.ProcessName;started_at=$started;cpu_seconds=$cpu;working_set_bytes=$_.WorkingSet64}
  }); [pscustomobject]@{processes=$page;total=$items.Count;offset=${offset};limit=${limit}} | ConvertTo-Json -Depth 5 -Compress`);
  return data as object;
}

export async function pcStatus(): Promise<object> {
  const volumes = await powershellJson(`@(Get-CimInstance Win32_LogicalDisk | ForEach-Object {
    [pscustomobject]@{name=$_.DeviceID;drive_type=$_.DriveType;filesystem=$_.FileSystem;size_bytes=$_.Size;free_bytes=$_.FreeSpace}
  }) | ConvertTo-Json -Depth 3 -Compress`);
  return { hostname: os.hostname(), os: os.type(), release: os.release(), version: os.version(),
    uptime_seconds: os.uptime(), total_memory_bytes: os.totalmem(), free_memory_bytes: os.freemem(),
    volumes: Array.isArray(volumes) ? volumes : volumes ? [volumes] : [] };
}

export function startChild(executable: string, args: string[], cwd: string) {
  return spawn(executable, args, { cwd, shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
}
