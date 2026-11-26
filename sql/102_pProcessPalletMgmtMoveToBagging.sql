/* =====================================================================
   Pallet Management - MoveToBagging (Boardman หน้า /pallet-management)
   -----------------------------------------------------------------
   ย้ายพาเลทที่เลือก (หลายพาเลทได้) กลับ Bagging Area -- แก้ตำแหน่งในระบบเท่านั้น
   ไม่สร้าง Job และไม่ส่งข้อมูลไป WMS

   @PalletIds = รายการ tr_pallet.id คั่นด้วย comma (เช่น '10,11,12')
   ทำทีละพาเลทคนละ transaction -- พาเลทที่ไม่ผ่านเงื่อนไขถูกข้าม พาเลทอื่นยังย้ายต่อ

   พาเลทที่ย้ายสำเร็จ:
     current_location_id / current_location_type = NULL (= Bagging Area เหมือนพาเลทใหม่
       และเหมือน pProcess*ResetPallet ; pProcessGetPalletList แสดง NULL เป็น Bagging Area)
     current_job_id / current_job_item_id = NULL (งานเดิมจบแล้ว -- ไม่ล้างจะติด error
       "already assigned to a job with the same job type" ตอนหยิบเข้างานประเภทเดิม)
   ไม่แก้ tr_pallet_history และ actual_qty ของงานเดิม เพื่อให้ประวัติงานที่จบแล้วคงเดิม

   ไม่ย้าย: ไม่พบพาเลท / อยู่ Bagging Area อยู่แล้ว / อยู่ในงานที่ยังไม่จบ (job_status_id <> 5)

   dbResult  : status / message
   dbResult1 : ผลรายพาเลท (pallet_id, pallet_no, is_success, message)
   Dependencies: 20_tr_transaction_log.sql (pInsertTransactionLog)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtMoveToBagging]
    @PalletIds NVARCHAR(MAX),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ids TABLE (pallet_id BIGINT PRIMARY KEY);
    DECLARE @results TABLE (pallet_id BIGINT, pallet_no VARCHAR(50), is_success BIT, message NVARCHAR(255));

    INSERT INTO @ids (pallet_id)
    SELECT DISTINCT TRY_CAST(value AS BIGINT)
    FROM   STRING_SPLIT(@PalletIds, ',')
    WHERE  TRY_CAST(value AS BIGINT) > 0;

    IF NOT EXISTS (SELECT 1 FROM @ids)
    BEGIN
        SELECT 'error' AS status, N'กรุณาเลือกพาเลท' AS message;
        SELECT pallet_id, pallet_no, is_success, message FROM @results;
        RETURN;
    END

    DECLARE @PalletId BIGINT = 0;
    DECLARE @PalletNo VARCHAR(50), @LocationType VARCHAR(10), @LocationId BIGINT, @JobId BIGINT;
    DECLARE @LogDetail NVARCHAR(MAX);

    WHILE 1 = 1
    BEGIN
        SELECT @PalletId = MIN(pallet_id) FROM @ids WHERE pallet_id > @PalletId;
        IF @PalletId IS NULL BREAK;

        SET @PalletNo = NULL;
        SET @LocationType = NULL;
        SET @LocationId = NULL;
        SET @JobId = NULL;

        BEGIN TRY
            BEGIN TRANSACTION;

            SELECT @PalletNo = pallet_no, @LocationType = current_location_type,
                   @LocationId = current_location_id, @JobId = current_job_id
            FROM   dbo.tr_pallet WITH (UPDLOCK)
            WHERE  id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

            IF @PalletNo IS NULL
            BEGIN
                INSERT INTO @results VALUES (@PalletId, NULL, 0, N'ไม่พบพาเลท หรือพาเลทถูกยกเลิกแล้ว');
                ROLLBACK TRANSACTION;
                CONTINUE;
            END

            --  NULL = Bagging Area (default เดียวกับ pProcessGetPalletList)
            IF COALESCE(@LocationType, 'BG-PLANT') = 'BG-PLANT'
            BEGIN
                INSERT INTO @results VALUES (@PalletId, @PalletNo, 0, N'พาเลทอยู่ Bagging Area อยู่แล้ว');
                ROLLBACK TRANSACTION;
                CONTINUE;
            END

            IF EXISTS (SELECT 1 FROM dbo.tr_job_main
                       WHERE id = @JobId AND job_status_id <> 5
                         AND is_active = 'Y' AND status_flag = 'A')
            BEGIN
                INSERT INTO @results VALUES (@PalletId, @PalletNo, 0,
                    N'พาเลทอยู่ในงานที่ยังไม่จบ (Job ID ' + CAST(@JobId AS NVARCHAR(20)) + N') กรุณา Reset จากงานก่อน');
                ROLLBACK TRANSACTION;
                CONTINUE;
            END

            UPDATE dbo.tr_pallet
            SET    current_location_id   = NULL,
                   current_location_type = NULL,
                   current_job_id        = NULL,
                   current_job_item_id   = NULL,
                   update_user_id        = @UserId,
                   update_datetime       = GETDATE()
            WHERE  id = @PalletId;

            --  *PL001*: PRE-ZONE #12 → Bagging Area
            SET @LogDetail = N'*' + @PalletNo + N'*: ' + @LocationType
                             + ISNULL(N' #' + CAST(@LocationId AS NVARCHAR(20)), N'') + N' → Bagging Area';

            EXEC dbo.pInsertTransactionLog
                 @topic    = 'Pallet Management',
                 @activity = 'Move to Bagging',
                 @detail   = @LogDetail,
                 @user_id  = @UserId;

            COMMIT TRANSACTION;

            INSERT INTO @results VALUES (@PalletId, @PalletNo, 1, N'ย้ายกลับ Bagging Area สำเร็จ');
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            INSERT INTO @results VALUES (@PalletId, @PalletNo, 0, LEFT(ERROR_MESSAGE(), 255));
        END CATCH
    END

    SELECT 'success' AS status, N'ดำเนินการเรียบร้อย' AS message;
    SELECT pallet_id, pallet_no, is_success, message FROM @results ORDER BY pallet_id;
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessPalletMgmtMoveToBagging @PalletIds = '10,11,12', @UserId = 101;
