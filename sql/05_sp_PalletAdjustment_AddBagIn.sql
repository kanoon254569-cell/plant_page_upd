/* =====================================================================
   Pallet Adjustment - AddBagIn
   -----------------------------------------------------------------
   Add one orphan bag into a target pallet. Rejects if the pallet is
   already full (bag_count >= unit_pallet) or if the bag is already
   matched to some other pallet.

   Also syncs pallet_status_id (dbo.ct_pallet_status, ดู 00_master_pallet_status.sql)
   ของพาเลทปลายทางให้ตรงกับจำนวนถุงจริงหลังเพิ่ม: 1=CREATED ถ้ายังไม่เต็ม,
   2=COMPLETED ถ้าเต็มพอดี -- เหมือน pattern ใน 13_pServiceMatchBagToPallet.sql
   ขั้นตอน 6.5 (ไม่แตะพาเลทที่เป็น 3=CONFIRMED หรือ 4=VOID แต่ในทางปฏิบัติ SP นี้
   guard ไปแล้วว่าต้องเป็นพาเลท is_active='Y' ที่ยังไม่เต็ม จึงมักจะเป็น 1 อยู่ก่อน)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_AddBagIn]
    @BagId         BIGINT,
    @PalletId      BIGINT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @AssignedBagNo INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @UnitPallet INT, @CurrentCount INT, @PalletNo VARCHAR(30);

        SELECT @UnitPallet = unit_pallet,
               @PalletNo   = pallet_no
        FROM   dbo.tr_pallet
        WHERE  id = @PalletId AND is_active = 'Y';

        IF @UnitPallet IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @CurrentCount = COUNT(*)
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        IF @CurrentCount >= @UnitPallet
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'พาเลทเต็มแล้ว ไม่สามารถเพิ่มถุงได้';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_bag
            WHERE id = @BagId AND pallet_id IS NULL AND is_active = 'Y'
        )
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ถุงนี้ถูกจับคู่กับพาเลทอื่นไปแล้ว หรือไม่พบข้อมูลถุง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @AssignedBagNo = @CurrentCount + 1;

        UPDATE dbo.tr_bag
        SET    pallet_id        = @PalletId,
               bag_no           = @AssignedBagNo,
               bag_status_id    = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @BagId;

        --  sync pallet_status_id -- @AssignedBagNo คือจำนวนถุงรวมของพาเลทหลังเพิ่มพอดี
        --  (= @CurrentCount + 1) ไม่ต้อง query นับใหม่
        UPDATE dbo.tr_pallet
        SET    pallet_status_id = CASE WHEN @AssignedBagNo >= @UnitPallet THEN 2 ELSE 1 END,
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @PalletId
          AND  ISNULL(pallet_status_id, 1) IN (1, 2)
          AND  pallet_status_id <> CASE WHEN @AssignedBagNo >= @UnitPallet THEN 2 ELSE 1 END;

        --  Log การแก้ไข -- ปลายทางเดิมของถุงเสมอคือ Orphan Bag (SP guard ไว้แล้วด้านบนว่า
        --  ต้องเป็น pallet_id IS NULL ก่อนถึงจะเพิ่มเข้าได้)
        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string
        --  ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'เพิ่มถุง (Bag ID: ' + CAST(@BagId AS VARCHAR(20)) + N') จากถุงที่ยังไม่ผูกพาเลท เข้าพาเลท '
                         + ISNULL(@PalletNo, N'-') + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N') '
                         + N'เป็นถุงหมายเลข ' + CAST(@AssignedBagNo AS VARCHAR(10)) + N' โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Add Bag In',
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
-- DECLARE @rc INT, @msg NVARCHAR(255), @bagNo INT;
-- EXEC dbo.sp_PalletAdjustment_AddBagIn
--      @BagId = 9990, @PalletId = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @AssignedBagNo = @bagNo OUTPUT;
-- SELECT @rc, @msg, @bagNo;
