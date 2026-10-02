import { spawn, type ChildProcess } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { EventEmitter } from 'node:events';
import { startChild, stopTree, validateCwd } from './windows.js';

type State = 'running' | 'completed' | 'stopped' | 'failed';
type Chunk = { start: number; end: number; text: string; channel: 'stdout' | 'stderr'; bytes: number };
type Session = {
  id: string; kind: 'command' | 'process'; child: ChildProcess; state: State; pid: number | null;
  started_at: string; finished_at: number | null; chunks: Chunk[]; bytes: number;
  nextCursor: number; readCursor: number; exit_code: number | null; error: string | null; events: EventEmitter;
};
const RETAIN_BYTES = 1024 * 1024;
const RESPONSE_BYTES = 64 * 1024;
const TTL = 30 * 60 * 1000;

function prefixByBytes(value: string, max: number): string {
  let end = Math.min(value.length, max);
  while (Buffer.byteLength(value.slice(0, end)) > max) end = Math.floor(end * 0.9);
  if (end > 0 && /[\uD800-\uDBFF]/.test(value[end - 1])) end--;
  return value.slice(0, end);
}

export class Sessions {
  private sessions = new Map<string, Session>();
  private shuttingDown = false;

  private prune(): void {
    const now = Date.now();
    for (const [id, item] of this.sessions) if (item.finished_at !== null && now - item.finished_at > TTL) this.sessions.delete(id);
  }
  private checkCapacity(): void {
    this.prune();
    if (this.shuttingDown) throw new Error('Server is shutting down.');
    if ([...this.sessions.values()].filter(s => s.state === 'running').length >= 8) throw new Error('Eight sessions are running. Stop one before starting another.');
    if (this.sessions.size >= 128) {
      const finished = [...this.sessions.values()].find(s => s.state !== 'running');
      if (finished) this.sessions.delete(finished.id);
    }
  }
  private get(id: string): Session {
    this.prune();
    const session = this.sessions.get(id);
    if (!session) throw new Error('Unknown or expired session_id. Use pc_list_sessions.');
    return session;
  }
  private append(session: Session, text: string, channel: Chunk['channel']): void {
    if (!text) return;
    for (let offset = 0; offset < text.length;) {
      const piece = prefixByBytes(text.slice(offset), 16 * 1024);
      const bytes = Buffer.byteLength(piece);
      session.chunks.push({ start: session.nextCursor, end: session.nextCursor + piece.length, text: piece, channel, bytes });
      session.nextCursor += piece.length;
      session.bytes += bytes;
      offset += piece.length;
      while (session.bytes > RETAIN_BYTES && session.chunks.length) session.bytes -= session.chunks.shift()!.bytes;
    }
    session.events.emit('update');
  }
  private track(child: ChildProcess, kind: Session['kind']): Session {
    const session: Session = { id: randomUUID(), kind, child, state: 'running', pid: child.pid ?? null,
      started_at: new Date().toISOString(), finished_at: null, chunks: [], bytes: 0, nextCursor: 0, readCursor: 0,
      exit_code: null, error: null, events: new EventEmitter() };
    this.sessions.set(session.id, session);
    for (const channel of ['stdout', 'stderr'] as const) {
      const decoder = new StringDecoder('utf8');
      child[channel]?.on('data', (data: Buffer) => this.append(session, decoder.write(data), channel));
      child[channel]?.on('end', () => this.append(session, decoder.end(), channel));
    }
    child.on('error', error => {
      session.error = error.message;
      session.state = 'failed';
      session.finished_at = Date.now();
      session.events.emit('update');
    });
    child.on('close', code => {
      if (session.state === 'running') session.state = code === null ? 'failed' : 'completed';
      session.exit_code = code;
      session.finished_at = Date.now();
      session.events.emit('update');
    });
    return session;
  }
  private async wait(session: Session, ms: number, output = false): Promise<void> {
    if (session.state !== 'running' || ms <= 0) return;
    await new Promise<void>(resolve => {
      const finish = () => { clearTimeout(timer); session.events.off('update', changed); resolve(); };
      const changed = () => { if (output || session.state !== 'running') finish(); };
      const timer = setTimeout(finish, ms);
      session.events.on('update', changed);
    });
  }
  async run(command: string, cwd: string | undefined, waitMs: number) {
    const directory = await validateCwd(cwd);
    this.checkCapacity();
    const comspec = process.env.ComSpec ?? 'C:\\Windows\\System32\\cmd.exe';
    // CMD's /s quoting differs from C runtime quoting. Pass its command line verbatim.
    const child = spawn(comspec, ['/d', '/s', '/c', `"chcp 65001>nul & ${command}"`],
      { cwd: directory, shell: false, windowsHide: true, windowsVerbatimArguments: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const session = this.track(child, 'command');
    await this.wait(session, waitMs);
    return this.read(session.id, 0);
  }
  async start(executable: string, args: string[], cwd?: string) {
    const directory = await validateCwd(cwd);
    this.checkCapacity();
    const child = startChild(executable, args, directory);
    const session = this.track(child, 'process');
    await new Promise<void>(resolve => { child.once('spawn', resolve); child.once('error', () => resolve()); });
    if (session.state === 'failed') throw new Error(session.error ?? 'Process failed to start.');
    return { session_id: session.id, pid: session.pid, state: session.state, started_at: session.started_at };
  }
  read(id: string, requested?: number) {
    const session = this.get(id);
    const cursor = requested ?? session.readCursor;
    if (cursor > session.nextCursor) throw new Error('Cursor is beyond the current output.');
    const first = session.chunks[0]?.start ?? session.nextCursor;
    let next = Math.max(cursor, first), stdout = '', stderr = '', bytes = 0;
    for (const chunk of session.chunks) {
      if (chunk.end <= next) continue;
      const piece = prefixByBytes(chunk.text.slice(Math.max(0, next - chunk.start)), RESPONSE_BYTES - bytes);
      if (!piece) break;
      if (chunk.channel === 'stdout') stdout += piece; else stderr += piece;
      next = Math.max(chunk.start, next) + piece.length;
      bytes += Buffer.byteLength(piece);
      if (next < chunk.end || bytes >= RESPONSE_BYTES) break;
    }
    session.readCursor = next;
    return { session_id: id, kind: session.kind, pid: session.pid, started_at: session.started_at,
      state: session.state, stdout, stderr, exit_code: session.exit_code, cursor: next,
      truncated: next < session.nextCursor || cursor < first, output_lost: cursor < first,
      error: session.error };
  }
  async poll(id: string, cursor: number | undefined, waitMs: number) {
    const session = this.get(id);
    const effective = cursor ?? session.readCursor;
    if (effective >= session.nextCursor) await this.wait(session, waitMs, true);
    return this.read(id, cursor);
  }
  list(state: State | undefined, limit: number) {
    this.prune();
    return { sessions: [...this.sessions.values()].filter(s => !state || s.state === state).slice(-limit).reverse().map(s =>
      ({ session_id: s.id, kind: s.kind, pid: s.pid, state: s.state, started_at: s.started_at, exit_code: s.exit_code })) };
  }
  async stop(id: string) {
    const session = this.get(id);
    if (session.state === 'running' && session.pid) {
      // The root can exit before inherited stdout closes. Never act on its old PID.
      if (session.child.exitCode !== null || session.child.signalCode !== null) {
        session.state = 'completed';
        session.exit_code = session.child.exitCode;
        session.finished_at = Date.now();
        return this.read(id);
      }
      try { await stopTree(session.pid); }
      catch (error) { if (session.state === 'running') throw error; }
      if (session.state === 'running' || session.state === 'completed') session.state = 'stopped';
      await this.wait(session, 3000);
    }
    return this.read(id);
  }
  async shutdown(): Promise<void> {
    this.shuttingDown = true;
    const running = [...this.sessions.values()].filter(s => s.state === 'running');
    const results = await Promise.allSettled(running.map(s => this.stop(s.id)));
    if (results.some(r => r.status === 'rejected')) throw new Error('Some owned processes could not be stopped.');
  }
}
