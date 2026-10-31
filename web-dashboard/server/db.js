// Lapisan database: menjalankan query lewat db-bridge.ps1 (SqlClient + Windows Auth).
// Satu proses PowerShell dipakai terus (koneksi tetap terbuka), permintaan diantre.
'use strict';
const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');

// Windows PowerShell 5.1 kadang membungkus array menjadi {value:[...],Count:n}
function unwrap(a) {
  if (a && !Array.isArray(a) && typeof a === 'object' && Array.isArray(a.value)) return a.value;
  if (a === null || a === undefined) return [];
  return Array.isArray(a) ? a : [a];
}
function normSets(sets) { return unwrap(sets).map((s) => unwrap(s)); }

// Cari powershell.exe dengan path lengkap (PATH di sebagian laptop tidak memuat System32)
function findPowerShell() {
  if (process.env.PBL_POWERSHELL) return process.env.PBL_POWERSHELL;
  const fs = require('fs');
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows';
  const cands = [
    path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
    path.join(root, 'Sysnative', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
  ];
  for (const c of cands) { try { if (fs.existsSync(c)) return c; } catch { /* lanjut */ } }
  return 'powershell.exe';
}

class SqlBridge {
  constructor(connStr, log) {
    this.connStr = connStr;
    this.log = log || console.log;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map();
    this.ready = null;
  }

  start() {
    if (this.proc) return this.ready;
    const ps1 = path.join(__dirname, 'db-bridge.ps1');
    const args = ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                  '-File', ps1, '-ConnStr', this.connStr];
    this.proc = spawn(findPowerShell(), args, { windowsHide: true });
    let resolveReady, rejectReady;
    this.ready = new Promise((res, rej) => { resolveReady = res; rejectReady = rej; });
    this.ready.catch(() => {});

    readline.createInterface({ input: this.proc.stdout }).on('line', (line) => {
      let msg;
      try { msg = JSON.parse(line.replace(/^﻿/, '')); } catch { this.log('[db] keluaran non-JSON: ' + line); return; }
      if (msg.ready) { resolveReady(); return; }
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.ok) p.resolve(normSets(msg.sets));
      else p.reject(new Error(msg.error || 'Query gagal'));
    });
    this.proc.stderr.on('data', (d) => this.log('[db stderr] ' + d.toString().trim()));
    this.proc.on('exit', (code) => {
      this.log(`[db] bridge berhenti (kode ${code}), akan dijalankan ulang saat dibutuhkan`);
      rejectReady(new Error('Bridge database berhenti'));
      for (const p of this.pending.values()) p.reject(new Error('Bridge database berhenti'));
      this.pending.clear();
      this.proc = null;
    });
    this.proc.on('error', (e) => {
      this.log('[db] gagal menjalankan PowerShell: ' + e.message);
      rejectReady(e);
    });
    return this.ready;
  }

  // query(sql, params) -> array of result sets (array of row objects)
  async query(sql, params = {}) {
    await this.start();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('Query timeout')); }
      }, 120000);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.proc.stdin.write(JSON.stringify({ id, sql, params }) + '\n');
    });
  }

  stop() { if (this.proc) this.proc.kill(); }
}

module.exports = { SqlBridge };
