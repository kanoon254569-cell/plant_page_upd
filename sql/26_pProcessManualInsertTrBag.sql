/* =====================================================================
   pProcessManualInsertTrBag
   -----------------------------------------------------------------
   Manual bulk-insert into dbo.tr_bag for one cost_center/grade/lot,
   built on top of the existing dbo.pProcessInsertTrBag (reused as-is,
   one call per bag -- no duplicated insert/validation logic here).

   Input is business-level, not per-bag: @pallet_qty (how many pallets
   worth of bags to create). Bags/pallet is looked up from
   dbo.ct_grade_package_ratio.unit_pallet for @grade (see
   09_ct_grade_package_ratio.sql) -- total bags inserted = @pallet_qty *
   unit_pallet.

   qr_text_data for each generated bag follows the same format every
   other object in this set relies on (cost_center|grade|lot|bag_no|
   pallet_running_no, see 10_fParseBagQr.sql): bag_no runs 1..unit_pallet
   within each pallet, pallet_running_no runs @pallet_qty consecutive
   numbers. To avoid colliding with pallet_running_no values already in
   use for this cost_center/grade/lot (real scanned bags or earlier
   manual runs), numbering continues from
   MAX(existing pallet_running_no) + 1 rather than always starting at 1
   -- existing pallet_running_no is read back out of qr_text_data via
   fParseBagQr (single source of truth), not the tr_bag columns, same
   reasoning as pProcessUpdateBagRejectStatus.

   @mode_id defaults to 3 -- the same mode dbo.pProcessInsertTrBag's own
   duplicate check already special-cases (`mode_id <> 3` in its EXISTS
   check), i.e. rows inserted this way never block, and are never
   blocked by, a later insert of the same qr_text_data. Caller can still
   override it.

   Whole batch runs in one transaction: if any individual
   pProcessInsertTrBag call returns status <> 'success' (bad input,
   genuine duplicate against a non-mode-3 row, etc.), the entire batch
   is rolled back and that call's own error message is returned as-is --
   never a partial insert.

   Dependencies: dbo.pProcessInsertTrBag (pre-existing SP, not part of
                 this file set), 09_ct_grade_package_ratio.sql,
                 10_fParseBagQr.sql.
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessManualInsertTrBag]
    @cost_center VARCHAR(20) = NULL,
    @grade       VARCHAR(30) = NULL,
    @lot         VARCHAR(20) = NULL,
    @pallet_qty  INT         = NULL,
    @mode_id     INT         = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ================================================
    -- Validate input parameters
    -- ================================================

    IF @cost_center IS NULL OR LEN(@cost_center) = 0
    BEGIN
        SELECT 'error' AS status, 'Cost center not found.' AS message
        RETURN
    END

    IF @grade IS NULL OR LEN(@grade) = 0
    BEGIN
        SELECT 'error' AS status, 'Grade not found.' AS message
        RETURN
    END

    IF @lot IS NULL OR LEN(@lot) = 0
    BEGIN
        SELECT 'error' AS status, 'Lot not found.' AS message
        RETURN
    END

    IF @pallet_qty IS NULL OR @pallet_qty <= 0
    BEGIN
        SELECT 'error' AS status, 'Pallet qty must be greater than 0.' AS message
        RETURN
    END

    IF @mode_id IS NULL
    BEGIN
        SELECT 'error' AS status, 'Mode not found.' AS message
        RETURN
    END

    IF LEN(@cost_center) > 4
    BEGIN
        SELECT 'error' AS status, 'Invalid format cost center.' AS message
        RETURN
    END

    IF LEN(@grade) > 20
    BEGIN
        SELECT 'error' AS status, 'Invalid grade.' AS message
        RETURN
    END

    IF LEN(@lot) > 15
    BEGIN
        SELECT 'error' AS status, 'Invalid lot.' AS message
        RETURN
    END

    -- ================================================
    -- Look up bags/pallet (unit_pallet) for this grade
    -- ================================================

    DECLARE @unit_pallet INT;

    SELECT @unit_pallet = unit_pallet
    FROM dbo.ct_grade_package_ratio
    WHERE grade = @grade;

    IF @unit_pallet IS NULL OR @unit_pallet <= 0
    BEGIN
        SELECT 'error' AS status, CONCAT('No package ratio (unit_pallet) found for grade ', @grade, '.') AS message
        RETURN
    END

    IF @unit_pallet > 99
    BEGIN
        SELECT 'error' AS status, CONCAT('unit_pallet (', @unit_pallet, ') exceeds bag_no format limit (max 99 bags/pallet).') AS message
        RETURN
    END

    -- ================================================
    -- Continue pallet_running_no from the highest one
    -- already in use for this cost_center/grade/lot
    -- (parsed from qr_text_data, not the tr_bag columns)
    -- ================================================

    DECLARE @start_pallet_no INT;

    SELECT @start_pallet_no = ISNULL(MAX(q.pallet_running_no), 0) + 1
    FROM dbo.tr_bag b
    CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
    WHERE b.cost_center = @cost_center
      AND b.grade       = @grade
      AND b.lot         = @lot
      AND b.status_flag = 'A';

    DECLARE @end_pallet_no INT = @start_pallet_no + @pallet_qty - 1;

    IF @end_pallet_no > 999
    BEGIN
        SELECT 'error' AS status,
               CONCAT('pallet_running_no would exceed format limit (max 999) - next available start is ',
                      @start_pallet_no, ' for qty ', @pallet_qty, '.') AS message
        RETURN
    END

    -- ================================================
    -- Generate one bag per (pallet_running_no, bag_no)
    -- via dbo.pProcessInsertTrBag, whole batch atomic
    -- ================================================

    DECLARE @call_result TABLE (status VARCHAR(20), message VARCHAR(400));
    DECLARE @call_status VARCHAR(20), @call_message VARCHAR(400);
    DECLARE @pallet_no INT = @start_pallet_no, @bag_no INT, @qr_text_data VARCHAR(100);
    DECLARE @inserted_count INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        WHILE @pallet_no <= @end_pallet_no
        BEGIN
            SET @bag_no = 1;

            WHILE @bag_no <= @unit_pallet
            BEGIN
                SET @qr_text_data = @cost_center + '|' + @grade + '|' + @lot + '|'
                    + RIGHT('00' + CAST(@bag_no AS VARCHAR(2)), 2) + '|'
                    + RIGHT('000' + CAST(@pallet_no AS VARCHAR(3)), 3);

                DELETE FROM @call_result;

                INSERT INTO @call_result (status, message)
                EXEC dbo.pProcessInsertTrBag @qr_text_data = @qr_text_data, @mode_id = @mode_id;

                SELECT @call_status = status, @call_message = message FROM @call_result;

                IF @call_status <> 'success'
                BEGIN
                    ROLLBACK TRAN;
                    SELECT 'error' AS status,
                           CONCAT('Insert failed at pallet_running_no ', @pallet_no, ', bag_no ', @bag_no,
                                  ' (qr_text_data=', @qr_text_data, '): ', @call_message) AS message
                    RETURN
                END

                SET @inserted_count += 1;
                SET @bag_no += 1;
            END

            SET @pallet_no += 1;
        END

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message
        RETURN
    END CATCH

    SELECT 'success' AS status,
           CONCAT(@inserted_count, ' bag(s) inserted across ', @pallet_qty, ' pallet(s) (',
                  @unit_pallet, ' bag/pallet) for ', @cost_center, '|', @grade, '|', @lot,
                  ', pallet_running_no ', @start_pallet_no, '-', @end_pallet_no, '.') AS message

END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessManualInsertTrBag @cost_center = '1301', @grade = 'V1160SUB',
--      @lot = 'L0001', @pallet_qty = 2;
