/* =====================================================================
   Pallet Adjustment - PullBagOut
   -----------------------------------------------------------------
   Pull one or more bags out of their current pallet (they become
   orphan bags). Any pallet(s) affected then get their remaining
   bag_no automatically re-ordered so numbering stays contiguous.

   Also syncs pallet_status_id (dbo.ct_pallet_status, ดู 00_master_pallet_status.sql)
   ของทุกพาเลทที่ได้รับผลกระทบให้ตรงกับจำนวนถุงจริงหลังดึงออก: 1=CREATED ถ้าไม่เต็ม
   (รวมกรณีดึงจนเหลือ 0 ถุง), 2=COMPLETED ถ้ายังเต็มพอดี (ปกติไม่เกิดเพราะดึงออกมีแต่
   จะลดจำนวน แต่เผื่อไว้ให้ตรง pattern เดียวกับที่อื่น) -- เหมือน pattern ใน
   13_pServiceMatchBagToPallet.sql ขั้นตอน 6.5 (ไม่แตะพาเลทที่เป็น 3=CONFIRMED หรือ
   4=VOID)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_PullBagOut]
    @BagIds        NVARCHAR(MAX),   --  comma-separated bag id list, e.g. '1005,1006'
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Ids TABLE (id BIGINT PRIMARY KEY);
        INSERT INTO @Ids
        SELECT CAST(value AS BIGINT) FROM STRING_SPLIT(@BagIds, ',');

        IF NOT EXISTS (SELECT 1 FROM @Ids)
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบรายการถุงที่เลือก';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        DECLARE @AffectedPallets TABLE (pallet_id BIGINT PRIMARY KEY);
        INSERT INTO @AffectedPallets
        SELECT DISTINCT pallet_id
        FROM   dbo.tr_bag
        WHERE  id IN (SELECT id FROM @Ids) AND pallet_id IS NOT NULL;

        --  เก็บสถานะ "ก่อนดึงออก" ไว้สำหรับ log -- ต้องเก็บก่อน UPDATE เพราะ
        --  UPDATE ด้านล่างจะ NULL ทั้ง pallet_id และ bag_no ทิ้งไปทันที
        DECLARE @BeforeSnapshot TABLE (bag_id BIGINT, bag_no INT, pallet_no VARCHAR(30));
        INSERT INTO @BeforeSnapshot (bag_id, bag_no, pallet_no)
        SELECT b.id, b.bag_no, p.pallet_no
        FROM   dbo.tr_bag b
        LEFT JOIN dbo.tr_pallet p ON p.id = b.pallet_id
        WHERE  b.id IN (SELECT id FROM @Ids);

        UPDATE dbo.tr_bag
        SET    pallet_id        = NULL,
               bag_no           = NULL,
               bag_status_id    = 5,   -- PULLED_OUT (see 00_master_bag_status.sql)
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id IN (SELECT id FROM @Ids);

        --  Auto re-order bag_no ของถุงที่เหลือในแต่ละ pallet ที่ได้รับผลกระทบ
        DECLARE @PalletId BIGINT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT pallet_id FROM @AffectedPallets;
        OPEN cur;
        FETCH NEXT FROM cur INTO @PalletId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
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

            FETCH NEXT FROM cur INTO @PalletId;
        END
        CLOSE cur;
        DEALLOCATE cur;

        --  sync pallet_status_id ของทุกพาเลทที่ได้รับผลกระทบ ตามจำนวนถุงจริงหลังดึงออก
        --  (LEFT JOIN เพราะพาเลทอาจถูกดึงจนเหลือ 0 ถุง -- ISNULL(cnt,0) < unit_pallet เสมอ)
        UPDATE p
        SET    p.pallet_status_id = CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END,
               p.update_user_id   = @UserId,
               p.update_datetime  = GETDATE()
        FROM   dbo.tr_pallet p
        JOIN   @AffectedPallets ap ON ap.pallet_id = p.id
        LEFT JOIN (
            SELECT pallet_id, COUNT(*) AS cnt
            FROM   dbo.tr_bag
            WHERE  is_active = 'Y'
            GROUP BY pallet_id
        ) bc ON bc.pallet_id = p.id
        WHERE  ISNULL(p.pallet_status_id, 1) IN (1, 2)
          AND  p.pallet_status_id <> CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END;

        --  Log การแก้ไข -- สรุปเป็น "ถุงหมายเลข X จากพาเลท Y" ต่อแถว คั่นด้วย ; ,
        --  ปลายทางเดียวกันหมดคือ Orphan Bag (pallet_id/bag_no ถูก NULL ทิ้งแล้ว)
        DECLARE @BagSummary NVARCHAR(MAX);
        SELECT  @BagSummary = STRING_AGG(
                    CONCAT('Bag ID ', bag_id, ' (ถุงหมายเลข ', ISNULL(CAST(bag_no AS VARCHAR(10)), '-'),
                           ') จากพาเลท ', ISNULL(pallet_no, '-')), '; ')
        FROM    @BeforeSnapshot;

        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string
        --  ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'ดึงถุงออกจากพาเลทไปเป็นถุงที่ยังไม่ผูกพาเลท จำนวน ' + CAST((SELECT COUNT(*) FROM @Ids) AS VARCHAR(10))
                         + N' ถุง: ' + ISNULL(@BagSummary, N'-') + N' โดย User ID: ' + CAST(@UserId AS VARCHAR(20));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Pull Bag Out',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'cur') >= 0
        BEGIN
            CLOSE cur;
            DEALLOCATE cur;
        END
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- DECLARE @rc INT, @msg NVARCHAR(255);
-- EXEC dbo.sp_PalletAdjustment_PullBagOut
--      @BagIds = '1005,1006', @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT;
-- SELECT @rc, @msg;
