/* =====================================================================
   Pallet Adjustment - ShiftMissingBag
   -----------------------------------------------------------------
   When 1 bag physically goes missing from the middle of a pallet
   (e.g. bag_no = 15 of 40 is lost), every bag AFTER that missing
   position must be shifted up into a brand-new pallet, re-numbered
   starting at 1 in the new pallet.

   New pallet_no is generated with the existing dbo.fGetPalletNo(@pallet_type)
   function (same one already used by the matching service), so numbering
   convention stays consistent across the whole system.

   New pallet starts at pallet_status_id = 1 (CREATED, dbo.ct_pallet_status).
   After moving bags, both the source pallet (bag_count now lower) and the new
   pallet (bag_count = @MovedCount) get pallet_status_id synced to 2=COMPLETED
   if they happen to be exactly full, else kept/reset to 1 -- same pattern as
   13_pServiceMatchBagToPallet.sql ขั้นตอน 6.5 (ไม่แตะพาเลทที่เป็น 3=CONFIRMED
   หรือ 4=VOID)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_ShiftMissingBag]
    @PalletId      BIGINT,
    @MissingBagNo  INT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @NewPalletId   BIGINT        OUTPUT,
    @NewPalletNo   VARCHAR(30)   OUTPUT,
    @MovedCount    INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @SrcPalletType   VARCHAR(1);
        DECLARE @SrcPdGroupCode  VARCHAR(20);
        DECLARE @SrcPdTypeCode   VARCHAR(20);
        DECLARE @SrcUnitRatio    INT;
        DECLARE @SrcUnitPallet   INT;
        DECLARE @SrcPalletNo     VARCHAR(30);

        SELECT  @SrcPalletType  = pallet_type,
                @SrcPdGroupCode = pd_group_code,
                @SrcPdTypeCode  = pd_type_code,
                @SrcUnitRatio   = unit_ratio,
                @SrcUnitPallet  = unit_pallet,
                @SrcPalletNo    = pallet_no
        FROM    dbo.tr_pallet
        WHERE   id = @PalletId AND is_active = 'Y';

        IF @SrcPalletType IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทต้นทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  ต้องมีถุงที่ bag_no >= จุดที่หายไปจริงถึงจะสร้างพาเลทใหม่
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_bag
            WHERE  pallet_id = @PalletId AND bag_no >= @MissingBagNo AND is_active = 'Y'
        )
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'ไม่พบถุงที่ต้องเลื่อนหลังตำแหน่งที่ระบุ';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  ใช้ function เดิมของระบบ gen เลขพาเลทใหม่ -- pallet_type เดียวกับพาเลทต้นทาง
        -- TODO(confirm): ถ้าพาเลทที่แตกออกมาควรเป็นคนละ pallet_type แจ้งทีมพัฒนาปรับตรงนี้
        SET @NewPalletNo = dbo.fGetPalletNo(@SrcPalletType);

        INSERT INTO dbo.tr_pallet
            (pallet_no, pallet_type, pd_group_code, pd_type_code, unit_ratio, unit_pallet,
             pallet_status_id, is_active, create_user_id, create_datetime,
             update_user_id, update_datetime, status_flag)
        VALUES
            (@NewPalletNo, @SrcPalletType, @SrcPdGroupCode, @SrcPdTypeCode, @SrcUnitRatio, @SrcUnitPallet,
             1, 'Y', @UserId, GETDATE(), @UserId, GETDATE(), 'A');

        SET @NewPalletId = SCOPE_IDENTITY();

        --  ย้ายถุงทุกใบที่ bag_no >= จุดที่หาย ไปพาเลทใหม่ แล้ว renumber เริ่ม 1
        ;WITH MoveList AS (
            SELECT id, bag_no,
                   ROW_NUMBER() OVER (ORDER BY bag_no) AS new_bag_no
            FROM   dbo.tr_bag
            WHERE  pallet_id = @PalletId
              AND  bag_no >= @MissingBagNo
              AND  is_active = 'Y'
        )
        UPDATE b
        SET    b.pallet_id       = @NewPalletId,
               b.bag_no          = m.new_bag_no,
               b.bag_status_id   = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               b.update_user_id  = @UserId,
               b.update_datetime = GETDATE()
        FROM   dbo.tr_bag b
        INNER JOIN MoveList m ON m.id = b.id;

        SET @MovedCount = @@ROWCOUNT;

        --  sync pallet_status_id ของทั้งพาเลทต้นทาง (ถุงลดลง) และพาเลทใหม่ (ถุง = @MovedCount)
        --  ตามจำนวนถุงจริงหลังย้าย -- ทั้งคู่เป็นพาเลท is_active='Y' ที่เพิ่งถูกแตะเลยเดาได้ว่า
        --  pallet_status_id เดิมเป็น 1 หรือ 2 (ยังไม่เคย CONFIRMED/VOID) แต่กันไว้ด้วย IN (1,2)
        DECLARE @SrcCount INT, @NewCount INT;

        SELECT @SrcCount = COUNT(*) FROM dbo.tr_bag WHERE pallet_id = @PalletId    AND is_active = 'Y';
        SELECT @NewCount = COUNT(*) FROM dbo.tr_bag WHERE pallet_id = @NewPalletId AND is_active = 'Y';

        UPDATE dbo.tr_pallet
        SET    pallet_status_id = CASE WHEN @SrcCount >= @SrcUnitPallet THEN 2 ELSE 1 END,
               update_user_id   = @UserId, update_datetime = GETDATE()
        WHERE  id = @PalletId
          AND  ISNULL(pallet_status_id, 1) IN (1, 2)
          AND  pallet_status_id <> CASE WHEN @SrcCount >= @SrcUnitPallet THEN 2 ELSE 1 END;

        UPDATE dbo.tr_pallet
        SET    pallet_status_id = CASE WHEN @NewCount >= @SrcUnitPallet THEN 2 ELSE 1 END,
               update_user_id   = @UserId, update_datetime = GETDATE()
        WHERE  id = @NewPalletId
          AND  ISNULL(pallet_status_id, 1) IN (1, 2)
          AND  pallet_status_id <> CASE WHEN @NewCount >= @SrcUnitPallet THEN 2 ELSE 1 END;

        --  Log การแก้ไข (topic/activity/detail: แก้ไขอะไร/ทำอะไร/จากไหน/ไปไหน/โดยใคร)
        --  หมายเหตุ: EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT เท่านั้น
        --  ต้อง build string ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'ถุงหมายเลข ' + CAST(@MissingBagNo AS VARCHAR(10)) + N' สูญหาย -- ระบบย้ายถุงตั้งแต่หมายเลข '
                         + CAST(@MissingBagNo AS VARCHAR(10)) + N' เป็นต้นไป จำนวน ' + CAST(@MovedCount AS VARCHAR(10))
                         + N' ถุง จากพาเลท ' + ISNULL(@SrcPalletNo, N'-') + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N') '
                         + N'ไปยังพาเลทใหม่ ' + ISNULL(@NewPalletNo, N'-') + N' (ID: ' + CAST(@NewPalletId AS VARCHAR(20)) + N') '
                         + N'โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Shift Missing Bag',
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
-- DECLARE @rc INT, @msg NVARCHAR(255), @newId BIGINT, @newNo VARCHAR(30), @moved INT;
-- EXEC dbo.sp_PalletAdjustment_ShiftMissingBag
--      @PalletId = 4, @MissingBagNo = 15, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT,
--      @NewPalletId = @newId OUTPUT, @NewPalletNo = @newNo OUTPUT, @MovedCount = @moved OUTPUT;
-- SELECT @rc, @msg, @newId, @newNo, @moved;
