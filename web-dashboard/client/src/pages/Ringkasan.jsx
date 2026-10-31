import React from 'react';
import {
  ResponsiveContainer, ComposedChart, Bar, Line, XAxis, YAxis, CartesianGrid, Tooltip, LabelList,
} from 'recharts';
import { useApi } from '../api.js';
import { C, AXIS, KpiCard, ChartCard, Filters, Loading, Empty, Tip, valueLabel } from '../components/ui.jsx';
import { fmtInt, fmtPct, fmtCompact, fmtTglPendek, fmtTgl, isNum, fmtLabel } from '../format.js';

export default function Ringkasan({ meta, f, setF, version }) {
  const { data, error } = useApi('ringkasan',
    { dept: f.dept, from: f.from, to: f.to, produk: f.produk, status: f.status }, version);

  return (
    <>
      <Filters meta={meta} f={f} setF={setF} />
      {!data ? <Loading error={error} /> : <Isi d={data} />}
    </>
  );
}

function Isi({ d }) {
  const k = d.kpi;
  const capaian = k.plan ? k.output / k.plan : null;
  const yStatus = isNum(k.yield) ? (k.yield >= k.targetYield ? 'good' : 'bad') : '';
  const defTarget = 1 - (k.targetYield ?? 0.975);
  const harian = d.harian.filter((r) => r.output > 0 || r.plan > 0);
  const yieldRows = harian.filter((r) => isNum(r.yield) && r.output > 0);

  return (
    <>
      <div className="kpis">
        <KpiCard label="Output (pcs)" value={fmtInt(k.output)}
                 sub={k.plan ? `${fmtPct(capaian)} dari plan ${fmtInt(k.plan)}` : 'Plan belum diisi'}
                 status={capaian === null ? '' : capaian >= 1 ? 'good' : capaian >= 0.9 ? 'warn' : 'bad'} />
        <KpiCard label="Yield" value={fmtPct(k.yield, 2)} accent={C.navy}
                 sub={`Target ${fmtPct(k.targetYield, 1)}`} status={yStatus} />
        <KpiCard label="Defect" value={fmtPct(k.defect, 2)} accent={C.orange}
                 sub={`${fmtInt(k.scrap)} pcs scrap · batas ${fmtPct(defTarget, 1)}`}
                 status={isNum(k.defect) ? (k.defect <= defTarget ? 'good' : 'bad') : ''} />
        <KpiCard label="Productivity" value={fmtPct(k.productivity, 1)} accent={C.purple}
                 sub={isNum(k.actualMHP) ? `${k.actualMHP.toFixed(4).replace('.', ',')} jam-orang/pcs` : 'Belum ada data'}
                 status={isNum(k.productivity) ? (k.productivity >= 1 ? 'good' : 'warn') : ''} />
        <KpiCard label="WIP (pcs)" value={fmtInt(k.wip)} accent={C.pink} sub="Sudah Forming, belum selesai Packaging" />
        <KpiCard label="Progres PO" value={fmtPct(k.progresPO, 0)} accent={C.blue}
                 sub={`${fmtInt(k.poSelesai)} dari ${fmtInt(k.poTotal)} PO selesai`} />
      </div>

      <div className="grid2">
        <ChartCard title="Output vs Plan per Hari" subtitle={`${fmtTgl(d.periode.from)} – ${fmtTgl(d.periode.to)}`}
                   legend={[{ label: 'Output', color: C.blue, type: 'bar' }, { label: 'Plan', color: C.orange, dash: true }]}
                   table={{ columns: ['Tanggal', 'Output', 'Plan', 'Capaian'],
                            rows: harian.map((r) => [fmtTgl(r.tanggal), fmtInt(r.output), fmtInt(r.plan),
                                                     r.plan ? fmtPct(r.output / r.plan) : '–']) }}>
          {harian.length === 0 ? <Empty /> : (
            <ResponsiveContainer>
              <ComposedChart data={harian} margin={{ top: harian.length > 16 ? 40 : 20, right: 8, left: 0, bottom: 0 }} barCategoryGap="22%">
                <CartesianGrid vertical={false} stroke={C.grid} />
                <XAxis dataKey="tanggal" tickFormatter={fmtTglPendek} tick={AXIS} tickLine={false}
                       axisLine={{ stroke: C.grid }} minTickGap={12} />
                <YAxis tickFormatter={fmtCompact} tick={AXIS} tickLine={false} axisLine={false} width={46} />
                <Tooltip cursor={{ fill: 'rgba(17,141,255,0.08)' }}
                         content={<Tip labelFmt={fmtTgl} rows={(p) => [
                           { label: 'Output', value: fmtInt(p.output), color: C.blue },
                           { label: 'Plan', value: fmtInt(p.plan), color: C.orange },
                           { label: 'Capaian', value: p.plan ? fmtPct(p.output / p.plan) : '–' },
                         ]} />} />
                <Bar dataKey="output" fill={C.blue} radius={[4, 4, 0, 0]} maxBarSize={28} isAnimationActive={false}>
                  <LabelList dataKey="output" content={valueLabel(fmtLabel, { count: harian.length, min: 0 })} />
                </Bar>
                <Line dataKey="plan" stroke={C.orange} strokeWidth={2} strokeDasharray="5 4" type="stepAfter"
                      dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
              </ComposedChart>
            </ResponsiveContainer>
          )}
        </ChartCard>

        <ChartCard title="Yield per Hari" subtitle="Good output ÷ (good + scrap)"
                   legend={[{ label: 'Yield', color: C.navy }, { label: 'Target', color: C.target, dash: true }]}
                   table={{ columns: ['Tanggal', 'Yield', 'Target', 'Scrap'],
                            rows: yieldRows.map((r) => [fmtTgl(r.tanggal), fmtPct(r.yield, 2), fmtPct(r.target, 1), fmtInt(r.scrap)]) }}>
          {yieldRows.length === 0 ? <Empty /> : (
            <ResponsiveContainer>
              <ComposedChart data={yieldRows} margin={{ top: yieldRows.length > 16 ? 44 : 22, right: 26, left: 0, bottom: 0 }}>
                <CartesianGrid vertical={false} stroke={C.grid} />
                <XAxis dataKey="tanggal" tickFormatter={fmtTglPendek} tick={AXIS} tickLine={false}
                       axisLine={{ stroke: C.grid }} minTickGap={12} />
                <YAxis domain={['auto', 1]} tickFormatter={(v) => fmtPct(v, 1)} tick={AXIS} tickLine={false}
                       axisLine={false} width={46} allowDataOverflow={false} />
                <Tooltip content={<Tip labelFmt={fmtTgl} rows={(p) => [
                  { label: 'Yield', value: fmtPct(p.yield, 2), color: C.navy },
                  { label: 'Target', value: fmtPct(p.target, 1), color: C.target },
                  { label: 'Output / Scrap', value: `${fmtInt(p.output)} / ${fmtInt(p.scrap)}` },
                ]} />} />
                <Line dataKey="target" stroke={C.target} strokeWidth={1.5} strokeDasharray="5 4" dot={false}
                      type="stepAfter" isAnimationActive={false} />
                <Line dataKey="yield" stroke={C.navy} strokeWidth={2} dot={{ r: 3, fill: C.navy, stroke: '#fff', strokeWidth: 1.5 }}
                      activeDot={{ r: 5 }} isAnimationActive={false}>
                  <LabelList dataKey="yield" content={valueLabel((v) => fmtPct(v, 1), { count: yieldRows.length, color: C.navy })} />
                </Line>
              </ComposedChart>
            </ResponsiveContainer>
          )}
        </ChartCard>
      </div>
    </>
  );
}
