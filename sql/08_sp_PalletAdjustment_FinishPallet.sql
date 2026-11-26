/* =====================================================================
   Pallet Adjustment - FinishPallet ("จบพาเลท")
   -----------------------------------------------------------------
   ใช้กับพาเลทสุดท้ายของ Lot ที่ผลิตไม่ครบจำนวนถุง/พาเลท (unit_pallet)
   เช่น lot หมดถุงพอดีตอนพาเลทยังไม่เต็ม -- กด "จบพาเลท" เพื่อยืนยันว่าพาเลทนี้
   เป็น "พาเลทเศษ" (ไม่ต้องรอถุงมาเติมจนครบอีกต่อไป)

   วิธีทำ: set tr_pallet.pallet_status_id = 3 (CONFIRMED, ดู
   00_master_pallet_status.sql / dbo.ct_pallet_status) ของพาเลทนี้ใบเดียว --
   sp_PalletAdjustment_GetOverview คำนวณ status='complete' ให้พาเลทที่
   pallet_status_id=3 อยู่แล้ว (เหมือนพาเลทที่เต็มตามปกติ) โดยไม่ต้องแก้
   unit_pallet เลย -- ไม่กระทบพาเลทใบอื่นของ grade เดียวกัน และไม่ทำให้ตัวเลข
   unit_pallet ที่แสดงในหน้าจอ (X/Y ถุง) ผิดเพี้ยนไปจากความเป็นจริง

   NOTE: ไม่แตะ bag_no / pallet_id ของถุงใด ๆ -- ถุงที่ match อยู่แล้วถูกต้อง
   ตาม planned_pos/ordinal ของ pServiceMatchBagToPallet อยู่แล้ว (การ matching
   เป็นแบบ sequential ทันทีที่ถุงมาถึง ไม่ได้รอพาเลทเต็มก่อนค่อยจับคู่) ปุ่มนี้
   จึงแค่ "ปิดบัญชี" พาเลทใบนี้ ไม่ใช่ย้ายถุง

   pallet_status_id หลังจากนี้จะไม่ถูก auto-matching (pServiceMatchBagToPallet
   ขั้นตอน 6.5) แตะอีก แม้จะรันซ้ำกี่ครั้งก็ตาม (SP นั้น skip พาเลทที่เป็น
   3=CONFIRMED หรือ 4=VOID เสมอ)

   Guard (ไม่เช็ค current_job_id/WH-Process อีกต่อไป -- ตั้งแต่ 2026-09-13 การจบ
   พาเลททำได้เสมอตราบใดที่ยังไม่ครบ ไม่สนใจว่ามีงาน WMS ผูกอยู่หรือไม่):
     - ไม่พบพาเลท / พาเลทถูกลบ (is_active <> 'Y')       -> ResultCode = 1
     - พาเลทยังไม่มีถุงเลย (bag_count = 0)                -> ResultCode = 2
     - พาเลทเต็ม/ครบอยู่แล้ว (bag_count >= unit_pallet)   -> ResultCode = 3
     - พาเลทถูกยืนยันเป็นพาเลทเศษไปแล้ว (pallet_status_id
       = 3 CONFIRMED)                                      -> ResultCode = 4
     - พาเลทถูกยกเลิกแล้ว (pallet_status_id = 4 VOID)      -> ResultCode = 5
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_FinishPallet]
    @PalletId      BIGINT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @BagCount      INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @unitPallet INT, @palletStatusId INT, @palletNo VARCHAR(30);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @unitPallet     = unit_pallet,
                @palletStatusId = ISNULL(pallet_status_id, 1),
                @palletNo       = pallet_no
        FROM    dbo.tr_pallet WITH (UPDLOCK, HOLDLOCK)
        WHERE   id = @PalletId AND is_active = 'Y';

        IF @@ROWCOUNT = 0
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทที่ต้องการจบพาเลท';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @BagCount = COUNT(*)
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        IF @BagCount = 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'พาเลทนี้ยังไม่มีถุง ไม่สามารถจบพาเลทได้';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @BagCount >= @unitPallet
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'พาเลทนี้ครบจำนวนถุงอยู่แล้ว ไม่จำเป็นต้องจบพาเลท';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @palletStatusId = 3
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'พาเลทนี้ถูกยืนยันเป็นพาเลทเศษไปแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @palletStatusId = 4
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'พาเลทนี้ถูกยกเลิกแล้ว ไม่สามารถจบพาเลทได้';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        UPDATE dbo.tr_pallet
        SET    pallet_status_id = 3,  -- CONFIRMED (ยืนยันพาเลทเศษ) -- ดู dbo.ct_pallet_status
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @PalletId;

        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string
        --  ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'ยืนยันพาเลท ' + ISNULL(@palletNo, N'-') + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N') เป็นพาเลทเศษ (จบพาเลท) '
                         + N'เปลี่ยนสถานะจาก "กำลังดำเนินการ" เป็น "เสร็จสมบูรณ์ (ยืนยันแล้ว)" ด้วยจำนวน '
                         + CAST(@BagCount AS VARCHAR(10)) + N'/' + CAST(@unitPallet AS VARCHAR(10)) + N' ถุง '
                         + N'โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Finish Pallet',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- DECLARE @rc INT, @msg NVARCHAR(255), @cnt INT;
-- EXEC dbo.sp_PalletAdjustment_FinishPallet
--      @PalletId = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @BagCount = @cnt OUTPUT;
-- SELECT @rc, @msg, @cnt;
