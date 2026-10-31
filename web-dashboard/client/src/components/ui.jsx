import React, { useState } from 'react';
import { addDays } from '../format.js';

// Palet (gaya Power BI, sudah dicek kontras & buta warna)
export const C = {
  blue: '#118DFF',
  navy: '#2B3FC4',
  orange: '#E66C37',
  purple: '#8A1F9E',
  pink: '#E044A7',
  target: '#6B6B6B',
  grid: '#E6E6E6',
  axis: '#8A8A8A',
  good: '#1A9E55',
  warn: '#C98A00',
  bad: '#D13438',
};
export const AXIS = { fontSize: 11, fill: '#5F5F5F' };

export function KpiCard({ label, value, sub, status, accent = C.blue }) {
  return (
    <div className="kpi" style={{ borderLeftColor: accent }}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && (
        <div className={`kpi-sub ${status || ''}`}>
          {status === 'good' && <span aria-hidden>▲ </span>}
          {status === 'bad' && <span aria-hidden>▼ </span>}
          {status === 'warn' && <span aria-hidden>● </span>}
          {sub}
        </div>
      )}
    </div>
  );
}

// Kartu grafik + tombol "Tabel" untuk melihat angka mentahnya
export function ChartCard({ title, subtitle, legend, table, children, height = 260, className = '' }) {
  const [showTable, setShowTable] = useState(false);
  return (
    <section className={`card ${className}`}>
      <header className="card-head">
        <div>
          <h3>{title}</h3>
          {subtitle && <p className="card-sub">{subtitle}</p>}
        </div>
        <div className="card-tools">
          {legend && <Legend items={legend} />}
          {table && (
            <button className="link-btn" onClick={() => setShowTable((v) => !v)}>
              {showTable ? 'Grafik' : 'Tabel'}
            </button>
          )}
        </div>
      </header>
      {showTable && table ? (
        <div className="table-wrap" style={{ maxHeight: height }}>
          <table>
            <thead><tr>{table.columns.map((c) => <th key={c}>{c}</th>)}</tr></thead>
            <tbody>
              {table.rows.map((r, i) => <tr key={i}>{r.map((v, j) => <td key={j}>{v}</td>)}</tr>)}
            </tbody>
          </table>
        </div>
      ) : (
        <div style={{ height }}>{children}</div>
      )}
    </section>
  );
}

export function Legend({ items }) {
  return (
    <ul className="legend">
      {items.map((it) => (
        <li key={it.label}>
          <svg width="18" height="10" aria-hidden>
            {it.type === 'bar' ? (
              <rect x="3" y="0" width="12" height="10" rx="2" fill={it.color} />
            ) : (
              <line x1="0" y1="5" x2="18" y2="5" stroke={it.color} strokeWidth="2"
                    strokeDasharray={it.dash ? '4 3' : undefined} />
            )}
          </svg>
          {it.label}
        </li>
      ))}
    </ul>
  );
}

// Tooltip seragam untuk semua grafik
export function Tip({ active, payload, label, labelFmt, rows }) {
  if (!active || !payload || !payload.length) return null;
  const p0 = payload[0].payload;
  return (
    <div className="tip">
      <div className="tip-title">{labelFmt ? labelFmt(label, p0) : label}</div>
      {rows(p0).map((r) => (
        <div className="tip-row" key={r.label}>
          <span className="tip-key">
            {r.color && <i style={{ background: r.color }} />}
            {r.label}
          </span>
          <b>{r.value}</b>
        </div>
      ))}
    </div>
  );
}

// Nama SKU asli tidak ditampilkan; hanya ukurannya (mis. "Produk 25G 8MM")
export function labelProduk(sku, i) {
  const m = String(sku || '').match(/(\d+\s*G)\b.*?(\d+(?:[.,]\d+)?\s*MM)\b/i);
  return m ? `Produk ${m[1].replace(/\s+/g, '').toUpperCase()} ${m[2].replace(/\s+/g, '').toUpperCase()}` : `Produk ${i + 1}`;
}

export function Filters({ meta, f, setF, show = ['periode', 'produk', 'status'] }) {
  const maxD = meta?.maxDate;
  const preset = (n) => maxD && setF({ ...f, from: addDays(maxD, -(n - 1)), to: maxD });
  return (
    <div className="filters">
      {show.includes('periode') && (
        <div className="fgroup">
          <label>Periode</label>
          <div className="periode">
            <input type="date" value={f.from || ''} max={f.to || undefined}
                   onChange={(e) => setF({ ...f, from: e.target.value })} />
            <span>s/d</span>
            <input type="date" value={f.to || ''} min={f.from || undefined}
                   onChange={(e) => setF({ ...f, to: e.target.value })} />
            <div className="seg">
              {[7, 14, 30].map((n) => (
                <button key={n} onClick={() => preset(n)}
                        className={maxD && f.to === maxD && f.from === addDays(maxD, -(n - 1)) ? 'on' : ''}>
                  {n} hr
                </button>
              ))}
              <button onClick={() => meta && setF({ ...f, from: meta.minDate, to: meta.maxDate })}
                      className={meta && f.from === meta.minDate && f.to === meta.maxDate ? 'on' : ''}>Semua</button>
            </div>
          </div>
        </div>
      )}
      {show.includes('tahun') && (
        <div className="fgroup">
          <label>Tahun</label>
          <select value={f.tahun || ''} onChange={(e) => setF({ ...f, tahun: e.target.value })}>
            {(meta?.tahun || []).map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      )}
      {show.includes('produk') && (
        <div className="fgroup">
          <label>Produk</label>
          <select value={f.produk || ''} onChange={(e) => setF({ ...f, produk: e.target.value })}>
            <option value="">Semua produk</option>
            {(meta?.produk || []).map((p, i) => <option key={p} value={p}>{labelProduk(p, i)}</option>)}
          </select>
        </div>
      )}
      {show.includes('status') && (
        <div className="fgroup">
          <label>Status PO</label>
          <select value={f.status || ''} onChange={(e) => setF({ ...f, status: e.target.value })}>
            <option value="">Semua status</option>
            {(meta?.status || []).map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
      )}
    </div>
  );
}

export function Loading({ error }) {
  if (error) return <div className="state error">Gagal memuat data: {error.message}</div>;
  return <div className="state">Memuat data…</div>;
}

export function Empty({ children = 'Belum ada data untuk filter ini.' }) {
  return <div className="state">{children}</div>;
}

// Label angka di atas tiap titik/batang grafik.
// Kalau titiknya banyak (> 16), teks diputar tegak supaya tidak bertumpuk.
export function valueLabel(fmt, { count = 0, color = '#333', min = null } = {}) {
  const tegak = count > 16;
  return function Label(props) {
    const { x, y, width, value } = props;
    if (value === null || value === undefined || Number.isNaN(value)) return null;
    if (min !== null && value <= min) return null;
    const cx = x + (width ? width / 2 : 0);
    const cy = y - 6;
    const text = fmt(value);
    return tegak ? (
      <text x={cx} y={cy} transform={`rotate(-90 ${cx} ${cy})`} textAnchor="start" dominantBaseline="central"
            fontSize={10} fill={color} style={{ pointerEvents: 'none' }}>{text}</text>
    ) : (
      <text x={cx} y={cy} textAnchor="middle" fontSize={10} fill={color} style={{ pointerEvents: 'none' }}>{text}</text>
    );
  };
}
