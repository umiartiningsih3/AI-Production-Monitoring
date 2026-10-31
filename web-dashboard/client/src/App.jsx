import React, { useEffect, useState } from 'react';
import { useApi, useLive } from './api.js';
import { addDays, fmtWaktu, fmtTgl } from './format.js';
import Ringkasan from './pages/Ringkasan.jsx';
import Tren from './pages/Tren.jsx';
import Prediksi from './pages/Prediksi.jsx';
import Defect from './pages/Defect.jsx';

const PAGES = [
  { id: 'ringkasan', label: 'Ringkasan Produksi', comp: Ringkasan },
  { id: 'tren', label: 'Pencapaian & Tren', comp: Tren },
  { id: 'prediksi', label: 'Aktual vs Prediksi', comp: Prediksi },
  { id: 'defect', label: 'Analisis Defect', comp: Defect },
];

const DEPT_DEFAULT = [
  { kode: 'HDC', nama: 'Hydrodissection Cannula' },
  { kode: 'SS', nama: 'Safety Series' },
];
const KOSONG = { from: '', to: '', produk: '', status: '', tahun: '' };

function readDept() {
  const m = window.location.search.match(/[?&]dept=([A-Za-z]+)/);
  if (m) return m[1].toUpperCase();
  try { return localStorage.getItem('pbl-dept') || 'HDC'; } catch { return 'HDC'; }
}

function readHash() {
  const h = window.location.hash.replace('#', '');
  return PAGES.some((p) => p.id === h) ? h : 'ringkasan';
}

export default function App() {
  const live = useLive();
  const [dept, setDeptState] = useState(readDept);
  const { data: metaRaw, error: metaErr } = useApi('meta', { dept }, live.version);
  const meta = metaRaw && metaRaw.dept === dept ? metaRaw : null;   // abaikan meta departemen sebelumnya
  const [page, setPage] = useState(readHash);
  const [f, setF] = useState({ ...KOSONG, dept });
  const departemen = (metaRaw && metaRaw.departemen && metaRaw.departemen.length) ? metaRaw.departemen : DEPT_DEFAULT;
  const namaDept = (departemen.find((d) => d.kode === dept) || {}).nama || dept;

  const setDept = (d) => {
    if (d === dept) return;
    try { localStorage.setItem('pbl-dept', d); } catch { /* abaikan */ }
    setDeptState(d);
    setF({ ...KOSONG, dept: d });     // filter direset: tiap departemen punya periode & produk sendiri
  };
  useEffect(() => { document.title = `Dashboard Produksi ${namaDept}`; }, [namaDept]);
  const [flash, setFlash] = useState(false);

  useEffect(() => {
    const onHash = () => setPage(readHash());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  // isi periode default (30 hari terakhir) setelah meta pertama kali datang
  useEffect(() => {
    if (!meta) return;
    setF((s) => {
      const n = { ...s };
      if (!s.to && meta.maxDate) n.to = meta.maxDate;
      if (!s.from && meta.maxDate) {
        const d = addDays(meta.maxDate, -29);
        n.from = meta.minDate && d < meta.minDate ? meta.minDate : d;
      }
      if (!s.tahun && meta.tahun && meta.tahun.length) n.tahun = String(meta.tahun[0]);
      return n;
    });
  }, [meta]);

  // periode tidak boleh mulai sebelum tanggal data pertama (mis. sisa tanggal bulan lalu)
  useEffect(() => {
    if (!meta || !meta.minDate) return;
    setF((s) => (s.from && s.from < meta.minDate ? { ...s, from: meta.minDate } : s));
  }, [meta && meta.minDate]);

  // kalau ada data baru dan periode sedang menempel ke tanggal terakhir, ikut geser
  useEffect(() => {
    if (!meta || !meta.maxDate) return;
    setF((s) => (s.to && s.to < meta.maxDate && s._follow !== false ? { ...s, to: meta.maxDate } : s));
  }, [meta && meta.maxDate]);

  useEffect(() => {
    if (!live.version) return;
    setFlash(true);
    const t = setTimeout(() => setFlash(false), 2500);
    return () => clearTimeout(t);
  }, [live.version]);

  const Page = PAGES.find((p) => p.id === page).comp;
  const ready = meta && f.from && f.to;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <div className="logo" aria-hidden>
            <svg viewBox="0 0 32 32" width="30" height="30">
              <rect width="32" height="32" rx="7" fill="#118DFF" />
              <rect x="7" y="17" width="4" height="8" rx="1" fill="#fff" />
              <rect x="14" y="11" width="4" height="14" rx="1" fill="#fff" />
              <rect x="21" y="7" width="4" height="18" rx="1" fill="#fff" />
            </svg>
          </div>
          <div>
            <h1>Monitoring &amp; Prediksi Produksi</h1>
            <p>PBLIF3-MD04</p>
          </div>
        </div>
        <div className="dept" role="group" aria-label="Pilih departemen">
          {departemen.map((d) => (
            <button key={d.kode} className={d.kode === dept ? 'on' : ''} aria-pressed={d.kode === dept}
                    onClick={() => setDept(d.kode)}>{d.nama}</button>
          ))}
        </div>
        <div className={`live ${live.connected ? 'on' : 'off'} ${flash ? 'flash' : ''}`}>
          <span className="dot" />
          <div>
            <b>{live.connected ? (flash ? 'Data baru masuk' : 'Live') : 'Menyambung ulang…'}</b>
            <small>
              Update terakhir: {fmtWaktu(meta?.lastUpdate)}
              {meta?.lastDataDate && <> · Data s/d {fmtTgl(meta.lastDataDate)}</>}
            </small>
          </div>
        </div>
      </header>

      <nav className="tabs" role="tablist">
        {PAGES.map((p) => (
          <a key={p.id} href={`#${p.id}`} role="tab" aria-selected={page === p.id}
             className={page === p.id ? 'active' : ''}>{p.label}</a>
        ))}
      </nav>

      <main className="content">
        {metaErr && <div className="state error">Tidak bisa terhubung ke server/database: {metaErr.message}</div>}
        {!metaErr && meta && !meta.maxDate && (
          <div className="state empty-db">
            <b>Belum ada data {namaDept}.</b>
            <p>Buka file Excel macro {namaDept} lalu klik tombol <b>POST</b>. Dashboard akan terisi otomatis dalam beberapa detik.</p>
          </div>
        )}
        {!metaErr && !ready && !(meta && !meta.maxDate) && <div className="state">Memuat…</div>}
        {ready && <Page key={dept} meta={meta} f={f} setF={(n) => setF({ ...n, dept, _follow: n.to === meta.maxDate })} version={live.version} />}
      </main>

      <footer className="foot">
        Sumber: SQL Server · PBL_MonitoringProduksi · Model {meta?.modelVersion || '-'} (XGBoost) ·
        Data diperbarui otomatis setiap kali tombol POST di Excel ditekan
      </footer>
    </div>
  );
}
