/* =====================================================================
   PBL PBLIF3-MD04  -  Bagian 8: fitur model memakai data harian lengkap
   vw_HarianSemua = data harian tanpa filter bulan laporan (untuk fitur
   XGBoost: lag/rata-rata butuh hari sebelumnya, juga lebih cepat).
   vw_Harian (dashboard) tetap hanya bulan laporan.
   ===================================================================== */
USE [PBL_MonitoringProduksi];
GO
CREATE OR ALTER VIEW dbo.vw_HarianSemua AS
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

CREATE OR ALTER VIEW dbo.vw_Fitur AS
WITH a AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield, Output_, Scrap,
           Yield_  = Output_ / NULLIF(Output_ + Scrap, 0),
           Defect_ = Scrap   / NULLIF(Output_ + Scrap, 0),
           IsForecast = 0
    FROM dbo.vw_HarianSemua WHERE Output_ > 0
), last_ AS (
    SELECT Dept, MAX(Tanggal) AS LastDay FROM a GROUP BY Dept
), planned AS (
    SELECT Dept, Tanggal, PlanOutput, TargetYield FROM (
        SELECT h.Dept, h.Tanggal, h.PlanOutput, h.TargetYield,
               rn = ROW_NUMBER() OVER (PARTITION BY h.Dept ORDER BY h.Tanggal)
        FROM dbo.vw_HarianSemua h JOIN last_ l ON l.Dept = h.Dept
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
