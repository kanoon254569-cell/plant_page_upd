-- =============================================================
-- 97_rollback_pProcessInboundPutAway.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 97_pProcessInboundPutAway_block_qty_over.sql: removes the
-- "qty over the WMS+ qty of the location" check, so a pallet is accepted
-- whatever its qty (as before).
--
-- Patched from the live definition with REPLACE, the reverse of 97:
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 97_ marker is not in the proc.
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
DECLARE @t2   NCHAR(2)      = NCHAR(9) + NCHAR(9);
DECLARE @t3   NCHAR(3)      = NCHAR(9) + NCHAR(9) + NCHAR(9);

DECLARE @old1 NVARCHAR(MAX) = N'UPDATE dbo.tr_pallet' + @lf + @t2 + N'SET current_job_id';
DECLARE @new1 NVARCHAR(MAX) =
    N'--  97_: refuse the pallet when its qty would push the moved qty past the' + @lf
  + @t2 + N'--  WMS+ qty of this job / item / location (nothing is saved).' + @lf
  + @t2 + N'DECLARE @put_qty INT = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);' + @lf
  + @t2 + N'DECLARE @loc_qty INT, @loc_actual_qty INT;' + @lf + @lf
  + @t2 + N'SELECT @loc_qty = SUM(ISNULL(qty, 0)), @loc_actual_qty = SUM(ISNULL(actual_qty, 0))' + @lf
  + @t2 + N'FROM dbo.tr_job_to_location' + @lf
  + @t2 + N'WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id' + @lf
  + @t2 + N'  AND to_location_id = @location_id AND ISNULL(qty, 0) <> 0' + @lf
  + @t2 + N'  AND is_active = ''Y'' AND status_flag = ''A'';' + @lf + @lf
  + @t2 + N'IF @loc_qty IS NOT NULL AND ISNULL(@loc_actual_qty, 0) + @put_qty > @loc_qty' + @lf
  + @t2 + N'BEGIN' + @lf
  + @t3 + N'ROLLBACK TRANSACTION;' + @lf
  + @t3 + N'SELECT ''error'' AS status,' + @lf
  + @t3 + @tab + N'CONCAT(N''จำนวนเกินที่กำหนด (กำหนด '', @loc_qty, N'', จัดเก็บแล้ว '', ISNULL(@loc_actual_qty, 0), N'', พาเลทนี้ '', @put_qty, N'')'') AS message;' + @lf
  + @t3 + N'RETURN;' + @lf
  + @t2 + N'END' + @lf + @lf
  + @t2 + @old1;

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundPutAway: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF @d NOT LIKE N'%97\_:%' ESCAPE N'\'
BEGIN
    PRINT 'pProcessInboundPutAway has no 97_ patch - skipped.';
    RETURN;
END

IF (LEN(@d) - LEN(REPLACE(@d, @new1, N''))) / LEN(@new1) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: the 97_ piece was not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @new1, @old1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway rolled back (97_ removed).';
GO
