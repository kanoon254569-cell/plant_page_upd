-- =============================================================
-- 96_rollback_pProcessInboundPutAway.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 96_pProcessInboundPutAway_no_wms_on_qty_short.sql: puts back
-- "is_job_complete = 1 as soon as every pallet is in" (WMS+ confirmed
-- even when the moved qty is short) and the success row without
-- is_qty_complete / actual_qty / qty.
--
-- Patched from the live definition with REPLACE, the reverse of 96:
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 96_ marker is not in the proc.
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

IF @d NOT LIKE N'%96\_:%' ESCAPE N'\'
BEGIN
    PRINT 'pProcessInboundPutAway has no 96_ patch - skipped.';
    RETURN;
END

IF (LEN(@d) - LEN(REPLACE(@d, @new1, N''))) / LEN(@new1) <> 1
   OR (LEN(@d) - LEN(REPLACE(@d, @new2, N''))) / LEN(@new2) <> 1
   OR (LEN(@d) - LEN(REPLACE(@d, @new3, N''))) / LEN(@new3) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: a 96_ piece was not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(REPLACE(REPLACE(@d, @new3, @old3), @new2, @old2), @new1, @old1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway rolled back (96_ removed).';
GO
