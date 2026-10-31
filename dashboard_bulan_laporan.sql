/* =====================================================================
   PBL PBLIF3-MD04  -  Bagian 6: dashboard hanya menampilkan bulan laporan
   Bulan laporan = bulan yang punya data Daily Output Summary (target harian)
   yang sudah di-POST. Baris Data Process Prod dengan "Date for Daily Report"
   di luar bulan itu (mis. 28 Feb di file bulan Maret) tidak ditampilkan,
   tapi tetap tersimpan dan tetap dipakai untuk menghitung WIP.
   Aman dijalankan berulang.
   ===================================================================== */
USE [PBL_MonitoringProduksi];
GO

CREATE OR ALTER VIEW dbo.vw_BulanLaporan AS
-- bulan laporan = bulan yang punya Daily Output Summary, ATAU bulan yang punya
-- data Data Process Prod minimal 3 hari laporan (baris nyasar 1-2 hari, mis. 28 Feb, tetap disembunyikan)
SELECT Dept, Bulan = DATEFROMPARTS(YEAR(DateOperation), MONTH(DateOperation), 1)
FROM dbo.tblBA204_DailyOutput2
WHERE DateOperation IS NOT NULL
UNION
SELECT Dept, BulanReport
FROM dbo.tblBA204_PODailyOutput
WHERE DateReport IS NOT NULL
GROUP BY Dept, BulanReport
HAVING COUNT(DISTINCT DateReport) >= 3;
GO

CREATE OR ALTER VIEW dbo.vw_Harian AS
WITH o AS (
    SELECT x.Dept, x.DateReport AS Tanggal, SUM(x.Qty_Output) AS Output_
    FROM dbo.vw_D_PODailyOutput x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
    JOIN dbo.vw_BulanLaporan bl ON bl.Dept = x.Dept AND bl.Bulan = DATEFROMPARTS(YEAR(x.DateReport), MONTH(x.DateReport), 1)
    WHERE x.Process = dp.ProsesOutput AND x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport
), s AS (
    SELECT x.Dept, x.DateReport AS Tanggal, SUM(x.Reject_qty) AS Scrap
    FROM dbo.vw_D_PODetailsReject x
    JOIN dbo.vw_BulanLaporan bl ON bl.Dept = x.Dept AND bl.Bulan = DATEFROMPARTS(YEAR(x.DateReport), MONTH(x.DateReport), 1)
    WHERE x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport
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

CREATE OR ALTER VIEW dbo.vw_PBI_OutputPO AS
WITH o AS (
    SELECT x.Dept, x.DateReport AS Tanggal, x.PON, SUM(x.Qty_Output) AS Output_
    FROM dbo.vw_D_PODailyOutput x JOIN dbo.tblBA204_Departemen dp ON dp.Dept = x.Dept
    JOIN dbo.vw_BulanLaporan bl ON bl.Dept = x.Dept AND bl.Bulan = DATEFROMPARTS(YEAR(x.DateReport), MONTH(x.DateReport), 1)
    WHERE x.Process = dp.ProsesOutput AND x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport, x.PON
), s AS (
    SELECT x.Dept, x.DateReport AS Tanggal, x.PON, SUM(x.Reject_qty) AS Scrap
    FROM dbo.vw_D_PODetailsReject x
    JOIN dbo.vw_BulanLaporan bl ON bl.Dept = x.Dept AND bl.Bulan = DATEFROMPARTS(YEAR(x.DateReport), MONTH(x.DateReport), 1)
    WHERE x.DateReport IS NOT NULL
    GROUP BY x.Dept, x.DateReport, x.PON
)
SELECT Dept    = COALESCE(o.Dept, s.Dept),
       Tanggal = COALESCE(o.Tanggal, s.Tanggal),
       PON     = COALESCE(o.PON, s.PON),
       Output_ = CAST(ISNULL(o.Output_, 0) AS float),
       Scrap   = CAST(ISNULL(s.Scrap, 0) AS float)
FROM o FULL OUTER JOIN s ON s.Dept = o.Dept AND s.Tanggal = o.Tanggal AND s.PON = o.PON;
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
JOIN dbo.vw_BulanLaporan bl ON bl.Dept = r.Dept AND bl.Bulan = DATEFROMPARTS(YEAR(r.DateReport), MONTH(r.DateReport), 1)
WHERE r.DateReport IS NOT NULL AND r.Reject_qty <> 0;
GO
