/* =====================================================================
   PBL PBLIF3-MD04  -  Bagian 7: percepatan query departemen
   Kolom Dept dibuat sebagai computed column PERSISTED di setiap tabel
   (ProductType mengandung kata kunci lini B -> SS, selain itu -> HDC;
   kata kunci asli ada di data_master_lokal.sql), jadi view
   tidak perlu menghitung departemen baris per baris lagi.
   Aman dijalankan berulang.
   ===================================================================== */
USE [PBL_MonitoringProduksi];
GO
IF COL_LENGTH('dbo.tblBA204_PODailyOutput', 'Dept') IS NULL
    ALTER TABLE dbo.tblBA204_PODailyOutput ADD Dept AS (CAST(CASE WHEN ProductType LIKE N'%LINI-B%' THEN N'SS' ELSE N'HDC' END AS nvarchar(10))) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_PODetailsReject', 'Dept') IS NULL
    ALTER TABLE dbo.tblBA204_PODetailsReject ADD Dept AS (CAST(CASE WHEN ProductType LIKE N'%LINI-B%' THEN N'SS' ELSE N'HDC' END AS nvarchar(10))) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_DailyOutput2', 'Dept') IS NULL
    ALTER TABLE dbo.tblBA204_DailyOutput2 ADD Dept AS (CAST(CASE WHEN ProductType LIKE N'%LINI-B%' THEN N'SS' ELSE N'HDC' END AS nvarchar(10))) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_Productivity2', 'Dept') IS NULL
    ALTER TABLE dbo.tblBA204_Productivity2 ADD Dept AS (CAST(CASE WHEN ProductType LIKE N'%LINI-B%' THEN N'SS' ELSE N'HDC' END AS nvarchar(10))) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_POHeader', 'Dept') IS NULL
    ALTER TABLE dbo.tblBA204_POHeader ADD Dept AS (CAST(CASE WHEN ProductType LIKE N'%LINI-B%' THEN N'SS' ELSE N'HDC' END AS nvarchar(10))) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_PODailyOutput', 'BulanReport') IS NULL
    ALTER TABLE dbo.tblBA204_PODailyOutput ADD BulanReport AS (DATEFROMPARTS(YEAR(DateReport), MONTH(DateReport), 1)) PERSISTED;
GO
IF COL_LENGTH('dbo.tblBA204_PODetailsReject', 'BulanReport') IS NULL
    ALTER TABLE dbo.tblBA204_PODetailsReject ADD BulanReport AS (DATEFROMPARTS(YEAR(DateReport), MONTH(DateReport), 1)) PERSISTED;
GO
CREATE OR ALTER VIEW dbo.vw_D_PODailyOutput AS
SELECT t.* FROM dbo.tblBA204_PODailyOutput t;
GO
CREATE OR ALTER VIEW dbo.vw_D_PODetailsReject AS
SELECT t.* FROM dbo.tblBA204_PODetailsReject t;
GO
CREATE OR ALTER VIEW dbo.vw_D_DailyOutput2 AS
SELECT t.* FROM dbo.tblBA204_DailyOutput2 t;
GO
CREATE OR ALTER VIEW dbo.vw_D_Productivity2 AS
SELECT t.* FROM dbo.tblBA204_Productivity2 t;
GO
CREATE OR ALTER VIEW dbo.vw_D_POHeader AS
SELECT t.* FROM dbo.tblBA204_POHeader t;
GO
CREATE OR ALTER VIEW dbo.vw_BulanLaporan AS
SELECT DISTINCT Dept, Bulan = DATEFROMPARTS(YEAR(DateOperation), MONTH(DateOperation), 1)
FROM dbo.tblBA204_DailyOutput2
WHERE DateOperation IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PODailyOutput_DeptRep')
    CREATE INDEX IX_PODailyOutput_DeptRep ON dbo.tblBA204_PODailyOutput (Dept, DateReport) INCLUDE (Process, PON, Qty_Output, Qty_Start, BulanReport);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PODailyOutput_DeptOp')
    CREATE INDEX IX_PODailyOutput_DeptOp ON dbo.tblBA204_PODailyOutput (Dept, Process, DateOperation) INCLUDE (PON, Qty_Output, Qty_Start);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PODetailsReject_DeptRep')
    CREATE INDEX IX_PODetailsReject_DeptRep ON dbo.tblBA204_PODetailsReject (Dept, DateReport) INCLUDE (PON, Process, RejectType, Reject_qty, BulanReport);
GO
