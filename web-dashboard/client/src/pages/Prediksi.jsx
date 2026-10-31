import React, { useState } from 'react';
import {
  ResponsiveContainer, ComposedChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ReferenceArea,
  BarChart, Bar, Cell, LabelList,
} from 'recharts';
import { useApi } from '../api.js';
import { C, AXIS, ChartCard, Filters, Loading, Empty, Tip, valueLabel } from '../components/ui.jsx';
import { fmtInt, fmtPct, fmtCompact, fmtTglPendek, fmtTgl, isNum, NAMA_FITUR, fmtLabel } from '../format.js';

const METRIK = {
  Output: { label: 'Output', fmt: fmtInt, axis: fmtCompact, unit: ' pcs', higherBetter: true },
  Yield: { label: 'Yield', fmt: (v) => fmtPct(v, 2), axis: (v) => fmtPct(v, 1), unit: '', higherBetter: true },
  Defect: { label: 'Defect', fmt: (v) => fmtPct(v, 2), axis: (v) => fmtPct(v, 1), unit: '', higherBetter: false },
};

export default function Prediksi({ meta, f, setF, version }) {
  const [metric, setMetric] = useState('Output');
  const { data, error } = useApi('prediksi', { dept: f.dept, metric, from: f.from, to: f.to }, version);
  return (
    <>
      <div className="toolbar">
        <div className="seg big" role="group" aria-label="Pilih metrik">
          {Object.keys(METRIK).map((m) => (
            <button key={m} className={metric === m ? 'on' : ''} onClick={() => setMetric(m)}>{m}</button>
          ))}
        </div>
        <Filters meta={meta} f={f} setF={setF} show={['periode']} />
      </div>
      {!data || data.metric !== metric ? <Loading error={error} /> : <Isi d={data} />}
    </>
  );
}

function peringatan(d, M) {
  if (!d.model) return { level: 'info', judul: 'Model prediksi belum tersedia untuk departemen ini',
    teks: 'Model XGBoost akan dilatih setelah data produksi departemen ini terkumpul (jalankan train_to_sql.py).' };
  const fc = d.data.filter((r) => r.forecast && isNum(r.prediksi));
  if (!fc.length) return { level: 'info', judul: 'Belum ada prediksi', teks: 'Data fitur untuk hari berikutnya belum tersedia.' };
  const pesan = fc.map((r) => {
    if (!isNum(r.target)) return { r, buruk: false, gap: null };
    const gap = M.higherBetter ? r.prediksi - r.target : r.target - r.prediksi;
    const tol = d.metric === 'Output' ? r.target * 0.1 : 0;   // output: toleransi 10% dari plan
    return { r, buruk: gap < -tol, mepet: gap < 0, gap };
  });
  const buruk = pesan.filter((p) => p.buruk);
  const mepet = pesan.filter((p) => p.mepet && !p.buruk);
  const list = (arr) => arr.map((p) => `${fmtTgl(p.r.tanggal)}: ${M.fmt(p.r.prediksi)} (target ${M.fmt(p.r.target)})`).join(' · ');
  if (buruk.length) return { level: 'bad', judul: `Peringatan: ${M.label} diprediksi di bawah target`, teks: list(buruk) };
  if (mepet.length) return { level: 'warn', judul: `Perhatian: ${M.label} diprediksi sedikit di bawah target`, teks: list(mepet) };
  return { level: 'good', judul: `Aman: ${M.label} diprediksi memenuhi target`, teks: list(pesan) };
}

function Isi({ d }) {
  const M = METRIK[d.metric];
  const rows = d.data.map((r) => ({ ...r, prediksiHist: r.forecast ? null : r.prediksi, prediksiFc: null }));
  // garis putus-putus forecast disambung dari titik aktual terakhir
  const firstFc = rows.findIndex((r) => r.forecast);
  if (firstFc > 0) {
    const last = rows[firstFc - 1];
    last.prediksiFc = isNum(last.aktual) ? last.aktual : last.prediksi;
    for (let i = firstFc; i < rows.length; i++) rows[i].prediksiFc = rows[i].prediksi;
  } else if (firstFc === 0) {
    rows.forEach((r) => { if (r.forecast) r.prediksiFc = r.prediksi; });
  }
  const w = peringatan(d, M);
  const hist = d.data.filter((r) => !r.forecast && isNum(r.aktual) && isNum(r.prediksi));
  // akurasi = 1 - (total selisih / total aktual), dibatasi 0..100% supaya tidak pernah minus
  const sumAkt = hist.reduce((a, r) => a + Math.abs(r.aktual), 0);
  const sumErr = hist.reduce((a, r) => a + Math.abs(r.aktual - r.prediksi), 0);
  const akurasi = sumAkt > 0 ? Math.min(1, Math.max(0, 1 - sumErr / sumAkt)) : null;
  const fitur = d.fitur.filter((x) => x.nilai > 0).map((x) => ({ ...x, nama: NAMA_FITUR[x.fitur] || x.fitur }));
  const fc = d.data.filter((r) => r.forecast);

  return (
    <>
      <div className={`warning ${w.level}`} role="status">
        <div className="w-icon" aria-hidden>{w.level === 'bad' ? '!' : w.level === 'warn' ? '!' : w.level === 'good' ? '✓' : 'i'}</div>
        <div>
          <b>Early warning — {w.judul}</b>
          <p>{w.teks}</p>
        </div>
        <div className="w-stats">
          <div><small>Akurasi periode ini</small><b>{isNum(akurasi) ? fmtPct(akurasi, 1) : '–'}</b></div>
          <div><small>MAPE uji model</small><b>{d.model ? fmtPct(d.model.MAPE, 2) : '–'}</b></div>
        </div>
      </div>

      <div className="grid-pred">
        <ChartCard title={`${M.label}: Aktual vs Prediksi vs Target`} points={rows.length} height={300}
                   subtitle={fc.length ? `Area abu-abu = prediksi ${fc.length} hari ke depan` : ''}
                   legend={[{ label: 'Aktual', color: C.blue }, { label: 'Prediksi', color: C.orange, dash: true },
                            { label: 'Target', color: C.target, dash: true }]}
                   table={{ columns: ['Tanggal', 'Aktual', 'Prediksi', 'Target', 'Selisih'],
                            rows: d.data.map((r) => [fmtTgl(r.tanggal) + (r.forecast ? ' (prediksi)' : ''), M.fmt(r.aktual),
                                                     M.fmt(r.prediksi), M.fmt(r.target), isNum(r.ape) ? fmtPct(r.ape, 1) : '–']) }}>
          {rows.length === 0 ? <Empty /> : (
            <ResponsiveContainer>
              <ComposedChart data={rows} margin={{ top: 22, right: 26, left: 0, bottom: 0 }}>
                <CartesianGrid vertical={false} stroke={C.grid} />
                {firstFc >= 0 && (
                  <ReferenceArea x1={rows[Math.max(firstFc - 1, 0)].tanggal} x2={rows[rows.length - 1].tanggal}
                                 fill="#000" fillOpacity={0.05} stroke="none" ifOverflow="extendDomain" />
                )}
                <XAxis dataKey="tanggal" tickFormatter={fmtTglPendek} tick={AXIS} tickLine={false}
                       axisLine={{ stroke: C.grid }} interval={0} />
                <YAxis domain={d.metric === 'Output' ? [0, 'auto'] : ['auto', 'auto']} tickFormatter={M.axis}
                       tick={AXIS} tickLine={false} axisLine={false} width={52} />
                <Tooltip content={<Tip labelFmt={(l, p) => fmtTgl(l) + (p.forecast ? ' · PREDIKSI' : '')} rows={(p) => [
                  ...(p.forecast ? [] : [{ label: 'Aktual', value: M.fmt(p.aktual), color: C.blue }]),
                  { label: 'Prediksi', value: M.fmt(p.prediksi), color: C.orange },
                  { label: 'Target', value: M.fmt(p.target), color: C.target },
                  ...(isNum(p.ape) ? [{ label: 'Error', value: fmtPct(p.ape, 1) }] : []),
                ]} />} />
                <Line dataKey="target" stroke={C.target} strokeWidth={1.5} strokeDasharray="5 4" dot={false}
                      type="stepAfter" isAnimationActive={false} />
                <Line dataKey="prediksiHist" stroke={C.orange} strokeWidth={2} strokeDasharray="2 3" strokeOpacity={0.75}
                      dot={false} activeDot={false} isAnimationActive={false} />
                <Line dataKey="prediksiFc" stroke={C.orange} strokeWidth={2.5} strokeDasharray="6 4"
                      dot={{ r: 4, fill: C.orange, stroke: '#fff', strokeWidth: 2 }} isAnimationActive={false} />
                <Line dataKey="aktual" stroke={C.blue} strokeWidth={2}
                      dot={{ r: 3, fill: C.blue, stroke: '#fff', strokeWidth: 1.5 }} activeDot={{ r: 5 }} isAnimationActive={false}>
                  <LabelList dataKey="aktual" content={valueLabel(d.metric === 'Output' ? fmtInt : (v) => fmtPct(v, 1), { count: rows.length, color: C.blue })} />
                </Line>
              </ComposedChart>
            </ResponsiveContainer>
          )}
        </ChartCard>

        <ChartCard title="Feature Importance" subtitle={`Model ${d.model?.ModelVersion || ''} · ${M.label}`} height={300}
                   table={{ columns: ['Fitur', 'Kontribusi'], rows: fitur.map((x) => [x.nama, fmtPct(x.nilai, 1)]) }}>
          {fitur.length === 0 ? <Empty>Model belum dilatih.</Empty> : (
            <ResponsiveContainer>
              <BarChart data={fitur} layout="vertical" margin={{ top: 0, right: 44, left: 4, bottom: 0 }} barCategoryGap="22%">
                <XAxis type="number" hide domain={[0, 'dataMax']} />
                <YAxis type="category" dataKey="nama" tick={{ ...AXIS, fill: '#333' }} tickLine={false} axisLine={false} width={150} />
                <Tooltip cursor={{ fill: 'rgba(17,141,255,0.08)' }}
                         content={<Tip labelFmt={(_, p) => p.nama} rows={(p) => [{ label: 'Kontribusi (gain)', value: fmtPct(p.nilai, 1) }]} />} />
                <Bar dataKey="nilai" radius={[0, 4, 4, 0]} isAnimationActive={false}>
                  {fitur.map((x, i) => <Cell key={x.fitur} fill={i === 0 ? C.blue : '#7FBFFF'} />)}
                  <LabelList dataKey="nilai" position="right" formatter={(v) => fmtPct(v, 0)}
                             style={{ fontSize: 11, fill: '#444' }} />
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          )}
        </ChartCard>
      </div>

      {d.model && (
        <p className="note">
          Model XGBoost dilatih dengan {fmtInt(d.model.TrainRows)} hari data ({fmtTgl(d.model.TrainFrom)} – {fmtTgl(d.model.TrainTo)}).
          Prediksi dihitung langsung di SQL Server, jadi setiap POST baru langsung menghasilkan prediksi baru.
        </p>
      )}
    </>
  );
}
