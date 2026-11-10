/* =====================================================================
   98_sp_PalletAdjustment_RejectMissingSlot.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   Reject ช่องที่ "ไม่มีข้อมูลการพิมพ์" (ช่องว่างสีแดงใน Bag List ของหน้า
   Pallet Adjustment = ตำแหน่ง QR cc|grade|lot|bag_no|ตัน ที่ไม่มีแถวใน tr_bag เลย
   เช่น พิมพ์ QR แล้วบันทึก DB ไม่สำเร็จ / ถุงเสียก่อนพิมพ์)

   เดิม: ช่องว่างยังครองตำแหน่งตัวเอง (13_ : ถุงที่ยังไม่พิมพ์ไม่ทำให้ถุงอื่นเลื่อน)
         และ Reject ทำได้เฉพาะถุงที่มีแถว (pProcessUpdateBagRejectStatus @bag_id)
         -> ช่องว่างค้างถาวร พาเลทไม่มีวันครบ
   ใหม่: Reject ช่องว่าง = INSERT tr_bag "placeholder" ของตำแหน่งนั้น
           is_active = 'R' , bag_status_id = 1 (ยังไม่ประมวลผล) , mode_id = 9 (ไม่มีข้อมูลการพิมพ์)
           pallet_id / bag_no / ton_no = NULL , qr_text_data = QR ของตำแหน่งนั้น
         -> 13_ นับเป็น reject (#rj) ถุงหลังจากนั้นทั้ง lot เลื่อนขึ้นมาแทน เหมือน reject ถุงจริง
            (step 0 mark bag_status_id = 9 ให้เอง) แล้วเรียก pServiceMatchBagToPallet ต่อทันที
         "คืนค่า" (pProcessUpdateBagRejectStatus @reject = 0) ของ placeholder
         -> ยกเลิก placeholder (is_active = 'N' , status_flag = 'D') ช่องกลับเป็นช่องว่าง
            + ปลดถุง auto 1 ใบที่อยู่หลังช่องนั้นเป็นถุงรอจับคู่ ให้ 13_ หยิบกลุ่มไป reconcile
            (#grp หยิบเฉพาะกลุ่มที่มีถุงค้าง/reject) ถุงจึงเลื่อนกลับ

   หมายเหตุ
   - QR ของ placeholder = cc|grade|lot|<bag 2 หลัก>|<ตัน 3 หลัก> (QR 6 ส่วนต่อท้าย |000000)
     ถ้าภายหลังพิมพ์ QR เดิมนี้ซ้ำ pProcessInsertTrBag จะตอบ 'Duplicate QR code data.'
     (placeholder ยัง status_flag = 'A') -> ต้องกด "คืนค่า" placeholder ก่อน
   - create_datetime ของ placeholder = create_datetime ล่าสุดของถุงบนพาเลทนั้น
     ให้โผล่ใน Rejected Bags ของหน้า Pallet Adjustment ด้วยตัวกรองวันที่พิมพ์เดียวกับพาเลท
   - ใช้กับพาเลท auto (pallet_type = 'A' ที่มี ref_pallet) เท่านั้น ; พาเลท J / M ไม่มีช่องให้ reject

   Objects
     dbo.sp_PalletAdjustment_GetMissingSlots   @PalletId            -> ช่องว่างของพาเลท
     dbo.sp_PalletAdjustment_RejectMissingSlot @PalletId, @QrText   -> reject 1 ช่อง
     dbo.pProcessUpdateBagRejectStatus  (ทับ definition บน prod 2026-10-21 + ยกเลิก placeholder)

   Rollback: 98_rollback_sp_PalletAdjustment_RejectMissingSlot.sql
   Dependencies: 10_fParseBagQr.sql, 13_pServiceMatchBagToPallet.sql, 20_tr_transaction_log.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* ---------------------------------------------------------------------
   ช่องว่าง (ไม่มีแถว tr_bag) ที่ตกบนพาเลทนี้ตามลำดับ canonical ของ 13_
     กลุ่ม  = cc + grade + lot + ordinal (+ |F6) จาก tr_pallet.ref_pallet , nl = tr_pallet.unit_pallet
     pos    = (ตัน - 1) * nl + bag_no ตาม QR
     ถุงที่ครองตำแหน่ง = ถุง Y / R ทุกใบของกลุ่ม (รวมถุงจัดการด้วยมือ 3/6 ตาม QR)
     reject = R ที่ไม่ใช่ 6 และไม่มีถุงดี/ถุง 6 ครองตำแหน่งเดียวกัน (เหมือน #rj ของ 13_)
     ช่องว่างที่ pos ตกบนพาเลทนี้เมื่อ (pos - reject ก่อนหน้า - 1) / nl + 1 = ordinal
   คืน: qr_text_data , cost_center , grade , lot , qr_format , qr_ton , qr_bag_no , planned_pos
        (เรียงตาม planned_pos)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_PalletAdjustment_GetMissingSlots
    @PalletId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ref VARCHAR(100), @nl INT, @p1 INT, @p2 INT, @p3 INT, @p4 INT,
            @cc VARCHAR(20), @grade VARCHAR(30), @lot VARCHAR(20), @o INT, @fmt TINYINT, @rjc INT;

    CREATE TABLE #m (
        qr_text_data VARCHAR(100), cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20),
        qr_format TINYINT, qr_ton INT, qr_bag_no INT, planned_pos INT);

    SELECT @ref = ref_pallet, @nl = unit_pallet
    FROM   dbo.tr_pallet
    WHERE  id = @PalletId AND status_flag = 'A' AND pallet_type = 'A';

    -- ref_pallet = cc|grade|lot|<ordinal> หรือ cc|grade|lot|<ordinal>|F6
    SET @p1 = CHARINDEX('|', @ref);
    SET @p2 = CASE WHEN @p1 > 0 THEN CHARINDEX('|', @ref, @p1 + 1) ELSE 0 END;
    SET @p3 = CASE WHEN @p2 > 0 THEN CHARINDEX('|', @ref, @p2 + 1) ELSE 0 END;
    SET @p4 = CASE WHEN @p3 > 0 THEN CHARINDEX('|', @ref, @p3 + 1) ELSE 0 END;
    IF @p3 > 0
    BEGIN
        SET @cc    = SUBSTRING(@ref, 1, @p1 - 1);
        SET @grade = SUBSTRING(@ref, @p1 + 1, @p2 - @p1 - 1);
        SET @lot   = SUBSTRING(@ref, @p2 + 1, @p3 - @p2 - 1);
        SET @o     = TRY_CONVERT(INT, CASE WHEN @p4 > 0 THEN SUBSTRING(@ref, @p3 + 1, @p4 - @p3 - 1)
                                           ELSE SUBSTRING(@ref, @p3 + 1, LEN(@ref) - @p3) END);
        SET @fmt   = CASE WHEN @p4 = 0 THEN 5
                          WHEN SUBSTRING(@ref, @p4 + 1, LEN(@ref) - @p4) = 'F6' THEN 6 END;
    END

    IF @o > 0 AND @fmt IS NOT NULL AND @nl > 0
    BEGIN
        CREATE TABLE #g (pos INT NOT NULL, is_active VARCHAR(1), bag_status_id INT);
        INSERT INTO #g (pos, is_active, bag_status_id)
        SELECT (q.pallet_running_no - 1) * @nl + q.bag_no, b.is_active, b.bag_status_id
        FROM   dbo.tr_bag b
        CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
          AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
          AND  q.qr_format = @fmt
          AND  q.pallet_running_no > 0 AND q.bag_no BETWEEN 1 AND @nl
        UNION ALL
        -- ถุงจัดการด้วยมือ ใช้กลุ่มตาม QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว -- เหมือน 13_)
        SELECT (q.pallet_running_no - 1) * @nl + q.bag_no, b.is_active, b.bag_status_id
        FROM   dbo.tr_bag b
        CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A'
          AND  q.cost_center = @cc AND q.grade = @grade AND q.lot = @lot
          AND  q.qr_format = @fmt
          AND  q.pallet_running_no > 0 AND q.bag_no BETWEEN 1 AND @nl;

        CREATE TABLE #rj (pos INT PRIMARY KEY);
        INSERT INTO #rj (pos)
        SELECT DISTINCT r.pos
        FROM   #g r
        WHERE  r.is_active = 'R' AND ISNULL(r.bag_status_id, 0) <> 6
          AND  NOT EXISTS (SELECT 1 FROM #g h
                           WHERE h.pos = r.pos AND (h.is_active = 'Y' OR h.bag_status_id = 6));
        SET @rjc = (SELECT COUNT(*) FROM #rj);

        -- ตำแหน่งที่อาจตกบนพาเลทนี้ : (o-1)*nl+1 .. o*nl + จำนวน reject (reject ดึงตำแหน่งถัดไปขึ้นมา)
        ;WITH n AS (
            SELECT TOP (@nl + @rjc)
                   (@o - 1) * @nl + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pos
            FROM   sys.all_columns a CROSS JOIN sys.all_columns b
        )
        INSERT INTO #m (qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos)
        SELECT CONCAT(@cc, '|', @grade, '|', @lot, '|',
                      RIGHT(CONCAT('0', m.bag_no), CASE WHEN m.bag_no > 9 THEN LEN(m.bag_no) ELSE 2 END), '|',
                      RIGHT(CONCAT('00', m.ton), CASE WHEN m.ton > 99 THEN LEN(m.ton) ELSE 3 END),
                      CASE WHEN @fmt = 6 THEN '|000000' ELSE '' END),
               @cc, @grade, @lot, @fmt, m.ton, m.bag_no, n.pos
        FROM   n
        CROSS APPLY (SELECT (n.pos - 1) / @nl + 1                                    AS ton,
                            (n.pos - 1) % @nl + 1                                    AS bag_no,
                            n.pos - (SELECT COUNT(*) FROM #rj r WHERE r.pos < n.pos) AS good_pos) m
        WHERE  NOT EXISTS (SELECT 1 FROM #g g WHERE g.pos = n.pos)
          AND  (m.good_pos - 1) / @nl + 1 = @o;
    END

    SELECT qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos
    FROM   #m
    ORDER BY planned_pos;
END
GO

/* ---------------------------------------------------------------------
   Reject ช่องว่าง 1 ช่องของพาเลท (@QrText ต้องอยู่ในผลของ sp_PalletAdjustment_GetMissingSlots
   ณ ตอนนี้ -- ถ้ามีถุงเข้ามาแล้วจะไม่ยอม) -> INSERT placeholder (ดูหัวไฟล์) แล้ว reconcile grade
   dbResult : status / message / bag_id  (ตามด้วย 3 result set ของ pServiceMatchBagToPallet)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_PalletAdjustment_RejectMissingSlot
    @PalletId BIGINT,
    @QrText   VARCHAR(100),
    @Reason   VARCHAR(255) = NULL,
    @UserId   INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = '',
            @lk INT, @bag_id BIGINT = NULL, @need_reconcile BIT = 0,
            @cc VARCHAR(20), @grade VARCHAR(30), @lot VARCHAR(20), @ton INT,
            @create_dt DATETIME, @pallet_no VARCHAR(50),
            @LogDetail NVARCHAR(MAX) = NULL;

    DECLARE @m TABLE (
        qr_text_data VARCHAR(100), cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20),
        qr_format TINYINT, qr_ton INT, qr_bag_no INT, planned_pos INT);

    SET @QrText = LTRIM(RTRIM(@QrText));
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), '');

    IF @PalletId IS NULL OR @PalletId <= 0 OR ISNULL(@QrText, '') = ''
    BEGIN
        SELECT 'error' AS status, N'ต้องระบุพาเลทและ QR ของช่องที่จะ Reject' AS message, @bag_id AS bag_id;
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
            SELECT 'warning' AS status, N'ระบบกำลังจับคู่ถุงอยู่ กรุณาลองใหม่อีกครั้ง' AS message, @bag_id AS bag_id;
            RETURN;
        END

        INSERT INTO @m
        EXEC dbo.sp_PalletAdjustment_GetMissingSlots @PalletId = @PalletId;

        SELECT @cc = cost_center, @grade = grade, @lot = lot, @ton = qr_ton
        FROM   @m
        WHERE  qr_text_data = @QrText;

        IF @grade IS NULL
            SET @message = N'ช่อง ' + @QrText + N' ไม่ใช่ช่องว่างของพาเลทนี้แล้ว (อาจมีถุงเข้ามาแล้ว) กรุณารีเฟรช';
        ELSE IF EXISTS (SELECT 1 FROM dbo.tr_bag WHERE qr_text_data = @QrText AND status_flag = 'A')
            SET @message = N'มีข้อมูล QR ' + @QrText + N' ในระบบแล้ว';

        IF @message <> ''
        BEGIN
            ROLLBACK TRAN;
            SELECT 'error' AS status, @message AS message, @bag_id AS bag_id;
            RETURN;
        END

        SELECT @pallet_no = pallet_no FROM dbo.tr_pallet WHERE id = @PalletId;
        SELECT @create_dt = MAX(create_datetime) FROM dbo.tr_bag WHERE pallet_id = @PalletId;

        INSERT INTO dbo.tr_bag
            ( cost_center, pallet_id, pallet_running_no, ton_no, bag_no, grade, lot, qr_text_data,
              mode_id, bag_status_id, remark, is_active,
              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
        VALUES
            ( @cc, NULL, @ton, NULL, NULL, @grade, @lot, @QrText,
              9, 1, LEFT('ไม่มีข้อมูลการพิมพ์' + ISNULL(': ' + @Reason, ''), 255), 'R',
              @UserId, ISNULL(@create_dt, GETDATE()), @UserId, GETDATE(), 'A' );
        SET @bag_id = SCOPE_IDENTITY();

        SET @LogDetail = N'*' + @QrText + N'* (ไม่มีข้อมูลการพิมพ์)'
                         + ISNULL(N' ช่องว่างบน *' + @pallet_no + N'*', N'')
                         + ISNULL(N' เหตุผล: ' + @Reason, N'');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Reject Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        COMMIT TRAN;

        SET @message = N'Reject ช่อง ' + @QrText + N' สำเร็จ';
        SET @need_reconcile = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SET @status = 'error';  SET @message = ERROR_MESSAGE();  SET @bag_id = NULL;
    END CATCH

    SELECT @status AS status, @message AS message, @bag_id AS bag_id;   -- dbResult

    -- reconcile นอก transaction ของตัวเอง (เหมือน pProcessUpdateBagRejectStatus)
    IF @need_reconcile = 1
        EXEC dbo.pServiceMatchBagToPallet @grade = @grade, @create_user_id = @UserId, @preview = 0;
END
GO

/* ---------------------------------------------------------------------
   pProcessUpdateBagRejectStatus = definition บน prod (OBJECT_DEFINITION 2026-10-30,
   แก้ล่าสุด 2026-10-21 -- ไฟล์ 15_ ใน repo เก่ากว่านี้) + กิ่ง placeholder (mode_id = 9)
   ใน @reject = 0 ; ส่วนอื่นไม่เปลี่ยน
   --------------------------------------------------------------------- */
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
            @qcc VARCHAR(20), @qgrade VARCHAR(30), @qlot VARCHAR(20), @qbagno INT, @qprn INT, @qfmt TINYINT, @next_bag_id BIGINT,
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
                SET @LogDetail = N'*' + ISNULL(@qr, N'-') + N'*'
                                 + ISNULL(N' ออกจาก *' + (SELECT pallet_no FROM dbo.tr_pallet WHERE id = @cur_pallet_id) + N'*', N'')
                                 + ISNULL(N' เหตุผล: ' + NULLIF(@reason, ''), N'');

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

            -- placeholder ของช่องที่ไม่มีข้อมูลการพิมพ์ (mode_id = 9, sp_PalletAdjustment_RejectMissingSlot)
            -- ไม่ใช่ถุงจริง : "คืนค่า" = ยกเลิก placeholder ให้ช่องกลับเป็นช่องว่าง (is_active 'N', status_flag 'D')
            -- แล้วปลดถุง auto 1 ใบที่อยู่หลังช่องนี้ (ตาม QR) เป็นถุงรอจับคู่ ให้ pServiceMatchBagToPallet
            -- หยิบกลุ่มไป reconcile (#grp หยิบเฉพาะกลุ่มที่มีถุงค้าง/reject) ถุงหลังจากนั้นจึงเลื่อนกลับ
            IF EXISTS (SELECT 1 FROM dbo.tr_bag WHERE id = @bag_id AND mode_id = 9)
            BEGIN
                SELECT @qbagno = bag_no, @qprn = pallet_running_no, @qfmt = qr_format
                FROM   dbo.fParseBagQr(@qr);

                SELECT TOP 1 @next_bag_id = b.id
                FROM   dbo.tr_bag b
                CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
                WHERE  b.grade = @cur_grade AND b.cost_center = @cur_cc AND b.lot = @cur_lot
                  AND  b.status_flag = 'A' AND b.is_active = 'Y'
                  AND  b.bag_status_id = 2 AND b.pallet_id IS NOT NULL
                  AND  q.qr_format = @qfmt
                  AND  (   q.pallet_running_no > @qprn
                        OR (q.pallet_running_no = @qprn AND q.bag_no > @qbagno) )
                ORDER BY q.pallet_running_no, q.bag_no;

                BEGIN TRAN;

                UPDATE dbo.tr_bag
                SET    is_active       = 'N',
                       status_flag     = 'D',
                       update_user_id  = @create_user_id,
                       update_datetime = GETDATE()
                WHERE  id = @bag_id;

                UPDATE dbo.tr_bag
                SET    pallet_id       = NULL,
                       bag_status_id   = 1,
                       update_user_id  = @create_user_id,
                       update_datetime = GETDATE()
                WHERE  id = @next_bag_id;

                INSERT INTO @out (bag_id, action, grade, cost_center, lot,
                                  before_is_active, before_bag_status_id, before_pallet_id, before_bag_no)
                VALUES (@bag_id, 'UNREJECT', @cur_grade, @cur_cc, @cur_lot,
                       @cur_is_active, @cur_status, @cur_pallet_id, @cur_bag_no);

                SET @message = CONCAT('bag_id ', @bag_id, ' (no print data) reject cancelled - slot is empty again');

                IF @preview = 0
                BEGIN
                    SET @LogDetail = N'*' + ISNULL(@qr, N'-') + N'* (ยกเลิก Reject ช่องที่ไม่มีข้อมูลการพิมพ์)';

                    EXEC dbo.pInsertTransactionLog
                         @topic    = 'Pallet Adjustment',
                         @activity = 'Unreject Bag',
                         @detail   = @LogDetail,
                         @user_id  = @create_user_id;
                END

                IF @preview = 1 ROLLBACK TRAN; ELSE COMMIT TRAN;
            END
            ELSE
            BEGIN
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
                    SET @LogDetail = N'*' + ISNULL(@qr, N'-') + N'*';

                    EXEC dbo.pInsertTransactionLog
                         @topic    = 'Pallet Adjustment',
                         @activity = 'Unreject Bag',
                         @detail   = @LogDetail,
                         @user_id  = @create_user_id;
                END

                IF @preview = 1 ROLLBACK TRAN; ELSE COMMIT TRAN;
            END
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
