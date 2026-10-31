import React from 'react';
import {
  ResponsiveContainer, BarChart, Bar, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, LabelList,
} from 'recharts';
import { useApi } from '../api.js';
import { C, AXIS, KpiCard, ChartCard, Filters, Loading, Empty, Tip, valueLabel } from '../components/ui.jsx';
import { fmtInt, fmtPct, fmtCompact, fmtTgl, namaBulan, bulanPendek, isNum } from '../format.js';

export default function Tren({ meta, f, setF, version }) {
  const { data, error } = useApi('tren', { dept: f.dept, tahun: f.tahun, produk: f.produk, status: f.status }, version);
  return (
    <>
      <Filters meta={meta} f={f} setF={setF} show={['tahun', 'produk', 'status']} />
      {!data ? <Loading error={error} /> : <Isi d={data} />}
    </>
  );
}

const statusCapaian = (v) => (v === null || v === undefined ? '' : v >= 1 ? 'good' : v >= 0.9 ? 'warn' : 'bad');

function Isi({ d }) {
  const semua = d.tahun === 'semua';
  const judulTahun = semua ? 'semua tahun' : d.tahun;
  // satu tahun: tampilkan 12 bulan penuh; semua tahun: bulan yang punya data, urut waktu
  const bulan = semua
    ? d.bulanan.filter((r) => r.output > 0 || r.plan > 0).map((x) => ({
        ...x, nama: `${bulanPendek(x.bulan)} ${x.tahun}`, judul: `${namaBulan(x.bulan)} ${x.tahun}` }))
    : Array.from({ length: 12 }, (_, i) => {
        const x = d.bulanan.find((r) => r.bulan === i + 1);
        return { bulan: i + 1, tahun: d.tahun, nama: bulanPendek(i + 1), judul: `${namaBulan(i + 1)} ${d.tahun}`,
                 output: x ? x.output : 0, plan: x ? x.plan : 0, scrap: x ? x.scrap : 0,
                 yield: x ? x.yield : null, capaian: x ? x.capaian : null };
      });
  const adaBulanan = bulan.some((r) => r.output > 0 || r.plan > 0);
  const outBulan = bulan.filter((r) => r.output > 0);
  const yieldBulan = bulan.filter((r) => isNum(r.yield));
  const b = d.bulanTerakhir;
  const lebar = semua ? bulan.length : 0;   // banyak bulan -> grafik bisa digeser

  return (
    <>
      <div className="kpis kpis-4">
        <KpiCard label={b ? `Pencapaian ${namaBulan(b.bulan)} ${b.tahun}` : 'Pencapaian bulan ini'}
                 value={fmtPct(b && b.capaian, 1)}
                 sub={b ? `${fmtInt(b.output)} dari plan ${fmtInt(b.plan)} pcs` : 'Belum ada data'}
                 status={statusCapaian(b && b.capaian)} />
        <KpiCard label={semua ? 'Pencapaian semua tahun' : `Pencapaian YTD ${d.tahun}`} value={fmtPct(d.ytd.capaian, 1)} accent={C.navy}
                 sub={`${fmtInt(d.ytd.output)} dari plan ${fmtInt(d.ytd.plan)} pcs`} status={statusCapaian(d.ytd.capaian)} />
        <KpiCard label={b ? `Yield ${namaBulan(b.bulan)} ${b.tahun}` : 'Yield bulan ini'} value={fmtPct(b && b.yield, 2)}
                 accent={C.orange} sub={b ? `${fmtInt(b.scrap)} pcs scrap` : ''} />
        <KpiCard label="Hari produksi" value={fmtInt(d.harian.length)} accent={C.purple}
                 sub={d.harian.length ? `${fmtTgl(d.harian[0].tanggal)} – ${fmtTgl(d.harian[d.harian.length - 1].tanggal)}` : ''} />
      </div>

      <ChartCard title={`Output vs Plan per Bulan, ${judulTahun}`} points={lebar}
                 legend={[{ label: 'Output', color: C.blue, type: 'bar' }, { label: 'Plan', color: C.navy, type: 'bar' }]}
                 table={{ columns: ['Bulan', 'Output', 'Plan', 'Capaian', 'Yield'],
                          rows: bulan.filter((r) => r.output || r.plan).map((r) => [r.judul, fmtInt(r.output), fmtInt(r.plan), fmtPct(r.capaian), fmtPct(r.yield, 2)]) }}>
        {!adaBulanan ? <Empty /> : (
          <ResponsiveContainer>
            <BarChart data={bulan} margin={{ top: 20, right: 8, left: 0, bottom: 0 }} barGap={2} barCategoryGap="24%">
              <CartesianGrid vertical={false} stroke={C.grid} />
              <XAxis dataKey="nama" tick={AXIS} tickLine={false} axisLine={{ stroke: C.grid }} interval={0} />
              <YAxis tickFormatter={fmtCompact} tick={AXIS} tickLine={false} axisLine={false} width={46} />
              <Tooltip cursor={{ fill: 'rgba(17,141,255,0.08)' }}
                       content={<Tip labelFmt={(_, p) => p.judul} rows={(p) => [
                         { label: 'Output', value: fmtInt(p.output), color: C.blue },
                         { label: 'Plan', value: fmtInt(p.plan), color: C.navy },
                         { label: 'Capaian', value: fmtPct(p.capaian) },
                       ]} />} />
              <Bar dataKey="output" fill={C.blue} radius={[4, 4, 0, 0]} maxBarSize={30} isAnimationActive={false}>
                <LabelList dataKey="output" content={valueLabel(fmtInt, { min: 0 })} />
              </Bar>
              <Bar dataKey="plan" fill={C.navy} radius={[4, 4, 0, 0]} maxBarSize={30} isAnimationActive={false} />
            </BarChart>
          </ResponsiveContainer>
        )}
      </ChartCard>

      <div className="grid2">
        <ChartCard title="Tren Output Bulanan" subtitle={`Good output proses akhir per bulan, ${judulTahun}`} points={lebar}
                   table={{ columns: ['Bulan', 'Output'], rows: outBulan.map((r) => [r.judul, fmtInt(r.output)]) }}>
          {outBulan.length === 0 ? <Empty /> : (
            <ResponsiveContainer>
              <LineChart data={bulan} margin={{ top: 22, right: 26, left: 0, bottom: 0 }}>
                <CartesianGrid vertical={false} stroke={C.grid} />
                <XAxis dataKey="nama" tick={AXIS} tickLine={false} axisLine={{ stroke: C.grid }} interval={0} />
                <YAxis domain={[0, 'auto']} tickFormatter={fmtCompact} tick={AXIS} tickLine={false} axisLine={false} width={46} />
                <Tooltip content={<Tip labelFmt={(_, p) => p.judul}
                                       rows={(p) => [{ label: 'Output', value: fmtInt(p.output) + ' pcs', color: C.blue }]} />} />
                <Line dataKey={(r) => (r.output > 0 ? r.output : null)} name="output" stroke={C.blue} strokeWidth={2} connectNulls
                      dot={{ r: 4, fill: C.blue, stroke: '#fff', strokeWidth: 2 }} activeDot={{ r: 6 }} isAnimationActive={false}>
                  <LabelList dataKey="output" content={valueLabel(fmtInt, { color: C.blue, min: 0 })} />
                </Line>
              </LineChart>
            </ResponsiveContainer>
          )}
        </ChartCard>

        <ChartCard title="Tren Yield Bulanan" subtitle={`Rata-rata tertimbang per bulan, ${judulTahun}`} points={lebar}
                   table={{ columns: ['Bulan', 'Yield'], rows: yieldBulan.map((r) => [r.judul, fmtPct(r.yield, 2)]) }}>
          {yieldBulan.length === 0 ? <Empty /> : (
            <ResponsiveContainer>
              <LineChart data={bulan} margin={{ top: 22, right: 26, left: 0, bottom: 0 }}>
                <CartesianGrid vertical={false} stroke={C.grid} />
                <XAxis dataKey="nama" tick={AXIS} tickLine={false} axisLine={{ stroke: C.grid }} interval={0} />
                <YAxis domain={['auto', 1]} tickFormatter={(v) => fmtPct(v, 1)} tick={AXIS} tickLine={false} axisLine={false} width={46} />
                <Tooltip content={<Tip labelFmt={(_, p) => p.judul}
                                       rows={(p) => [{ label: 'Yield', value: fmtPct(p.yield, 2), color: C.navy }]} />} />
                <Line dataKey="yield" stroke={C.navy} strokeWidth={2} connectNulls
                      dot={{ r: 4, fill: C.navy, stroke: '#fff', strokeWidth: 2 }} activeDot={{ r: 6 }} isAnimationActive={false}>
                  <LabelList dataKey="yield" content={valueLabel((v) => fmtPct(v, 2), { color: C.navy })} />
                </Line>
              </LineChart>
            </ResponsiveContainer>
          )}
        </ChartCard>
      </div>
    </>
  );
}
