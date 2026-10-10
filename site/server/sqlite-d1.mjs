import { closeSync, constants, fchmodSync, mkdirSync, openSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

// The relay only needs this small subset of D1. Statements are prepared lazily
// so a schema batch can create a table before preparing its indexes.
class SQLiteStatement {
  constructor(database, sql, parameters = []) {
    this.database = database;
    this.sql = sql;
    this.parameters = parameters;
  }

  bind(...parameters) {
    return new SQLiteStatement(this.database, this.sql, parameters);
  }

  first(column) {
    const row = this.database.connection.prepare(this.sql).get(...this.parameters);
    return Promise.resolve(column === undefined ? row ?? null : row?.[column] ?? null);
  }

  all() {
    return Promise.resolve({
      success: true,
      results: this.database.connection.prepare(this.sql).all(...this.parameters),
      meta: {},
    });
  }

  run() {
    return Promise.resolve(this.runSync());
  }

  runSync() {
    const result = this.database.connection.prepare(this.sql).run(...this.parameters);
    return {
      success: true,
      results: [],
      meta: { changes: Number(result.changes), last_row_id: Number(result.lastInsertRowid) },
    };
  }
}

export class SQLiteD1Database {
  constructor(filePath) {
    if (!filePath || filePath === ":memory:") {
      throw new Error("A durable database file is required.");
    }
    this.filePath = resolve(filePath);
    mkdirSync(dirname(this.filePath), { recursive: true, mode: 0o700 });
    // Set the mode before SQLite creates its WAL/SHM files. Refuse an existing
    // symlink instead of accidentally opening a different database.
    const descriptor = openSync(this.filePath, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
    try { fchmodSync(descriptor, 0o600); }
    finally { closeSync(descriptor); }
    this.connection = new DatabaseSync(this.filePath, { enableForeignKeyConstraints: true });
    this.closed = false;
    try {
      this.connection.exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;");
    } catch (error) {
      this.close();
      throw error;
    }
  }

  prepare(sql) {
    return new SQLiteStatement(this, sql);
  }

  batch(statements) {
    this.connection.exec("BEGIN IMMEDIATE");
    try {
      const results = statements.map(statement => {
        if (!(statement instanceof SQLiteStatement) || statement.database !== this) {
          throw new Error("A batch statement belongs to a different database.");
        }
        return statement.runSync();
      });
      this.connection.exec("COMMIT");
      return Promise.resolve(results);
    } catch (error) {
      this.connection.exec("ROLLBACK");
      throw error;
    }
  }

  close() {
    if (this.closed) return;
    this.connection.close();
    this.closed = true;
  }
}
