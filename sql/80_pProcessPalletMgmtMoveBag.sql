/* =====================================================================
   Pallet Management - MoveBag (PWA Forklift หน้า /pallet-management)
   -----------------------------------------------------------------
   ย้ายถุง 1 ใบ จากพาเลทต้นทาง -> พาเลทปลายทาง ใน transaction เดียว
   ใช้ตอน Add Bag ด้วย QR พาเลท (เช่น PLM2610160008|03R01B|0261001361|500)
   = ย้ายถุงทั้งพาเลทนั้นมาเข้าพาเลทที่เปิดอยู่ (frontend เรียกทีละถุง)

   ต่างจาก sp_PalletAdjustment_AddBagIn (05) ที่รับเฉพาะถุง orphan:
   SP นี้รับถุงที่อยู่บนพาเลทอื่น แล้วทำ PullBagOut (04) + AddBagIn (05) รวดเดียว
   ไม่มีจังหวะที่ถุงค้างเป็น orphan ถ้าล้มกลางทาง

   - ปลายทางต้องยังไม่เต็ม (bag_count < unit_pallet) -- ห้ามเกิน pallet ratio
   - Grade/Lot ของถุงต้องตรงกับพาเลทปลายทาง (ถุงส่วนใหญ่บนพาเลท เหมือน 27 GetPallet)
     ถ้าปลายทางยังไม่มีถุงเลย ไม่เช็ค
   - ต้นทาง: เรียง bag_no ที่เหลือใหม่ 1..n
   - sync pallet_status_id ทั้งสองพาเลท (1=CREATED / 2=COMPLETED, ไม่แตะ 3/4)

   @ResultCode : 0 = success , > 0 = business error , -1 = system error
   Dependencies: 20_tr_transaction_log.sql (pInsertTransactionLog)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtMoveBag]
    @BagId         BIGINT,
    @PalletId      BIGINT,          --  พาเลทปลายทาง
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
        DECLARE @SrcPalletId BIGINT, @SrcPalletNo VARCHAR(30), @SrcBagNo INT;
        DECLARE @BagGrade VARCHAR(30), @BagLot VARCHAR(20);
        DECLARE @TgtGrade VARCHAR(30), @TgtLot VARCHAR(20);
        DECLARE @BagFound BIT = 0;

        SELECT @UnitPallet = unit_pallet,
               @PalletNo   = pallet_no
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @UnitPallet IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @BagFound    = 1,
               @SrcPalletId = b.pallet_id,
               @SrcBagNo    = b.bag_no,
               @BagGrade    = b.grade,
               @BagLot      = b.lot
        FROM   dbo.tr_bag b WITH (UPDLOCK)
        WHERE  b.id = @BagId AND b.is_active = 'Y' AND b.status_flag = 'A';

        IF @BagFound = 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'ไม่พบข้อมูลถุง หรือถุงถูก Reject/ยกเลิกแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SrcPalletId IS NULL
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ถุงนี้ไม่ได้อยู่บนพาเลทใด (ใช้ Add Bag แบบสแกน QR ถุงแทน)';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SrcPalletId = @PalletId
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'ถุงนี้อยู่บนพาเลทนี้อยู่แล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @CurrentCount = COUNT(*)
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        IF @CurrentCount >= @UnitPallet
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'พาเลทเต็มแล้ว ไม่สามารถเพิ่มถุงได้ (ห้ามเกิน Pallet Ratio)';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  Grade/Lot ของปลายทาง = กลุ่มที่มีถุงมากที่สุด (เหมือน pProcessPalletMgmtGetPallet)
        SELECT TOP 1 @TgtGrade = grade, @TgtLot = lot
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot
        ORDER BY COUNT(*) DESC;

        IF @TgtGrade IS NOT NULL
           AND (UPPER(LTRIM(RTRIM(@TgtGrade))) <> UPPER(LTRIM(RTRIM(ISNULL(@BagGrade, ''))))
             OR UPPER(LTRIM(RTRIM(ISNULL(@TgtLot, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(@BagLot, '')))))
        BEGIN
            SET @ResultCode = 6;
            SET @ResultMessage = N'Grade/Lot ของถุงไม่ตรงกับพาเลทปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @SrcPalletNo = pallet_no FROM dbo.tr_pallet WHERE id = @SrcPalletId;

        SET @AssignedBagNo = @CurrentCount + 1;

        UPDATE dbo.tr_bag
        SET    pallet_id        = @PalletId,
               bag_no           = @AssignedBagNo,
               bag_status_id    = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @BagId;

        --  ต้นทาง: เรียง bag_no ที่เหลือใหม่ 1..n (เหมือน 04 PullBagOut)
        ;WITH Reorder AS (
            SELECT id, ROW_NUMBER() OVER (ORDER BY create_datetime, id) AS rn
            FROM   dbo.tr_bag
            WHERE  pallet_id = @SrcPalletId AND is_active = 'Y'
        )
        UPDATE b
        SET    b.bag_no          = r.rn,
               b.update_user_id  = @UserId,
               b.update_datetime = GETDATE()
        FROM   dbo.tr_bag b
        INNER JOIN Reorder r ON r.id = b.id;

        --  sync pallet_status_id ทั้งต้นทางและปลายทาง ตามจำนวนถุงจริง
        UPDATE p
        SET    p.pallet_status_id = CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END,
               p.update_user_id   = @UserId,
               p.update_datetime  = GETDATE()
        FROM   dbo.tr_pallet p
        LEFT JOIN (
            SELECT pallet_id, COUNT(*) AS cnt
            FROM   dbo.tr_bag
            WHERE  is_active = 'Y' AND pallet_id IN (@PalletId, @SrcPalletId)
            GROUP BY pallet_id
        ) bc ON bc.pallet_id = p.id
        WHERE  p.id IN (@PalletId, @SrcPalletId)
          AND  ISNULL(p.pallet_status_id, 1) IN (1, 2)
          AND  p.pallet_status_id <> CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END;

        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'ย้ายถุง (Bag ID: ' + CAST(@BagId AS VARCHAR(20)) + N') จากพาเลท '
                         + ISNULL(@SrcPalletNo, N'-') + N' (ถุงหมายเลข ' + ISNULL(CAST(@SrcBagNo AS VARCHAR(10)), N'-') + N') เข้าพาเลท '
                         + ISNULL(@PalletNo, N'-') + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N') '
                         + N'เป็นถุงหมายเลข ' + CAST(@AssignedBagNo AS VARCHAR(10)) + N' โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Move Bag',
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
-- EXEC dbo.pProcessPalletMgmtMoveBag
--      @BagId = 9990, @PalletId = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @AssignedBagNo = @bagNo OUTPUT;
-- SELECT @rc, @msg, @bagNo;
