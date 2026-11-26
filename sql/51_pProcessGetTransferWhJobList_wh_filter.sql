-- =============================================================
-- 51_pProcessGetTransferWhJobList_wh_filter.sql  (IRPC_QTRACK)
-- =============================================================
-- WH04 Transfer Warehouse list: "WH ต้นทาง" / "WH ปลายทาง" filters.
--
--   @from_wh_code  IRPC_E_TRANSFER.dbo.VTransferWhForm.source   (header, e.g. M42)
--   @to_wh_code    IRPC_E_TRANSFER.dbo.VTransferWhForm.wh_code  (item,   e.g. M38, M40)
--
-- Both optional (default NULL -- existing callers unchanged). Job-level:
-- a job keeps all its rows when any of its form rows matches, so the card's
-- other items and totals aren't cut down (same rule as pProcessGetJobList's
-- @to_wh_code). Options: GET api/v1/process-cb/location-wh?wh=MWH (wh_code).
--
-- Patches the live definition with REPLACE (same way as 44 / 47): every
-- piece must be found exactly once, else nothing is changed. Idempotent.
-- Needs 50 deployed first.
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetTransferWhJobList'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%@from_wh_code%'
BEGIN
    PRINT 'pProcessGetTransferWhJobList already has the WH filters - skipped.';
    RETURN;
END

-- 1) parameters
DECLARE @o1 NVARCHAR(400) = N'    @user_id        INT             = NULL' + @nl + N'AS';
DECLARE @n1 NVARCHAR(400) =
      N'    @user_id        INT             = NULL,' + @nl
    + N'    @from_wh_code   NVARCHAR(30)    = NULL,' + @nl
    + N'    @to_wh_code     NVARCHAR(30)    = NULL' + @nl
    + N'AS';

-- 2) job-level filter on the form's source / wh_code
DECLARE @o2 NVARCHAR(400) = N'      AND (@job_status_id IS NULL OR j.job_status_id = @job_status_id);';
DECLARE @n2 NVARCHAR(MAX) =
      N'      AND (@job_status_id IS NULL OR j.job_status_id = @job_status_id)' + @nl
    + N'      AND (@from_wh_code IS NULL OR EXISTS (' + @nl
    + N'            SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferWhForm tw' + @nl
    + N'            WHERE tw.header_id = j.header_id AND tw.source = @from_wh_code))' + @nl
    + N'      AND (@to_wh_code IS NULL OR EXISTS (' + @nl
    + N'            SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferWhForm tw' + @nl
    + N'            WHERE tw.header_id = j.header_id AND tw.wh_code = @to_wh_code));';

IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
BEGIN
    RAISERROR('pProcessGetTransferWhJobList: text to patch not found exactly once - not patched (run 50 first).', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetTransferWhJobList patched: @from_wh_code / @to_wh_code.';
GO
