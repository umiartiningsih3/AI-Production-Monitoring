# AI Production Monitoring — PBLIF3-MD04

Monitoring & prediksi produksi untuk dua departemen: **Hydrodissection Cannula** dan **Safety Series**.

```
Excel (VBA, tombol POST) ──ADO──▶ SQL Server 2022 (PBL_MonitoringProduksi)
        view + prediksi XGBoost (T-SQL) ──▶ API Node.js ──SSE──▶ Dashboard React
```

## Isi repository

| Folder / file | Isi |
|---|---|
| `VBA (cadangan)/YieldOutput.bas` | Kode VBA macro Excel (tombol POST ke SQL Server). File Excel berisi data produksi tidak di-upload. |
| `setup_database.sql` | Membuat database & tabel |
| `dashboard_realtime.sql` | View dashboard, fungsi prediksi XGBoost, data model |
| `dashboard_departemen.sql` | Dukungan 2 departemen (HDC & Safety Series) |
| `Model XGBoost/` | Skrip Python: dataset, pelatihan XGBoost, ekspor model ke T-SQL |
| `web-dashboard/` | Web dashboard: server Node.js (`server/`) + React/Vite/Recharts (`client/`) |

## Menjalankan dashboard

1. Jalankan `setup_database.sql`, `dashboard_realtime.sql`, `dashboard_departemen.sql`, lalu skrip di `web-dashboard/sql/` (05 sampai 08) di SQL Server. Isi master material dari file lokal `data_master_lokal.sql`.
2. Sesuaikan `web-dashboard/config.json` (nama server SQL).
3. Klik dua kali `web-dashboard/START.bat`, lalu buka http://localhost:3000.

Detail ada di `web-dashboard/BACA-SAYA.txt`.

## Halaman dashboard

1. **Ringkasan Produksi** — output, yield, defect, productivity, WIP, progres PO
2. **Pencapaian & Tren** — capaian bulanan & YTD, tren output dan yield
3. **Aktual vs Prediksi** — prediksi XGBoost H+1/H+2, early warning, feature importance
4. **Analisis Defect** — defect rate, prediksi defect, top 5 defect, distribusi per proses
