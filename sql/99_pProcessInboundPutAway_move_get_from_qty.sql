-- =============================================================
-- 99_pProcessInboundPutAway_move_get_from_qty.sql  (IRPC_QTRACK)
-- =============================================================
-- Follow-up to the 2026-10-30 change (dbo.fPutAwayTargetItem + the
-- redirect block in pProcessInboundPutAway).
--
-- Bug: when the scanned item is full at the put-away location, the proc
-- puts the pallet on another item (target) and moves the pallet's GET row
-- (tr_pallet_history process_id 1) to that item. But the GET also added
-- fGetPalletQty(pallet) to tr_job_from_location.actual_qty of the SCANNED
-- item (pProcessInboundGetPallet), and that qty was not moved:
--   - scanned item: from actual_qty stays too high (no GET row for it)
--   - target item : from actual_qty too low (GET row, no qty)
--   - pProcessInboundResetPallet takes the qty back by the history
--     job_item_id (now target) -> takes it from the wrong item (clamped at
--     0), the scanned item keeps the extra qty for good.
--
-- Changes:
--   1. pProcessInboundPutAway: right after "SET @job_item_id =
--      dbo.fPutAwayTargetItem(...)", when the item changed, move the
--      pallet's qty from the scanned item's tr_job_from_location row to the
--      target item's row (same from location = the GET row's location_id),
--      with the same row filter the GET used (qty <> 0, active).
--   2. dbo.fPutAwayTargetItem: if the scanned item has no row in the job
--      function, return it as is. Before, @grade/@lot_no/@from_location_id
--      stayed NULL and the 2nd SELECT could pick any item whose grade/lot
--      is empty.
--
-- (1) patched from the live definition with REPLACE (same way as sql/93,
-- 95, 96): the anchor must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 99_ marker is already in the proc.
-- Rollback: sql/99_rollback_pProcessInboundPutAway_move_get_from_qty.sql
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------
-- 1. pProcessInboundPutAway
-- -------------------------------------------------------------
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

IF @d LIKE N'%99\_:%' ESCAPE N'\'
BEGIN
    PRINT 'pProcessInboundPutAway is already patched (99_) - skipped.';
    RETURN;
END

--  anchor exactly once
IF (LEN(@d) - LEN(REPLACE(@d, @old1, N''))) / LEN(@old1) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: the fPutAwayTargetItem line was not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @old1, @new1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway patched (99_).';
GO

-- -------------------------------------------------------------
-- 2. dbo.fPutAwayTargetItem (no Thai text -> full ALTER is safe)
-- -------------------------------------------------------------
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

    -- 99_: scanned item not in the job function -> keep it (else NULL grade/lot
    -- would match any item with an empty grade/lot).
    IF @@ROWCOUNT = 0
        RETURN @job_item_id;

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
PRINT 'fPutAwayTargetItem altered (99_).';
GO
