// Semua query SQL untuk API dashboard. Memakai view yang dibuat di dashboard_realtime.sql.
'use strict';

const F_PO = `p.Dept = @dept AND (@sku IS NULL OR p.SKU = @sku) AND (@status IS NULL OR p.StatusPO = @status)`;

// Data view disalin dulu ke tabel sementara (#temp) supaya SQL Server tidak
// menghitung ulang view berkali-kali saat di-JOIN (jauh lebih cepat).
const PO_TMP = `SET NOCOUNT ON;
SELECT p.PON, p.WIP_Qty, p.IsCompleted INTO #po FROM dbo.vw_PBI_PO p WHERE ${F_PO};`;
const OUT_TMP = (where) => `SELECT o.Tanggal, o.PON, o.Output_, o.Scrap INTO #o
FROM dbo.vw_PBI_OutputPO o WHERE o.Dept = @dept AND ${where};
SELECT o.Tanggal, o.Output_, o.Scrap INTO #op FROM #o o JOIN #po p ON p.PON = o.PON;`;

const SQL = {
  // token perubahan: berubah setiap kali VBA melakukan POST
  token: `
SELECT Token = CONCAT(
  (SELECT CONVERT(varchar(30), MAX(InputOn), 126) FROM dbo.tblBA204_PODailyOutput), '|',
  (SELECT COUNT_BIG(*) FROM dbo.tblBA204_PODailyOutput), '|',
  (SELECT CONVERT(varchar(30), MAX(InputOn), 126) FROM dbo.tblBA204_DailyOutput2), '|',
  (SELECT COUNT_BIG(*) FROM dbo.tblBA204_DailyOutput2), '|',
  (SELECT CONVERT(varchar(30), MAX(InputOn), 126) FROM dbo.tblBA204_Productivity2), '|',
  (SELECT COUNT_BIG(*) FROM dbo.tblBA204_PODetailsReject), '|',
  (SELECT CONVERT(varchar(30), MAX(InputOn), 126) FROM dbo.tblBA204_POHeader), '|',
  (SELECT CONVERT(varchar(30), MAX(TrainedOn), 126) FROM dbo.tblBA204_ModelInfo));`,

  meta: `
SELECT Dept, Nama FROM dbo.tblBA204_Departemen ORDER BY Urut;
SELECT DISTINCT SKU FROM dbo.vw_PBI_PO WHERE Dept = @dept AND SKU IS NOT NULL ORDER BY SKU;
SELECT DISTINCT StatusPO FROM dbo.vw_PBI_PO WHERE Dept = @dept AND StatusPO IS NOT NULL ORDER BY StatusPO;
SELECT MinDate = CONVERT(char(10), MIN(Tanggal), 23), MaxDate = CONVERT(char(10), MAX(Tanggal), 23)
FROM dbo.vw_Harian WHERE Dept = @dept AND Output_ > 0;
SELECT DISTINCT Tahun = YEAR(Tanggal) FROM dbo.vw_Harian WHERE Dept = @dept AND Output_ > 0 ORDER BY Tahun DESC;
SELECT LastUpdate = CONVERT(varchar(19), LastUpdate, 126) FROM dbo.vw_PBI_Info;
SELECT ModelVersion = MAX(ModelVersion) FROM dbo.tblBA204_ModelInfo WHERE Dept = @dept;`,

  ringkasan: `
${PO_TMP}
${OUT_TMP('o.Tanggal BETWEEN @from AND @to')}
SELECT Tanggal, PlanOutput, TargetYield INTO #pl FROM dbo.vw_PBI_Plan WHERE Dept = @dept AND Tanggal BETWEEN @from AND @to;
-- KPI output / scrap
SELECT Output_ = ISNULL(SUM(Output_), 0), Scrap = ISNULL(SUM(Scrap), 0) FROM #op;
-- plan & target yield
SELECT PlanOutput = ISNULL(SUM(PlanOutput), 0), TargetYield = AVG(CASE WHEN PlanOutput > 0 THEN TargetYield END) FROM #pl;
-- produktivitas (jam standar / jam aktual)
SELECT Productivity = SUM(StdHours) / NULLIF(SUM(TotalManhours), 0),
       ActualMHP = SUM(TotalManhours) / NULLIF(SUM(ActOutput), 0)
FROM dbo.vw_PBI_Produktivitas WHERE Dept = @dept AND Tanggal BETWEEN @from AND @to;
-- WIP & progres PO (posisi saat ini)
SELECT WIP = ISNULL(SUM(WIP_Qty), 0), POTotal = COUNT(*), POSelesai = ISNULL(SUM(IsCompleted), 0) FROM #po;
-- harian
WITH o AS (SELECT Tanggal, Output_ = SUM(Output_), Scrap = SUM(Scrap) FROM #op GROUP BY Tanggal)
SELECT Tanggal = CONVERT(char(10), COALESCE(o.Tanggal, pl.Tanggal), 23),
       Output_ = ISNULL(o.Output_, 0), Scrap = ISNULL(o.Scrap, 0),
       PlanOutput = ISNULL(pl.PlanOutput, 0), TargetYield = pl.TargetYield
FROM o FULL OUTER JOIN #pl pl ON pl.Tanggal = o.Tanggal
ORDER BY COALESCE(o.Tanggal, pl.Tanggal);`,

  tren: `
${PO_TMP}
${OUT_TMP('YEAR(o.Tanggal) = @year')}
WITH o AS (
  SELECT m = MONTH(Tanggal), Output_ = SUM(Output_), Scrap = SUM(Scrap) FROM #op GROUP BY MONTH(Tanggal)
), pl AS (
  SELECT m = MONTH(Tanggal), PlanOutput = SUM(PlanOutput)
  FROM dbo.vw_PBI_Plan WHERE Dept = @dept AND YEAR(Tanggal) = @year GROUP BY MONTH(Tanggal)
)
SELECT Bulan = COALESCE(o.m, pl.m), Output_ = ISNULL(o.Output_, 0), Scrap = ISNULL(o.Scrap, 0),
       PlanOutput = ISNULL(pl.PlanOutput, 0)
FROM o FULL OUTER JOIN pl ON pl.m = o.m
ORDER BY COALESCE(o.m, pl.m);
SELECT Tanggal = CONVERT(char(10), Tanggal, 23), Output_ = SUM(Output_)
FROM #op GROUP BY Tanggal HAVING SUM(Output_) > 0 ORDER BY Tanggal;`,

  prediksi: `
SET NOCOUNT ON;
SELECT Tanggal, Aktual, Prediksi, Target, IsForecast, APE INTO #pr
FROM dbo.vw_PBI_Prediksi
WHERE Dept = @dept AND Metric = @metric AND ((Tanggal BETWEEN @from AND @to) OR IsForecast = 1);
SELECT Tanggal = CONVERT(char(10), Tanggal, 23), Aktual, Prediksi, Target, IsForecast, APE FROM #pr ORDER BY Tanggal;
SELECT Feature, Importance FROM dbo.vw_PBI_FeatureImportance WHERE Dept = @dept AND Metric = @metric ORDER BY Importance DESC;
SELECT Metric, ModelVersion, TrainRows, TrainFrom = CONVERT(char(10), TrainFrom, 23),
       TrainTo = CONVERT(char(10), TrainTo, 23), MAE, MAPE
FROM dbo.tblBA204_ModelInfo WHERE Dept = @dept AND Metric = @metric;`,

  defect: `
${PO_TMP}
${OUT_TMP('o.Tanggal BETWEEN @from AND @to')}
SELECT d.PON, d.Process, d.RejectCode, d.RejectName, d.Qty INTO #d
FROM dbo.vw_PBI_Defect d WHERE d.Dept = @dept AND d.Tanggal BETWEEN @from AND @to;
SELECT Tanggal, Prediksi, IsForecast INTO #pr FROM dbo.vw_PBI_Prediksi
WHERE Dept = @dept AND Metric = N'Defect' AND ((Tanggal BETWEEN @from AND @to) OR IsForecast = 1);
SELECT Output_ = ISNULL(SUM(Output_), 0), Scrap = ISNULL(SUM(Scrap), 0) FROM #op;
SELECT d.RejectName, d.RejectCode, Qty = SUM(d.Qty)
FROM #d d JOIN #po p ON p.PON = d.PON
GROUP BY d.RejectName, d.RejectCode ORDER BY Qty DESC;
-- nama proses asli tidak ditampilkan: diganti Forming, Inspection, Covering, Packaging sesuai urutan alur
SELECT Process = CASE WHEN d.Process = dp.ProsesWIPAwal  THEN N'Forming'
                      WHEN d.Process = dp.ProsesOutput   THEN N'Covering'
                      WHEN d.Process = dp.ProsesWIPAkhir THEN N'Packaging'
                      ELSE N'Inspection' END,
       Qty = SUM(d.Qty)
FROM #d d JOIN #po p ON p.PON = d.PON
CROSS JOIN (SELECT * FROM dbo.tblBA204_Departemen WHERE Dept = @dept) dp
GROUP BY CASE WHEN d.Process = dp.ProsesWIPAwal  THEN N'Forming'
              WHEN d.Process = dp.ProsesOutput   THEN N'Covering'
              WHEN d.Process = dp.ProsesWIPAkhir THEN N'Packaging'
              ELSE N'Inspection' END
ORDER BY Qty DESC;
WITH o AS (
  SELECT Tanggal, Output_ = SUM(Output_), Scrap = SUM(Scrap) FROM #op GROUP BY Tanggal HAVING SUM(Output_) > 0
)
SELECT Tanggal = CONVERT(char(10), COALESCE(o.Tanggal, pr.Tanggal), 23),
       Aktual = o.Scrap / NULLIF(o.Output_ + o.Scrap, 0),
       Prediksi = pr.Prediksi, IsForecast = ISNULL(pr.IsForecast, 0)
FROM o FULL OUTER JOIN #pr pr ON pr.Tanggal = o.Tanggal
ORDER BY COALESCE(o.Tanggal, pr.Tanggal);`,
};

module.exports = { SQL };
