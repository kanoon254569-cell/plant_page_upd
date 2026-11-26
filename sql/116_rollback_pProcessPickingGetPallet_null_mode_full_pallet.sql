/* =====================================================================
   Rollback of 116_pProcessPickingGetPallet_null_mode_full_pallet.sql
   (10.31.1.75): restores pProcessPickingGetPallet as it was on
   2026-11-11 (modify_date 2026-11-11 15:01:41) -- a bag QR with
   @mode_id NULL takes only the scanned bag.
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
        --  (bag QR: that bag; mode 1 / pallet QR: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 2, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@bag_id IS NOT NULL AND ISNULL(@mode_id, 0) <> 1 AND ph.bag_id = @bag_id_text)
                 OR ((@bag_id IS NULL OR @mode_id = 1) AND EXISTS (
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
        --   mode 1 / pallet QR: every active bag of the pallet
        --   mode 2: store bag -- the scanned bag stays (process 4), the rest of the pallet is taken
        --   other : the scanned bag
        -- ------------------------------------------------
        IF @mode_id = 1 OR @bag_id IS NULL
        BEGIN
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
              AND b.status_flag = 'A';
        END
        ELSE IF @mode_id = 2
        BEGIN
            --  only active rows count, so a reset pallet can be scanned again
            IF NOT EXISTS (
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
        END
        ELSE
        BEGIN
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
        END

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
