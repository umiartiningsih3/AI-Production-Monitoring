import React from 'react';
import {
  ResponsiveContainer, BarChart, Bar, PieChart, Pie, Cell, ComposedChart, Line, XAxis, YAxis,
  CartesianGrid, Tooltip, LabelList,
} from 'recharts';
import { useApi } from '../api.js';
import { C, AXIS, KpiCard, ChartCard, Filters, Loading, Empty, Tip, valueLabel } from '../components/ui.jsx';
import { fmtInt, fmtPct, fmtTglPendek, fmtTgl, isNum } from '../format.js';

const DONUT = [C.blue, C.navy, C.orange, C.purple, C.pink, '#9A9A9A'];

export default function Defect({ meta, f, setF, version }) {
  const { data, error } = useApi('defect', { dept: f.dept, from: f.from, to: f.to, produk: f.produk, status: f.status }, version);
  return (
    <>
      <Filters meta={meta} f={f} setF={setF} />
      {!data ? <Loading error={error} /> : <Isi d={data} />}
    </>
  );
}

function Isi({ d }) {
  const top5 = d.jenis.slice(0, 5).map((x) => ({ ...x, label: x.kode ? `${x.nama} (${x.kode})` : x.nama }));
  const totalJenis = d.jenis.reduce((a, x) => a + x.qty, 0);
  // donut per proses; lebih dari 5 proses digabung jadi "Lainnya"
  let proses = d.proses.slice(0, 5);
  if (d.proses.length > 5) proses = [...proses, { nama: 'Lainnya', qty: d.proses.slice(5).reduce((a, x) => a + x.qty, 0) }];
  const totalProses = proses.reduce((a, x) => a + x.qty, 0);
  const tren = d.tren.map((r) => ({ ...r }));
  const firstFc = tren.findIndex((r) => r.forecast);
  tren.forEach((r) => { r.pHist = r.forecast ? null : r.prediksi; r.pFc = r.forecast ? r.prediksi : null; });
  if (firstFc > 0) tren[firstFc - 1].pFc = isNum(tren[firstFc - 1].aktual) ? tren[firstFc - 1].aktual : tren[firstFc - 1].prediksi;
  const nb = d.prediksiBesok;
  const naik = nb && isNum(nb.nilai) && isNum(d.defectRate) ? nb.nilai > d.defectRate : null;

  return (
    <>
      <div className="kpis kpis-4">
        <KpiCard label="Defect rate" value={fmtPct(d.defectRate, 2)} accent={C.orange}
                 sub={`${fmtInt(d.scrap)} pcs scrap pada periode ini`} />
        <KpiCard label={nb ? `Prediksi defect ${fmtTgl(nb.tanggal)}` : 'Prediksi defect H+1'}
                 value={fmtPct(nb && nb.nilai, 2)} accent={C.purple}
                 sub={naik === null ? 'Prediksi model XGBoost' : naik ? 'Lebih tinggi dari rata-rata periode' : 'Lebih rendah dari rata-rata periode'}
                 status={naik === null ? '' : naik ? 'bad' : 'good'} />
        <KpiCard label="Jenis defect terbanyak" value={top5[0] ? top5[0].nama : '–'} accent={C.blue}
                 sub={top5[0] ? `${fmtInt(top5[0].qty)} pcs · ${fmtPct(top5[0].qty / totalJenis, 1)} dari total` : ''} />
        <KpiCard label="Proses penyumbang terbesar" value={d.proses[0] ? d.proses[0].nama : '–'} accent={C.navy}
                 sub={d.proses[0] ? `${fmtInt(d.proses[0].qty)} pcs · ${fmtPct(d.proses[0].qty / totalProses, 1)}` : ''} />
      </div>

      <div className="grid2">
        <ChartCard title="Top 5 Jenis Defect" subtitle="Jumlah pcs reject"
                   table={{ columns: ['Jenis defect', 'Kode', 'Qty', '%'],
                            rows: d.jenis.map((x) => [x.nama, x.kode || '-', fmtInt(x.qty), fmtPct(x.qty / totalJenis, 1)]) }}>
          {top5.length === 0 ? <Empty>Tidak ada defect pada periode ini.</Empty> : (
            <ResponsiveContainer>
              <BarChart data={top5} layout="vertical" margin={{ top: 0, right: 56, left: 4, bottom: 0 }} barCategoryGap="22%">
                <XAxis type="number" hide domain={[0, 'dataMax']} />
                <YAxis type="category" dataKey="label" width={170} tick={{ ...AXIS, fill: '#333' }} tickLine={false} axisLine={false} />
                <Tooltip cursor={{ fill: 'rgba(230,108,55,0.08)' }}
                         content={<Tip labelFmt={(_, p) => p.label} rows={(p) => [
                           { label: 'Qty', value: fmtInt(p.qty) + ' pcs', color: C.orange },
                           { label: 'Porsi', value: fmtPct(p.qty / totalJenis, 1) }]} />} />
                <Bar dataKey="qty" fill={C.orange} radius={[0, 4, 4, 0]} isAnimationActive={false}>
                  <LabelList dataKey="qty" position="right" formatter={fmtInt} style={{ fontSize: 11, fill: '#444' }} />
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          )}
        </ChartCard>

        <ChartCard title="Distribusi Defect per Proses"
                   table={{ columns: ['Proses', 'Qty', '%'], rows: proses.map((x) => [x.nama, fmtInt(x.qty), fmtPct(x.qty / totalProses, 1)]) }}>
          {proses.length === 0 ? <Empty>Tidak ada defect pada periode ini.</Empty> : (
            <div className="donut">
              <div className="donut-chart">
                <ResponsiveContainer>
                  <PieChart>
                    <Pie data={proses} dataKey="qty" nameKey="nama" innerRadius="58%" outerRadius="88%"
                         paddingAngle={1} stroke="#fff" strokeWidth={2} isAnimationActive={false}>
                      {proses.map((x, i) => <Cell key={x.nama} fill={DONUT[i % DONUT.length]} />)}
                    </Pie>
                    <Tooltip content={<Tip labelFmt={(_, p) => p.nama} rows={(p) => [
                      { label: 'Qty', value: fmtInt(p.qty) + ' pcs' }, { label: 'Porsi', value: fmtPct(p.qty / totalProses, 1) }]} />} />
                  </PieChart>
                </ResponsiveContainer>
                <div className="donut-center"><b>{fmtInt(totalProses)}</b><small>pcs</small></div>
              </div>
              <ul className="donut-legend">
                {proses.map((x, i) => (
                  <li key={x.nama}>
                    <i style={{ background: DONUT[i % DONUT.length] }} />
                    <span>{x.nama}</span>
                    <b>{fmtPct(x.qty / totalProses, 1)}</b>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </ChartCard>
      </div>

      <ChartCard title="Tren Defect Harian: Aktual vs Prediksi" points={tren.length}
                 legend={[{ label: 'Aktual', color: C.orange }, { label: 'Prediksi', color: C.purple, dash: true }]}
                 table={{ columns: ['Tanggal', 'Aktual', 'Prediksi'],
                          rows: d.tren.map((r) => [fmtTgl(r.tanggal) + (r.forecast ? ' (prediksi)' : ''), fmtPct(r.aktual, 2), fmtPct(r.prediksi, 2)]) }}>
        {tren.length === 0 ? <Empty /> : (
          <ResponsiveContainer>
            <ComposedChart data={tren} margin={{ top: 22, right: 26, left: 0, bottom: 0 }}>
              <CartesianGrid vertical={false} stroke={C.grid} />
              <XAxis dataKey="tanggal" tickFormatter={fmtTglPendek} tick={AXIS} tickLine={false} axisLine={{ stroke: C.grid }} interval={0} />
              <YAxis domain={[0, 'auto']} tickFormatter={(v) => fmtPct(v, 1)} tick={AXIS} tickLine={false} axisLine={false} width={52} />
              <Tooltip content={<Tip labelFmt={(l, p) => fmtTgl(l) + (p.forecast ? ' · PREDIKSI' : '')} rows={(p) => [
                ...(p.forecast ? [] : [{ label: 'Aktual', value: fmtPct(p.aktual, 2), color: C.orange }]),
                { label: 'Prediksi', value: fmtPct(p.prediksi, 2), color: C.purple }]} />} />
              <Line dataKey="pHist" stroke={C.purple} strokeWidth={2} strokeDasharray="2 3" strokeOpacity={0.75}
                    dot={false} activeDot={false} isAnimationActive={false} />
              <Line dataKey="pFc" stroke={C.purple} strokeWidth={2.5} strokeDasharray="6 4"
                    dot={{ r: 4, fill: C.purple, stroke: '#fff', strokeWidth: 2 }} isAnimationActive={false} />
              <Line dataKey="aktual" stroke={C.orange} strokeWidth={2} dot={{ r: 3, fill: C.orange, stroke: '#fff', strokeWidth: 1.5 }}
                    activeDot={{ r: 5 }} isAnimationActive={false}>
                <LabelList dataKey="aktual" content={valueLabel((v) => fmtPct(v, 2), { count: tren.length, color: C.orange })} />
              </Line>
            </ComposedChart>
          </ResponsiveContainer>
        )}
      </ChartCard>
    </>
  );
}
