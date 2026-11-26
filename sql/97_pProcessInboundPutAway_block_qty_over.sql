-- =============================================================
-- 97_pProcessInboundPutAway_block_qty_over.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessInboundPutAway (TS / RC put-away): refuse a pallet whose qty
-- would push the moved qty past the WMS+ qty of its destination.
--
-- Rule: for the job / item / to_location row(s) that this proc adds
-- actual_qty to (tr_job_to_location, active, qty <> 0):
--     SUM(actual_qty) + fGetPalletQty(pallet) > SUM(qty)  -> error, nothing saved.
-- When the location has no such row, nothing changes (actual_qty is not
-- updated there either, same as before).
--
-- The check runs inside the transaction, right after the UPDLOCK/HOLDLOCK
-- on tr_job_main, so two scans of the same job cannot both pass it.
--
-- Change (everything else unchanged): a check block is inserted before
-- "UPDATE dbo.tr_pallet / SET current_job_id ...". Works with or without
-- the 96_ patch.
--
-- Patched from the live definition with REPLACE (same way as sql/93, 95, 96):
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 97_ marker is already in the proc.
-- Rollback: sql/97_rollback_pProcessInboundPutAway.sql (reverse REPLACE).
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

IF @d LIKE N'%97\_:%' ESCAPE N'\'
BEGIN
    PRINT 'pProcessInboundPutAway is already patched (97_) - skipped.';
    RETURN;
END

--  piece exactly once
IF (LEN(@d) - LEN(REPLACE(@d, @old1, N''))) / LEN(@old1) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: the piece to replace was not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @old1, @new1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway patched (97_).';
GO
