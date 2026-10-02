import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, lstatSync } from 'node:fs';
import path from 'node:path';

export function dataDirectory(override?: string): string {
  const base = override ?? process.env.PC_MCP_DATA_DIR;
  const result = base ?? path.join(process.env.LOCALAPPDATA ?? '', 'PcControlMcp');
  if (!path.isAbsolute(result)) throw new Error('A local absolute runtime directory is required.');
  return result;
}

function protect(directory: string, file?: string): void {
  if (process.platform !== 'win32') throw new Error('This service requires Windows.');
  const sid = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'], { encoding: 'utf8', windowsHide: true }).trim();
  if (!/^S-1-\d+(?:-\d+)+$/.test(sid)) throw new Error('Cannot identify the current Windows account.');
  execFileSync('icacls.exe', [directory, '/inheritance:r', '/grant:r', `*${sid}:(OI)(CI)F`], { windowsHide: true, stdio: 'pipe' });
  if (file) execFileSync('icacls.exe', [file, '/inheritance:r', '/grant:r', `*${sid}:F`], { windowsHide: true, stdio: 'pipe' });
}

export function provisionToken(directory: string, rotate = false): string {
  mkdirSync(directory, { recursive: true });
  if (lstatSync(directory).isSymbolicLink()) throw new Error('Runtime directory cannot be a symlink.');
  const file = path.join(directory, 'token.json');
  if (existsSync(file) && lstatSync(file).isSymbolicLink()) throw new Error('Token file cannot be a symlink.');
  protect(directory);
  if (!existsSync(file) || rotate) {
    const token = randomBytes(32).toString('base64url');
    writeFileSync(file, JSON.stringify({ version: 1, token, created_at: new Date().toISOString() }, null, 2), { mode: 0o600 });
  }
  protect(directory, file);
  const document = JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  if (document.version !== 1 || !/^[A-Za-z0-9_-]{43}$/.test(document.token)) throw new Error('Invalid token file. Rotate the local token.');
  return document.token;
}

export function bearerValidator(token: string): (header: string | undefined) => boolean {
  const expected = createHash('sha256').update(token).digest();
  return header => {
    if (!header || header.length > 512 || !/^Bearer [A-Za-z0-9_-]{43}$/i.test(header)) return false;
    const actual = createHash('sha256').update(header.slice(7)).digest();
    return timingSafeEqual(expected, actual);
  };
}

export function safeError(error: unknown, token: string): string {
  const message = error instanceof Error ? error.message : 'Operation failed.';
  return message.split(token).join('[redacted]').slice(0, 2000);
}
