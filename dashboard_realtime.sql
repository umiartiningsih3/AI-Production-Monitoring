/* =====================================================================
   PBL PBLIF3-MD04  -  Bagian 2: dashboard real-time + prediksi
   Jalankan SETELAH setup_database.sql (bagian 1).
   Aman dijalankan berulang (CREATE OR ALTER / IF NOT EXISTS).
   ===================================================================== */
USE [PBL_MonitoringProduksi];
GO

/* ---------- Tabel tambahan ---------- */
IF OBJECT_ID('dbo.tblBA204_POHeader','U') IS NULL
CREATE TABLE dbo.tblBA204_POHeader (
    ProductType      nvarchar(100) NOT NULL,
    PON              nvarchar(50)  NOT NULL,
    Batch            nvarchar(50)  NULL,
    Material         nvarchar(50)  NULL,
    MaterialDesc     nvarchar(150) NULL,
    Supplier         nvarchar(100) NULL,
    ProductionStatus nvarchar(50)  NULL,
    QCRelease        nvarchar(30)  NULL,
    QCReleaseDate    date          NULL,
    StartDate        date          NULL,
    EndDate          date          NULL,
    InputBy          nvarchar(100) NULL,
    InputOn          datetime2(0)  NULL,
    CONSTRAINT PK_POHeader PRIMARY KEY (ProductType, PON)
);
GO

IF OBJECT_ID('dbo.tblBA204_FeatureImportance','U') IS NULL
CREATE TABLE dbo.tblBA204_FeatureImportance (
    Metric       nvarchar(20)  NOT NULL,
    Feature      nvarchar(50)  NOT NULL,
    Importance   decimal(9,6)  NOT NULL,
    ModelVersion nvarchar(50)  NOT NULL,
    CONSTRAINT PK_FeatureImportance PRIMARY KEY (Metric, Feature)
);
GO

IF OBJECT_ID('dbo.tblBA204_ModelInfo','U') IS NULL
CREATE TABLE dbo.tblBA204_ModelInfo (
    Metric       nvarchar(20)  NOT NULL PRIMARY KEY,
    ModelVersion nvarchar(50)  NOT NULL,
    TrainRows    int           NOT NULL,
    TrainFrom    date          NULL,
    TrainTo      date          NULL,
    MAE          decimal(18,6) NULL,
    MAPE         decimal(9,6)  NULL,
    TrainedOn    datetime2(0)  NOT NULL
);
GO

/* ---------- Data harian (dasar KPI & prediksi) ----------
   Output  = Good output proses akhir (PROSES_3) per Date for Daily Report
   Scrap   = semua reject (semua proses) per Date for Daily Report
   Sama dengan rumus di sheet Daily Output Summary.                  */
CREATE OR ALTER VIEW dbo.vw_Harian AS
WITH o AS (
    SELECT DateReport AS Tanggal, SUM(Qty_Output) AS Output_
    FROM dbo.tblBA204_PODailyOutput
    WHERE Process = N'PROSES_3' AND DateReport IS NOT NULL
    GROUP BY DateReport
), s AS (
    SELECT DateReport AS Tanggal, SUM(Reject_qty) AS Scrap
    FROM dbo.tblBA204_PODetailsReject
    WHERE DateReport IS NOT NULL
    GROUP BY DateReport
), p AS (
    SELECT DateOperation AS Tanggal, SUM(Target_Output) AS PlanOutput,
           MAX(Target_Yield) AS TargetYield
    FROM dbo.tblBA204_DailyOutput2
    GROUP BY DateOperation
), t AS (
    SELECT Tanggal FROM o UNION SELECT Tanggal FROM s UNION SELECT Tanggal FROM p
)
SELECT t.Tanggal,
       PlanOutput  = CAST(ISNULL(p.PlanOutput, 0) AS float),
       TargetYield = CAST(COALESCE(NULLIF(p.TargetYield, 0), 0.975) AS float),
       Output_     = CAST(ISNULL(o.Output_, 0) AS float),
       Scrap       = CAST(ISNULL(s.Scrap, 0) AS float)
FROM t
LEFT JOIN o ON o.Tanggal = t.Tanggal
LEFT JOIN s ON s.Tanggal = t.Tanggal
LEFT JOIN p ON p.Tanggal = t.Tanggal;
GO

/* WIP (pcs sudah masuk PROSES_1 tapi belum selesai PROSES_4) & progres PO pada akhir suatu tanggal */
CREATE OR ALTER FUNCTION dbo.fn_WIP_Snapshot (@Tanggal date)
RETURNS TABLE AS RETURN
WITH b AS (
    SELECT PON, SUM(Qty_Start) AS Mulai
    FROM dbo.tblBA204_PODailyOutput
    WHERE Process = N'PROSES_1' AND DateOperation <= @Tanggal
    GROUP BY PON
), c AS (
    SELECT PON, SUM(Qty_Output) AS Selesai
    FROM dbo.tblBA204_PODailyOutput
    WHERE Process = N'PROSES_4' AND DateOperation <= @Tanggal
    GROUP BY PON
)
SELECT WIP       = CAST(ISNULL(SUM(CASE WHEN b.Mulai - ISNULL(c.Selesai, 0) > 0
                                        THEN b.Mulai - ISNULL(c.Selesai, 0) ELSE 0 END), 0) AS float),
       ProgresPO = CAST(SUM(CASE WHEN c.PON IS NOT NULL THEN 1 ELSE 0 END) AS float)
                   / NULLIF(COUNT(*), 0)
FROM b LEFT JOIN c ON c.PON = b.PON;
GO

/* Fitur model: baris hari kerja aktual + 2 hari ke depan (forecast).
   Fitur dihitung dari data s/d hari sebelumnya (tidak bocor).        */
CREATE OR ALTER VIEW dbo.vw_Fitur AS
WITH a AS (
    SELECT Tanggal, PlanOutput, TargetYield, Output_, Scrap,
           Yield_  = Output_ / NULLIF(Output_ + Scrap, 0),
           Defect_ = Scrap   / NULLIF(Output_ + Scrap, 0),
           IsForecast = 0
    FROM dbo.vw_Harian
    WHERE Output_ > 0
), last_ AS (
    SELECT MAX(Tanggal) AS LastDay FROM a
), planned AS (                       -- hari ke depan yang sudah punya target
    SELECT TOP (2) h.Tanggal, h.PlanOutput, h.TargetYield
    FROM dbo.vw_Harian h CROSS JOIN last_
    WHERE h.Tanggal > last_.LastDay AND h.PlanOutput > 0
    ORDER BY h.Tanggal
), gen AS (                           -- kalau belum ada target ke depan: 2 hari kerja berikutnya
    SELECT TOP (2) d.Tanggal
    FROM last_
    CROSS APPLY (VALUES (1),(2),(3),(4)) n(i)
    CROSS APPLY (SELECT DATEADD(day, n.i, last_.LastDay) AS Tanggal) d
    WHERE (DATEDIFF(day, '19000101', d.Tanggal) % 7) <> 6        -- bukan Minggu
      AND NOT EXISTS (SELECT 1 FROM planned)
    ORDER BY d.Tanggal
), f AS (
    SELECT Tanggal, PlanOutput, TargetYield FROM planned
    UNION ALL
    SELECT g.Tanggal,
           (SELECT AVG(x.PlanOutput) FROM (SELECT TOP (5) PlanOutput FROM a WHERE PlanOutput > 0 ORDER BY Tanggal DESC) x),
           (SELECT TOP (1) TargetYield FROM a ORDER BY Tanggal DESC)
    FROM gen g
), s AS (
    SELECT Tanggal, PlanOutput, TargetYield, Output_, Scrap, Yield_, Defect_, IsForecast FROM a
    UNION ALL
    SELECT Tanggal, PlanOutput, TargetYield, NULL, NULL, NULL, NULL, 1 FROM f
)
SELECT s.Tanggal, s.IsForecast, s.PlanOutput, s.TargetYield,
       s.Output_, s.Scrap, s.Yield_, s.Defect_,
       plan_output = s.PlanOutput,
       output_lag1 = LAST_VALUE(s.Output_) IGNORE NULLS OVER (ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       output_ma3  = AVG(s.Output_)  OVER (ORDER BY s.Tanggal ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING),
       yield_lag1  = LAST_VALUE(s.Yield_) IGNORE NULLS OVER (ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       yield_ma7   = AVG(s.Yield_)   OVER (ORDER BY s.Tanggal ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING),
       defect_lag1 = LAST_VALUE(s.Defect_) IGNORE NULLS OVER (ORDER BY s.Tanggal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
       wip         = w.WIP,
       progres_po  = w.ProgresPO,
       hari_ke     = CAST((DATEDIFF(day, '19000101', s.Tanggal) % 7) + 1 AS float)
FROM s
OUTER APPLY dbo.fn_WIP_Snapshot(DATEADD(day, -1, s.Tanggal)) w;
GO

/* ---------- View untuk Power BI (DirectQuery) ---------- */

CREATE OR ALTER VIEW dbo.vw_PBI_Kalender AS
WITH r AS (
    SELECT MIN(d) AS mn, MAX(d) AS mx FROM (
        SELECT DateOperation AS d FROM dbo.tblBA204_PODailyOutput
        UNION ALL SELECT DateReport FROM dbo.tblBA204_PODailyOutput
        UNION ALL SELECT DateOperation FROM dbo.tblBA204_DailyOutput2
        UNION ALL SELECT DateOperation FROM dbo.tblBA204_Productivity2
        UNION ALL SELECT CAST(GETDATE() AS date)
    ) x WHERE d IS NOT NULL
), n AS (
    SELECT TOP (4000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), d AS (
    SELECT DATEADD(day, n.i, r.mn) AS [Date]
    FROM r JOIN n ON DATEADD(day, n.i, r.mn) <= DATEADD(day, 7, r.mx)
)
SELECT [Date],
       Tahun      = YEAR([Date]),
       BulanNo    = MONTH([Date]),
       Bulan      = LEFT(DATENAME(month, [Date]), 3) + N' ' + CAST(YEAR([Date]) AS nvarchar(4)),
       BulanPendek= CHOOSE(MONTH([Date]), N'Jan',N'Feb',N'Mar',N'Apr',N'Mei',N'Jun',N'Jul',N'Agu',N'Sep',N'Okt',N'Nov',N'Des'),
       BulanUrut  = YEAR([Date]) * 100 + MONTH([Date]),
       Tanggal    = DAY([Date]),
       HariKe     = (DATEDIFF(day, '19000101', [Date]) % 7) + 1,
       Hari       = CHOOSE((DATEDIFF(day, '19000101', [Date]) % 7) + 1, N'Sen',N'Sel',N'Rab',N'Kam',N'Jum',N'Sab',N'Min')
FROM d;
GO

-- Dimensi PO (produk/SKU, status, WIP saat ini)
CREATE OR ALTER VIEW dbo.vw_PBI_PO AS
WITH pos AS (
    SELECT DISTINCT PON FROM dbo.tblBA204_PODailyOutput
    UNION SELECT PON FROM dbo.tblBA204_POHeader
    UNION SELECT DISTINCT PON FROM dbo.tblBA204_PODetailsReject
), agg AS (
    SELECT PON,
           Material     = MAX(Material),
           QtyMulaiWIP = SUM(CASE WHEN Process = N'PROSES_1'   THEN Qty_Start  ELSE 0 END),
           QtySelesaiWIP = SUM(CASE WHEN Process = N'PROSES_4' THEN Qty_Output ELSE 0 END),
           FirstDate    = MIN(DateOperation),
           LastDate     = MAX(DateOperation)
    FROM dbo.tblBA204_PODailyOutput GROUP BY PON
)
SELECT p.PON,
       Material   = COALESCE(h.Material, a.Material),
       SKU        = COALESCE(m.SKU, REPLACE(h.MaterialDesc, N'.', N' '), N'Material ' + COALESCE(h.Material, a.Material)),
       Batch      = h.Batch,
       Supplier   = h.Supplier,
       StatusPO   = COALESCE(NULLIF(h.ProductionStatus, N''), CASE WHEN a.QtySelesaiWIP > 0 THEN N'Completed' ELSE N'WIP' END),
       IsCompleted= CAST(CASE WHEN COALESCE(h.ProductionStatus, N'') LIKE N'Completed%' THEN 1
                              WHEN h.ProductionStatus IS NULL AND a.QtySelesaiWIP > 0 THEN 1 ELSE 0 END AS int),
       QCRelease  = h.QCRelease,
       StartDate  = COALESCE(h.StartDate, a.FirstDate),
       EndDate    = COALESCE(h.EndDate, a.LastDate),
       QtyMulaiWIP = CAST(ISNULL(a.QtyMulaiWIP, 0) AS float),
       QtySelesaiWIP = CAST(ISNULL(a.QtySelesaiWIP, 0) AS float),
       WIP_Qty    = CAST(CASE WHEN ISNULL(a.QtyMulaiWIP,0) - ISNULL(a.QtySelesaiWIP,0) > 0
                              THEN ISNULL(a.QtyMulaiWIP,0) - ISNULL(a.QtySelesaiWIP,0) ELSE 0 END AS float)
FROM pos p
LEFT JOIN agg a ON a.PON = p.PON
LEFT JOIN dbo.tblBA204_POHeader h ON h.PON = p.PON
LEFT JOIN dbo.tblBA204_MaterialMaster m ON m.Material = COALESCE(h.Material, a.Material);
GO

-- Output & scrap per tanggal laporan per PO (fakta utama KPI)
CREATE OR ALTER VIEW dbo.vw_PBI_OutputPO AS
WITH o AS (
    SELECT DateReport AS Tanggal, PON, SUM(Qty_Output) AS Output_
    FROM dbo.tblBA204_PODailyOutput
    WHERE Process = N'PROSES_3' AND DateReport IS NOT NULL
    GROUP BY DateReport, PON
), s AS (
    SELECT DateReport AS Tanggal, PON, SUM(Reject_qty) AS Scrap
    FROM dbo.tblBA204_PODetailsReject
    WHERE DateReport IS NOT NULL
    GROUP BY DateReport, PON
)
SELECT Tanggal = COALESCE(o.Tanggal, s.Tanggal),
       PON     = COALESCE(o.PON, s.PON),
       Output_ = CAST(ISNULL(o.Output_, 0) AS float),
       Scrap   = CAST(ISNULL(s.Scrap, 0) AS float)
FROM o FULL OUTER JOIN s ON s.Tanggal = o.Tanggal AND s.PON = o.PON;
GO

-- Target harian
CREATE OR ALTER VIEW dbo.vw_PBI_Plan AS
SELECT Tanggal = DateOperation,
       PlanOutput  = CAST(SUM(Target_Output) AS float),
       TargetYield = CAST(COALESCE(NULLIF(MAX(Target_Yield), 0), 0.975) AS float)
FROM dbo.tblBA204_DailyOutput2
GROUP BY DateOperation;
GO

-- Produktivitas harian (StdHours = output x MHP threshold)
CREATE OR ALTER VIEW dbo.vw_PBI_Produktivitas AS
SELECT Tanggal = DateOperation,
       ActOutput   = CAST(SUM(ActOutput) AS float),
       TotalManhours = CAST(SUM(TotalManhours) AS float),
       StdHours    = CAST(SUM(ActOutput * MaxMHP) AS float),
       Headcount   = CAST(SUM(TotalHC) AS float),
       Absen       = CAST(SUM(AbsentHC) AS float),
       Overtime    = CAST(SUM(ActOT) AS float),
       NormalManhours = CAST(SUM(NormalManHours) AS float)
FROM dbo.tblBA204_Productivity2
GROUP BY DateOperation;
GO

-- Detail defect per PO per jenis
CREATE OR ALTER VIEW dbo.vw_PBI_Defect AS
SELECT Tanggal = r.DateReport,
       r.PON,
       r.Process,
       RejectCode = CASE WHEN LEFT(r.RejectType, 1) = N'(' AND CHARINDEX(N')', r.RejectType) > 2
                         THEN SUBSTRING(r.RejectType, 2, CHARINDEX(N')', r.RejectType) - 2) END,
       RejectName = LTRIM(RTRIM(REPLACE(REPLACE(
                        CASE WHEN CHARINDEX(N')', r.RejectType) > 0
                             THEN SUBSTRING(r.RejectType, CHARINDEX(N')', r.RejectType) + 1, 200)
                             ELSE r.RejectType END, CHAR(13), N' '), CHAR(10), N' '))),
       Qty = CAST(r.Reject_qty AS float)
FROM dbo.tblBA204_PODetailsReject r
WHERE r.DateReport IS NOT NULL AND r.Reject_qty <> 0;
GO

-- Info update terakhir
CREATE OR ALTER VIEW dbo.vw_PBI_Info AS
SELECT LastUpdate = (SELECT MAX(x) FROM (
           SELECT MAX(InputOn) AS x FROM dbo.tblBA204_PODailyOutput
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_DailyOutput2
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_Productivity2
           UNION ALL SELECT MAX(InputOn) FROM dbo.tblBA204_POHeader) u),
       LastDataDate = (SELECT MAX(Tanggal) FROM dbo.vw_Harian WHERE Output_ > 0),
       ModelVersion = (SELECT MAX(ModelVersion) FROM dbo.tblBA204_ModelInfo);
GO

-- Pilihan metrik untuk tombol halaman prediksi
CREATE OR ALTER VIEW dbo.vw_PBI_Metrik AS
SELECT Metric, Urut FROM (VALUES (N'Output', 1), (N'Yield', 2), (N'Defect', 3)) v(Metric, Urut);
GO

-- Feature importance model
CREATE OR ALTER VIEW dbo.vw_PBI_FeatureImportance AS
SELECT Metric, Feature, Importance = CAST(Importance AS float), ModelVersion
FROM dbo.tblBA204_FeatureImportance;
GO
/* ===== Bagian 3: model XGBoost hasil latih (dibuat otomatis) ===== */
USE [PBL_MonitoringProduksi];
GO

CREATE OR ALTER FUNCTION dbo.fn_Pred_Output (@plan_output float, @output_lag1 float, @output_ma3 float, @yield_lag1 float, @yield_ma7 float, @defect_lag1 float, @wip float, @progres_po float, @hari_ke float)
RETURNS float
AS
BEGIN
    -- XGBoost xgb-v1.0: 60 pohon, max_depth 2, learning_rate 0.1, dilatih 21 hari
    RETURN 12717.57142857143 +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 227.19428571428568
                ELSE -8.747321428571501 END
            ELSE -332.004761904762 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 209.0187428571428
                ELSE -7.92726004464297 END
            ELSE -309.8711111111112 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 192.2972434285714
                ELSE -7.184079415457609 END
            ELSE -289.21303703703705 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 107.55569853279155
                ELSE -56.696690460689496 END
            ELSE -269.93216790123455 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 168.30900807166242
                ELSE -8.38129925803362 END
            ELSE -251.93669004115233 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -225.85339013744206
                ELSE -24.136231497002882 END
            ELSE CASE WHEN (@yield_lag1 < 0.9887129409109497 OR @yield_lag1 IS NULL)
                THEN 115.78083063228529
                ELSE -69.52208041260506 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 145.58182097534652
                ELSE -7.490882985146789 END
            ELSE -225.29506168674067 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -202.90746518570813
                ELSE -21.50063862349043 END
            ELSE CASE WHEN (@yield_lag1 < 0.9887129409109497 OR @yield_lag1 IS NULL)
                THEN 100.37000979307285
                ELSE -58.301003690233806 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 125.90567451387295
                ELSE -6.615487254596144 END
            ELSE -201.56844194509324 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -182.31941988542292
                ELSE -19.157628133649876 END
            ELSE CASE WHEN (@yield_lag1 < 0.9887129409109497 OR @yield_lag1 IS NULL)
                THEN 87.02792004344883
                ELSE -48.55844300210911 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 64.17576235696403
                ELSE -35.349016012279456 END
            ELSE -180.43461705250255 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 103.73692596073002
                ELSE -6.814421963339612 END
            ELSE -168.40564258233573 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -160.30440446359532
                ELSE -14.047539291210796 END
            ELSE CASE WHEN (@yield_lag1 < 0.9887129409109497 OR @yield_lag1 IS NULL)
                THEN 69.88157462465777
                ELSE -34.08738138729891 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 89.847445913899
                ELSE -5.927246026714716 END
            ELSE -150.6988735484835 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -144.21773998877785
                ELSE -12.38297384805037 END
            ELSE CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -41.90743957399573
                ELSE 56.85728830385156 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 80.08636173403579
                ELSE -5.407461895054951 END
            ELSE -137.74026692242043 END) +
        (CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
            THEN -131.33554530685535
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 100.22926654484236
                ELSE -6.034947714312565 END END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@wip < 34078.0 OR @wip IS NULL)
                THEN -143.56418954407994
                ELSE -19.44316536300438 END
            ELSE CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -44.74271755804645
                ELSE 50.93278695030975 END END) +
        (CASE WHEN (@output_ma3 < 13942.0 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 68.13129484290178
                ELSE -4.53476164657485 END
            ELSE -121.54283610670598 END) +
        (CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
            THEN -117.7117441578125
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 86.17415303219718
                ELSE -4.954788726594994 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -52.64623338013567
                ELSE 27.137106733279275 END
            ELSE -112.59938158583816 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -108.52955036105128
                ELSE -10.24789114302439 END
            ELSE CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
                THEN 53.434806575165204
                ELSE -26.180081140729456 END END) +
        (CASE WHEN (@output_ma3 < 13942.0 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -46.66589525346012
                ELSE 24.033340936732696 END
            ELSE -104.66586198216385 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@output_lag1 < 12756.0 OR @output_lag1 IS NULL)
                THEN -16.53451847095582
                ELSE -113.82264572143674 END
            ELSE CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
                THEN 48.456657690185295
                ELSE -24.594357200605774 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 29.891783850689002
                ELSE -31.431259304542465 END
            ELSE -98.38964771802998 END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@wip < 34078.0 OR @wip IS NULL)
                THEN -104.25737362538305
                ELSE -15.796125807232082 END
            ELSE CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -43.66294418284779
                ELSE 38.10903465162596 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -4.043577642548117
                ELSE 108.83585580921888 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 7.4320371508335485
                ELSE -131.82188957312619 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -3.66617706257702
                ELSE 101.5801320886043 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 6.87463436452108
                ELSE -123.03376360158444 END END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 52.1443445950695
                ELSE -6.412257074305342 END
            ELSE -80.87321297504155 END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -2.229116837129647
                ELSE 93.28372036533857 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 2.448210942551714
                ELSE -111.92199702650053 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -2.021065932330821
                ELSE 87.06480567431603 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 2.2645951218603386
                ELSE -104.46053055806718 END END) +
        (CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
            THEN -72.65968628470407
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 61.9401332086874
                ELSE -5.740999904938583 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 46.97204183494526
                ELSE -15.70638889346379 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 0.8142359844040584
                ELSE -94.88313898120796 END END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.988888936138434 OR @yield_lag1 IS NULL)
                THEN -67.01370783000921
                ELSE -5.231622137838804 END
            ELSE CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -43.88870150467901
                ELSE 30.701526593383264 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -1.787524059785428
                ELSE 74.2089429573481 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 0.31530949352159043
                ELSE -87.34719034123988 END END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@progres_po < 0.849025974025974 OR @progres_po IS NULL)
                THEN -1.620688480872074
                ELSE 69.2616800935249 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 0.29166128150741316
                ELSE -81.52404431849058 END END) +
        (CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
            THEN -57.86086226178614
            ELSE CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -41.91190335079719
                ELSE 16.819609632962408 END END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@progres_po < 0.7607142857142857 OR @progres_po IS NULL)
                THEN -4.5153266970653325
                ELSE -57.618574380210276 END
            ELSE CASE WHEN (@output_lag1 < 11478.0 OR @output_lag1 IS NULL)
                THEN -29.96066091545113
                ELSE 29.03149390742793 END END) +
        (CASE WHEN (@output_ma3 < 13942.0 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
                THEN -37.1575943862882
                ELSE 14.895844879430019 END
            ELSE -54.387171252895286 END) +
        (CASE WHEN (@progres_po < 0.8661702127659574 OR @progres_po IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 35.24948384450454
                ELSE -13.231250031826114 END
            ELSE CASE WHEN (@yield_lag1 < 0.985915223423824 OR @yield_lag1 IS NULL)
                THEN 1.8252050280854293
                ELSE -72.45178604808886 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9866286566255416 OR @yield_lag1 IS NULL)
                THEN -4.9271366996908235
                ELSE -67.62166697821628 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 75.87289606658142
                ELSE -12.040437528961794 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9866286566255416 OR @yield_lag1 IS NULL)
                THEN -4.49601223846787
                ELSE -63.113555846335174 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 70.18242886158782
                ELSE -10.956798151355233 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 1.5 OR @hari_ke IS NULL)
                THEN 22.130890379530626
                ELSE -34.491439606143274 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 64.91874669696873
                ELSE -9.970686317733234 END END) +
        (CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
            THEN -42.408596816292174
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 46.24636605061669
                ELSE -5.771445442843491 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9866286566255416 OR @yield_lag1 IS NULL)
                THEN -2.837647870625847
                ELSE -55.000554740865425 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 59.182253815572864
                ELSE -8.553894459281329 END END) +
        (CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
            THEN -33.87434867492116
            ELSE CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
                THEN 12.709722082831222
                ELSE -38.05012130009309 END END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9925754296840896 OR @yield_lag1 IS NULL)
                THEN -33.753208811332875
                ELSE 7.5421170442442875 END
            ELSE CASE WHEN (@hari_ke < 2.5 OR @hari_ke IS NULL)
                THEN 34.863285136361235
                ELSE -8.108292865446108 END END) +
        (CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
            THEN -31.158817110791645
            ELSE CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
                THEN 11.694698062978366
                ELSE -35.55044909092115 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 1.5 OR @hari_ke IS NULL)
                THEN 20.812799169173683
                ELSE -28.449826370129642 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 52.44708578333257
                ELSE -7.935866027445518 END END) +
        (CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
            THEN CASE WHEN (@progres_po < 0.7607142857142857 OR @progres_po IS NULL)
                THEN -0.05828825376396102
                ELSE -38.05193893927406 END
            ELSE CASE WHEN (@hari_ke < 2.5 OR @hari_ke IS NULL)
                THEN 32.002792133085926
                ELSE -7.447702866502247 END END) +
        (CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
            THEN -29.045003522092703
            ELSE CASE WHEN (@hari_ke < 1.5 OR @hari_ke IS NULL)
                THEN 42.21497288439266
                ELSE -2.1549100475981717 END END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9866286566255416 OR @yield_lag1 IS NULL)
                THEN -1.3960316299603166
                ELSE -44.7416255393671 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 48.247487943150375
                ELSE -7.004702580327248 END END) +
        (CASE WHEN (@output_lag1 < 10991.0 OR @output_lag1 IS NULL)
            THEN -26.62170911192957
            ELSE CASE WHEN (@output_ma3 < 12298.166666666666 OR @output_ma3 IS NULL)
                THEN 30.81943657012547
                ELSE -4.553667793544622 END END) +
        (CASE WHEN (@yield_ma7 < 0.9842105072520877 OR @yield_ma7 IS NULL)
            THEN CASE WHEN (@plan_output < 12650.0 OR @plan_output IS NULL)
                THEN -34.79042923381094
                ELSE -1.9468690502268755 END
            ELSE CASE WHEN (@yield_ma7 < 0.9851478261404688 OR @yield_ma7 IS NULL)
                THEN 35.0467222077411
                ELSE -3.2423860975079637 END END) +
        (CASE WHEN (@output_lag1 < 11478.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -27.507369537685857
                ELSE -7.682602512480905 END
            ELSE CASE WHEN (@output_ma3 < 12298.166666666666 OR @output_ma3 IS NULL)
                THEN 38.50109295784196
                ELSE -4.381497975575907 END END) +
        (CASE WHEN (@output_ma3 < 13942.0 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_ma3 < 13366.166666666668 OR @output_ma3 IS NULL)
                THEN -5.221877501589492
                ELSE 24.48242540831522 END
            ELSE -28.07754673011132 END) +
        (CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 26.288495215660916
                ELSE -3.91759183155757 END
            ELSE -27.914110631192763 END) +
        (CASE WHEN (@yield_lag1 < 0.9876568080922378 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 1.5 OR @hari_ke IS NULL)
                THEN 18.720415563637896
                ELSE -22.816671307798913 END
            ELSE CASE WHEN (@yield_lag1 < 0.9882569827385113 OR @yield_lag1 IS NULL)
                THEN 40.859095390779615
                ELSE -5.110177112452457 END END) +
        (CASE WHEN (@output_ma3 < 12298.166666666666 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 11478.0 OR @output_lag1 IS NULL)
                THEN -9.681316599526326
                ELSE 35.220512835546195 END
            ELSE CASE WHEN (@hari_ke < 1.5 OR @hari_ke IS NULL)
                THEN 36.384665924979046
                ELSE -15.769948461799666 END END) +
        (CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
            THEN -25.086199154354716
            ELSE CASE WHEN (@output_lag1 < 15323.0 OR @output_lag1 IS NULL)
                THEN 7.975843216354285
                ELSE -24.070945077651597 END END);
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_Pred_Yield (@plan_output float, @output_lag1 float, @output_ma3 float, @yield_lag1 float, @yield_ma7 float, @defect_lag1 float, @wip float, @progres_po float, @hari_ke float)
RETURNS float
AS
BEGIN
    -- XGBoost xgb-v1.0: 60 pohon, max_depth 2, learning_rate 0.1, dilatih 21 hari
    RETURN 0.9878110515474494 +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN -0.0005045476681327732
                ELSE -0.00011012044895947204 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN 0.0003487768139128933
                ELSE -8.288551073355022e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -0.00015396250763873696
                ELSE -0.0005832452617177131 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN 0.00028044475029175936
                ELSE -0.00019091378208936733 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN -0.0003216388222166311
                ELSE 0.00012562641309563362 END
            ELSE CASE WHEN (@output_ma3 < 12392.0 OR @output_ma3 IS NULL)
                THEN 3.827886399364322e-05
                ELSE 0.00035208707434880744 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN -0.0002926913282171384
                ELSE 0.00011620443211345922 END
            ELSE CASE WHEN (@output_ma3 < 12392.0 OR @output_ma3 IS NULL)
                THEN 3.5407949194118936e-05
                ELSE 0.0003219081822617622 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN -0.00040789512622719793
                ELSE -3.1261745315327445e-05 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN 0.000247815113021993
                ELSE -6.493593639397722e-05 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN -0.0002515630663502833
                ELSE 0.00010454051869910053 END
            ELSE CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
                THEN 7.114402412058222e-05
                ELSE 0.00032137901119503763 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN -0.00022892239037875406
                ELSE 9.669997979666611e-05 END
            ELSE CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
                THEN 6.521535544386873e-05
                ELSE 0.00029566869029943764 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 4.612485189514811e-05
                ELSE -0.00025026911732123623 END
            ELSE CASE WHEN (@yield_lag1 < 0.9879288323485997 OR @yield_lag1 IS NULL)
                THEN -1.9849020061820287e-05
                ELSE 0.0002222884363130187 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -3.7052733756486645e-05
                ELSE -0.0004499311658933876 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN 0.00018050405545462446
                ELSE -4.040549253607973e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -3.387678514878344e-05
                ELSE -0.00041993575483382606 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN 0.00016425869046370447
                ELSE -3.717305313319708e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN -0.0003120953393271919
                ELSE 3.3569031629803184e-05 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN 0.00017363003683663477
                ELSE -9.32603655514619e-06 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 5.731231348231059e-05
                ELSE -0.00020786070898701494 END
            ELSE CASE WHEN (@yield_lag1 < 0.993415399034849 OR @yield_lag1 IS NULL)
                THEN 0.0001744474137701485
                ELSE -4.999196653748447e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN -0.0002637405673407811
                ELSE 5.253817925274796e-05 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN 0.00016791202249856444
                ELSE -7.816767779855738e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -5.2059725134207775e-06
                ELSE -0.00037059746813523274 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN 0.0001116475008528776
                ELSE -8.849691869516527e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -4.759746297985527e-06
                ELSE -0.00034589097025954736 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN 0.00013450980469596058
                ELSE -1.5273150088259056e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -4.35176804387221e-06
                ELSE -0.0003228315722422474 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN 9.532403762690841e-05
                ELSE -8.657167926907628e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.618237373322895e-05
                ELSE -0.000385536108112002 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN 0.0001413919884528535
                ELSE -0.00013763057288371054 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 6.0571330422184066e-05
                ELSE -0.00016737806518607042 END
            ELSE CASE WHEN (@yield_lag1 < 0.993415399034849 OR @yield_lag1 IS NULL)
                THEN 0.00013281204907996392
                ELSE -8.169755139549503e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN -0.00022127410043806472
                ELSE 4.3026753182959785e-05 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN 0.00010895879282920018
                ELSE -1.8339478645431777e-05 END END) +
        (CASE WHEN (@progres_po < 0.8329545454545455 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -5.009408467674393e-05
                ELSE 0.0001335901784995569 END
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 5.186205999146247e-05
                ELSE -0.0002927866170647886 END END) +
        (CASE WHEN (@progres_po < 0.8329545454545455 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -4.5800305990168725e-05
                ELSE 0.00012190103788084494 END
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN 4.75402216588446e-05
                ELSE -0.0002708276207849303 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.3236535597582756e-05
                ELSE 0.00011917250654038443 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 8.695423008421966e-05
                ELSE -0.00038267988589249703 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN -0.00018310119851057313
                ELSE 5.213196493526843e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN 9.6343200993544e-05
                ELSE -5.7426049901335155e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.071333223530853e-05
                ELSE 0.00011126453149700362 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 7.405888504033343e-05
                ELSE -0.0003542759602490953 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -9.739392941186179e-06
                ELSE 0.00017048120278607138 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN -0.00031133290684506323
                ELSE 3.0389573587498644e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -8.446297957878842e-05
                ELSE 5.320713607485016e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 6.570300835011089e-05
                ELSE -0.0003212927851239056 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -7.883211427353784e-05
                ELSE 3.849506173944639e-05 END
            ELSE CASE WHEN (@output_lag1 < 14274.5 OR @output_lag1 IS NULL)
                THEN -0.00021882803228400935
                ELSE 3.9635925745040713e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.3514044080253919e-05
                ELSE -0.0002756300924022718 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN 8.382283970215232e-05
                ELSE -7.56483813227312e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -3.075110450572599e-05
                ELSE 7.401492724344378e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 5.0615701006546663e-05
                ELSE -0.0002821528846399931 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.2925384395349888e-05
                ELSE 0.0001451142057949467 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN -0.0002503168209955701
                ELSE 1.9702336614043797e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -2.8904906604265703e-05
                ELSE 6.734790715927888e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 4.499025799689971e-05
                ELSE -0.00025565554285128154 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN 3.54696728442964e-05
                ELSE -6.081594627805887e-05 END
            ELSE CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
                THEN 2.913556109407356e-05
                ELSE -0.00018127376784577248 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN -0.00012517537802190782
                ELSE 2.8800201395440264e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN 7.051684794849979e-05
                ELSE -5.625475030720528e-05 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.1800384795843869e-05
                ELSE 0.00012852918425727 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN -0.00021414695003795596
                ELSE 1.4022921633516373e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -7.173281054630257e-05
                ELSE 3.9218726003311827e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 3.792049887397564e-05
                ELSE -0.00022525895154521894 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -2.5500989199367387e-05
                ELSE 5.569265158970419e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 3.48868589640583e-05
                ELSE -0.0002102416881088698 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -6.795701192289228e-05
                ELSE 2.6813642494047388e-05 END
            ELSE CASE WHEN (@output_lag1 < 14274.5 OR @output_lag1 IS NULL)
                THEN -0.00014868799574998168
                ELSE 2.108069650798757e-05 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.2028916504934863e-05
                ELSE 0.00011178995995117237 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN -0.00018445503285818843
                ELSE 1.1391583603743389e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9926215913333583 OR @yield_lag1 IS NULL)
                THEN 3.722132230051886e-05
                ELSE -5.531814090367071e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 2.9268809998557192e-05
                ELSE -0.00018639431548459485 END END) +
        (CASE WHEN (@hari_ke < 5.5 OR @hari_ke IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 7.385751573314032e-06
                ELSE -0.00013304372625435047 END
            ELSE 6.531745107084541e-05 END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN -9.320834920643432e-05
                ELSE 1.8643946327231062e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN 5.519361066023256e-05
                ELSE -4.821247475820523e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -6.311294152332078e-05
                ELSE 3.098631284124925e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 2.503289835991352e-05
                ELSE -0.00016851227067804508 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN -1.2184155840161919e-05
                ELSE 9.73067371483477e-05 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN -0.00015219890986381361
                ELSE 8.788915230780895e-06 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -2.3277482377671855e-05
                ELSE 4.44847699998727e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 2.2327153272658774e-05
                ELSE -0.00015249778614507455 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -5.880004461983335e-05
                ELSE 2.1190125866917683e-05 END
            ELSE CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
                THEN 1.4019384875193128e-05
                ELSE -0.00011137981271559887 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 2.9946396544755507e-06
                ELSE -0.00013544555910642483 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN -2.576373404794552e-06
                ELSE 6.67521925486414e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9926215913333583 OR @yield_lag1 IS NULL)
                THEN 2.888478730365044e-05
                ELSE -4.762952814515997e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 1.9073551767228026e-05
                ELSE -0.0001347242130900687 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.6557775372194608e-06
                ELSE -0.00012288787430645432 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN -1.631537284499385e-06
                ELSE 6.006998083654403e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN -2.3116434059017313e-05
                ELSE 3.9442990332825036e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 1.5210129883769242e-05
                ELSE -0.00012159195183103488 END END) +
        (CASE WHEN (@yield_ma7 < 0.9880012751159515 OR @yield_ma7 IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9867742435646345 OR @yield_ma7 IS NULL)
                THEN -3.22819492440507e-06
                ELSE -9.79816807422429e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.9920653775178567 OR @yield_lag1 IS NULL)
                THEN 4.60870959792914e-05
                ELSE -3.956952298170003e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9833500382452243 OR @yield_ma7 IS NULL)
                THEN 3.918072443900671e-05
                ELSE -4.75630244111495e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN 3.9426058619604666e-05
                ELSE -3.950154886674662e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.1423711820335304e-06
                ELSE -0.00010541251981978823 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN 3.189421579496853e-05
                ELSE -2.8468972128041042e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN -5.4711537934182264e-05
                ELSE 2.300951158751444e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN 1.2025516455076436e-05
                ELSE -0.00010702205362555691 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -2.540877720047519e-07
                ELSE -9.558460043053533e-05 END
            ELSE CASE WHEN (@output_ma3 < 13198.833333333334 OR @output_ma3 IS NULL)
                THEN 5.556278280739458e-05
                ELSE 1.9211607863321866e-06 END END) +
        (CASE WHEN (@hari_ke < 5.5 OR @hari_ke IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 6.002597598239734e-06
                ELSE -8.748795211163951e-05 END
            ELSE 3.882261931316134e-05 END) +
        (CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
            THEN -5.330789841296128e-05
            ELSE CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 2.494048380912717e-05
                ELSE -2.582068629449763e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.6269080970066074e-06
                ELSE -8.477473616507933e-05 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN -5.938036055364027e-07
                ELSE 4.6550812164497526e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.4804863682749138e-06
                ELSE -7.912308708740712e-05 END
            ELSE CASE WHEN (@output_ma3 < 13198.833333333334 OR @output_ma3 IS NULL)
                THEN 5.087210431518422e-05
                ELSE 1.698547304737927e-06 END END) +
        (CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
            THEN -5.132640206024405e-05
            ELSE CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
                THEN 1.9811654490321203e-05
                ELSE -2.8861578071199504e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -2.41891093374913e-06
                ELSE -7.354655049554386e-05 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN -3.2418598180650186e-07
                ELSE 4.265055882034797e-05 END END);
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_Pred_Defect (@plan_output float, @output_lag1 float, @output_ma3 float, @yield_lag1 float, @yield_ma7 float, @defect_lag1 float, @wip float, @progres_po float, @hari_ke float)
RETURNS float
AS
BEGIN
    -- XGBoost xgb-v1.0: 60 pohon, max_depth 2, learning_rate 0.1, dilatih 21 hari
    RETURN 0.012188948452550606 +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN 0.0005045476681327715
                ELSE 0.00011012044895947018 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN -0.000348776813912896
                ELSE 8.288551073355022e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 0.00015396250763873958
                ELSE 0.0005832452617177114 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN -0.0002804447502917604
                ELSE 0.00019091378208936733 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN 0.0003216388222166336
                ELSE -0.00012562641309563595 END
            ELSE CASE WHEN (@output_ma3 < 12392.0 OR @output_ma3 IS NULL)
                THEN -3.8278863993641404e-05
                ELSE -0.00035208707434880864 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN 0.0002926913282171365
                ELSE -0.00011620443211346324 END
            ELSE CASE WHEN (@output_ma3 < 12392.0 OR @output_ma3 IS NULL)
                THEN -3.5407949194118285e-05
                ELSE -0.00032190818226176783 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN 0.0004078951262272002
                ELSE 3.1261745315332296e-05 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN -0.00024781511302199614
                ELSE 6.4935936393975e-05 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN 0.0002515630663502854
                ELSE -0.00010454051869910236 END
            ELSE CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
                THEN -7.114402412058018e-05
                ELSE -0.00032137901119503877 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9911550375487366 OR @yield_ma7 IS NULL)
                THEN 0.00022892239037875965
                ELSE -9.669997979666964e-05 END
            ELSE CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
                THEN -6.521535544386511e-05
                ELSE -0.00029566869029943574 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN -4.612485189514409e-05
                ELSE 0.0002502691173212374 END
            ELSE CASE WHEN (@defect_lag1 < 0.012071167651400351 OR @defect_lag1 IS NULL)
                THEN -0.00022228843631301603
                ELSE 1.984902006182202e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 3.705273375649452e-05
                ELSE 0.00044993116589338875 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN -0.00018050405545462131
                ELSE 4.0405492536082364e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 3.387678514879503e-05
                ELSE 0.0004199357548338295 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN -0.0001642586904637054
                ELSE 3.717305313319583e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN 0.0003120953393271979
                ELSE -3.356903162979569e-05 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN -0.00017363003683663243
                ELSE 9.326036555148792e-06 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN -5.731231348230674e-05
                ELSE 0.00020786070898701952 END
            ELSE CASE WHEN (@defect_lag1 < 0.006584600965150978 OR @defect_lag1 IS NULL)
                THEN 4.999196653748395e-05
                ELSE -0.00017444741377014778 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN 0.0002637405673407861
                ELSE -5.253817925273755e-05 END
            ELSE CASE WHEN (@progres_po < 0.8179054054054054 OR @progres_po IS NULL)
                THEN -0.00016791202249856574
                ELSE 7.816767779855799e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 5.2059725134318305e-06
                ELSE 0.00037059746813523545 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN -0.00011164750085287803
                ELSE 8.849691869516676e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 4.759746297994795e-06
                ELSE 0.00034589097025955305 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN -0.00013450980469596467
                ELSE 1.5273150088259056e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN 4.3517680438808836e-06
                ELSE 0.00032283157224224945 END
            ELSE CASE WHEN (@output_lag1 < 15305.0 OR @output_lag1 IS NULL)
                THEN -9.532403762691016e-05
                ELSE 8.65716792690791e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.6182373733229306e-05
                ELSE 0.00038553610811200255 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN -0.00014139198845284826
                ELSE 0.0001376305728837184 END END) +
        (CASE WHEN (@wip < 36960.5 OR @wip IS NULL)
            THEN CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN -6.05713304221806e-05
                ELSE 0.0001673780651860764 END
            ELSE CASE WHEN (@yield_lag1 < 0.993415399034849 OR @yield_lag1 IS NULL)
                THEN -0.00013281204907996435
                ELSE 8.169755139548815e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9872020344850654 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12866.166666666668 OR @output_ma3 IS NULL)
                THEN 0.00022127410043807006
                ELSE -4.302675318294865e-05 END
            ELSE CASE WHEN (@plan_output < 12400.0 OR @plan_output IS NULL)
                THEN -0.00010895879282920708
                ELSE 1.8339478645434304e-05 END END) +
        (CASE WHEN (@progres_po < 0.8329545454545455 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 5.0094084676743175e-05
                ELSE -0.0001335901784995651 END
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN -5.186205999145533e-05
                ELSE 0.00029278661706479413 END END) +
        (CASE WHEN (@progres_po < 0.8329545454545455 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 4.580030599016521e-05
                ELSE -0.00012190103788085314 END
            ELSE CASE WHEN (@wip < 30405.5 OR @wip IS NULL)
                THEN -4.7540221658834e-05
                ELSE 0.00027082762078493454 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.3236535597584994e-05
                ELSE -0.00011917250654038749 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -8.695423008421854e-05
                ELSE 0.00038267988589249426 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN 0.00018310119851057567
                ELSE -5.213196493525687e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN -9.634320099354872e-05
                ELSE 5.742604990133082e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.0713332235313829e-05
                ELSE -0.00011126453149700188 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -7.405888504032879e-05
                ELSE 0.0003542759602490938 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 9.739392941194315e-06
                ELSE -0.00017048120278607428 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN 0.00031133290684505976
                ELSE -3.038957358749168e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 8.446297957879958e-05
                ELSE -5.320713607485007e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -6.570300835010306e-05
                ELSE 0.000321292785123902 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 7.883211427354628e-05
                ELSE -3.84950617394428e-05 END
            ELSE CASE WHEN (@output_lag1 < 14274.5 OR @output_lag1 IS NULL)
                THEN 0.0002188280322840087
                ELSE -3.9635925745028225e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.3514044080255333e-05
                ELSE 0.0002756300924022686 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN -8.382283970214538e-05
                ELSE 7.564838132273685e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 3.0751104505729114e-05
                ELSE -7.401492724344225e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -5.061570100654424e-05
                ELSE 0.0002821528846399895 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.2925384395348769e-05
                ELSE -0.00014511420579495137 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN 0.00025031682099556574
                ELSE -1.9702336614037847e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 2.890490660426347e-05
                ELSE -6.734790715928093e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -4.499025799689756e-05
                ELSE 0.00025565554285127254 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN -3.546967284429684e-05
                ELSE 6.081594627804848e-05 END
            ELSE CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
                THEN -2.913556109406986e-05
                ELSE 0.00018127376784577416 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN 0.00012517537802190636
                ELSE -2.8800201395427918e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN -7.051684794850395e-05
                ELSE 5.6254750307194874e-05 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.1800384795846281e-05
                ELSE -0.00012852918425727285 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN 0.00021414695003795186
                ELSE -1.4022921633507723e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 7.173281054630894e-05
                ELSE -3.9218726003309814e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -3.792049887397006e-05
                ELSE 0.00022525895154521018 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 2.550098919936587e-05
                ELSE -5.569265158969956e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -3.488685896405244e-05
                ELSE 0.00021024168810886287 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 6.79570119228995e-05
                ELSE -2.6813642494044904e-05 END
            ELSE CASE WHEN (@output_lag1 < 14274.5 OR @output_lag1 IS NULL)
                THEN 0.0001486879957499873
                ELSE -2.108069650797745e-05 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.2028916504942047e-05
                ELSE -0.00011178995995117494 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN 0.00018445503285818827
                ELSE -1.1391583603733278e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9926215913333583 OR @yield_lag1 IS NULL)
                THEN -3.722132230050873e-05
                ELSE 5.531814090367195e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -2.926880999854872e-05
                ELSE 0.0001863943154845922 END END) +
        (CASE WHEN (@hari_ke < 5.5 OR @hari_ke IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -7.385751573309386e-06
                ELSE 0.00013304372625435134 END
            ELSE -6.531745107083472e-05 END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12950.333333333334 OR @output_ma3 IS NULL)
                THEN 9.320834920643603e-05
                ELSE -1.8643946327218862e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN -5.5193610660232306e-05
                ELSE 4.821247475820319e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 6.311294152332401e-05
                ELSE -3.098631284124573e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -2.5032898359904757e-05
                ELSE 0.00016851227067804451 END END) +
        (CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 12584.0 OR @output_lag1 IS NULL)
                THEN 1.2184155840165453e-05
                ELSE -9.730673714835632e-05 END
            ELSE CASE WHEN (@output_ma3 < 13117.666666666668 OR @output_ma3 IS NULL)
                THEN 0.0001521989098638158
                ELSE -8.788915230770375e-06 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 2.3277482377669558e-05
                ELSE -4.448476999987032e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -2.2327153272650707e-05
                ELSE 0.0001524977861450733 END END) +
        (CASE WHEN (@progres_po < 0.8784779050736498 OR @progres_po IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 5.880004461983132e-05
                ELSE -2.119012586691828e-05 END
            ELSE CASE WHEN (@wip < 26865.0 OR @wip IS NULL)
                THEN -1.4019384875190409e-05
                ELSE 0.00011137981271561078 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -2.9946396544769818e-06
                ELSE 0.00013544555910643155 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN 2.5763734048005153e-06
                ELSE -6.675219254863479e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@yield_lag1 < 0.9926215913333583 OR @yield_lag1 IS NULL)
                THEN -2.8884787303644984e-05
                ELSE 4.76295281451549e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -1.9073551767216978e-05
                ELSE 0.00013472421309007078 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.6557775372219845e-06
                ELSE 0.0001228878743064553 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN 1.6315372845072778e-06
                ELSE -6.0069980836535225e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_ma3 < 12343.333333333332 OR @output_ma3 IS NULL)
                THEN 2.3116434059017052e-05
                ELSE -3.944299033281872e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -1.5210129883758503e-05
                ELSE 0.00012159195183103408 END END) +
        (CASE WHEN (@yield_ma7 < 0.9880012751159515 OR @yield_ma7 IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9867742435646345 OR @yield_ma7 IS NULL)
                THEN 3.2281949244107344e-06
                ELSE 9.798168074224142e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.9920653775178567 OR @yield_lag1 IS NULL)
                THEN -4.608709597928995e-05
                ELSE 3.956952298170124e-05 END END) +
        (CASE WHEN (@yield_lag1 < 0.9879013974588347 OR @yield_lag1 IS NULL)
            THEN CASE WHEN (@yield_ma7 < 0.9833500382452243 OR @yield_ma7 IS NULL)
                THEN -3.918072443900445e-05
                ELSE 4.756302441115e-05 END
            ELSE CASE WHEN (@yield_lag1 < 0.992852349132318 OR @yield_lag1 IS NULL)
                THEN -3.942605861960287e-05
                ELSE 3.950154886674527e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -1.1423711820336604e-06
                ELSE 0.00010541251981978594 END
            ELSE CASE WHEN (@yield_ma7 < 0.9887231371788777 OR @yield_ma7 IS NULL)
                THEN -3.1894215794966745e-05
                ELSE 2.8468972128036936e-05 END END) +
        (CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
            THEN CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
                THEN 5.471153793417787e-05
                ELSE -2.3009511587510726e-05 END
            ELSE CASE WHEN (@yield_ma7 < 0.986911340173757 OR @yield_ma7 IS NULL)
                THEN -1.2025516455075308e-05
                ELSE 0.00010702205362555438 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 2.540877720084382e-07
                ELSE 9.55846004305321e-05 END
            ELSE CASE WHEN (@output_ma3 < 13198.833333333334 OR @output_ma3 IS NULL)
                THEN -5.5562782807396454e-05
                ELSE -1.921160786330346e-06 END END) +
        (CASE WHEN (@hari_ke < 5.5 OR @hari_ke IS NULL)
            THEN CASE WHEN (@hari_ke < 4.5 OR @hari_ke IS NULL)
                THEN -6.002597598237333e-06
                ELSE 8.748795211164236e-05 END
            ELSE -3.8822619313156085e-05 END) +
        (CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
            THEN 5.3307898412961345e-05
            ELSE CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN -2.494048380911889e-05
                ELSE 2.582068629450008e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.6269080970193059e-06
                ELSE 8.477473616508314e-05 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN 5.938036055405226e-07
                ELSE -4.655081216449247e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 1.4804863682876032e-06
                ELSE 7.912308708741094e-05 END
            ELSE CASE WHEN (@output_ma3 < 13198.833333333334 OR @output_ma3 IS NULL)
                THEN -5.0872104315183875e-05
                ELSE -1.6985473047360382e-06 END END) +
        (CASE WHEN (@output_lag1 < 10310.5 OR @output_lag1 IS NULL)
            THEN 5.1326402060241846e-05
            ELSE CASE WHEN (@output_lag1 < 14023.0 OR @output_lag1 IS NULL)
                THEN -1.9811654490309995e-05
                ELSE 2.8861578071204562e-05 END END) +
        (CASE WHEN (@output_ma3 < 12934.166666666668 OR @output_ma3 IS NULL)
            THEN CASE WHEN (@output_lag1 < 13595.0 OR @output_lag1 IS NULL)
                THEN 2.4189109337641355e-06
                ELSE 7.354655049555381e-05 END
            ELSE CASE WHEN (@wip < 37682.5 OR @wip IS NULL)
                THEN 3.2418598181424306e-07
                ELSE -4.265055882034165e-05 END END);
END;
GO

DELETE FROM dbo.tblBA204_FeatureImportance;
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'plan_output', 0.134329, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'output_lag1', 0.400065, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'output_ma3', 0.018517, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'yield_lag1', 0.180699, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'yield_ma7', 0.001251, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'defect_lag1', 0.000000, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'wip', 0.203481, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'progres_po', 0.052217, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Output', N'hari_ke', 0.009441, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'plan_output', 0.009482, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'output_lag1', 0.109685, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'output_ma3', 0.129730, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'yield_lag1', 0.259071, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'yield_ma7', 0.141989, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'defect_lag1', 0.000000, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'wip', 0.221870, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'progres_po', 0.063189, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Yield', N'hari_ke', 0.064985, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'plan_output', 0.009482, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'output_lag1', 0.109685, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'output_ma3', 0.129730, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'yield_lag1', 0.251715, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'yield_ma7', 0.141989, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'defect_lag1', 0.007356, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'wip', 0.221870, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'progres_po', 0.063189, N'xgb-v1.0');
INSERT INTO dbo.tblBA204_FeatureImportance (Metric, Feature, Importance, ModelVersion) VALUES (N'Defect', N'hari_ke', 0.064985, N'xgb-v1.0');
DELETE FROM dbo.tblBA204_ModelInfo;
INSERT INTO dbo.tblBA204_ModelInfo (Metric, ModelVersion, TrainRows, TrainFrom, TrainTo, MAE, MAPE, TrainedOn) VALUES (N'Output', N'xgb-v1.0', 21, '2026-03-02', '2026-03-31', 3704.958327, 0.409378, SYSDATETIME());
INSERT INTO dbo.tblBA204_ModelInfo (Metric, ModelVersion, TrainRows, TrainFrom, TrainTo, MAE, MAPE, TrainedOn) VALUES (N'Yield', N'xgb-v1.0', 21, '2026-03-02', '2026-03-31', 0.005782, 0.005892, SYSDATETIME());
INSERT INTO dbo.tblBA204_ModelInfo (Metric, ModelVersion, TrainRows, TrainFrom, TrainTo, MAE, MAPE, TrainedOn) VALUES (N'Defect', N'xgb-v1.0', 21, '2026-03-02', '2026-03-31', 0.005723, 0.340523, SYSDATETIME());
GO
/* ===== Bagian 4: view prediksi untuk Power BI (real-time) ===== */
USE [PBL_MonitoringProduksi];
GO
CREATE OR ALTER VIEW dbo.vw_PBI_Prediksi AS
SELECT f.Tanggal,
       v.Metric,
       Aktual   = v.Aktual,
       Prediksi = v.Prediksi,
       Target   = v.Target,
       IsForecast = f.IsForecast,
       APE      = CASE WHEN v.Aktual IS NULL OR v.Aktual = 0 THEN NULL
                       ELSE ABS(v.Aktual - v.Prediksi) / ABS(v.Aktual) END
FROM dbo.vw_Fitur f
CROSS APPLY (SELECT
    pOut = dbo.fn_Pred_Output(f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke),
    pYld = dbo.fn_Pred_Yield (f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke),
    pDef = dbo.fn_Pred_Defect(f.plan_output, f.output_lag1, f.output_ma3, f.yield_lag1, f.yield_ma7,
                              f.defect_lag1, f.wip, f.progres_po, f.hari_ke)) p
CROSS APPLY (VALUES
    (N'Output', f.Output_,  CASE WHEN p.pOut < 0 THEN 0 ELSE p.pOut END,                       f.PlanOutput),
    (N'Yield',  f.Yield_,   CASE WHEN p.pYld > 1 THEN 1 WHEN p.pYld < 0 THEN 0 ELSE p.pYld END, f.TargetYield),
    (N'Defect', f.Defect_,  CASE WHEN p.pDef > 1 THEN 1 WHEN p.pDef < 0 THEN 0 ELSE p.pDef END, 1 - f.TargetYield)
) v(Metric, Aktual, Prediksi, Target);
GO
