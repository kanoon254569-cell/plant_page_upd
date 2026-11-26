/* =====================================================================
   103_sp_PalletAdjustment_AddMissingBag.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   ปุ่ม "เพิ่มข้อมูล" หน้า Pallet Adjustment : เพิ่มข้อมูล tr_bag ด้วยมือให้ช่องว่างที่ไม่มีข้อมูลการพิมพ์
   (เช่น พิมพ์ QR ติดถุงแล้วแต่บันทึก DB ไม่สำเร็จ) -- ถุงยังอยู่จริง จึงไม่ใช่ Reject

   INSERT tr_bag เป็นถุงปกติ QR format เดิม ของตำแหน่งนั้น
     cc|grade|lot|<bag 2 หลัก>|<ตัน 3 หลัก>  (QR 6 ส่วนต่อท้าย |ddHHmm จากถุงบนพาเลทเดียวกัน)
     is_active = 'Y' , bag_status_id = 1 , pallet_id = NULL , mode_id = 2 (Manual)
   แล้วเรียก pServiceMatchBagToPallet ต่อทันที -> ถุงลงพาเลท/ช่องตามตำแหน่ง QR (ถุงอื่นไม่เลื่อน)

   หมายเหตุ
   - @QrText ต้องอยู่ในผลของ sp_PalletAdjustment_GetMissingSlots ณ ตอนนี้ (98_)
   - mode_id = 2 ถูกตรวจซ้ำใน pProcessInsertTrBag : พิมพ์ QR เดิมซ้ำภายหลังจะได้ 'Duplicate QR code data.'
   - create_datetime = create_datetime ล่าสุดของถุงบนพาเลทนั้น (เหมือน 98_)
     ให้ถุงอยู่ในตัวกรองวันที่พิมพ์เดียวกับพาเลท
   - ยกเลิกถุงที่เพิ่มผิด : ใช้ "ถุง Reject" ตามปกติ

   dbResult : status / message / bag_id / qr_text_data  (ตามด้วย 3 result set ของ pServiceMatchBagToPallet)
   Rollback: 103_rollback_sp_PalletAdjustment_AddMissingBag.sql
   Dependencies: 98_sp_PalletAdjustment_RejectMissingSlot.sql, 10_fParseBagQr.sql,
                 13_pServiceMatchBagToPallet.sql, 20_tr_transaction_log.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.sp_PalletAdjustment_AddMissingBag
    @PalletId BIGINT,
    @QrText   VARCHAR(100),
    @UserId   INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = '',
            @lk INT, @bag_id BIGINT = NULL, @need_reconcile BIT = 0,
            @cc VARCHAR(20), @grade VARCHAR(30), @lot VARCHAR(20),
            @ton INT, @bag_no INT, @fmt TINYINT, @qr VARCHAR(100), @qr_time VARCHAR(50),
            @create_dt DATETIME, @pallet_no VARCHAR(50),
            @LogDetail NVARCHAR(MAX) = NULL;

    DECLARE @m TABLE (
        qr_text_data VARCHAR(100), cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20),
        qr_format TINYINT, qr_ton INT, qr_bag_no INT, planned_pos INT);

    SET @QrText = LTRIM(RTRIM(@QrText));

    IF @PalletId IS NULL OR @PalletId <= 0 OR ISNULL(@QrText, '') = ''
    BEGIN
        SELECT 'error' AS status, N'ต้องระบุพาเลทและ QR ของช่องที่จะเพิ่มข้อมูล' AS message,
               @bag_id AS bag_id, @qr AS qr_text_data;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRAN;

        -- lock เดียวกับ pServiceMatchBagToPallet : กันช่องว่างเปลี่ยนระหว่างตรวจกับ INSERT
        EXEC @lk = sp_getapplock @Resource = 'QTRACK_MatchBagToPallet',
                                 @LockMode = 'Exclusive', @LockOwner = 'Transaction',
                                 @LockTimeout = 15000;
        IF @lk < 0
        BEGIN
            ROLLBACK TRAN;
            SELECT 'warning' AS status, N'ระบบกำลังจับคู่ถุงอยู่ กรุณาลองใหม่อีกครั้ง' AS message,
                   @bag_id AS bag_id, @qr AS qr_text_data;
            RETURN;
        END

        INSERT INTO @m
        EXEC dbo.sp_PalletAdjustment_GetMissingSlots @PalletId = @PalletId;

        SELECT @cc = cost_center, @grade = grade, @lot = lot,
               @ton = qr_ton, @bag_no = qr_bag_no, @fmt = qr_format
        FROM   @m
        WHERE  qr_text_data = @QrText;

        SET @qr = @QrText;

        -- QR 6 ส่วน : GetMissingSlots ต่อท้าย |000000 -> ใช้ ddHHmm จากถุงบนพาเลทเดียวกัน
        IF @fmt = 6
        BEGIN
            SELECT TOP 1 @qr_time = q.qr_time
            FROM   dbo.tr_bag b
            CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
            WHERE  b.pallet_id = @PalletId AND b.status_flag = 'A' AND q.qr_format = 6
            ORDER BY b.id DESC;

            SET @qr = CONCAT(LEFT(@QrText, LEN(@QrText) - 6),
                             ISNULL(@qr_time, FORMAT(GETDATE(), 'ddHHmm')));
        END

        IF @grade IS NULL
            SET @message = N'ช่อง ' + @QrText + N' ไม่ใช่ช่องว่างของพาเลทนี้แล้ว (อาจมีถุงเข้ามาแล้ว) กรุณารีเฟรช';
        ELSE IF EXISTS (SELECT 1 FROM dbo.tr_bag WHERE qr_text_data = @qr AND status_flag = 'A')
            SET @message = N'มีข้อมูล QR ' + @qr + N' ในระบบแล้ว';

        IF @message <> ''
        BEGIN
            ROLLBACK TRAN;
            SELECT 'error' AS status, @message AS message, @bag_id AS bag_id, @qr AS qr_text_data;
            RETURN;
        END

        SELECT @pallet_no = pallet_no FROM dbo.tr_pallet WHERE id = @PalletId;
        SELECT @create_dt = MAX(create_datetime) FROM dbo.tr_bag WHERE pallet_id = @PalletId;

        INSERT INTO dbo.tr_bag
            ( cost_center, pallet_id, pallet_running_no, ton_no, bag_no, grade, lot, qr_text_data,
              mode_id, bag_status_id, remark, is_active,
              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
        VALUES
            ( @cc, NULL, @ton, @ton, @bag_no, @grade, @lot, @qr,
              2, 1, 'เพิ่มข้อมูลด้วยมือ (ไม่มีข้อมูลการพิมพ์)', 'Y',
              @UserId, ISNULL(@create_dt, GETDATE()), @UserId, GETDATE(), 'A' );
        SET @bag_id = SCOPE_IDENTITY();

        SET @LogDetail = N'*' + @qr + N'* (เพิ่มข้อมูลด้วยมือ)'
                         + ISNULL(N' ช่องว่างบน *' + @pallet_no + N'*', N'');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Add Missing Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        COMMIT TRAN;

        SET @message = N'เพิ่มข้อมูล ' + @qr + N' สำเร็จ';
        SET @need_reconcile = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SET @status = 'error';  SET @message = ERROR_MESSAGE();  SET @bag_id = NULL;
    END CATCH

    SELECT @status AS status, @message AS message, @bag_id AS bag_id, @qr AS qr_text_data;   -- dbResult

    -- reconcile นอก transaction ของตัวเอง (เหมือน sp_PalletAdjustment_RejectMissingSlot)
    IF @need_reconcile = 1
        EXEC dbo.pServiceMatchBagToPallet @grade = @grade, @create_user_id = @UserId, @preview = 0;
END
GO
