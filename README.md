# AI Production Monitoring

Sistem monitoring dan prediksi produksi harian berbasis web. Data diinput lewat Excel, disimpan di SQL Server, diprediksi dengan XGBoost, lalu ditampilkan di dashboard React yang ter-update otomatis secara real-time.

Proyek PBL (Project Based Learning) — PBLIF3-MD04.

## Arsitektur

```
Excel + VBA (tombol POST)
        │  ADODB
        ▼
SQL Server 2022 ── view KPI + fungsi prediksi XGBoost (T-SQL)
        │  query
        ▼
Server Node.js ── REST API + Server-Sent Events (cek data baru tiap 3 detik)
        │  SSE
        ▼
Dashboard React (Vite + Recharts)
```

Model XGBoost dilatih dengan Python, lalu setiap pohonnya diekspor menjadi fungsi T-SQL, sehingga prediksi dihitung langsung di database setiap ada data baru.

## Fitur

- **Input tanpa ubah kebiasaan** — operator tetap mengisi Excel; tombol POST mengirim data ke database dalam satu transaksi, tanpa data dobel.
- **Dashboard real-time** — grafik berubah otomatis beberapa detik setelah POST, tanpa refresh.
- **Prediksi XGBoost** — output, yield, dan defect 1–2 hari ke depan, lengkap dengan early warning dan feature importance.
- **Multi lini produk** — satu dashboard untuk dua lini produk, dipilih lewat filter.
- **Filter** — periode, produk, status production order, dan tahun.

## Halaman dashboard

1. **Ringkasan Produksi** — KPI output, yield, defect, productivity, WIP, progres production order
2. **Pencapaian & Tren** — capaian bulanan & year-to-date, tren output dan yield
3. **Aktual vs Prediksi** — aktual vs prediksi vs target, early warning, feature importance
4. **Analisis Defect** — defect rate, prediksi defect, top 5 jenis defect, distribusi per proses

## Tech stack

| Bagian | Teknologi |
| --- | --- |
| Input data | Microsoft Excel, VBA, ADODB |
| Database | SQL Server 2022 Express (T-SQL, view, window function) |
| Machine learning | Python (pandas, numpy), XGBoost |
| Backend | Node.js (REST API, Server-Sent Events) |
| Frontend | React 18, Vite 5, Recharts |

## Struktur folder

| Folder / file | Isi |
| --- | --- |
| `VBA (cadangan)/YieldOutput.bas` | Kode macro VBA untuk tombol POST |
| `setup_database.sql`, `dashboard_*.sql` | Pembuatan tabel, view KPI, dan fungsi prediksi |
| `Model XGBoost/` | Skrip Python untuk menyiapkan data dan melatih model |
| `web-dashboard/server/` | Server Node.js (API + real-time) |
| `web-dashboard/client/` | Aplikasi React |
| `web-dashboard/sql/` | Skrip SQL tambahan (multi lini produk & optimasi) |

## Menjalankan

1. Jalankan skrip SQL di SQL Server: `setup_database.sql`, `dashboard_realtime.sql`, `dashboard_departemen.sql`, lalu `web-dashboard/sql/` (05 sampai 08).
2. Sesuaikan nama server SQL di `web-dashboard/config.json`.
3. Klik dua kali `web-dashboard/START.bat`, lalu buka http://localhost:3000.

> Data produksi asli tidak disertakan dalam repository ini.
