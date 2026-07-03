// Durable session state on bun:sqlite. Lets Jarvis survive a respring/relaunch
// mid-task: on boot, load(id) rehydrates messages + summary + pinned state and
// the loop picks up where it left off. One row per session; the snapshot is
// stored as JSON because the message shape is the SDK's, not ours to normalise.

import { Database } from "bun:sqlite";
import type { SessionSnapshot, SessionStore } from "./harness";

export class SqliteStore implements SessionStore {
  private db: Database;

  constructor(path = "jarvis.sqlite") {
    this.db = new Database(path);
    this.db.run("PRAGMA journal_mode = WAL");
    this.db.run(
      `CREATE TABLE IF NOT EXISTS sessions (
        id      TEXT PRIMARY KEY,
        snapshot TEXT NOT NULL,
        updated  INTEGER NOT NULL
      )`,
    );
  }

  async save(s: SessionSnapshot): Promise<void> {
    this.db
      .query("INSERT OR REPLACE INTO sessions (id, snapshot, updated) VALUES (?, ?, ?)")
      .run(s.id, JSON.stringify(s), Date.now());
  }

  async load(id: string): Promise<SessionSnapshot | null> {
    const row = this.db
      .query<{ snapshot: string }, [string]>("SELECT snapshot FROM sessions WHERE id = ?")
      .get(id);
    return row ? (JSON.parse(row.snapshot) as SessionSnapshot) : null;
  }
}

// Audit log lives in the same db, append-only. Non-negotiable for an agent with
// filesystem + input-injection reach: every gated call, allowed or not, lands here.
export class SqliteAudit {
  private db: Database;
  constructor(path = "jarvis.sqlite") {
    this.db = new Database(path);
    this.db.run(
      `CREATE TABLE IF NOT EXISTS audit (
        ts INTEGER, sessionId TEXT, tool TEXT, scope TEXT,
        capabilities TEXT, mode TEXT, allowed INTEGER
      )`,
    );
  }
  write = (e: {
    ts: number;
    sessionId: string;
    tool: string;
    scope: string;
    capabilities: string[];
    mode: string;
    allowed: boolean;
  }) => {
    this.db
      .query(
        "INSERT INTO audit (ts, sessionId, tool, scope, capabilities, mode, allowed) VALUES (?,?,?,?,?,?,?)",
      )
      .run(e.ts, e.sessionId, e.tool, e.scope, e.capabilities.join(","), e.mode, e.allowed ? 1 : 0);
  };

  recent(limit = 50) {
    return this.db
      .query<
        { ts: number; tool: string; scope: string; mode: string; allowed: number },
        [number]
      >("SELECT ts, tool, scope, mode, allowed FROM audit ORDER BY ts DESC LIMIT ?")
      .all(limit)
      .map((r) => ({ ...r, allowed: !!r.allowed }));
  }
}
