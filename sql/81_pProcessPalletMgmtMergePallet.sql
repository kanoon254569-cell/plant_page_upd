/* =====================================================================
   Pallet Management - MergePallet (PWA Forklift หน้า /pallet-management)
   -----------------------------------------------------------------
   รวมพาเลทต้นทาง (@SrcPalletId) เข้าพาเลทปลายทาง (@PalletId) ทั้งพาเลทใน transaction เดียว
   ใช้ตอน Add Bag ด้วย QR พาเลท (PL<code>|grade|lot|qty) เมื่อมีพาเลท Manual (pallet_type='M') เกี่ยวข้อง

   qty ของพาเลท:
     Manual (M) = unit_pallet * unit_ratio
     อื่นๆ (A)  = จำนวนถุง active * unit_ratio  (เหมือน 27 GetPallet)
   "รวม qty" (ตามที่ user กำหนด) = tr_pallet.unit_pallet ของปลายทาง
                                 = (qty ต้นทาง + qty ปลายทาง) / unit_ratio ปลายทาง  (ต้องหารลงตัว)

   Case 1 : Manual -> Manual : ปลายทาง unit_pallet = รวม , ลบ tr_bag ของต้นทาง (DELETE จริง; log QR ไว้)
   Case 2 : Manual -> Auto   : ปลายทาง unit_pallet = รวม , เก็บ tr_bag ของต้นทาง -> ย้ายมาปลายทาง
   Case 3 : Auto   -> Manual : ปลายทาง unit_pallet = รวม , tr_bag ของปลายทางคงเดิม , ถุงต้นทางย้ายมาปลายทาง
   Auto -> Auto : ไม่ใช้ SP นี้ (ResultCode 7) -- ใช้ 80 pProcessPalletMgmtMoveBag ทีละถุงเหมือนเดิม

   - Grade/Lot ของสองพาเลทต้องตรงกัน (ถุงส่วนใหญ่บนพาเลท เหมือน 27/80) ; ไม่เช็ค bag_count < unit_pallet
     เพราะ unit_pallet ของปลายทางถูกคำนวณใหม่
   - ถุงที่ย้าย: pallet_id = ปลายทาง, bag_no ต่อท้าย, bag_status_id = 3 (MANUAL_MATCHED -> 13 ไม่ re-point)
   - ต้นทางหลังรวม: is_active = 'N' (ไม่แตะ tr_pallet_manual_item)
   - pallet_status_id ของปลายทางไม่เปลี่ยน
   - รวมได้ทุกสถานะ รวมถึง pallet_status_id = 4 (VOID) และพาเลทที่เข้าคลังแล้ว (inbound_to_wh_id)
     (ต้องยัง is_active = 'Y' / status_flag = 'A')

   @ResultCode : 0 = success , > 0 = business error , -1 = system error
   Dependencies: 20_tr_transaction_log.sql (pInsertTransactionLog)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtMergePallet]
    @SrcPalletId   BIGINT,          --  พาเลทต้นทาง (ที่สแกน QR)
    @PalletId      BIGINT,          --  พาเลทปลายทาง (ที่เปิดอยู่)
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @NewUnitPallet INT           OUTPUT,
    @TotalQty      INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @SrcNo VARCHAR(30), @SrcType VARCHAR(1), @SrcRatio INT, @SrcUnitPallet INT, @SrcStatus INT, @SrcInWh BIGINT;
        DECLARE @TgtNo VARCHAR(30), @TgtType VARCHAR(1), @TgtRatio INT, @TgtUnitPallet INT, @TgtStatus INT, @TgtInWh BIGINT;
        DECLARE @SrcCount INT, @TgtCount INT, @SrcQty INT, @TgtQty INT;
        DECLARE @SrcGrade VARCHAR(30), @SrcLot VARCHAR(20), @TgtGrade VARCHAR(30), @TgtLot VARCHAR(20);
        DECLARE @Case INT, @CaseText NVARCHAR(50), @BagDetail NVARCHAR(MAX);

        IF @SrcPalletId = @PalletId
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'เป็นพาเลทเดียวกัน';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @TgtNo = pallet_no, @TgtType = pallet_type, @TgtRatio = unit_ratio, @TgtUnitPallet = unit_pallet,
               @TgtStatus = pallet_status_id, @TgtInWh = inbound_to_wh_id
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        SELECT @SrcNo = pallet_no, @SrcType = pallet_type, @SrcRatio = unit_ratio, @SrcUnitPallet = unit_pallet,
               @SrcStatus = pallet_status_id, @SrcInWh = inbound_to_wh_id
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @TgtNo IS NULL OR @SrcNo IS NULL
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = CASE WHEN @TgtNo IS NULL THEN N'ไม่พบพาเลทปลายทาง' ELSE N'ไม่พบพาเลทต้นทาง' END;
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @Case = CASE WHEN @SrcType = 'M' AND @TgtType = 'M' THEN 1
                         WHEN @SrcType = 'M'                    THEN 2
                         WHEN @TgtType = 'M'                    THEN 3
                    END;

        IF @Case IS NULL
        BEGIN
            SET @ResultCode = 7;
            SET @ResultMessage = N'ไม่มีพาเลท Manual -- ใช้การย้ายถุงทีละใบ (move-bag)';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF ISNULL(@TgtRatio, 0) <= 0
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'พาเลทปลายทางไม่มี Unit Ratio';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  Grade/Lot = กลุ่มที่มีถุงมากที่สุด (เหมือน 27/80)
        SELECT TOP 1 @SrcGrade = grade, @SrcLot = lot
        FROM   dbo.tr_bag
        WHERE  pallet_id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot ORDER BY COUNT(*) DESC;

        SELECT TOP 1 @TgtGrade = grade, @TgtLot = lot
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot ORDER BY COUNT(*) DESC;

        IF @SrcGrade IS NOT NULL AND @TgtGrade IS NOT NULL
           AND (UPPER(LTRIM(RTRIM(@TgtGrade))) <> UPPER(LTRIM(RTRIM(@SrcGrade)))
             OR UPPER(LTRIM(RTRIM(ISNULL(@TgtLot, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(@SrcLot, '')))))
        BEGIN
            SET @ResultCode = 6;
            SET @ResultMessage = N'Grade/Lot ของพาเลทต้นทางไม่ตรงกับพาเลทปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @SrcCount = COUNT(*) FROM dbo.tr_bag WITH (UPDLOCK) WHERE pallet_id = @SrcPalletId AND is_active = 'Y';
        SELECT @TgtCount = COUNT(*) FROM dbo.tr_bag WITH (UPDLOCK) WHERE pallet_id = @PalletId    AND is_active = 'Y';

        SET @SrcQty = CASE WHEN @SrcType = 'M' THEN ISNULL(@SrcUnitPallet, 0) ELSE @SrcCount END * ISNULL(@SrcRatio, 0);
        SET @TgtQty = CASE WHEN @TgtType = 'M' THEN ISNULL(@TgtUnitPallet, 0) ELSE @TgtCount END * @TgtRatio;
        SET @TotalQty = @SrcQty + @TgtQty;

        IF @SrcQty <= 0
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'พาเลทต้นทางไม่มีจำนวน (qty = 0)';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @TotalQty % @TgtRatio <> 0
        BEGIN
            SET @ResultCode = 8;
            SET @ResultMessage = N'จำนวนรวม ' + CAST(@TotalQty AS VARCHAR(20)) + N' หารด้วย Unit Ratio '
                                 + CAST(@TgtRatio AS VARCHAR(20)) + N' ของพาเลทปลายทางไม่ลงตัว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @NewUnitPallet = @TotalQty / @TgtRatio;

        --  QR ของถุงต้นทางเก็บลง log ก่อนย้าย/ลบ
        SELECT @BagDetail = STUFF((
            SELECT N', ' + CAST(id AS VARCHAR(20)) + N':' + ISNULL(qr_text_data, N'-')
            FROM   dbo.tr_bag
            WHERE  pallet_id = @SrcPalletId
            ORDER BY bag_no, id
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

        IF @Case = 1
        BEGIN
            SET @CaseText = N'Manual -> Manual';
            DELETE FROM dbo.tr_bag WHERE pallet_id = @SrcPalletId;
        END
        ELSE
        BEGIN
            SET @CaseText = CASE WHEN @Case = 2 THEN N'Manual -> Auto' ELSE N'Auto -> Manual' END;

            ;WITH mv AS (
                SELECT id, @TgtCount + ROW_NUMBER() OVER (ORDER BY bag_no, id) AS new_no
                FROM   dbo.tr_bag
                WHERE  pallet_id = @SrcPalletId AND is_active = 'Y'
            )
            UPDATE b
            SET    b.pallet_id       = @PalletId,
                   b.bag_no          = mv.new_no,
                   b.bag_status_id   = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
                   b.update_user_id  = @UserId,
                   b.update_datetime = GETDATE()
            FROM   dbo.tr_bag b
            INNER JOIN mv ON mv.id = b.id;
        END

        UPDATE dbo.tr_pallet
        SET    unit_pallet     = @NewUnitPallet,
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @PalletId;

        UPDATE dbo.tr_pallet
        SET    is_active       = 'N',
               remark          = LEFT(CONCAT(N'Merged into ', @TgtNo), 500),
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @SrcPalletId;

        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'รวมพาเลท (' + @CaseText + N') ' + @SrcNo + N' (ID: ' + CAST(@SrcPalletId AS VARCHAR(20))
                         + N', qty ' + CAST(@SrcQty AS VARCHAR(20)) + N') เข้าพาเลท ' + @TgtNo
                         + N' (ID: ' + CAST(@PalletId AS VARCHAR(20)) + N', qty ' + CAST(@TgtQty AS VARCHAR(20))
                         + N') รวม ' + CAST(@TotalQty AS VARCHAR(20)) + N' -> unit_pallet '
                         + ISNULL(CAST(@TgtUnitPallet AS VARCHAR(20)), N'-') + N' เป็น ' + CAST(@NewUnitPallet AS VARCHAR(20))
                         + CASE WHEN @Case = 1 THEN N' / ลบถุงต้นทาง: ' ELSE N' / ย้ายถุงต้นทาง: ' END
                         + ISNULL(@BagDetail, N'-') + N' โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Merge Pallet',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'รวมพาเลท ' + @SrcNo + N' เข้า ' + @TgtNo + N' สำเร็จ (รวม ' + CAST(@TotalQty AS VARCHAR(20)) + N')';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = LEFT(ERROR_MESSAGE(), 255);
        SET @NewUnitPallet = NULL;
        SET @TotalQty = NULL;
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- DECLARE @rc INT, @msg NVARCHAR(255), @up INT, @qty INT;
-- EXEC dbo.pProcessPalletMgmtMergePallet
--      @SrcPalletId = 10, @PalletId = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @NewUnitPallet = @up OUTPUT, @TotalQty = @qty OUTPUT;
-- SELECT @rc, @msg, @up, @qty;
