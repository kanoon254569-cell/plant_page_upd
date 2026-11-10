/* =====================================================================
   Pallet Matching Service - pProcessUpdateBagRejectStatus
   -----------------------------------------------------------------
   SP เดียว ใช้ร่วมกันทั้ง reject และปรับกลับปกติ (รวม pProcessRejectBag +
   pProcessUnrejectBag เดิมเข้าด้วยกัน ผ่าน @reject) -- นี่คือ SP ที่ backend
   ของหน้า Pallet Adjustment เรียกจริงสำหรับปุ่ม "ถุง Reject" / "คืนค่า"
   (ดู PalletController.cs RejectBag/UnrejectBag, 02_sp_PalletAdjustment_
   GetBagList.sql อ่านผลลัพธ์)

   @reject = 1  (ถุง reject) : ถุง (ต้องเป็น is_active='Y') -> is_active='R'
                            เก็บเหตุผลลง remark (@reason)

   @reject = 0  (ถุงปกติ)   : ถุง (ต้องเป็น is_active='R') -> is_active='Y' , bag_status_id=1 (pending) ,
                            pallet_id=NULL , กู้ bag_no / pallet_running_no จาก qr_text_data
                            (cost_center|grade|lot|bag_no|pallet_running_no) เพราะตอน reject ถุงที่เคย
                            match แล้วจะถูก pServiceMatchBagToPallet NULL ทิ้ง bag_no ไป (bag_status_id
                            ค้างที่ 9) -- set is_active='Y' เฉย ๆ ไม่พอ ถุงจะไม่เข้าเงื่อนไข "ถุงรอจับ" เลย

   ทั้ง 2 ทิศทาง : ถ้า @auto_reconcile=1 (ค่าเริ่มต้น) และ @preview=0 -> เรียก dbo.pServiceMatchBagToPallet
                   @grade=<grade ของถุงนี้> ต่อทันทีหลัง commit เสมอ (ไม่ต้องรอ SQL Agent job 1 นาที)
                   ทั้ง reject (ปลดถุง+จัดลำดับที่เหลือใหม่ ถ้าเคย match) และปรับกลับปกติ (จับถุงนี้กลับ
                   เข้าคิว+อาจ reshuffle ถุงอื่นในกลุ่มถ้าตำแหน่งทำให้ good_pos เลื่อน)

   พารามิเตอร์ :
     @reject         1 = ถุง reject , 0 = ปรับกลับเป็นถุงปกติ (ห้ามเป็น NULL)
     @reason         ใช้เฉพาะ @reject=1 - เก็บลง remark (ไม่ส่งมาก็ไม่ทับ remark เดิม)
     @auto_reconcile 0 = ปล่อยให้ SQL Agent job ราย 1 นาทีจับแทน (ภายใน <= 1 นาที) แทนการเรียกทันที
     @preview        1 = ROLLBACK (คืนแผนอย่างเดียว, ไม่เรียก reconcile ต่อ) , 0 = COMMIT

   หมายเหตุ : เมื่อเรียก reconcile จริง จะมี "result set เพิ่ม" ต่อท้ายจาก pServiceMatchBagToPallet
              (dbResult/dbResult1/dbResult2 ของมันเอง) นอกเหนือจาก 2 result set ปกติของ SP นี้

   dbResult  : status (success/warning/error) / message
   dbResult1 : bag_id, action ('REJECT'/'UNREJECT'), grade, cost_center, lot,
               before_is_active, before_bag_status_id, before_pallet_id, before_bag_no,
               after_bag_no, after_pallet_running_no   (2 คอลัมน์หลังมีค่าเฉพาะตอน @reject=0)

   Dependencies: 10_fParseBagQr.sql, 13_pServiceMatchBagToPallet.sql (เรียกใช้
                 ตอน auto-reconcile), 09_ct_grade_package_ratio.sql (ผ่าน 13),
                 20_tr_transaction_log.sql (dbo.pInsertTransactionLog -- log
                 การ Reject/คืนค่าถุงจากหน้า Pallet Adjustment)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--  ลบ SP รุ่นเก่าที่ถูกรวมเข้ามาในตัวนี้แล้ว (ถ้ามี) กันชื่อค้าง/สร้างซ้ำผิด
IF OBJECT_ID('dbo.pProcessRejectBag', 'P') IS NOT NULL DROP PROCEDURE dbo.pProcessRejectBag;
IF OBJECT_ID('dbo.pProcessUnrejectBag', 'P') IS NOT NULL DROP PROCEDURE dbo.pProcessUnrejectBag;
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
                SET @LogDetail = N'Reject ถุง (Bag ID: ' + CAST(@bag_id AS VARCHAR(20)) + N', QR: ' + ISNULL(@qr, N'-') + N') '
                                 + N'Grade ' + ISNULL(@cur_grade, N'-') + N' Lot ' + ISNULL(@cur_lot, N'-')
                                 + CASE WHEN @cur_pallet_id IS NOT NULL
                                        THEN N' ออกจากพาเลท ID ' + CAST(@cur_pallet_id AS VARCHAR(20))
                                        ELSE N' (ยังไม่ได้จับคู่พาเลท)' END
                                 + N' เป็นถุงที่ยังไม่ผูกพาเลท/Reject เหตุผล: ' + ISNULL(@reason, N'-')
                                 + N' โดย User ID: ' + CAST(@create_user_id AS VARCHAR(20));

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
                SET @LogDetail = N'คืนค่าถุง (Bag ID: ' + CAST(@bag_id AS VARCHAR(20)) + N', QR: ' + ISNULL(@qr, N'-') + N') '
                                 + N'จากสถานะ Reject กลับเป็นถุงปกติ (bag_no=' + CAST(@qbagno AS VARCHAR(10))
                                 + N', pallet_running_no=' + CAST(@qprn AS VARCHAR(10)) + N') '
                                 + N'โดย User ID: ' + CAST(@create_user_id AS VARCHAR(20));

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

-- ตัวอย่างเรียกใช้:
-- แจ้งถุง reject (จะเรียก reconcile ต่อทันทีให้เองถ้าเคย match แล้ว)
-- EXEC dbo.pProcessUpdateBagRejectStatus @bag_id = 12345, @reject = 1,
--      @reason = N'ถุงฉีกขาด', @create_user_id = 0, @preview = 1;  -- dry-run
-- EXEC dbo.pProcessUpdateBagRejectStatus @bag_id = 12345, @reject = 1,
--      @reason = N'ถุงฉีกขาด', @create_user_id = 0, @preview = 0;  -- ทำจริง
--
-- ปรับถุงจาก reject กลับเป็นปกติ (กู้ bag_no จาก qr_text_data ให้อัตโนมัติ)
-- EXEC dbo.pProcessUpdateBagRejectStatus @bag_id = 12345, @reject = 0,
--      @create_user_id = 0, @preview = 1;  -- dry-run ดูก่อน
-- EXEC dbo.pProcessUpdateBagRejectStatus @bag_id = 12345, @reject = 0,
--      @create_user_id = 0, @preview = 0;  -- ทำจริง
