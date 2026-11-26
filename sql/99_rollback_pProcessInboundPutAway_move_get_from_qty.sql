-- =============================================================
-- 99_rollback_pProcessInboundPutAway_move_get_from_qty.sql  (IRPC_QTRACK)
-- =============================================================
-- Reverses sql/99_pProcessInboundPutAway_move_get_from_qty.sql:
--   1. pProcessInboundPutAway: removes the 99_ block (reverse REPLACE).
--   2. dbo.fPutAwayTargetItem: back to the 2026-10-30 08:38 definition
--      (without the @@ROWCOUNT guard).
-- Does not touch tr_job_from_location rows already moved by the 99_ block.
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
DECLARE @t2   NCHAR(2)      = NCHAR(9) + NCHAR(9);
DECLARE @t3   NCHAR(3)      = NCHAR(9) + NCHAR(9) + NCHAR(9);
DECLARE @t4   NCHAR(4)      = NCHAR(9) + NCHAR(9) + NCHAR(9) + NCHAR(9);

DECLARE @old1 NVARCHAR(MAX) = N'SET @job_item_id = dbo.fPutAwayTargetItem(@job_main_id, @job_item_id, @location_id);';
DECLARE @new1 NVARCHAR(MAX) =
    @old1 + @lf + @lf
  + @t2 + N'--  99_: the GET added this pallet''s qty to tr_job_from_location.actual_qty' + @lf
  + @t2 + N'--  of the scanned item -> move it to the target item too (same from' + @lf
  + @t2 + N'--  location), so the counts and pProcessInboundResetPallet stay right.' + @lf
  + @t2 + N'--  Runs before the GET row is moved below (still on @orig_item_id here).' + @lf
  + @t2 + N'IF @job_item_id <> @orig_item_id' + @lf
  + @t2 + N'BEGIN' + @lf
  + @t3 + N'DECLARE @get_location_id INT, @get_qty INT = dbo.fGetPalletQty(@pallet_id);' + @lf + @lf
  + @t3 + N'SELECT TOP (1) @get_location_id = location_id' + @lf
  + @t3 + N'FROM dbo.tr_pallet_history' + @lf
  + @t3 + N'WHERE job_main_id = @job_main_id AND job_item_id = @orig_item_id' + @lf
  + @t3 + N'  AND pallet_id = @pallet_id AND process_id = 1' + @lf
  + @t3 + N'  AND is_active = ''Y'' AND status_flag = ''A''' + @lf
  + @t3 + N'ORDER BY id DESC;' + @lf + @lf
  + @t3 + N'IF @get_location_id IS NOT NULL' + @lf
  + @t3 + N'BEGIN' + @lf
  + @t4 + N'UPDATE dbo.tr_job_from_location' + @lf
  + @t4 + N'SET actual_qty = CASE WHEN ISNULL(actual_qty, 0) - @get_qty < 0 THEN 0' + @lf
  + @t4 + N'                      ELSE ISNULL(actual_qty, 0) - @get_qty END,' + @lf
  + @t4 + N'	update_user_id = @user_id, update_datetime = GETDATE()' + @lf
  + @t4 + N'WHERE job_main_id = @job_main_id AND interface_job_item_id = @orig_item_id' + @lf
  + @t4 + N'  AND from_location_id = @get_location_id AND ISNULL(qty, 0) <> 0' + @lf
  + @t4 + N'  AND is_active = ''Y'' AND status_flag = ''A'';' + @lf + @lf
  + @t4 + N'UPDATE dbo.tr_job_from_location' + @lf
  + @t4 + N'SET actual_qty = ISNULL(actual_qty, 0) + @get_qty,' + @lf
  + @t4 + N'	update_user_id = @user_id, update_datetime = GETDATE()' + @lf
  + @t4 + N'WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id' + @lf
  + @t4 + N'  AND from_location_id = @get_location_id AND ISNULL(qty, 0) <> 0' + @lf
  + @t4 + N'  AND is_active = ''Y'' AND status_flag = ''A'';' + @lf
  + @t3 + N'END' + @lf
  + @t2 + N'END';

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundPutAway: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF (LEN(@d) - LEN(REPLACE(@d, @new1, N''))) / LEN(@new1) <> 1
BEGIN
    PRINT 'pProcessInboundPutAway: 99_ block not found exactly once - not changed.';
    RETURN;
END

SET @d = REPLACE(@d, @new1, @old1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway rolled back (99_ removed).';
GO

ALTER FUNCTION dbo.fPutAwayTargetItem
(
    @job_main_id INT,
    @job_item_id INT,
    @location_id INT
)
RETURNS INT
AS
BEGIN
    DECLARE @job_type_id INT = (SELECT job_type_id FROM dbo.tr_job_main WHERE id = @job_main_id);

    DECLARE @job TABLE (
        item_id          INT,
        grade            NVARCHAR(50),   -- fSpecialJob returns NVARCHAR(50), others VARCHAR(30)
        lot_no           NVARCHAR(50),
        from_location_id INT,
        to_location_id   INT,
        qty              INT,
        actual_qty       INT
    );

    IF @job_type_id = 1
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fTransferSlipJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 2
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fReceiveJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 3
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fRequestJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 4
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fPickingJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 5
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fShippingJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 6
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fBrokenBagJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 7
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fSpecialJob(@job_main_id, NULL, NULL);
    ELSE IF @job_type_id = 9
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fLoadingJob(@job_main_id, NULL);
    ELSE IF @job_type_id = 10
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fInternalTransferJob(@job_main_id, NULL);
    ELSE IF @job_type_id = 11
        INSERT INTO @job SELECT item_id, grade, lot_no, from_location_id, to_location_id, qty_to_location, actual_qty_to_location
        FROM dbo.fTransferWhJob(@job_main_id, NULL, NULL);
    ELSE
        RETURN @job_item_id;

    DECLARE @grade NVARCHAR(50), @lot_no NVARCHAR(50), @from_location_id INT, @target_item_id INT;

    -- Scanned item's grade/lot; prefer its row at the put-away location.
    SELECT TOP (1) @grade = grade, @lot_no = lot_no, @from_location_id = from_location_id
    FROM @job
    WHERE item_id = @job_item_id
    ORDER BY CASE WHEN to_location_id = @location_id THEN 0 ELSE 1 END;

    -- Scanned item first, then the lowest other item_id with room.
    SELECT TOP (1) @target_item_id = item_id
    FROM @job
    WHERE ISNULL(grade, '')  = ISNULL(@grade, '')
      AND ISNULL(lot_no, '') = ISNULL(@lot_no, '')
      AND ISNULL(from_location_id, -1) = ISNULL(@from_location_id, -1)
      AND to_location_id = @location_id
      AND ISNULL(actual_qty, 0) < ISNULL(qty, 0)
    ORDER BY CASE WHEN item_id = @job_item_id THEN 0 ELSE 1 END, item_id;

    RETURN ISNULL(@target_item_id, @job_item_id);
END
GO
PRINT 'fPutAwayTargetItem rolled back.';
GO
