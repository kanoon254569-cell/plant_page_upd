/* =====================================================================
   Deploy: get-pallet (PK / RQ / TW / IT) -- bag QR with no @mode_id takes the whole pallet. Rollback: deploy_75_rollback_get_pallet_null_mode_full_pallet_20261112.sql
   Server: 10.31.1.75 (IRPC_QTRACK)
   Contains, in order:
     - sql/116_pProcessPickingGetPallet_null_mode_full_pallet.sql
     - sql/117_pProcessRequestGetPallet_null_mode_full_pallet.sql
     - sql/118_pProcessTransferWhGetPallet_null_mode_full_pallet.sql
     - sql/119_pProcessInternalTransferGetPallet_null_mode_full_pallet.sql
   Each part is CREATE OR ALTER PROC and does not depend on the others.
   ===================================================================== */
-- #################### 116_pProcessPickingGetPallet_null_mode_full_pallet.sql ####################
/* =====================================================================
   Deploy to 10.31.1.75 -- pProcessPickingGetPallet (Picking, PK)
   Bag QR with no @mode_id takes the whole pallet.
   ---------------------------------------------------------------------
   The forklift app's normal / manual-pallet flow (runInboundGet) sends
   only qrCode, so the API passes @mode_id = NULL; that took only the
   scanned bag (job 1999 on 2026-11-11: 15 scans = 15 bags = 375 kg of
   15000 kg). Special-job flow always sends modeId 1 / 2 / 3.
   Whole pallet now = pallet QR, @mode_id NULL or @mode_id 1.
   Modes 2 (store bag) and 3 (pick bag) are unchanged.
   Rollback: 116_rollback_pProcessPickingGetPallet_null_mode_full_pallet.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- ===== dbo.pProcessPickingGetPallet =====
-- ---------------------------------------------------------------------
-- pProcessPickingGetPallet: GET like pProcessRequestGetPallet
-- (bag / pallet QR, @pallet_seq, @mode_id, kg over qty -> roll back)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessPickingGetPallet]
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @mode_id            INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    -- ------------------------------------------------
    -- Job / item (picking job_type_id 4 + vPickingForm)
    -- ------------------------------------------------
    DECLARE @job_ok BIT = 0, @item_ok BIT = 0;

    IF EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
        SET @job_ok = 1;

    IF EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
          AND (jm.is_active IS NULL OR jm.is_active = 'Y')
          AND f.item_id = @job_item_id
    )
        SET @item_ok = 1;

    --  JB: create pallet + bag on first scan (pProcessInsertJbPalletBag),
    --  only for an existing job / item, before the QR lookup
    IF @job_ok = 1 AND @item_ok = 1
    BEGIN
        DECLARE @jb_status  VARCHAR(20);
        DECLARE @jb_message VARCHAR(200);

        EXEC dbo.pProcessInsertJbPalletBag
            @qr_code_text  = @qr_code_text,
            @user_id       = @user_id,
            @return_result = 0,
            @status        = @jb_status  OUTPUT,
            @message       = @jb_message OUTPUT;

        IF @jb_status = 'error'
        BEGIN
            SELECT 'error' AS status, @jb_message AS message;
            RETURN;
        END
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    IF @job_ok = 0 OR @item_ok = 0
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    --  Whole pallet: pallet QR, mode 1 or no mode (the app's normal flow sends no mode)
    DECLARE @is_full_pallet BIT = CASE WHEN @bag_id IS NULL OR @mode_id IS NULL OR @mode_id = 1 THEN 1 ELSE 0 END;
    DECLARE @locked_job_id INT, @job_status_id INT;
    DECLARE @loc_qty INT, @loc_actual_before INT, @loc_actual_after INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  A pallet already in another picking job
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet p
            INNER JOIN dbo.tr_job_main jm ON jm.id = p.current_job_id
            WHERE p.id = @pallet_id
              AND p.current_job_id <> @job_main_id
              AND jm.job_type_id = 4
              AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
              AND (jm.is_active IS NULL OR jm.is_active = 'Y')
              AND EXISTS (
                  SELECT 1 FROM dbo.vPickingForm f
                  WHERE f.header_id = jm.interface_job_id AND f.item_id IS NOT NULL
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้อยู่ในงาน Picking อื่นแล้ว' AS message;
            RETURN;
        END

        --  Only at a from-location of this item
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_from_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND (@location_type IS NULL OR from_location_type = @location_type)
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'ตำแหน่งนี้ไม่ใช่ต้นทางของงานนี้' AS message;
            RETURN;
        END

        --  No bag taken twice in this job (Get, Put or store bag)
        --  (mode 2 / 3: that bag; whole pallet: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 2, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@is_full_pallet = 0 AND ph.bag_id = @bag_id_text)
                 OR (@is_full_pallet = 1 AND EXISTS (
                        SELECT 1 FROM dbo.tr_bag b
                        WHERE b.id = TRY_CONVERT(BIGINT, ph.bag_id)
                          AND b.pallet_id = @pallet_id
                          AND b.is_active = 'Y'
                          AND b.status_flag = 'A'))
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกรับเข้ามาแล้ว' AS message;
            RETURN;
        END

        --  qty of this item / from-location and what is taken there already
        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_from_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND from_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        IF @loc_qty IS NOT NULL
            SELECT @loc_actual_before = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        UPDATE dbo.tr_job_main
        SET job_status_id = 4,
            start_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @job_main_id
          AND ISNULL(job_status_id, 0) <> 4;

        UPDATE dbo.tr_pallet
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @pallet_id;

        -- ------------------------------------------------
        -- Get rows (one per bag)
        --   whole pallet: every active bag of the pallet
        --   mode 2 (store bag): the scanned bag stays (process 4), the rest of the pallet is taken
        --   mode 3 (pick bag) : the scanned bag
        -- (Whole pallet: the taken-twice check above leaves no active row of the
        --  pallet's bags in this job, so the NOT EXISTS below filters nothing.)
        -- ------------------------------------------------
        IF @is_full_pallet = 0 AND @mode_id = 2
           --  only active rows count, so a reset pallet can be scanned again
           AND NOT EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history
                WHERE job_main_id = @job_main_id
                  AND job_item_id = @job_item_id
                  AND bag_id = @bag_id_text
                  AND process_id = 4
                  AND is_active = 'Y'
                  AND status_flag = 'A'
           )
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        IF @is_full_pallet = 1 OR @mode_id = 2
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.tr_pallet_history ph
                  WHERE ph.job_main_id = @job_main_id
                    AND ph.job_item_id = @job_item_id
                    AND ph.bag_id = CAST(b.id AS VARCHAR(255))
                    AND ph.process_id IN (1, 4)
                    AND ph.is_active = 'Y'
                    AND ph.status_flag = 'A'
              );
        ELSE
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        -- ------------------------------------------------
        -- tr_job_from_location.actual_qty (kg) of this item / location; over qty -> roll back
        -- ------------------------------------------------
        IF @loc_qty IS NOT NULL
        BEGIN
            SELECT @loc_actual_after = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                       THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                       ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

            IF @loc_actual_after > @loc_qty
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'error' AS status,
                    CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                           N', รับแล้ว ', @loc_actual_before,
                           N', ครั้งนี้ ', @loc_actual_after - @loc_actual_before, N')') AS message;
                RETURN;
            END

            UPDATE dbo.tr_job_from_location
            SET actual_qty = @loc_actual_after,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND ISNULL(qty, 0) <> 0
              AND is_active = 'Y'
              AND status_flag = 'A'
              AND ISNULL(actual_qty, -1) <> @loc_actual_after;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    --  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
    EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

    SELECT 'success' AS status, N'พาเลทนี้ถูกรับเข้ามาสำเร็จ' AS message, @pallet_seq AS pallet_seq;
END
GO

-- #################### 117_pProcessRequestGetPallet_null_mode_full_pallet.sql ####################
/* =====================================================================
   Deploy to 10.31.1.75 -- pProcessRequestGetPallet (Request, RQ)
   Bag QR with no @mode_id takes the whole pallet.
   ---------------------------------------------------------------------
   The forklift app's normal / manual-pallet flow (runInboundGet) sends
   only qrCode, so the API passes @mode_id = NULL; that took only the
   scanned bag (job 1999 on 2026-11-11: 15 scans = 15 bags = 375 kg of
   15000 kg). Special-job flow always sends modeId 1 / 2 / 3.
   Whole pallet now = pallet QR, @mode_id NULL or @mode_id 1.
   Modes 2 (store bag) and 3 (pick bag) are unchanged.
   Rollback: 117_rollback_pProcessRequestGetPallet_null_mode_full_pallet.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- Request (RQ, job_type_id 3) Get / Put / Reset: clean rewrite of the 3 procs.
-- Server: 10.31.1.74 (IRPC_QTRACK). Rollback: sql/rollback_pProcessRequest_clean_10.31.1.74.sql
-- Same rules as sql/pProcessInternalTransfer_clean_10.31.1.74.sql:
-- - The job row is locked (tr_job_main UPDLOCK, HOLDLOCK) for the whole scan, so
--   2 scans of one job run one after the other.
-- - Qty formula: M / S pallet = unit_ratio * unit_pallet, else distinct bag count * unit_ratio.
-- - tr_job_from_location.actual_qty = active Get rows (process_id 1) at that location
--   (pWmsPlus_OutboundRequestPutAway sends this value to WMS+).
-- - tr_job_to_location.actual_qty   = active Put rows (process_id 2) at that location.
-- - A bag is not taken (Get) or put (Put) twice in one job.
-- - A scan that would take / put more than the location qty is rolled back.
-- - Get only at a from-location of the item, Put only at a to-location of the item.
-- - No Get / Put on a completed job (job_status_id 5).
-- - Put of a pallet with nothing taken, and Reset of a pallet with nothing in the
--   job, are errors (both used to answer success and do nothing).
-- - Messages to the app are Thai. SET XACT_ABORT ON in all 3.
--
-- Kept from the live RQ procs:
-- - A pallet already in another RQ job is refused.
-- - Put sets tr_pallet.outbound_to_plant_*; Reset clears them.
-- - Split remark 'RQ split: job <job> ...', transaction log topic 'Request'.
--
-- Changed from the live RQ procs:
-- - vJobMain / vRequestJob / fRequestBags -> tr_job_main + IRPC_E_TRANSFER.dbo.VRequestForm
--   and direct tr_pallet_history queries (same item rows, same completed qty and the
--   same complete / not complete result on all 67 RQ jobs on 10.31.1.74).
-- - fGetPalletQty -> inline formula above.
-- - tr_job_to_location.actual_qty is per to-location (was the item's total put qty).
-- - Get: actual_qty is recalculated for the scanned location (was actual_qty += qty).
-- - Same as Internal Transfer: @mode_id NULL = the whole pallet, as mode 1
--   (sql/117); Put recalculates tr_job_from_location.actual_qty of the whole
--   job; Put success and Put-twice messages are the IT ones.
-- - Reset: actual_qty is recalculated from history (the subtract step is gone).
--
-- Note: RQ jobs before about 2026-10-02 (job 709 and older) have one Get row per
-- pallet instead of one per bag. The formula counts those as 1 bag, so a Put or a
-- Reset on such a job gives a smaller actual_qty than before. All of them except jobs 5 and
-- 590 are completed (no Get / Put any more).

-- ================================================
-- pProcessRequestGetPallet
-- ================================================
CREATE OR ALTER PROC [dbo].[pProcessRequestGetPallet]
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @mode_id            INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    -- ------------------------------------------------
    -- Job / item (vJobMain rows of job_type_id 3, on base tables)
    -- ------------------------------------------------
    DECLARE @job_ok BIT = 0, @item_ok BIT = 0;

    IF EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
        SET @job_ok = 1;

    IF EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN IRPC_E_TRANSFER.dbo.VRequestForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 3
          AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
          AND (jm.is_active IS NULL OR jm.is_active = 'Y')
          AND f.item_id = @job_item_id
    )
        SET @item_ok = 1;

    --  JB: create pallet + bag on first scan (pProcessInsertJbPalletBag),
    --  only for an existing job / item, before the QR lookup
    IF @job_ok = 1 AND @item_ok = 1
    BEGIN
        DECLARE @jb_status  VARCHAR(20);
        DECLARE @jb_message VARCHAR(200);

        EXEC dbo.pProcessInsertJbPalletBag
            @qr_code_text  = @qr_code_text,
            @user_id       = @user_id,
            @return_result = 0,
            @status        = @jb_status  OUTPUT,
            @message       = @jb_message OUTPUT;

        IF @jb_status = 'error'
        BEGIN
            SELECT 'error' AS status, @jb_message AS message;
            RETURN;
        END
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    IF @job_ok = 0 OR @item_ok = 0
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    --  Whole pallet: pallet QR, mode 1 or no mode (the app's normal flow sends no mode)
    DECLARE @is_full_pallet BIT = CASE WHEN @bag_id IS NULL OR @mode_id IS NULL OR @mode_id = 1 THEN 1 ELSE 0 END;
    DECLARE @locked_job_id INT, @job_status_id INT;
    DECLARE @loc_qty INT, @loc_actual_before INT, @loc_actual_after INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  A pallet already in another RQ job (vJobMain rows of job_type_id 3)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet p
            INNER JOIN dbo.tr_job_main jm ON jm.id = p.current_job_id
            WHERE p.id = @pallet_id
              AND p.current_job_id <> @job_main_id
              AND jm.job_type_id = 3
              AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
              AND (jm.is_active IS NULL OR jm.is_active = 'Y')
              AND EXISTS (
                  SELECT 1 FROM IRPC_E_TRANSFER.dbo.VRequestForm f
                  WHERE f.header_id = jm.interface_job_id AND f.item_id IS NOT NULL
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้อยู่ในงานเบิกอื่นแล้ว' AS message;
            RETURN;
        END

        --  Only at a from-location of this item
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_from_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND (@location_type IS NULL OR from_location_type = @location_type)
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'ตำแหน่งนี้ไม่ใช่ต้นทางของงานนี้' AS message;
            RETURN;
        END

        --  No bag taken twice in this job (Get, Put or store bag)
        --  (mode 2 / 3: that bag; whole pallet: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 2, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@is_full_pallet = 0 AND ph.bag_id = @bag_id_text)
                 OR (@is_full_pallet = 1 AND EXISTS (
                        SELECT 1 FROM dbo.tr_bag b
                        WHERE b.id = TRY_CONVERT(BIGINT, ph.bag_id)
                          AND b.pallet_id = @pallet_id
                          AND b.is_active = 'Y'
                          AND b.status_flag = 'A'))
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกรับเข้ามาแล้ว' AS message;
            RETURN;
        END

        --  qty of this item / from-location and what is taken there already
        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_from_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND from_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        IF @loc_qty IS NOT NULL
            SELECT @loc_actual_before = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        UPDATE dbo.tr_job_main
        SET job_status_id = 4,
            start_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @job_main_id
          AND ISNULL(job_status_id, 0) <> 4;

        UPDATE dbo.tr_pallet
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @pallet_id;

        -- ------------------------------------------------
        -- Get rows (one per bag)
        --   whole pallet: every active bag of the pallet
        --   mode 2 (store bag): the scanned bag stays (process 4), the rest of the pallet is taken
        --   mode 3 (pick bag) : the scanned bag
        -- (Whole pallet: the taken-twice check above leaves no active row of the
        --  pallet's bags in this job, so the NOT EXISTS below filters nothing.)
        -- ------------------------------------------------
        IF @is_full_pallet = 0 AND @mode_id = 2
           --  only active rows count, so a reset pallet can be scanned again
           AND NOT EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history
                WHERE job_main_id = @job_main_id
                  AND job_item_id = @job_item_id
                  AND bag_id = @bag_id_text
                  AND process_id = 4
                  AND is_active = 'Y'
                  AND status_flag = 'A'
           )
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        IF @is_full_pallet = 1 OR @mode_id = 2
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.tr_pallet_history ph
                  WHERE ph.job_main_id = @job_main_id
                    AND ph.job_item_id = @job_item_id
                    AND ph.bag_id = CAST(b.id AS VARCHAR(255))
                    AND ph.process_id IN (1, 4)
                    AND ph.is_active = 'Y'
                    AND ph.status_flag = 'A'
              );
        ELSE
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        -- ------------------------------------------------
        -- tr_job_from_location.actual_qty of this item / location; over qty -> roll back
        -- ------------------------------------------------
        IF @loc_qty IS NOT NULL
        BEGIN
            SELECT @loc_actual_after = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                       THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                       ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

            IF @loc_actual_after > @loc_qty
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'error' AS status,
                    CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                           N', รับแล้ว ', @loc_actual_before,
                           N', ครั้งนี้ ', @loc_actual_after - @loc_actual_before, N')') AS message;
                RETURN;
            END

            UPDATE dbo.tr_job_from_location
            SET actual_qty = @loc_actual_after,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND ISNULL(qty, 0) <> 0
              AND is_active = 'Y'
              AND status_flag = 'A'
              AND ISNULL(actual_qty, -1) <> @loc_actual_after;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    --  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
    EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

    SELECT 'success' AS status, N'พาเลทนี้ถูกรับเข้ามาสำเร็จ' AS message, @pallet_seq AS pallet_seq;
END
GO

-- #################### 118_pProcessTransferWhGetPallet_null_mode_full_pallet.sql ####################
/* =====================================================================
   Deploy to 10.31.1.75 -- pProcessTransferWhGetPallet (Transfer WH, TW)
   Bag QR with no @mode_id takes the whole pallet.
   ---------------------------------------------------------------------
   The forklift app's normal / manual-pallet flow (runInboundGet) sends
   only qrCode, so the API passes @mode_id = NULL; that took only the
   scanned bag (job 1999 on 2026-11-11: 15 scans = 15 bags = 375 kg of
   15000 kg). Special-job flow always sends modeId 1 / 2 / 3.
   Whole pallet now = pallet QR, @mode_id NULL or @mode_id 1.
   Modes 2 (store bag) and 3 (pick bag) are unchanged.
   Rollback: 118_rollback_pProcessTransferWhGetPallet_null_mode_full_pallet.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- Transfer WH (TW, job_type_id 11) Get / Put / Reset: clean rewrite of the 3 procs.
-- Server: 10.31.1.74 (IRPC_QTRACK). Rollback: sql/rollback_pProcessTransferWh_clean_10.31.1.74.sql
-- Same rules as sql/pProcessInternalTransfer_clean_10.31.1.74.sql:
-- - The job row is locked (tr_job_main UPDLOCK, HOLDLOCK) for the whole scan, so
--   2 scans of one job run one after the other.
-- - Qty formula: M / S pallet = unit_ratio * unit_pallet, else distinct bag count * unit_ratio.
-- - tr_job_from_location.actual_qty = active Get rows (process_id 1) at that location.
-- - tr_job_to_location.actual_qty   = active Put rows (process_id 2) at that location
--   (pWmsPlus_OutboundTransferWhPutAway sends this value to WMS+).
-- - A bag is not taken (Get) or put (Put) twice in one job.
-- - A scan that would take / put more than the location qty is rolled back.
-- - Get only at a from-location of the item, Put only at a to-location of the item.
-- - No Get / Put on a completed job (job_status_id 5).
-- - Put of a pallet with nothing taken, and Reset of a pallet with nothing in the
--   job, are errors (both used to answer success).
-- - @mode_id NULL = the whole pallet, as mode 1 (sql/118).
-- - Put recalculates tr_job_from_location.actual_qty of the whole job.
-- - Messages to the app are Thai. SET XACT_ABORT ON in all 3.
--
-- Kept from the live TW procs:
-- - A bag already put in this job is not taken again (Get checks process 1, 2, 4).
-- - Put sets tr_pallet.inbound_to_wh_*; Reset clears them.
-- - Job completion: fTransferWhBags / fTransferWhJob, as before.
-- - Put result columns: status, message, is_job_complete.
-- - Put calls pProcessSyncJobAssigneeUser after COMMIT (as on 10.31.1.75).
--
-- Changed from the live TW procs:
-- - vJobMain -> tr_job_main + IRPC_E_TRANSFER.dbo.VTransferWhForm (vJobMain uses the
--   same view for job_type_id 11).
-- - fGetPalletQty -> inline formula above.
-- - tr_job_to_location.actual_qty is per to-location (was the item's total put qty).
-- - Get: actual_qty is recalculated for the scanned location (was actual_qty += qty).
-- - Reset: actual_qty is recalculated from history (the subtract step is gone);
--   the pallet goes back to its Get location (was NULL), as Internal Transfer.
-- - Put stamps only the pallets that have bags put in this scan.
-- - Get no longer refuses a pallet that is in another TW job (the live
--   same-job-type guard is removed).

-- ================================================
-- pProcessTransferWhGetPallet
-- ================================================
CREATE OR ALTER PROC [dbo].[pProcessTransferWhGetPallet]
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @mode_id            INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    -- ------------------------------------------------
    -- Job / item (vJobMain rows of job_type_id 11, on base tables)
    -- ------------------------------------------------
    DECLARE @job_ok BIT = 0, @item_ok BIT = 0;

    IF EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
        SET @job_ok = 1;

    IF EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 11
          AND f.item_id = @job_item_id
    )
        SET @item_ok = 1;

    --  JB: create pallet + bag on first scan (pProcessInsertJbPalletBag),
    --  only for an existing job / item, before the QR lookup
    IF @job_ok = 1 AND @item_ok = 1
    BEGIN
        DECLARE @jb_status  VARCHAR(20);
        DECLARE @jb_message VARCHAR(200);

        EXEC dbo.pProcessInsertJbPalletBag
            @qr_code_text  = @qr_code_text,
            @user_id       = @user_id,
            @return_result = 0,
            @status        = @jb_status  OUTPUT,
            @message       = @jb_message OUTPUT;

        IF @jb_status = 'error'
        BEGIN
            SELECT 'error' AS status, @jb_message AS message;
            RETURN;
        END
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    IF @job_ok = 0 OR @item_ok = 0
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    --  Whole pallet: pallet QR, mode 1 or no mode (the app's normal flow sends no mode)
    DECLARE @is_full_pallet BIT = CASE WHEN @bag_id IS NULL OR @mode_id IS NULL OR @mode_id = 1 THEN 1 ELSE 0 END;
    DECLARE @locked_job_id INT, @job_status_id INT;
    DECLARE @loc_qty INT, @loc_actual_before INT, @loc_actual_after INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  Only at a from-location of this item
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_from_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND (@location_type IS NULL OR from_location_type = @location_type)
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'ตำแหน่งนี้ไม่ใช่ต้นทางของงานนี้' AS message;
            RETURN;
        END

        --  No bag taken twice in this job (Get, Put or store bag)
        --  (mode 2 / 3: that bag; whole pallet: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 2, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@is_full_pallet = 0 AND ph.bag_id = @bag_id_text)
                 OR (@is_full_pallet = 1 AND EXISTS (
                        SELECT 1 FROM dbo.tr_bag b
                        WHERE b.id = TRY_CONVERT(BIGINT, ph.bag_id)
                          AND b.pallet_id = @pallet_id
                          AND b.is_active = 'Y'
                          AND b.status_flag = 'A'))
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกรับเข้ามาแล้ว' AS message;
            RETURN;
        END

        --  qty of this item / from-location and what is taken there already
        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_from_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND from_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        IF @loc_qty IS NOT NULL
            SELECT @loc_actual_before = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        UPDATE dbo.tr_job_main
        SET job_status_id = 4,
            start_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @job_main_id
          AND ISNULL(job_status_id, 0) <> 4;

        UPDATE dbo.tr_pallet
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @pallet_id;

        -- ------------------------------------------------
        -- Get rows (one per bag)
        --   whole pallet: every active bag of the pallet
        --   mode 2 (store bag): the scanned bag stays (process 4), the rest of the pallet is taken
        --   mode 3 (pick bag) : the scanned bag
        -- (Whole pallet: the taken-twice check above leaves no active row of the
        --  pallet's bags in this job, so the NOT EXISTS below filters nothing.)
        -- ------------------------------------------------
        IF @is_full_pallet = 0 AND @mode_id = 2
           --  only active rows count, so a reset pallet can be scanned again
           AND NOT EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history
                WHERE job_main_id = @job_main_id
                  AND job_item_id = @job_item_id
                  AND bag_id = @bag_id_text
                  AND process_id = 4
                  AND is_active = 'Y'
                  AND status_flag = 'A'
           )
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        IF @is_full_pallet = 1 OR @mode_id = 2
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.tr_pallet_history ph
                  WHERE ph.job_main_id = @job_main_id
                    AND ph.job_item_id = @job_item_id
                    AND ph.bag_id = CAST(b.id AS VARCHAR(255))
                    AND ph.process_id IN (1, 4)
                    AND ph.is_active = 'Y'
                    AND ph.status_flag = 'A'
              );
        ELSE
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        -- ------------------------------------------------
        -- tr_job_from_location.actual_qty of this item / location; over qty -> roll back
        -- ------------------------------------------------
        IF @loc_qty IS NOT NULL
        BEGIN
            SELECT @loc_actual_after = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                       THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                       ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

            IF @loc_actual_after > @loc_qty
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'error' AS status,
                    CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                           N', รับแล้ว ', @loc_actual_before,
                           N', ครั้งนี้ ', @loc_actual_after - @loc_actual_before, N')') AS message;
                RETURN;
            END

            UPDATE dbo.tr_job_from_location
            SET actual_qty = @loc_actual_after,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND ISNULL(qty, 0) <> 0
              AND is_active = 'Y'
              AND status_flag = 'A'
              AND ISNULL(actual_qty, -1) <> @loc_actual_after;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    --  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
    EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

    SELECT 'success' AS status, N'พาเลทนี้ถูกรับเข้ามาสำเร็จ' AS message, @pallet_seq AS pallet_seq;
END
GO

-- #################### 119_pProcessInternalTransferGetPallet_null_mode_full_pallet.sql ####################
/* =====================================================================
   Deploy to 10.31.1.75 -- pProcessInternalTransferGetPallet (Internal Transfer, IT)
   Bag QR with no @mode_id takes the whole pallet.
   ---------------------------------------------------------------------
   The forklift app's normal / manual-pallet flow (runInboundGet) sends
   only qrCode, so the API passes @mode_id = NULL; that took only the
   scanned bag (job 1999 on 2026-11-11: 15 scans = 15 bags = 375 kg of
   15000 kg). Special-job flow always sends modeId 1 / 2 / 3.
   Whole pallet now = pallet QR, @mode_id NULL or @mode_id 1.
   Modes 2 (store bag) and 3 (pick bag) are unchanged.
   Rollback: 119_rollback_pProcessInternalTransferGetPallet_null_mode_full_pallet.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- Internal Transfer (WH02) Get / Put / Reset: clean rewrite of the 3 procs.
-- Server: 10.31.1.75 (IRPC_QTRACK). Rollback: sql/rollback_pProcessInternalTransfer_clean_10.31.1.75.sql
-- Replaces sql/pProcessInternalTransfer_actual_qty_10.31.1.75.sql,
-- sql/pProcessInternalTransferResetPallet_thai_success_10.31.1.75.sql and the perf
-- patch: each proc is written out whole, so it does not matter which of them ran.
--
-- Rules (same in all 3 procs):
-- - The job row is locked (tr_job_main UPDLOCK, HOLDLOCK) for the whole scan, so
--   2 scans of one job run one after the other.
-- - Qty formula: M / S pallet = unit_ratio * unit_pallet, else distinct bag count * unit_ratio.
-- - tr_job_from_location.actual_qty = active Get rows (process_id 1) at that location.
-- - tr_job_to_location.actual_qty   = active Put rows (process_id 2) at that location.
-- - A bag is not taken (Get) or put (Put) twice in one job.
-- - A scan that would take / put more than the location qty is rolled back.
-- - Get only at a from-location of the item, Put only at a to-location of the item.
-- - No Get / Put on a completed job (job_status_id 5): N'งานนี้ถูกทำเสร็จแล้ว'.
-- - Put of a pallet with nothing taken in the job, and Reset of a pallet with
--   nothing in the job, are errors (both used to answer success and do nothing).
-- - Messages to the app are Thai.
--
-- Changed from the live procs:
-- - vJobMain        -> tr_job_main + vInternalTransferJobForm (same rows for job_type_id 10).
-- - fInternalTransferBags / vInternalTransferJob (job completion) -> direct
--   tr_pallet_history query (same completed qty on all 11 IT jobs on 10.31.1.75).
-- - fGetPalletQty   -> inline formula above.
-- - tr_job_to_location.actual_qty is per to-location (was the item's total put
--   qty written to every to-location of the item; same value when the item has
--   one to-location).
-- - Reset: actual_qty is recalculated from history (the subtract step is gone).
-- - Reset error messages in Thai.
-- - SET XACT_ABORT ON in all 3.

-- ================================================
-- pProcessInternalTransferGetPallet
-- ================================================
CREATE OR ALTER PROC [dbo].[pProcessInternalTransferGetPallet]
    @qr_code_text       VARCHAR(100)    = NULL,
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @mode_id            INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    -- ------------------------------------------------
    -- Job / item (vJobMain rows of job_type_id 10, on base tables)
    -- ------------------------------------------------
    DECLARE @job_ok BIT = 0, @item_ok BIT = 0;

    IF EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
        SET @job_ok = 1;

    IF EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vInternalTransferJobForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 10
          AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
          AND (jm.is_active IS NULL OR jm.is_active = 'Y')
          AND f.item_id = @job_item_id
    )
        SET @item_ok = 1;

    --  JB: create pallet + bag on first scan (pProcessInsertJbPalletBag),
    --  only for an existing job / item, before the QR lookup
    IF @job_ok = 1 AND @item_ok = 1
    BEGIN
        DECLARE @jb_status  VARCHAR(20);
        DECLARE @jb_message VARCHAR(200);

        EXEC dbo.pProcessInsertJbPalletBag
            @qr_code_text  = @qr_code_text,
            @user_id       = @user_id,
            @return_result = 0,
            @status        = @jb_status  OUTPUT,
            @message       = @jb_message OUTPUT;

        IF @jb_status = 'error'
        BEGIN
            SELECT 'error' AS status, @jb_message AS message;
            RETURN;
        END
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    IF @job_ok = 0 OR @item_ok = 0
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    --  Whole pallet: pallet QR, mode 1 or no mode (the app's normal flow sends no mode)
    DECLARE @is_full_pallet BIT = CASE WHEN @bag_id IS NULL OR @mode_id IS NULL OR @mode_id = 1 THEN 1 ELSE 0 END;
    DECLARE @locked_job_id INT;
    DECLARE @loc_qty INT, @loc_actual_before INT, @loc_actual_after INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @job_status_id INT;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  Only at a from-location of this item
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_from_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND (@location_type IS NULL OR from_location_type = @location_type)
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'ตำแหน่งนี้ไม่ใช่ต้นทางของงานนี้' AS message;
            RETURN;
        END

        --  No bag taken twice in this job
        --  (mode 2 / 3: that bag; whole pallet: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@is_full_pallet = 0 AND ph.bag_id = @bag_id_text)
                 OR (@is_full_pallet = 1 AND EXISTS (
                        SELECT 1 FROM dbo.tr_bag b
                        WHERE b.id = TRY_CONVERT(BIGINT, ph.bag_id)
                          AND b.pallet_id = @pallet_id
                          AND b.is_active = 'Y'
                          AND b.status_flag = 'A'))
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกรับเข้ามาแล้ว' AS message;
            RETURN;
        END

        --  qty of this item / from-location and what is taken there already
        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_from_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND from_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        IF @loc_qty IS NOT NULL
            SELECT @loc_actual_before = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        UPDATE dbo.tr_job_main
        SET job_status_id = 4,
            start_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @job_main_id
          AND ISNULL(job_status_id, 0) <> 4;

        UPDATE dbo.tr_pallet
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @pallet_id;

        -- ------------------------------------------------
        -- Get rows (one per bag)
        --   whole pallet: every active bag of the pallet
        --   mode 2 (store bag): the scanned bag stays (process 4), the rest of the pallet is taken
        --   mode 3 (pick bag) : the scanned bag
        -- (Whole pallet: the taken-twice check above leaves no active row of the
        --  pallet's bags in this job, so the NOT EXISTS below filters nothing.)
        -- ------------------------------------------------
        IF @is_full_pallet = 0 AND @mode_id = 2
           --  only active rows count, so a reset pallet can be scanned again
           AND NOT EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history
                WHERE job_main_id = @job_main_id
                  AND job_item_id = @job_item_id
                  AND bag_id = @bag_id_text
                  AND process_id = 4
                  AND is_active = 'Y'
                  AND status_flag = 'A'
           )
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        IF @is_full_pallet = 1 OR @mode_id = 2
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.tr_pallet_history ph
                  WHERE ph.job_main_id = @job_main_id
                    AND ph.job_item_id = @job_item_id
                    AND ph.bag_id = CAST(b.id AS VARCHAR(255))
                    AND ph.process_id IN (1, 4)
                    AND ph.is_active = 'Y'
                    AND ph.status_flag = 'A'
              );
        ELSE
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );

        -- ------------------------------------------------
        -- tr_job_from_location.actual_qty of this item / location; over qty -> roll back
        -- ------------------------------------------------
        IF @loc_qty IS NOT NULL
        BEGIN
            SELECT @loc_actual_after = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                       THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                       ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

            IF @loc_actual_after > @loc_qty
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'error' AS status,
                    CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                           N', รับแล้ว ', @loc_actual_before,
                           N', ครั้งนี้ ', @loc_actual_after - @loc_actual_before, N')') AS message;
                RETURN;
            END

            UPDATE dbo.tr_job_from_location
            SET actual_qty = @loc_actual_after,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND ISNULL(qty, 0) <> 0
              AND is_active = 'Y'
              AND status_flag = 'A'
              AND ISNULL(actual_qty, -1) <> @loc_actual_after;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    --  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
    EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

    SELECT 'success' AS status, N'พาเลทนี้ถูกรับเข้ามาสำเร็จ' AS message, @pallet_seq AS pallet_seq;
END
GO
