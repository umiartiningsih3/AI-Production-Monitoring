// Format angka & tanggal gaya Indonesia
const nf0 = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 1 });
const BULAN = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
const BULAN_PANJANG = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus',
  'September', 'Oktober', 'November', 'Desember'];
const HARI = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'];

export const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
export const fmtInt = (v) => (isNum(v) ? nf0.format(v) : '–');
export const fmtPct = (v, d = 1) =>
  isNum(v) ? new Intl.NumberFormat('id-ID', { minimumFractionDigits: d, maximumFractionDigits: d }).format(v * 100) + '%' : '–';
export const fmtDec = (v) => (isNum(v) ? nf1.format(v) : '–');
export const fmtCompact = (v) => {
  if (!isNum(v)) return '–';
  if (Math.abs(v) >= 1e6) return nf1.format(v / 1e6) + ' jt';
  if (Math.abs(v) >= 1e3) return nf1.format(v / 1e3) + ' rb';
  return nf0.format(v);
};

const parse = (iso) => {
  const [y, m, d] = String(iso).slice(0, 10).split('-').map(Number);
  return { y, m, d, dow: new Date(Date.UTC(y, m - 1, d)).getUTCDay() };
};
export const fmtTglPendek = (iso) => { if (!iso) return ''; const t = parse(iso); return `${t.d} ${BULAN[t.m - 1]}`; };
export const fmtTgl = (iso) => { if (!iso) return '–'; const t = parse(iso); return `${HARI[t.dow]}, ${t.d} ${BULAN[t.m - 1]} ${t.y}`; };
export const namaBulan = (m) => BULAN_PANJANG[m - 1] || '';
export const bulanPendek = (m) => BULAN[m - 1] || '';
export const fmtWaktu = (iso) => {
  if (!iso) return '–';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso).replace('T', ' ');
  return d.toLocaleString('id-ID', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' });
};

export function addDays(iso, n) {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export const NAMA_FITUR = {
  plan_output: 'Plan output hari ini',
  output_lag1: 'Output kemarin',
  output_ma3: 'Rata-rata output 3 hari',
  yield_lag1: 'Yield kemarin',
  yield_ma7: 'Rata-rata yield 7 hari',
  defect_lag1: 'Defect kemarin',
  wip: 'WIP',
  progres_po: 'Progres PO',
  hari_ke: 'Hari dalam minggu',
};

// angka ringkas untuk label grafik: 12.345 -> "12,3rb"
export const fmtLabel = (v) => {
  if (!isNum(v)) return '';
  if (Math.abs(v) >= 1e6) return nf1.format(v / 1e6) + 'jt';
  if (Math.abs(v) >= 1e3) return nf1.format(v / 1e3) + 'rb';
  return nf0.format(v);
};
