-- =============================================================
-- 96_pProcessInboundPutAway_no_wms_on_qty_short.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessInboundPutAway (TS / RC put-away): when the last pallet is put
-- away the job still completes (job_status_id = 5, end_datetime) as
-- before, but is_job_complete is now 1 only when the qty moved
-- (SUM tr_job_to_location.actual_qty) has reached the WMS+ qty
-- (SUM tr_job_to_location.qty).
--
-- Why: JobController InboundGetPutAway sends the job to WMS+
-- (pWmsPlus_InboundGetPutAway -> WMS212 confirm location) only when
-- is_job_complete = 1. A job whose pallets are all in but whose moved qty
-- is short of WMS+ (e.g. job 745: 2/2 pallets, 702 / 3,501 kg) must not be
-- confirmed to WMS+ -- the user finishes the rest in WMS+ (boardman's
-- job-list shows a red strip for it).
--
-- Changes (everything else unchanged):
--   1. after "DECLARE @is_job_complete BIT = 0;": read @to_qty /
--      @to_actual_qty for the job and set @is_qty_complete.
--   2. "SET @is_job_complete = 1;" -> "SET @is_job_complete = @is_qty_complete;"
--   3. the success row also returns is_qty_complete, actual_qty, qty
--      (extra columns; callers read by name).
--
-- Patched from the live definition with REPLACE (same way as sql/93, 95):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 96_ marker is already in the proc.
-- Rollback: sql/96_rollback_pProcessInboundPutAway.sql (reverse REPLACE).
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessInboundPutAway';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @lf   NCHAR(1)      = NCHAR(10);
DECLARE @tab  NCHAR(1)      = NCHAR(9);

DECLARE @old1 NVARCHAR(MAX) = N'DECLARE @is_job_complete BIT = 0;';
DECLARE @new1 NVARCHAR(MAX) =
    N'DECLARE @is_job_complete BIT = 0;' + @lf + @lf
  + @tab + @tab + N'--  96_: WMS+ is confirmed (is_job_complete = 1) only when the qty moved' + @lf
  + @tab + @tab + N'--  has reached the WMS+ qty; the job still completes on pallets alone.' + @lf
  + @tab + @tab + N'DECLARE @to_qty INT, @to_actual_qty INT;' + @lf + @lf
  + @tab + @tab + N'SELECT @to_qty = SUM(ISNULL(qty, 0)), @to_actual_qty = SUM(ISNULL(actual_qty, 0))' + @lf
  + @tab + @tab + N'FROM dbo.tr_job_to_location' + @lf
  + @tab + @tab + N'WHERE job_main_id = @job_main_id AND is_active = ''Y'' AND status_flag = ''A'';' + @lf + @lf
  + @tab + @tab + N'DECLARE @is_qty_complete BIT = CASE WHEN ISNULL(@to_actual_qty, 0) >= ISNULL(@to_qty, 0) THEN 1 ELSE 0 END;';

DECLARE @old2 NVARCHAR(MAX) = N'SET @is_job_complete = 1;';
DECLARE @new2 NVARCHAR(MAX) = N'SET @is_job_complete = @is_qty_complete;';

DECLARE @old3 NVARCHAR(MAX) = N'@is_job_complete AS is_job_complete;';
DECLARE @new3 NVARCHAR(MAX) =
    N'@is_job_complete AS is_job_complete,' + @lf
  + @tab + @tab + @tab + N'@is_qty_complete AS is_qty_complete, ISNULL(@to_actual_qty, 0) AS actual_qty, ISNULL(@to_qty, 0) AS qty;';

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundPutAway: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF @d LIKE N'%96\_:%' ESCAPE N'\'
BEGIN
    PRINT 'pProcessInboundPutAway is already patched (96_) - skipped.';
    RETURN;
END

--  each piece exactly once
IF (LEN(@d) - LEN(REPLACE(@d, @old1, N''))) / LEN(@old1) <> 1
   OR (LEN(@d) - LEN(REPLACE(@d, @old2, N''))) / LEN(@old2) <> 1
   OR (LEN(@d) - LEN(REPLACE(@d, @old3, N''))) / LEN(@old3) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: a piece to replace was not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(REPLACE(REPLACE(@d, @old1, @new1), @old2, @new2), @old3, @new3);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway patched (96_).';
GO
