/* =====================================================================
   98_rollback_sp_PalletAdjustment_RejectMissingSlot.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   ย้อน 98_sp_PalletAdjustment_RejectMissingSlot.sql
   - pProcessUpdateBagRejectStatus กลับเป็น definition บน prod ก่อนรัน 98_
     (OBJECT_DEFINITION 2026-10-30)
   - DROP sp_PalletAdjustment_GetMissingSlots / sp_PalletAdjustment_RejectMissingSlot
   ถุง placeholder (tr_bag.mode_id = 9) ที่สร้างไปแล้วไม่ถูกลบ : ยังเป็น reject ตามปกติ
   (ถ้า "คืนค่า" หลัง rollback จะกลายเป็นถุงรอจับคู่ -- ให้ยกเลิกก่อน rollback)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
DROP PROCEDURE IF EXISTS dbo.sp_PalletAdjustment_RejectMissingSlot;
GO
DROP PROCEDURE IF EXISTS dbo.sp_PalletAdjustment_GetMissingSlots;
GO
CREATE OR ALTER PROCEDURE dbo.pProcessUpdateBagRejectStatus
    @bag_id         BIGINT,
    @reject         BIT,                  -- 1 = ถุง reject , 0 = ปรับกลับเป็นถุงปกติ
    @reason         VARCHAR(255) = NULL,  -- ใช้เฉพาะ @reject = 1
    @create_user_id INT = 0,
    @auto_reconcile BIT = 1,              -- 1 = เรียก pServiceMatchBagToPallet ต่อทันทีเสมอ (ทั้ง 2 ทิศทาง)
    @preview        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = '',
            @qr VARCHAR(100),
            @qcc VARCHAR(20), @qgrade VARCHAR(30), @qlot VARCHAR(20), @qbagno INT, @qprn INT,
            @cur_is_active VARCHAR(1), @cur_status INT, @cur_pallet_id BIGINT, @cur_bag_no INT,
            @cur_cc VARCHAR(20), @cur_grade VARCHAR(30), @cur_lot VARCHAR(20),
            @mismatch BIT = 0, @need_reconcile BIT = 0,
            @LogDetail NVARCHAR(MAX) = NULL;  --  build ที่นี่แล้ว EXEC pInsertTransactionLog ด้วยตัวแปรนี้ (รับ constant/variable เท่านั้น ไม่ใช่ concat "+" ตรง ๆ)

    DECLARE @out TABLE (
        bag_id BIGINT, action VARCHAR(10), grade VARCHAR(30), cost_center VARCHAR(20), lot VARCHAR(20),
        before_is_active VARCHAR(1), before_bag_status_id INT, before_pallet_id BIGINT, before_bag_no INT,
        after_bag_no INT NULL, after_pallet_running_no INT NULL);

    IF @reject IS NULL
    BEGIN
        SELECT 'error' AS status, N'@reject ต้องเป็น 1 (reject) หรือ 0 (ปกติ)' AS message;
        SELECT * FROM @out;
        RETURN;
    END

    BEGIN TRY
        SELECT @qr = qr_text_data, @cur_is_active = is_active, @cur_status = bag_status_id,
               @cur_pallet_id = pallet_id, @cur_bag_no = bag_no,
               @cur_cc = cost_center, @cur_grade = grade, @cur_lot = lot
        FROM   dbo.tr_bag
        WHERE  id = @bag_id;

        IF @@ROWCOUNT = 0
        BEGIN
            SELECT 'error' AS status, CONCAT('bag_id ', @bag_id, ' not found') AS message;
            SELECT * FROM @out;
            RETURN;
        END

        -- reconcile ต่อทันทีหลัง commit เสมอ (ทั้ง reject และปรับกลับปกติ) เว้นแต่ปิดไว้ด้วย @auto_reconcile=0
        SET @need_reconcile = CASE WHEN @auto_reconcile = 1 THEN 1 ELSE 0 END;

        -----------------------------------------------------------------
        -- @reject = 1 : is_active 'Y' -> 'R'
        -----------------------------------------------------------------
        IF @reject = 1
        BEGIN
            IF @cur_is_active = 'R'
            BEGIN
                SELECT 'warning' AS status, CONCAT('bag_id ', @bag_id, ' is already rejected') AS message;
                SELECT * FROM @out;
                RETURN;
            END

            IF ISNULL(@cur_is_active, '') <> 'Y'
            BEGIN
                SELECT 'warning' AS status,
                       CONCAT('bag_id ', @bag_id, ' has is_active=', ISNULL(@cur_is_active, 'NULL'),
                              ' - only an active (Y) bag can be rejected') AS message;
                SELECT * FROM @out;
                RETURN;
            END

            BEGIN TRAN;

            UPDATE dbo.tr_bag
            SET    is_active       = 'R',
                   remark          = ISNULL(@reason, remark),
                   update_user_id  = @create_user_id,
                   update_datetime = GETDATE()
            WHERE  id = @bag_id;

            INSERT INTO @out (bag_id, action, grade, cost_center, lot,
                              before_is_active, before_bag_status_id, before_pallet_id, before_bag_no)
            VALUES (@bag_id, 'REJECT', @cur_grade, @cur_cc, @cur_lot,
                   @cur_is_active, @cur_status, @cur_pallet_id, @cur_bag_no);

            SET @message = CASE WHEN @cur_pallet_id IS NOT NULL
                THEN CONCAT('bag_id ', @bag_id, ' rejected (was matched to pallet_id ', @cur_pallet_id, ')')
                ELSE CONCAT('bag_id ', @bag_id, ' rejected (was not yet matched)')
                END;

            IF @preview = 0
            BEGIN
                SET @LogDetail = N'*' + ISNULL(@qr, N'-') + N'*'
                                 + ISNULL(N' ออกจาก *' + (SELECT pallet_no FROM dbo.tr_pallet WHERE id = @cur_pallet_id) + N'*', N'')
                                 + ISNULL(N' เหตุผล: ' + NULLIF(@reason, ''), N'');

                EXEC dbo.pInsertTransactionLog
                     @topic    = 'Pallet Adjustment',
                     @activity = 'Reject Bag',
                     @detail   = @LogDetail,
                     @user_id  = @create_user_id;
            END

            IF @preview = 1 ROLLBACK TRAN; ELSE COMMIT TRAN;
        END
        ELSE
        -----------------------------------------------------------------
        -- @reject = 0 : is_active 'R' -> 'Y'  (กู้ bag_no / pallet_running_no จาก qr_text_data)
        -----------------------------------------------------------------
        BEGIN
            IF ISNULL(@cur_is_active, '') <> 'R'
            BEGIN
                SELECT 'warning' AS status,
                       CONCAT('bag_id ', @bag_id, ' is not rejected (is_active=', ISNULL(@cur_is_active, 'NULL'), ')') AS message;
                SELECT * FROM @out;
                RETURN;
            END

            -- parse qr_text_data : cost_center|grade|lot|bag_no|pallet_running_no (ฟังก์ชันเดียวกับ pServiceMatchBagToPallet)
            SELECT @qcc = cost_center, @qgrade = grade, @qlot = lot, @qbagno = bag_no, @qprn = pallet_running_no
            FROM   dbo.fParseBagQr(@qr);

            IF @qbagno IS NULL OR @qprn IS NULL
            BEGIN
                SELECT 'error' AS status,
                       CONCAT('cannot parse bag_no/pallet_running_no from qr_text_data: ', @qr) AS message;
                SELECT * FROM @out;
                RETURN;
            END

            -- sanity check : cost_center/grade/lot ใน QR ควรตรงกับที่บันทึกไว้ในตาราง
            IF ISNULL(@qcc, '') <> ISNULL(@cur_cc, '')
               OR ISNULL(@qgrade, '') <> ISNULL(@cur_grade, '')
               OR ISNULL(@qlot, '') <> ISNULL(@cur_lot, '')
                SET @mismatch = 1;

            BEGIN TRAN;

            UPDATE dbo.tr_bag
            SET    is_active         = 'Y',
                   bag_status_id     = 1,           -- กลับเป็น pending
                   pallet_id         = NULL,        -- กันเคสมี pallet_id ค้าง (ปกติควรเป็น NULL อยู่แล้ว)
                   bag_no            = @qbagno,      -- กู้จาก QR
                   pallet_running_no = @qprn,        -- กู้จาก QR
                   ton_no            = @qprn,        -- ค่าเริ่มต้น = pallet_running_no (reconcile ต่อจะ re-run ให้ถ้าลำดับเลื่อน)
                   update_user_id    = @create_user_id,
                   update_datetime   = GETDATE()
            WHERE  id = @bag_id;

            INSERT INTO @out (bag_id, action, grade, cost_center, lot,
                              before_is_active, before_bag_status_id, before_pallet_id, before_bag_no,
                              after_bag_no, after_pallet_running_no)
            VALUES (@bag_id, 'UNREJECT', @cur_grade, @cur_cc, @cur_lot,
                   @cur_is_active, @cur_status, @cur_pallet_id, @cur_bag_no,
                   @qbagno, @qprn);

            SET @status  = CASE WHEN @mismatch = 1 THEN 'warning' ELSE 'success' END;
            SET @message = CASE WHEN @mismatch = 1
                THEN CONCAT('bag_id ', @bag_id, ' restored (bag_no=', @qbagno, ', pallet_running_no=', @qprn,
                            ') - WARNING: qr_text_data cost_center/grade/lot differs from stored row, please verify')
                ELSE CONCAT('bag_id ', @bag_id, ' restored to pending (bag_no=', @qbagno,
                            ', pallet_running_no=', @qprn, ')')
                END;

            IF @preview = 0
            BEGIN
                SET @LogDetail = N'*' + ISNULL(@qr, N'-') + N'*';

                EXEC dbo.pInsertTransactionLog
                     @topic    = 'Pallet Adjustment',
                     @activity = 'Unreject Bag',
                     @detail   = @LogDetail,
                     @user_id  = @create_user_id;
            END

            IF @preview = 1 ROLLBACK TRAN; ELSE COMMIT TRAN;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SET @status = 'error';  SET @message = ERROR_MESSAGE();
        SET @need_reconcile = 0;
    END CATCH

    SELECT @status AS status, @message AS message;   -- dbResult
    SELECT * FROM @out;                              -- dbResult1

    -- reconcile แยกนอก transaction ของตัวเอง (กันปัญหา nested transaction ปนกับของ pServiceMatchBagToPallet)
    -- เกิดทุกครั้งที่ action สำเร็จ (ทั้ง reject และปรับกลับปกติ) เว้นแต่ @auto_reconcile=0 หรือ @preview=1
    IF @preview = 0 AND @need_reconcile = 1 AND @status <> 'error'
        EXEC dbo.pServiceMatchBagToPallet @grade = @cur_grade, @create_user_id = @create_user_id, @preview = 0;
END
GO
