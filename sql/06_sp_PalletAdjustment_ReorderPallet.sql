/* =====================================================================
   Pallet Adjustment - ReorderPallet
   -----------------------------------------------------------------
   Re-numbers bag_no for ALL active bags currently in a pallet, in
   order of create_datetime (i.e. the order they were actually
   printed/inserted), starting from 1.

   NOTE: ไม่ต้อง sync pallet_status_id ที่นี่ (ต่างจาก 03/04/05) เพราะ SP นี้แค่
   จัดเรียง bag_no ใหม่ ไม่เปลี่ยนจำนวนถุงในพาเลทเลย (bag_count เท่าเดิมเสมอ)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_ReorderPallet]
    @PalletId      BIGINT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @BagCount      INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletNo VARCHAR(30);
        SELECT  @PalletNo = pallet_no FROM dbo.tr_pallet WHERE id = @PalletId AND is_active = 'Y';

        IF @PalletNo IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทที่ต้องการ re-order';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        ;WITH Reorder AS (
            SELECT id, ROW_NUMBER() OVER (ORDER BY create_datetime, id) AS rn
            FROM   dbo.tr_bag
            WHERE  pallet_id = @PalletId AND is_active = 'Y'
        )
        UPDATE b
        SET    b.bag_no          = r.rn,
               b.update_user_id  = @UserId,
               b.update_datetime = GETDATE()
        FROM   dbo.tr_bag b
        INNER JOIN Reorder r ON r.id = b.id;

        SET @BagCount = @@ROWCOUNT;

        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string
        --  ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'จัดเรียงหมายเลขถุงใหม่ทั้งหมดในพาเลท ' + ISNULL(@PalletNo, N'-') + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N') '
                         + N'จำนวน ' + CAST(@BagCount AS VARCHAR(10)) + N' ถุง โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Reorder Pallet',
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
-- EXEC dbo.sp_PalletAdjustment_ReorderPallet
--      @PalletId = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @BagCount = @cnt OUTPUT;
-- SELECT @rc, @msg, @cnt;
