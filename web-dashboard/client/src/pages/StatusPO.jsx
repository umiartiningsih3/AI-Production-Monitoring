import React, { useState } from 'react';
import { ResponsiveContainer, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, LabelList, Cell } from 'recharts';
import { useApi } from '../api.js';
import { C, AXIS, KpiCard, ChartCard, Filters, Loading, Empty, Tip, labelProduk } from '../components/ui.jsx';
import { fmtInt, fmtTgl } from '../format.js';

// Monitoring PO yang belum closed: posisi proses sekarang, WIP, umur PO, aktivitas terakhir
export default function StatusPO({ meta, f, setF, version }) {
  const { data, error } = useApi('statusPO', { dept: f.dept, produk: f.produk }, version);
  return (
    <>
      <Filters meta={meta} f={f} setF={setF} show={['produk']} />
      {!data ? <Loading error={error} /> : <Isi d={data} meta={meta} />}
    </>
  );
}

const DIAM_BATAS = 3;   // PO dianggap "tidak bergerak" kalau tidak ada aktivitas >= 3 hari

function Isi({ d, meta }) {
  const [semua, setSemua] = useState(false);
  const [cari, setCari] = useState('');
  const terbuka = d.daftar.filter((p) => !p.closed);
  const tampil = (semua ? d.daftar : terbuka)
    .filter((p) => !cari || String(p.po).includes(cari.trim()) || String(p.batch || '').includes(cari.trim()))
    .sort((a, b) => (a.closed - b.closed) || ((b.umur ?? -1) - (a.umur ?? -1)));
  const totalWip = terbuka.reduce((a, p) => a + p.wip, 0);
  const terlama = terbuka.reduce((m, p) => (p.umur !== null && (!m || p.umur > m.umur) ? p : m), null);
  const diam = terbuka.filter((p) => p.diam !== null && p.diam >= DIAM_BATAS);
  const produkIdx = (sku) => Math.max(0, (meta?.produk || []).indexOf(sku));

  // jumlah PO terbuka per posisi proses, urut sesuai alur
  const perPosisi = d.proses.map((pr) => ({
    proses: pr,
    po: terbuka.filter((p) => p.posisi === pr).length,
    wip: terbuka.filter((p) => p.posisi === pr).reduce((a, p) => a + p.wip, 0),
  }));
  const belumMulai = terbuka.filter((p) => !p.posisi).length;
  if (belumMulai) perPosisi.unshift({ proses: 'Belum mulai', po: belumMulai, wip: 0 });

  return (
    <>
      <div className="kpis kpis-4">
        <KpiCard label="PO belum closed" value={fmtInt(terbuka.length)} accent={C.blue}
                 sub={`dari ${fmtInt(d.daftar.length)} PO · data s/d ${fmtTgl(d.tglData)}`}
                 status={terbuka.length ? 'warn' : 'good'} />
        <KpiCard label="Total WIP (pcs)" value={fmtInt(totalWip)} accent={C.pink}
                 sub="Sudah masuk proses awal, belum selesai proses akhir" />
        <KpiCard label="PO paling lama terbuka" value={terlama ? `${fmtInt(terlama.umur)} hari` : '–'} accent={C.orange}
                 sub={terlama ? `PO ${terlama.po} · posisi ${terlama.posisi || 'belum mulai'}` : 'Tidak ada PO terbuka'} />
        <KpiCard label={`Tidak bergerak ≥ ${DIAM_BATAS} hari`} value={fmtInt(diam.length)} accent={C.purple}
                 sub={diam.length ? diam.slice(0, 3).map((p) => p.po).join(', ') + (diam.length > 3 ? ', …' : '') : 'Semua PO terbuka masih bergerak'}
                 status={diam.length ? 'bad' : 'good'} />
      </div>

      <ChartCard title="Posisi PO yang belum closed" subtitle="Jumlah PO per proses yang sedang berjalan (urut sesuai alur proses)"
                 height={220}
                 table={{ columns: ['Proses', 'Jumlah PO', 'WIP (pcs)'], rows: perPosisi.map((x) => [x.proses, fmtInt(x.po), fmtInt(x.wip)]) }}>
        {terbuka.length === 0 ? <Empty>Semua PO sudah closed.</Empty> : (
          <ResponsiveContainer>
            <BarChart data={perPosisi} margin={{ top: 22, right: 8, left: 0, bottom: 0 }} barCategoryGap="30%">
              <CartesianGrid vertical={false} stroke={C.grid} />
              <XAxis dataKey="proses" tick={{ ...AXIS, fill: '#333' }} tickLine={false} axisLine={{ stroke: C.grid }} interval={0} />
              <YAxis allowDecimals={false} tick={AXIS} tickLine={false} axisLine={false} width={36} />
              <Tooltip cursor={{ fill: 'rgba(17,141,255,0.08)' }}
                       content={<Tip labelFmt={(_, p) => p.proses} rows={(p) => [
                         { label: 'Jumlah PO', value: fmtInt(p.po), color: C.blue },
                         { label: 'WIP', value: fmtInt(p.wip) + ' pcs' }]} />} />
              <Bar dataKey="po" radius={[4, 4, 0, 0]} maxBarSize={60} isAnimationActive={false}>
                {perPosisi.map((x) => <Cell key={x.proses} fill={x.proses === 'Belum mulai' ? '#9A9A9A' : C.blue} />)}
                <LabelList dataKey="po" position="top" formatter={(v) => (v ? `${fmtInt(v)} PO` : '')} style={{ fontSize: 11, fill: '#333' }} />
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        )}
      </ChartCard>

      <section className="card">
        <header className="card-head">
          <div>
            <h3>Daftar Status PO</h3>
            <p className="card-sub">Posisi proses tiap PO. Lingkaran biru = proses yang sedang berjalan, hijau = sudah dikerjakan, abu-abu = belum.</p>
          </div>
          <div className="card-tools">
            <input className="cari-po" placeholder="Cari no. PO / batch" value={cari} onChange={(e) => setCari(e.target.value)} />
            <div className="seg">
              <button className={!semua ? 'on' : ''} onClick={() => setSemua(false)}>Belum closed ({terbuka.length})</button>
              <button className={semua ? 'on' : ''} onClick={() => setSemua(true)}>Semua PO ({d.daftar.length})</button>
            </div>
          </div>
        </header>
        {tampil.length === 0 ? (
          <Empty>{semua || cari ? 'Tidak ada PO yang cocok.' : 'Semua PO sudah closed. Pilih "Semua PO" untuk melihat riwayatnya.'}</Empty>
        ) : (
          <div className="table-wrap po-table">
            <table>
              <thead>
                <tr>
                  <th>No. PO</th><th>Produk</th><th>Batch</th><th>Status</th><th>Posisi sekarang</th>
                  <th>Alur proses (good output)</th><th className="num">WIP</th><th>Mulai</th><th>Aktivitas terakhir</th><th className="num" title="PO terbuka: umur sampai data terakhir. PO closed: lama pengerjaan.">Umur / lama</th>
                </tr>
              </thead>
              <tbody>
                {tampil.map((p) => (
                  <tr key={p.po} className={p.closed ? 'closed' : ''}>
                    <td><b>{p.po}</b></td>
                    <td>{p.produk ? labelProduk(p.produk, produkIdx(p.produk)) : '–'}</td>
                    <td>{p.batch || '–'}</td>
                    <td><span className={`badge ${p.closed ? 'ok' : 'run'}`}>{p.closed ? (p.status || 'Completed') : (p.status && !/^completed/i.test(p.status) ? p.status : 'Running')}</span></td>
                    <td>{p.closed ? <span className="muted">Selesai</span> : <b>{p.posisi || 'Belum mulai'}</b>}</td>
                    <td><Alur proses={d.proses} po={p} /></td>
                    <td className="num">{fmtInt(p.wip)}</td>
                    <td>{p.mulai ? fmtTgl(p.mulai) : '–'}</td>
                    <td>{p.terakhir ? fmtTgl(p.terakhir) : '–'}
                      {!p.closed && p.diam !== null && p.diam >= DIAM_BATAS && <span className="badge bad">{p.diam} hari diam</span>}</td>
                    <td className="num">{p.umur !== null ? `${fmtInt(p.umur)} hari` : '–'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

function Alur({ proses, po }) {
  const ada = new Map(po.proses.map((x) => [x.proses, x]));
  return (
    <div className="alur">
      {proses.map((pr) => {
        const x = ada.get(pr);
        const kelas = !x ? 'belum' : (!po.closed && pr === po.posisi ? 'jalan' : 'sudah');
        return (
          <div key={pr} className={`step ${kelas}`} title={x ? `${pr}: start ${fmtInt(x.start)}, good ${fmtInt(x.good)}, scrap ${fmtInt(x.scrap)} (${fmtTgl(x.mulai)} – ${fmtTgl(x.terakhir)})` : `${pr}: belum dikerjakan`}>
            <i />
            <span>{pr}</span>
            <small>{x ? fmtInt(x.good) : '–'}</small>
          </div>
        );
      })}
    </div>
  );
}
