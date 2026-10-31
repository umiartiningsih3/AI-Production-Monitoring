// =====================================================================
//  Server web dashboard PBLIF3-MD04
//  - API JSON  : /api/meta, /api/ringkasan, /api/tren, /api/prediksi, /api/defect
//  - Real-time : /api/events (Server-Sent Events). Server mengecek SQL Server
//                tiap 3 detik; begitu VBA melakukan POST, semua browser yang
//                terbuka langsung diberi tahu dan memuat ulang datanya.
//  - Frontend  : file hasil build React di client/dist
//  Tanpa dependency npm (hanya modul bawaan Node.js).
// =====================================================================
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { SqlBridge } = require('./db');
const { SQL } = require('./queries');

const ROOT = path.join(__dirname, '..');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.json'), 'utf8'));
const PORT = Number(process.env.PORT || cfg.port || 3000);
const DIST = path.join(ROOT, 'client', 'dist');
const LOG_DIR = path.join(ROOT, 'logs');
fs.mkdirSync(LOG_DIR, { recursive: true });
const LOG_FILE = path.join(LOG_DIR, 'server.log');

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch { /* abaikan */ }
}

const db = new SqlBridge(cfg.connectionString, log);

// ---------- util ----------
const isDate = (s) => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s);
const str = (v) => (v === undefined || v === null || v === '' || v === 'all' ? null : String(v).slice(0, 200));
const num = (v) => (v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));

function addDays(iso, n) {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// departemen: kode HDC / SS, nama lengkapnya ada di tabel tblBA204_Departemen
const deptOf = (q) => (q && /^[A-Za-z]{1,10}$/.test(q.dept || '') ? q.dept.toUpperCase() : 'HDC');

let metaCache = {};
async function getMeta(dept, force) {
  if (metaCache[dept] && !force) return metaCache[dept];
  const [depts, sku, status, range, years, info, model] = await db.query(SQL.meta, { dept });
  metaCache[dept] = {
    dept,
    departemen: depts.map((r) => ({ kode: r.Dept, nama: r.Nama })),
    produk: sku.map((r) => r.SKU),
    status: status.map((r) => r.StatusPO),
    minDate: range[0] ? range[0].MinDate : null,
    maxDate: range[0] ? range[0].MaxDate : null,
    tahun: years.map((r) => r.Tahun),
    lastUpdate: info[0] ? info[0].LastUpdate : null,
    lastDataDate: range[0] ? range[0].MaxDate : null,
    modelVersion: model[0] ? model[0].ModelVersion : null,
  };
  return metaCache[dept];
}

// periode default = 30 hari terakhir sampai tanggal data terakhir
async function periode(q) {
  const m = await getMeta(deptOf(q));
  let to = isDate(q.to) ? q.to : (m.maxDate || new Date().toISOString().slice(0, 10));
  let from = isDate(q.from) ? q.from : addDays(to, -29);
  if (from > to) [from, to] = [to, from];
  return { from, to };
}
const filterPO = (q) => ({ dept: deptOf(q), sku: str(q.produk), status: str(q.status) });

// ---------- handler API ----------
const DIAG = {
  po: 'SELECT n = COUNT(*) FROM dbo.vw_PBI_PO',
  out: 'SELECT n = COUNT(*) FROM dbo.vw_PBI_OutputPO',
  plan: 'SELECT n = COUNT(*) FROM dbo.vw_PBI_Plan',
  prod: 'SELECT n = COUNT(*) FROM dbo.vw_PBI_Produktivitas',
  defect: 'SELECT n = COUNT(*) FROM dbo.vw_PBI_Defect',
  harian: 'SELECT n = COUNT(*) FROM dbo.vw_Harian',
  fitur: 'SELECT n = COUNT(*) FROM dbo.vw_Fitur',
  pred: "SELECT n = COUNT(*) FROM dbo.vw_PBI_Prediksi WHERE Metric = N'Output'",
  token: SQL.token,
};

const api = {
  async meta(q) { return getMeta(deptOf(q)); },

  // cek kecepatan tiap view: /api/diag?q=po
  async diag(q) {
    const sql = DIAG[q.q];
    if (!sql) return { pilihan: Object.keys(DIAG) };
    const t0 = Date.now();
    const sets = await db.query(sql);
    return { q: q.q, ms: Date.now() - t0, hasil: sets[0] };
  },

  async ringkasan(q) {
    const p = await periode(q);
    const [kpi, plan, prod, wip, harian] = await db.query(SQL.ringkasan, { ...p, ...filterPO(q) });
    const k = kpi[0] || {}, pl = plan[0] || {}, pr = prod[0] || {}, w = wip[0] || {};
    const total = (k.Output_ || 0) + (k.Scrap || 0);
    return {
      periode: p,
      kpi: {
        output: k.Output_ || 0,
        plan: pl.PlanOutput || 0,
        scrap: k.Scrap || 0,
        yield: total ? k.Output_ / total : null,
        defect: total ? k.Scrap / total : null,
        targetYield: pl.TargetYield ?? 0.975,
        productivity: pr.Productivity ?? null,
        actualMHP: pr.ActualMHP ?? null,
        wip: w.WIP || 0,
        poTotal: w.POTotal || 0,
        poSelesai: w.POSelesai || 0,
        progresPO: w.POTotal ? w.POSelesai / w.POTotal : null,
      },
      harian: harian.map((r) => {
        const t = (r.Output_ || 0) + (r.Scrap || 0);
        return {
          tanggal: r.Tanggal, output: r.Output_, plan: r.PlanOutput, scrap: r.Scrap,
          yield: t ? r.Output_ / t : null, target: r.TargetYield ?? null,
        };
      }),
    };
  },

  async tren(q) {
    const m = await getMeta(deptOf(q));
    const semua = q.tahun === 'semua';
    const year = semua ? 0 : (num(q.tahun) || (m.tahun && m.tahun[0]) || new Date().getFullYear());
    const [bulanan, harian] = await db.query(SQL.tren, { year, ...filterPO(q) });
    const bulan = bulanan.map((r) => {
      const t = (r.Output_ || 0) + (r.Scrap || 0);
      return { tahun: r.Tahun, bulan: r.Bulan, output: r.Output_, plan: r.PlanOutput, scrap: r.Scrap,
               yield: t ? r.Output_ / t : null,
               capaian: r.PlanOutput ? r.Output_ / r.PlanOutput : null };
    });
    const last = [...bulan].reverse().find((b) => b.output > 0) || null;
    const ytdOut = bulan.reduce((a, b) => a + (b.output || 0), 0);
    const ytdPlan = bulan.reduce((a, b) => a + (b.plan || 0), 0);
    return {
      tahun: semua ? 'semua' : year,
      bulanTerakhir: last,
      ytd: { output: ytdOut, plan: ytdPlan, capaian: ytdPlan ? ytdOut / ytdPlan : null },
      bulanan: bulan,
      harian: harian.map((r) => ({ tanggal: r.Tanggal, output: r.Output_ })),
    };
  },

  async prediksi(q) {
    const metric = ['Output', 'Yield', 'Defect'].includes(q.metric) ? q.metric : 'Output';
    const p = await periode(q);
    const [rows, fi, info] = await db.query(SQL.prediksi, { ...p, metric, dept: deptOf(q) });
    return {
      metric, periode: p,
      data: rows.map((r) => ({ tanggal: r.Tanggal, aktual: r.Aktual, prediksi: r.Prediksi,
                               target: r.Target, forecast: !!r.IsForecast, ape: r.APE })),
      fitur: fi.map((r) => ({ fitur: r.Feature, nilai: r.Importance })),
      model: info[0] || null,
    };
  },

  async defect(q) {
    const p = await periode(q);
    const [tot, jenis, proses, tren] = await db.query(SQL.defect, { ...p, ...filterPO(q) });
    const t = tot[0] || {};
    const all = (t.Output_ || 0) + (t.Scrap || 0);
    const next = tren.find((r) => r.IsForecast) || null;
    return {
      periode: p,
      defectRate: all ? t.Scrap / all : null,
      scrap: t.Scrap || 0,
      prediksiBesok: next ? { tanggal: next.Tanggal, nilai: next.Prediksi } : null,
      jenis: jenis.map((r) => ({ nama: r.RejectName || '(tanpa nama)', kode: r.RejectCode, qty: r.Qty })),
      proses: proses.map((r) => ({ nama: r.Process || '-', qty: r.Qty })),
      tren: tren.map((r) => ({ tanggal: r.Tanggal, aktual: r.Aktual, prediksi: r.Prediksi, forecast: !!r.IsForecast })),
    };
  },
};

// ---------- cache hasil API ----------
const apiCache = new Map();

// ---------- real-time (SSE) ----------
const clients = new Set();
let lastToken = null;
let version = 0;

async function poll() {
  try {
    const [[row]] = await db.query(SQL.token);
    const tok = row ? row.Token : '';
    if (lastToken !== null && tok !== lastToken) {
      version++;
      metaCache = {};
      apiCache.clear();
      log(`[realtime] data berubah (versi ${version}), memberi tahu ${clients.size} browser`);
      broadcast('update', { version, at: new Date().toISOString() });
    }
    lastToken = tok;
  } catch (e) {
    log('[realtime] gagal cek perubahan: ' + e.message);
  } finally {
    setTimeout(poll, cfg.pollMs || 3000);
  }
}

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) res.write(msg);
}
setInterval(() => { for (const res of clients) res.write(': ping\n\n'); }, 25000);

// ---------- file statis ----------
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.ico': 'image/x-icon', '.json': 'application/json', '.woff2': 'font/woff2',
};

function serveStatic(req, res, pathname) {
  let file = path.normalize(path.join(DIST, decodeURIComponent(pathname)));
  if (!file.startsWith(DIST)) { res.writeHead(403); return res.end(); }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) file = path.join(DIST, 'index.html');   // SPA fallback
    fs.readFile(file, (e2, buf) => {
      if (e2) {
        res.writeHead(503, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end('<meta http-equiv="refresh" content="3"><p style="font-family:sans-serif">' +
          'Tampilan dashboard sedang di-build… halaman ini akan muncul otomatis.</p>');
      }
      const ext = path.extname(file).toLowerCase();
      res.writeHead(200, {
        'Content-Type': MIME[ext] || 'application/octet-stream',
        'Cache-Control': ext === '.html' ? 'no-cache' : 'public, max-age=31536000, immutable',
      });
      res.end(buf);
    });
  });
}

// ---------- server ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const p = url.pathname;
  if (p === '/api/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache',
                         Connection: 'keep-alive' });
    res.write(`event: hello\ndata: ${JSON.stringify({ version })}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (p.startsWith('/api/')) {
    const name = p.slice(5);
    const fn = api[name];
    if (!fn) { res.writeHead(404, { 'Content-Type': 'application/json' }); return res.end('{"error":"not found"}'); }
    const q = Object.fromEntries(url.searchParams);
    const t0 = Date.now();
    try {
      // hasil disimpan sampai ada POST baru (versi berubah); permintaan sama yang
      // datang bersamaan cukup dijalankan sekali
      const key = `${version}|${name}|${url.searchParams.toString()}`;
      let pending = name === 'diag' || name === 'migrasi' ? null : apiCache.get(key);
      if (!pending) {
        pending = fn(q);
        if (name !== 'diag' && name !== 'migrasi') {
          apiCache.set(key, pending);
          pending.catch(() => apiCache.delete(key));
          if (apiCache.size > 300) apiCache.delete(apiCache.keys().next().value);
        }
      }
      const data = await pending;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
      log(`GET ${req.url} ${Date.now() - t0}ms`);
    } catch (e) {
      log(`GET ${req.url} ERROR ${e.message}`);
      res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }
  serveStatic(req, res, p === '/' ? '/index.html' : p);
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    log(`[X] Port ${PORT} sudah dipakai. Tutup dulu jendela dashboard lain (START.bat) yang masih terbuka, lalu jalankan START.bat lagi.`);
  } else log('[X] server error: ' + e.message);
  setTimeout(() => process.exit(1), 300);
});
server.listen(PORT, () => {
  log(`Dashboard berjalan di http://localhost:${PORT}  (node ${process.version})`);
  db.start().then(() => { log('[db] terhubung ke SQL Server'); poll(); })
    .catch((e) => { log('[db] gagal start: ' + e.message); setTimeout(poll, 3000); });
});
process.on('uncaughtException', (e) => log('uncaught: ' + (e.stack || e.message)));
process.on('unhandledRejection', (e) => log('unhandled: ' + ((e && e.stack) || e)));
