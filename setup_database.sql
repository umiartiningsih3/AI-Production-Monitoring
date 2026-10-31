/* =====================================================================
   PBL PBLIF3-MD04
   Pengembangan Sistem Monitoring dan Prediksi Produksi
   menggunakan Machine Learning

   Skrip database untuk SQL Server 2022.
   Isi : database, 5 tabel posting Excel, tabel master SKU, tabel hasil
         prediksi XGBoost, dan 7 view siap pakai untuk Power BI.
   Aman dijalankan berulang kali: tabel dan data yang sudah ada TIDAK
   dihapus, view diperbarui (CREATE OR ALTER).
   Isinya sama dengan macro "SiapkanDatabase" di file Excel.
   ===================================================================== */
IF DB_ID(N'PBL_MonitoringProduksi') IS NULL
    CREATE DATABASE [PBL_MonitoringProduksi];
GO
USE [PBL_MonitoringProduksi];
GO

/* ---------------------------------------------------------------------
   A. TABEL POSTING DARI EXCEL
   --------------------------------------------------------------------- */

-- 1. Output per PO per proses (sheet "Data Process Prod")
IF OBJECT_ID('dbo.tblBA204_PODailyOutput','U') IS NULL
CREATE TABLE dbo.tblBA204_PODailyOutput (
    Id            int IDENTITY(1,1) PRIMARY KEY,
    DateOperation date           NOT NULL,
    DateReport    date           NULL,
    Process       nvarchar(50)   NOT NULL,
    Shift         nvarchar(10)   NULL,
    ProductType   nvarchar(100)  NOT NULL,
    PON           nvarchar(50)   NOT NULL,
    Batch         nvarchar(50)   NULL,
    Material      nvarchar(50)   NULL,
    Qty_Start     decimal(18,2)  NULL,
    Qty_Output    decimal(18,2)  NULL,
    Qty_Scrap     decimal(18,2)  NULL,
    Remark        nvarchar(1000) NULL,
    InputBy       nvarchar(100)  NULL,
    InputOn       datetime2(0)   NULL
);
GO

-- 2. Detail reject per PO per proses (sheet "Data Process Prod")
IF OBJECT_ID('dbo.tblBA204_PODetailsReject','U') IS NULL
CREATE TABLE dbo.tblBA204_PODetailsReject (
    Id            int IDENTITY(1,1) PRIMARY KEY,
    DateOperation date           NOT NULL,
    DateReport    date           NULL,
    Process       nvarchar(50)   NOT NULL,
    Shift         nvarchar(10)   NULL,
    ProductType   nvarchar(100)  NOT NULL,
    PON           nvarchar(50)   NOT NULL,
    RejectType    nvarchar(200)  NOT NULL,
    Reject_qty    decimal(18,2)  NULL,
    InputBy       nvarchar(100)  NULL,
    InputOn       datetime2(0)   NULL
);
GO

-- 3. Ringkasan output harian (sheet "Daily Output Summary")
IF OBJECT_ID('dbo.tblBA204_DailyOutput2','U') IS NULL
CREATE TABLE dbo.tblBA204_DailyOutput2 (
    Id             int IDENTITY(1,1) PRIMARY KEY,
    DateOperation  date           NOT NULL,
    ProductType    nvarchar(100)  NOT NULL,
    ProductSubType nvarchar(150)  NULL,
    Qty_Process    decimal(18,2)  NULL,
    Qty_Output     decimal(18,2)  NULL,
    Qty_Reject     decimal(18,2)  NULL,
    Target_Yield   decimal(9,4)   NULL,
    Target_Output  decimal(18,2)  NULL,
    Remark         nvarchar(1000) NULL,
    InputBy        nvarchar(100)  NULL,
    InputOn        datetime2(0)   NULL
);
GO

-- 4. Ringkasan reject harian (sheet "Daily Scrap summary")
IF OBJECT_ID('dbo.tblBA204_DetailsReject2','U') IS NULL
CREATE TABLE dbo.tblBA204_DetailsReject2 (
    Id             int IDENTITY(1,1) PRIMARY KEY,
    DateOperation  date           NOT NULL,
    ProductType    nvarchar(100)  NOT NULL,
    ProductSubType nvarchar(150)  NULL,
    RejectType     nvarchar(200)  NOT NULL,
    Qty_Reject     decimal(18,2)  NULL,
    InputBy        nvarchar(100)  NULL,
    InputOn        datetime2(0)   NULL
);
GO

-- 5. Produktivitas harian (sheet "Daily Productivity Summary")
IF OBJECT_ID('dbo.tblBA204_Productivity2','U') IS NULL
CREATE TABLE dbo.tblBA204_Productivity2 (
    Id              int IDENTITY(1,1) PRIMARY KEY,
    DateOperation   date           NOT NULL,
    ProductType     nvarchar(100)  NOT NULL,
    MaxMHP          decimal(18,6)  NULL,
    MaxOT           decimal(9,4)   NULL,
    ActOutput       decimal(18,2)  NULL,
    TotalHC         decimal(9,2)   NULL,
    AbsentHC        decimal(9,2)   NULL,
    NormalManHours  decimal(18,2)  NULL,
    LostManHours    decimal(18,2)  NULL,
    ActOT           decimal(18,2)  NULL,
    SupportManHours decimal(18,2)  NULL,
    TotalManhours   decimal(18,2)  NULL,
    ActManhours     decimal(18,6)  NULL,
    Remark          nvarchar(1000) NULL,
    InputBy         nvarchar(100)  NULL,
    InputOn         datetime2(0)   NULL
);
GO

/* ---------------------------------------------------------------------
   B. TABEL PENDUKUNG
   --------------------------------------------------------------------- */

-- 6. Master SKU (Material Number -> nama produk, gauge, panjang)
IF OBJECT_ID('dbo.tblBA204_MaterialMaster','U') IS NULL
CREATE TABLE dbo.tblBA204_MaterialMaster (
    Material    nvarchar(50)  NOT NULL PRIMARY KEY,
    SKU         nvarchar(100) NOT NULL,
    Gauge       nvarchar(10)  NULL,
    LengthMM    decimal(5,1)  NULL
);
GO

-- Isi master material (nomor material & nama SKU perusahaan) TIDAK disimpan di repository.
-- Jalankan file lokal data_master_lokal.sql (tidak di-upload) setelah skrip ini.
-- Contoh format:
-- INSERT INTO dbo.tblBA204_MaterialMaster (Material, SKU, Gauge, LengthMM)
-- VALUES (N'<nomor material>', N'<nama SKU>', N'25G', 8.0);

-- 7. Hasil prediksi model XGBoost (diisi oleh skrip Python / API)
IF OBJECT_ID('dbo.tblBA204_Prediction','U') IS NULL
CREATE TABLE dbo.tblBA204_Prediction (
    Id             int IDENTITY(1,1) PRIMARY KEY,
    DateOperation  date           NOT NULL,
    ProductType    nvarchar(100)  NOT NULL,
    ProductSubType nvarchar(150)  NULL,
    Material       nvarchar(50)   NULL,
    Pred_Output    decimal(18,2)  NOT NULL,
    Pred_Yield     decimal(9,4)   NULL,
    ModelName      nvarchar(50)   NOT NULL CONSTRAINT DF_Prediction_Model DEFAULT (N'XGBoost'),
    ModelVersion   nvarchar(50)   NULL,
    CreatedOn      datetime2(0)   NOT NULL CONSTRAINT DF_Prediction_Created DEFAULT (SYSDATETIME())
);
GO

/* ---------------------------------------------------------------------
   C. INDEX (mempercepat posting & refresh Power BI)
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PODailyOutput_Key')
    CREATE INDEX IX_PODailyOutput_Key ON dbo.tblBA204_PODailyOutput (DateOperation, ProductType, Process, PON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PODetailsReject_Key')
    CREATE INDEX IX_PODetailsReject_Key ON dbo.tblBA204_PODetailsReject (DateOperation, ProductType, Process, PON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DailyOutput2_Key')
    CREATE INDEX IX_DailyOutput2_Key ON dbo.tblBA204_DailyOutput2 (DateOperation, ProductType);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DetailsReject2_Key')
    CREATE INDEX IX_DetailsReject2_Key ON dbo.tblBA204_DetailsReject2 (DateOperation, ProductType);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Productivity2_Key')
    CREATE INDEX IX_Productivity2_Key ON dbo.tblBA204_Productivity2 (DateOperation, ProductType);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Prediction_Key')
    CREATE INDEX IX_Prediction_Key ON dbo.tblBA204_Prediction (DateOperation, ProductType, CreatedOn);
GO

/* ---------------------------------------------------------------------
   D. VIEW UNTUK POWER BI  (di Power BI cukup pilih view vw_PBI_...)
   --------------------------------------------------------------------- */

-- Output per PO per proses + info SKU
CREATE OR ALTER VIEW dbo.vw_PBI_POOutput AS
SELECT
    o.DateOperation,
    o.DateReport,
    o.Process,
    ProcessOrder = CASE o.Process WHEN N'PROSES_1' THEN 1 WHEN N'PROSES_2' THEN 2
                                  WHEN N'PROSES_3' THEN 3 WHEN N'PROSES_4' THEN 4 ELSE 9 END,
    o.Shift,
    o.ProductType,
    o.PON,
    o.Batch,
    o.Material,
    SKU      = ISNULL(m.SKU, N'Material ' + o.Material),
    m.Gauge,
    m.LengthMM,
    o.Qty_Start,
    o.Qty_Output,
    o.Qty_Scrap,
    RejectRate = CAST(o.Qty_Scrap / NULLIF(o.Qty_Start, 0) AS decimal(9,6)),
    o.Remark
FROM dbo.tblBA204_PODailyOutput o
LEFT JOIN dbo.tblBA204_MaterialMaster m ON m.Material = o.Material;
GO

-- Detail reject per PO per proses + kode/nama reject terpisah
CREATE OR ALTER VIEW dbo.vw_PBI_POReject AS
SELECT
    r.DateOperation,
    r.DateReport,
    r.Process,
    r.Shift,
    r.ProductType,
    r.PON,
    po.Material,
    SKU        = ISNULL(m.SKU, N'Material ' + po.Material),
    RejectType = LTRIM(RTRIM(REPLACE(REPLACE(r.RejectType, CHAR(13), N' '), CHAR(10), N' '))),
    RejectCode = CASE WHEN LEFT(r.RejectType, 1) = N'(' AND CHARINDEX(N')', r.RejectType) > 2
                      THEN SUBSTRING(r.RejectType, 2, CHARINDEX(N')', r.RejectType) - 2) END,
    RejectName = CASE WHEN CHARINDEX(N')', r.RejectType) > 0
                      THEN LTRIM(RTRIM(REPLACE(REPLACE(SUBSTRING(r.RejectType, CHARINDEX(N')', r.RejectType) + 1, 200),
                                                       CHAR(13), N' '), CHAR(10), N' ')))
                      ELSE r.RejectType END,
    r.Reject_qty
FROM dbo.tblBA204_PODetailsReject r
OUTER APPLY (SELECT TOP (1) o.Material
             FROM dbo.tblBA204_PODailyOutput o
             WHERE o.DateOperation = r.DateOperation AND o.ProductType = r.ProductType
               AND o.Process = r.Process AND o.PON = r.PON) po
LEFT JOIN dbo.tblBA204_MaterialMaster m ON m.Material = po.Material;
GO

-- Ringkasan output harian vs target
CREATE OR ALTER VIEW dbo.vw_PBI_DailyOutput AS
SELECT
    d.DateOperation,
    d.ProductType,
    d.ProductSubType,
    d.Qty_Process,
    d.Qty_Output,
    d.Qty_Reject,
    d.Target_Output,
    d.Target_Yield,
    Actual_Yield    = CAST(d.Qty_Output / NULLIF(d.Qty_Process, 0) AS decimal(9,6)),
    Output_Variance = d.Qty_Output - d.Target_Output,
    IsWorkingDay    = CAST(CASE WHEN d.Qty_Process > 0 OR d.Target_Output > 0 THEN 1 ELSE 0 END AS bit),
    d.Remark
FROM dbo.tblBA204_DailyOutput2 d;
GO

-- Ringkasan reject harian per jenis reject
CREATE OR ALTER VIEW dbo.vw_PBI_DailyReject AS
SELECT
    r.DateOperation,
    r.ProductType,
    r.ProductSubType,
    RejectType = LTRIM(RTRIM(REPLACE(REPLACE(r.RejectType, CHAR(13), N' '), CHAR(10), N' '))),
    RejectCode = CASE WHEN LEFT(r.RejectType, 1) = N'(' AND CHARINDEX(N')', r.RejectType) > 2
                      THEN SUBSTRING(r.RejectType, 2, CHARINDEX(N')', r.RejectType) - 2) END,
    RejectName = CASE WHEN CHARINDEX(N')', r.RejectType) > 0
                      THEN LTRIM(RTRIM(REPLACE(REPLACE(SUBSTRING(r.RejectType, CHARINDEX(N')', r.RejectType) + 1, 200),
                                                       CHAR(13), N' '), CHAR(10), N' ')))
                      ELSE r.RejectType END,
    r.Qty_Reject
FROM dbo.tblBA204_DetailsReject2 r;
GO

-- Produktivitas harian
CREATE OR ALTER VIEW dbo.vw_PBI_Productivity AS
SELECT
    p.DateOperation,
    p.ProductType,
    MHP_Threshold      = p.MaxMHP,
    OT_Threshold       = p.MaxOT,
    Actual_Output      = p.ActOutput,
    Headcount_Total    = p.TotalHC,
    Headcount_Absent   = p.AbsentHC,
    Normal_Manhours    = p.NormalManHours,
    Lost_Manhours      = p.LostManHours,
    Actual_Overtime    = p.ActOT,
    CrossCharge_MH     = p.SupportManHours,
    Total_Manhours     = p.TotalManhours,
    Actual_MHP         = p.ActManhours,
    Overtime_Rate      = CAST(p.ActOT / NULLIF(p.NormalManHours, 0) AS decimal(9,6)),
    MHP_Status         = CASE WHEN p.ActOutput IS NULL OR p.ActOutput = 0 THEN N'Libur'
                              WHEN p.ActManhours <= p.MaxMHP THEN N'On Target'
                              ELSE N'Over Threshold' END,
    p.Remark
FROM dbo.tblBA204_Productivity2 p;
GO

-- Master SKU
CREATE OR ALTER VIEW dbo.vw_PBI_SKU AS
SELECT Material, SKU, Gauge, LengthMM FROM dbo.tblBA204_MaterialMaster;
GO

-- Aktual vs Prediksi (output harian). Prediksi diambil versi terbaru
-- untuk setiap tanggal + product type + sub type + material.
CREATE OR ALTER VIEW dbo.vw_PBI_AktualVsPrediksi AS
WITH aktual AS (
    SELECT DateOperation, ProductType,
           Actual_Output = SUM(Qty_Output),
           Target_Output = SUM(Target_Output),
           Qty_Process   = SUM(Qty_Process)
    FROM dbo.tblBA204_DailyOutput2
    GROUP BY DateOperation, ProductType
),
prediksi_terbaru AS (
    SELECT *, rn = ROW_NUMBER() OVER (
              PARTITION BY DateOperation, ProductType, ISNULL(ProductSubType, N''), ISNULL(Material, N'')
              ORDER BY CreatedOn DESC, Id DESC)
    FROM dbo.tblBA204_Prediction
),
prediksi AS (
    SELECT DateOperation, ProductType,
           Pred_Output  = SUM(Pred_Output),
           Pred_Yield   = AVG(Pred_Yield),
           ModelName    = MAX(ModelName),
           ModelVersion = MAX(ModelVersion)
    FROM prediksi_terbaru
    WHERE rn = 1
    GROUP BY DateOperation, ProductType
)
SELECT
    DateOperation = COALESCE(a.DateOperation, p.DateOperation),
    ProductType   = COALESCE(a.ProductType, p.ProductType),
    a.Actual_Output,
    a.Target_Output,
    Actual_Yield  = CAST(a.Actual_Output / NULLIF(a.Qty_Process, 0) AS decimal(9,6)),
    p.Pred_Output,
    p.Pred_Yield,
    Selisih       = a.Actual_Output - p.Pred_Output,
    APE           = CAST(ABS(a.Actual_Output - p.Pred_Output) / NULLIF(a.Actual_Output, 0) AS decimal(9,6)),
    p.ModelName,
    p.ModelVersion
FROM aktual a
FULL OUTER JOIN prediksi p
    ON p.DateOperation = a.DateOperation AND p.ProductType = a.ProductType;
GO
