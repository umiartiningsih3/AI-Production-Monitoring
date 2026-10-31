/* =====================================================================
   PBL PBLIF3-MD04  -  Bagian 5: dukungan 2 departemen
     HDC = Lini Produk A
     SS  = Lini Produk B
   Departemen ditentukan dari kolom ProductType yang dikirim VBA:
   ProductType yang mengandung kata kunci lini B -> SS, selain itu -> HDC.
   Aturan proses (output akhir & WIP) per departemen ada di tabel
   dbo.tblBA204_Departemen, jadi bisa diubah tanpa mengubah kode.
   Aman dijalankan berulang.
   ===================================================================== */
USE [PBL_MonitoringProduksi];
GO

/* ---------- 1. Tabel departemen ---------- */
IF OBJECT_ID('dbo.tblBA204_Departemen','U') IS NULL
CREATE TABLE dbo.tblBA204_Departemen (
    Dept            nvarchar(10)  NOT NULL PRIMARY KEY,
    Nama            nvarchar(100) NOT NULL,
    PolaProductType nvarchar(100) NOT NULL,   -- pola LIKE untuk ProductType
    Prioritas       int           NOT NULL,   -- dicek dari angka terkecil
    ProsesOutput    nvarchar(50)  NOT NULL,   -- proses penghasil good output akhir
    ProsesWIPAwal   nvarchar(50)  NOT NULL,   -- WIP = mulai di proses ini ...
    ProsesWIPAkhir  nvarchar(50)  NOT NULL,   -- ... dikurangi output proses ini
    TargetYieldDefault float      NOT NULL CONSTRAINT DF_Departemen_TY DEFAULT (0.975),
    Urut            int           NOT NULL
);
GO
MERGE dbo.tblBA204_Departemen AS t
USING (VALUES
    (N'SS',  N'Lini Produk B',            N'%LINI-B%', 1, N'Sheating', N'Bending', N'Cartoning', 0.975, 2),
    (N'HDC', N'Lini Produk A',            N'%',        9, N'Sheating', N'Bending', N'Cartoning', 0.975, 1)
) AS s (Dept, Nama, PolaProductType, Prioritas, ProsesOutput, ProsesWIPAwal, ProsesWIPAkhir, TargetYieldDefault, Urut)
ON t.Dept = s.Dept
WHEN NOT MATCHED THEN INSERT (Dept, Nama, PolaProductType, Prioritas, ProsesOutput, ProsesWIPAwal, ProsesWIPAkhir, TargetYieldDefault, Urut)
     VALUES (s.Dept, s.Nama, s.PolaProductType, s.Prioritas, s.ProsesOutput, s.ProsesWIPAwal, s.ProsesWIPAkhir, s.TargetYieldDefault, s.Urut);
GO

/* fungsi kecil: ProductType -> kode departemen */
CREATE OR ALTER FUNCTION dbo.fn_Dept (@ProductType nvarchar(100))
RETURNS TABLE AS RETURN
SELECT TOP (1) Dept FROM dbo.tblBA204_Departemen
WHERE ISNULL(@ProductType, N'') LIKE PolaProductType
ORDER BY Prioritas;
GO

/* ---------- 2. Model & feature importance per departemen ---------- */
IF COL_LENGTH('dbo.tblBA204_ModelInfo', 'Dept') IS NULL
BEGIN
    ALTER TABLE dbo.tblBA204_ModelInfo ADD Dept nvarchar(10) NOT NULL
        CONSTRAINT DF_ModelInfo_Dept DEFAULT (N'HDC') WITH VALUES;
    DECLARE @pk sysname = (SELECT name FROM sys.key_constraints
                           WHERE parent_object_id = OBJECT_ID('dbo.tblBA204_ModelInfo') AND type = 'PK');
    DECLARE @cmd nvarchar(400) = N'ALTER TABLE dbo.tblBA204_ModelInfo DROP CONSTRAINT ' + QUOTENAME(@pk);
    IF @pk IS NOT NULL EXEC (@cmd);
    EXEC (N'ALTER TABLE dbo.tblBA204_ModelInfo ADD CONSTRAINT PK_ModelInfo PRIMARY KEY (Dept, Metric)');
END
GO
IF COL_LENGTH('dbo.tblBA204_FeatureImportance', 'Dept') IS NULL
BEGIN
    ALTER TABLE dbo.tblBA204_FeatureImportance ADD Dept nvarchar(10) NOT NULL
        CONSTRAINT DF_FeatureImportance_Dept DEFAULT (N'HDC') WITH VALUES;
    DECLARE @pk sysname = (SELECT name FROM sys.key_constraints
                           WHERE parent_object_id = OBJECT_ID('dbo.tblBA204_FeatureImportance') AND type = 'PK');
    DECLARE @cmd nvarchar(400) = N'ALTER TABLE dbo.tblBA204_FeatureImportance DROP CONSTRAINT ' + QUOTENAME(@pk);
    IF @pk IS NOT NULL EXEC (@cmd);
    EXEC (N'ALTER TABLE dbo.tblBA204_FeatureImportance ADD CONSTRAINT PK_FeatureImportance PRIMARY KEY (Dept, Metric, Feature)');
END
GO

/* ---------- 3. View dasar: tabel + kolom Dept ---------- */
CREATE OR ALTER VIEW dbo.vw_D_PODailyOutput AS
SELECT t.*, Dept = ISNULL(d.Dept, N'HDC') FROM dbo.tblBA204_PODailyOutput t OUTER APPLY dbo.fn_Dept(t.ProductType) d;
GO
CREATE OR ALTER VIEW dbo.vw_D_PODetailsReject AS
SELECT t.*, Dept = ISNULL(d.Dept, N'HDC') FROM dbo.tblBA204_PODetailsReject t OUTER APPLY dbo.fn_Dept(t.ProductType) d;
GO
CREATE OR ALTER VIEW dbo.vw_D_DailyOutput2 AS
SELECT t.*, Dept = ISNULL(d.Dept, N'HDC') FROM dbo.tblBA204_DailyOutput2 t OUTER APPLY dbo.fn_Dept(t.ProductType) d;
GO
CREATE OR ALTER VIEW dbo.vw_D_Productivity2 AS
SELECT t.*, Dept = ISNULL(d.Dept, N'HDC') FROM dbo.tblBA204_Productivity2 t OUTER APPLY dbo.fn_Dept(t.ProductType) d;
GO
CREATE OR ALTER VIEW dbo.vw_D_POHeader AS
SELECT t.*, Dept = ISNULL(d.Dept, N'HDC') FROM dbo.tblBA204_POHeader t OUTER APPLY dbo.fn_Dept(t.ProductType) d;
GO

/* ---------- 4. Data harian per departemen ---------- */
CREATE OR ALTER VIEW dbo.vw_Harian AS
WITH o AS (
    SELECT x.Dept, x.DateReport AS Tanggal, SUM(x.Qty_Output) AS Output_
    FROM dbo.vw_D_PODailyOutput x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
    WHERE x.Process = dp.ProsesOutput AND x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport
), s AS (
    SELECT Dept, DateReport AS Tanggal, SUM(Reject_qty) AS Scrap
    FROM dbo.vw_D_PODetailsReject WHERE DateReport IS NOT NULL
    GROUP BY Dept, DateReport
), p AS (
    SELECT Dept, DateOperation AS Tanggal, SUM(Target_Output) AS PlanOutput, MAX(Target_Yield) AS TargetYield
    FROM dbo.vw_D_DailyOutput2 GROUP BY Dept, DateOperation
), t AS (
    SELECT Dept, Tanggal FROM o UNION SELECT Dept, Tanggal FROM s UNION SELECT Dept, Tanggal FROM p
)
SELECT t.Dept, t.Tanggal,
       PlanOutput  = CAST(ISNULL(p.PlanOutput, 0) AS float),
       TargetYield = CAST(COALESCE(NULLIF(p.TargetYield, 0), dp.TargetYieldDefault) AS float),
       Output_     = CAST(ISNULL(o.Output_, 0) AS float),
       Scrap       = CAST(ISNULL(s.Scrap, 0) AS float)
FROM t
JOIN dbo.tblBA204_Departemen dp ON dp.Dept = t.Dept
LEFT JOIN o ON o.Dept = t.Dept AND o.Tanggal = t.Tanggal
LEFT JOIN s ON s.Dept = t.Dept AND s.Tanggal = t.Tanggal
LEFT JOIN p ON p.Dept = t.Dept AND p.Tanggal = t.Tanggal;
GO

/* WIP & progres PO per departemen pada akhir suatu tanggal */
CREATE OR ALTER FUNCTION dbo.fn_WIP_SnapshotDept (@Tanggal date, @Dept nvarchar(10))
RETURNS TABLE AS RETURN
WITH dp AS (SELECT * FROM dbo.tblBA204_Departemen WHERE Dept = @Dept),
b AS (
    SELECT x.PON, SUM(x.Qty_Start) AS Mulai
    FROM dbo.vw_D_PODailyOutput x JOIN dp ON x.Process = dp.ProsesWIPAwal
    WHERE x.Dept = @Dept AND x.DateOperation <= @Tanggal
    GROUP BY x.PON
), c AS (
    SELECT x.PON, SUM(x.Qty_Output) AS Selesai
    FROM dbo.vw_D_PODailyOutput x JOIN dp ON x.Process = dp.ProsesWIPAkhir
    WHERE x.Dept = @Dept AND x.DateOperation <= @Tanggal
    GROUP BY x.PON
)
SELECT WIP       = CAST(ISNULL(SUM(CASE WHEN b.Mulai - ISNULL(c.Selesai, 0) > 0
                                        THEN b.Mulai - ISNULL(c.Selesai, 0) ELSE 0 END), 0) AS float),
       ProgresPO = CAST(SUM(CASE WHEN c.PON IS NOT NULL THEN 1 ELSE 0 END) AS float) / NULLIF(COUNT(*), 0)
FROM b LEFT JOIN c ON c.PON = b.PON;
GO

/* versi lama (dipakai skrip lain) = departemen HDC */
CREATE OR ALTER FUNCTION dbo.fn_WIP_Snapshot (@Tanggal date)
RETURNS TABLE AS RETURN
SELECT WIP, ProgresPO FROM dbo.fn_WIP_SnapshotDept(@Tanggal, N'HDC');
GO

/* Fitur model per departemen (+2 hari ke depan per departemen) */
CREATE OR ALTER VIEW dbo.vw_Fitur AS
WITH a AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield, Output_, Scrap,
           Yield_  = Output_ / NULLIF(Output_ + Scrap, 0),
           Defect_ = Scrap   / NULLIF(Output_ + Scrap, 0),
           IsForecast = 0
    FROM dbo.vw_Harian WHERE Output_ > 0
), last_ AS (
    SELECT Dept, MAX(Tanggal) AS LastDay FROM a GROUP BY Dept
), planned AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield FROM (
        SELECT h.Dept, h.Tanggal, h.PlanOutput, h.TargetYield,
               rn = ROW_NUMBER() OVER (PARTITION BY h.Dept ORDER BY h.Tanggal)
        FROM dbo.vw_Harian h JOIN last_ l ON l.Dept = h.Dept
        WHERE h.Tanggal > l.LastDay AND h.PlanOutput > 0) x
    WHERE rn <= 2
), gen AS (
    SELECT Dept, Tanggal FROM (
        SELECT l.Dept, d.Tanggal, rn = ROW_NUMBER() OVER (PARTITION BY l.Dept ORDER BY d.Tanggal)
        FROM last_ l
        CROSS APPLY (VALUES (1),(2),(3),(4)) n(i)
        CROSS APPLY (SELECT DATEADD(day, n.i, l.LastDay) AS Tanggal) d
        WHERE (DATEDIFF(day, '19000101', d.Tanggal) % 7) <> 6
          AND NOT EXISTS (SELECT 1 FROM planned p WHERE p.Dept = l.Dept)) x
    WHERE rn <= 2
), f AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield FROM planned
    UNION ALL
    SELECT g.Dept, g.Tanggal,
           (SELECT AVG(x.PlanOutput) FROM (SELECT TOP (5) PlanOutput FROM a WHERE a.Dept = g.Dept AND PlanOutput > 0 ORDER BY Tanggal DESC) x),
           (SELECT TOP (1) TargetYield FROM a WHERE a.Dept = g.Dept ORDER BY Tanggal DESC)
    FROM gen g
), s AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield, Output_, Scrap, Yield_, Defect_, IsForecast FROM a
    UNION ALL
    SELECT Dept, Tanggal, PlanOutput, TargetYield, NULL, NULL, NULL, NULL, 1 FROM f
)
SELECT s.Dept, s.Tanggal, s.IsForecast, s.PlanOutput, s.TargetYield,
       s.Output_, s.Scrap, s.Yield_, s.Defect_,
       plan_output = s.PlanOutput,
       output_lag1 = LAST_VALUE(s.Output_) IGNORE NULLS OVER (PARTITION BY s.Dept ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       output_ma3  = AVG(s.Output_)  OVER (PARTITION BY s.Dept ORDER BY s.Tanggal ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING),
       yield_lag1  = LAST_VALUE(s.Yield_) IGNORE NULLS OVER (PARTITION BY s.Dept ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       yield_ma7   = AVG(s.Yield_)   OVER (PARTITION BY s.Dept ORDER BY s.Tanggal ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING),
       defect_lag1 = LAST_VALUE(s.Defect_) IGNORE NULLS OVER (PARTITION BY s.Dept ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       wip         = w.WIP,
       progres_po  = w.ProgresPO,
       hari_ke     = CAST((DATEDIFF(day, '19000101', s.Tanggal) % 7) + 1 AS float)
FROM s
OUTER APPLY dbo.fn_WIP_SnapshotDept(DATEADD(day, -1, s.Tanggal), s.Dept) w;
GO

/* ---------- 5. View dashboard per departemen ---------- */
CREATE OR ALTER VIEW dbo.vw_PBI_PO AS
WITH pos AS (
    SELECT DISTINCT Dept, PON FROM dbo.vw_D_PODailyOutput
    UNION SELECT Dept, PON FROM dbo.vw_D_POHeader
    UNION SELECT DISTINCT Dept, PON FROM dbo.vw_D_PODetailsReject
), agg AS (
    SELECT x.Dept, x.PON,
           Material     = MAX(x.Material),
           BendingStart = SUM(CASE WHEN x.Process = dp.ProsesWIPAwal  THEN x.Qty_Start  ELSE 0 END),
           CartonOutput = SUM(CASE WHEN x.Process = dp.ProsesWIPAkhir THEN x.Qty_Output ELSE 0 END),
           FirstDate    = MIN(x.DateOperation),
           LastDate     = MAX(x.DateOperation)
    FROM dbo.vw_D_PODailyOutput x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
    GROUP BY x.Dept, x.PON
)
SELECT p.Dept, p.PON,
       Material   = COALESCE(h.Material, a.Material),
       SKU        = COALESCE(m.SKU, REPLACE(h.MaterialDesc, N'.', N' '), N'Material ' + COALESCE(h.Material, a.Material)),
       Batch      = h.Batch,
       Supplier   = h.Supplier,
       StatusPO   = COALESCE(NULLIF(h.ProductionStatus, N''), CASE WHEN a.CartonOutput > 0 THEN N'Completed' ELSE N'WIP' END),
       IsCompleted= CAST(CASE WHEN COALESCE(h.ProductionStatus, N'') LIKE N'Completed%' THEN 1
                              WHEN h.ProductionStatus IS NULL AND a.CartonOutput > 0 THEN 1 ELSE 0 END AS int),
       QCRelease  = h.QCRelease,
       StartDate  = COALESCE(h.StartDate, a.FirstDate),
       EndDate    = COALESCE(h.EndDate, a.LastDate),
       BendingStart = CAST(ISNULL(a.BendingStart, 0) AS float),
       CartonOutput = CAST(ISNULL(a.CartonOutput, 0) AS float),
       WIP_Qty    = CAST(CASE WHEN ISNULL(a.BendingStart,0) - ISNULL(a.CartonOutput,0) > 0
                              THEN ISNULL(a.BendingStart,0) - ISNULL(a.CartonOutput,0) ELSE 0 END AS float)
FROM pos p
LEFT JOIN agg a ON a.Dept = p.Dept AND a.PON = p.PON
LEFT JOIN dbo.vw_D_POHeader h ON h.Dept = p.Dept AND h.PON = p.PON
LEFT JOIN dbo.tblBA204_MaterialMaster m ON m.Material = COALESCE(h.Material, a.Material);
GO

CREATE OR ALTER VIEW dbo.vw_PBI_OutputPO AS
WITH o AS (
    SELECT x.Dept, x.DateReport AS Tanggal, x.PON, SUM(x.Qty_Output) AS Output_
    FROM dbo.vw_D_PODailyOutput x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
    WHERE x.Process = dp.ProsesOutput AND x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport, x.PON
), s AS (
    SELECT Dept, DateReport AS Tanggal, PON, SUM(Reject_qty) AS Scrap
    FROM dbo.vw_D_PODetailsReject WHERE DateReport IS NOT NULL
    GROUP BY Dept, DateReport, PON
)
SELECT Dept    = COALESCE(o.Dept, s.Dept),
       Tanggal = COALESCE(o.Tanggal, s.Tanggal),
       PON     = COALESCE(o.PON, s.PON),
       Output_ = CAST(ISNULL(o.Output_, 0) AS float),
       Scrap   = CAST(ISNULL(s.Scrap, 0) AS float)
FROM o FULL OUTER JOIN s ON s.Dept = o.Dept AND s.Tanggal = o.Tanggal AND s.PON = o.PON;
GO

CREATE OR ALTER VIEW dbo.vw_PBI_Plan AS
SELECT x.Dept, Tanggal = x.DateOperation,
       PlanOutput  = CAST(SUM(x.Target_Output) AS float),
       TargetYield = CAST(COALESCE(NULLIF(MAX(x.Target_Yield), 0), MAX(dp.TargetYieldDefault)) AS float)
FROM dbo.vw_D_DailyOutput2 x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
GROUP BY x.Dept, x.DateOperation;
GO

CREATE OR ALTER VIEW dbo.vw_PBI_Produktivitas AS
SELECT Dept, Tanggal = DateOperation,
       ActOutput   = CAST(SUM(ActOutput) AS float),
       TotalManhours = CAST(SUM(TotalManhours) AS float),
       StdHours    = CAST(SUM(ActOutput * MaxMHP) AS float),
       Headcount   = CAST(SUM(TotalHC) AS float),
       Absen       = CAST(SUM(AbsentHC) AS float),
       Overtime    = CAST(SUM(ActOT) AS float),
       NormalManhours = CAST(SUM(NormalManHours) AS float)
FROM dbo.vw_D_Productivity2
GROUP BY Dept, DateOperation;
GO

CREATE OR ALTER VIEW dbo.vw_PBI_Defect AS
SELECT r.Dept, Tanggal = r.DateReport, r.PON, r.Process,
       RejectCode = CASE WHEN LEFT(r.RejectType, 1) = N'(' AND CHARINDEX(N')', r.RejectType) > 2
                         THEN SUBSTRING(r.RejectType, 2, CHARINDEX(N')', r.RejectType) - 2) END,
       RejectName = LTRIM(RTRIM(REPLACE(REPLACE(
                        CASE WHEN CHARINDEX(N')', r.RejectType) > 0
                             THEN SUBSTRING(r.RejectType, CHARINDEX(N')', r.RejectType) + 1, 200)
                             ELSE r.RejectType END, CHAR(13), N' '), CHAR(10), N' '))),
       Qty = CAST(r.Reject_qty AS float)
FROM dbo.vw_D_PODetailsReject r
WHERE r.DateReport IS NOT NULL AND r.Reject_qty <> 0;
GO

CREATE OR ALTER VIEW dbo.vw_PBI_FeatureImportance AS
SELECT Dept, Metric, Feature, Importance = CAST(Importance AS float), ModelVersion
FROM dbo.tblBA204_FeatureImportance;
GO

/* Prediksi: model XGBoost saat ini dilatih dengan data HDC.
   Departemen lain baru diprediksi setelah punya model sendiri
   (baris di tblBA204_ModelInfo dengan Dept tersebut).           */
CREATE OR ALTER VIEW dbo.vw_PBI_Prediksi AS
SELECT f.Dept, f.Tanggal, v.Metric,
       Aktual   = v.Aktual,
       Prediksi = v.Prediksi,
       Target   = v.Target,
       IsForecast = f.IsForecast,
       APE      = CASE WHEN v.Aktual IS NULL OR v.Aktual = 0 THEN NULL
                       ELSE ABS(v.Aktual - v.Prediksi) / ABS(v.Aktual) END
FROM dbo.vw_Fitur f
CROSS APPLY (SELECT
    pOut = CASE WHEN f.Dept = N'HDC' THEN dbo.fn_Pred_Output(f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke) END,
    pYld = CASE WHEN f.Dept = N'HDC' THEN dbo.fn_Pred_Yield (f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke) END,
    pDef = CASE WHEN f.Dept = N'HDC' THEN dbo.fn_Pred_Defect(f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke) END) p
CROSS APPLY (VALUES
    (N'Output', f.Output_,  CASE WHEN p.pOut < 0 THEN 0 ELSE p.pOut END,                       f.PlanOutput),
    (N'Yield',  f.Yield_,   CASE WHEN p.pYld > 1 THEN 1 WHEN p.pYld < 0 THEN 0 ELSE p.pYld END, f.TargetYield),
    (N'Defect', f.Defect_,  CASE WHEN p.pDef > 1 THEN 1 WHEN p.pDef < 0 THEN 0 ELSE p.pDef END, 1 - f.TargetYield)
) v(Metric, Aktual, Prediksi, Target)
WHERE EXISTS (SELECT 1 FROM dbo.tblBA204_ModelInfo mi WHERE mi.Dept = f.Dept);
GO

CREATE OR ALTER VIEW dbo.vw_PBI_Info AS
SELECT LastUpdate = (SELECT MAX(x) FROM (
           SELECT MAX(InputOn) AS x FROM dbo.tblBA204_PODailyOutput
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_DailyOutput2
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_Productivity2
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_POHeader) u),
       LastDataDate = (SELECT MAX(Tanggal) FROM dbo.vw_Harian WHERE Output_ > 0),
       ModelVersion = (SELECT MAX(ModelVersion) FROM dbo.tblBA204_ModelInfo);
GO
