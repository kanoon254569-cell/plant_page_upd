/* =====================================================================
   Pallet Management (PWA Forklift หน้า /pallet-management)
   -----------------------------------------------------------------
   4 SP สำหรับหน้า Pallet Management ของ Forklift PWA
   (IRPC_BARCODE_FE_PWA_FL/src/app/components/pallet-management):

   1) pProcessPalletMgmtGetPallet  -- ข้อมูล Pallet + รายการถุง
        @qr_code = QR ถุง (cost_center|grade|lot|bag_no|pallet_running_no)
                   -> หา pallet ที่ถุงนั้นอยู่
                 หรือ pallet_no (รับรูปแบบ PL<code>|grade|lot|qty ได้ ใช้แค่ส่วนแรก)
   2) pProcessPalletMgmtFindBag    -- หาถุงที่จะนำมา Add / Replace (สลับ)
        สแกน QR (@qr_code) หรือกรอกเองครบ 5 ส่วน (@cost_center + @grade + @lot + @bag_no + @pallet_running_no)
        ปกติ (Add): ใช้ได้เฉพาะถุงที่มีอยู่แล้วใน tr_bag, is_active='Y', ยังไม่อยู่พาเลทใด
        @allow_on_pallet = 1 (Replace/สลับ): รับถุงที่อยู่บนพาเลทอื่นได้ด้วย แต่ห้ามอยู่บน @current_pallet_id
   3) pProcessPalletMgmtReplaceBag -- เปลี่ยน/สลับถุงบนพาเลท
        ถุงใหม่เป็นถุง orphan:
          ถุงเดิม -> Reject (is_active='R', pallet_id/bag_no=NULL, bag_status_id=6 REPLACED)
          ถุงใหม่ -> เข้าช่อง bag_no เดิม, bag_status_id=3 (MANUAL_MATCHED)
        ถุงใหม่อยู่บนพาเลทอื่น -> สลับที่กันจริง (ไม่มีถุงไหนถูก Reject):
          ถุงใหม่ -> พาเลทนี้ ช่องของถุงเดิม / ถุงเดิม -> พาเลทอื่น ช่องของถุงใหม่ (ทั้งคู่ bag_status_id=3)
        ถุงใหม่อยู่บนพาเลทเดียวกัน -> ไม่อนุญาต
        ไม่เรียก auto-reconcile (ต่างจาก pProcessUpdateBagRejectStatus) เพราะ
        ต้องการให้พาเลทคงถุงเท่าเดิม ไม่ให้ถุงอื่นเลื่อนตาม
   4) pProcessPalletMgmtEditBag    -- แก้ cost_center / grade / lot / bag_no / pallet_running_no ของถุงบนพาเลท (ต้องครบ)
        ถุงที่ถูกแก้ -> bag_status_id=3 (MANUAL_MATCHED)

   Add Bag ใช้ dbo.sp_PalletAdjustment_AddBagIn (05) เดิม ไม่สร้างซ้ำ

   bag_status_id=3 / 6 ถูก 13_pServiceMatchBagToPallet ถือเป็นถุง "จัดการด้วยมือ"
   -> auto matching ไม่ re-point ถุงเหล่านี้อีก (ดูหัวไฟล์ 13)

   Dependencies: 10_fParseBagQr.sql, 20_tr_transaction_log.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* ---------------------------------------------------------------------
   1) pProcessPalletMgmtGetPallet
   dbResult  : status / message
   dbResult1 : pallet (0-1 แถว)
   dbResult2 : bags ของพาเลท เรียงตาม bag_no
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtGetPallet]
    @qr_code VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @code VARCHAR(100) = LTRIM(RTRIM(ISNULL(@qr_code, '')));
    DECLARE @pallet_id BIGINT, @bag_pallet_id BIGINT, @bag_found BIT = 0;
    DECLARE @is_bag_qr BIT = 0;

    IF LEN(@code) = 0
    BEGIN
        SELECT 'error' AS status, N'กรุณาสแกน QR Code' AS message;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        RETURN;
    END

    --  QR ถุง = 5 ส่วน (มี '|' 4 ตัว) หรือ 6 ส่วน (format ใหม่ต่อท้าย |ddHHmm) และส่วน
    --  bag_no/pallet_running_no เป็นตัวเลข
    --  นอกนั้นถือเป็น pallet_no (เช่น PLA2609250001) -- เช็คจำนวน '|' ก่อนเรียก fParseBagQr
    IF LEN(@code) - LEN(REPLACE(@code, '|', '')) IN (4, 5)
       AND EXISTS (SELECT 1 FROM dbo.fParseBagQr(@code) q
                   WHERE q.bag_no IS NOT NULL AND q.pallet_running_no IS NOT NULL)
        SET @is_bag_qr = 1;

    IF @is_bag_qr = 1
    BEGIN
        SELECT TOP 1 @bag_found = 1, @bag_pallet_id = b.pallet_id
        FROM   dbo.tr_bag b
        WHERE  b.qr_text_data = @code
          AND  b.status_flag  = 'A'
          AND  b.is_active    = 'Y'
        ORDER BY CASE WHEN b.pallet_id IS NULL THEN 1 ELSE 0 END, b.id DESC;

        IF @bag_found = 0
        BEGIN
            SELECT 'error' AS status, N'ไม่พบถุงนี้ในระบบ' AS message;
            SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
            SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
            RETURN;
        END

        IF @bag_pallet_id IS NULL
        BEGIN
            SELECT 'error' AS status, N'ถุงนี้ยังไม่ได้อยู่บนพาเลทใด' AS message;
            SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
            SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
            RETURN;
        END

        SET @pallet_id = @bag_pallet_id;
    END
    ELSE
    BEGIN
        --  pallet_no (รูปแบบ PL<code>|grade|lot|qty ใช้แค่ส่วนแรก)
        DECLARE @pallet_no VARCHAR(100) =
            LTRIM(RTRIM(CASE WHEN CHARINDEX('|', @code) > 0 THEN LEFT(@code, CHARINDEX('|', @code) - 1) ELSE @code END));

        SELECT TOP 1 @pallet_id = p.id
        FROM   dbo.tr_pallet p
        WHERE  p.pallet_no   = @pallet_no
          AND  p.status_flag = 'A'
          AND  p.is_active   = 'Y'
        ORDER BY p.id DESC;
    END

    IF @pallet_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet WHERE id = @pallet_id AND status_flag = 'A' AND is_active = 'Y')
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลท' AS message;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        RETURN;
    END

    SELECT 'success' AS status, N'Data retrieved successfully.' AS message;

    --  grade/lot ของพาเลท: ถุงส่วนใหญ่บนพาเลท (fallback แกะจาก ref_pallet = cc|grade|lot|ordinal)
    ;WITH bags AS (
        SELECT grade, lot, cost_center
        FROM   dbo.tr_bag
        WHERE  pallet_id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    ),
    top_gl AS (
        SELECT TOP 1 grade, lot, cost_center
        FROM   bags
        GROUP BY grade, lot, cost_center
        ORDER BY COUNT(*) DESC
    )
    SELECT
        p.id,
        p.pallet_no,
        COALESCE(g.cost_center, r.cost_center) AS cost_center,
        COALESCE(g.grade, r.grade)             AS grade,
        COALESCE(g.lot, r.lot)                 AS lot,
        p.unit_pallet,
        p.unit_ratio,
        (SELECT COUNT(*) FROM bags)                               AS bag_count,
        (SELECT COUNT(*) FROM bags) * ISNULL(p.unit_ratio, 0)     AS qty,
        p.pallet_status_id,
        p.current_location_type,
        p.current_location_id
    FROM   dbo.tr_pallet p
    LEFT JOIN top_gl g ON 1 = 1
    OUTER APPLY dbo.fParseBagQr(p.ref_pallet + '|0') r   -- ref_pallet มี 4 ส่วน เติมส่วนที่ 5 ให้ parse ได้
    WHERE  p.id = @pallet_id;

    SELECT
        b.id,
        b.bag_no,
        b.pallet_running_no,     -- Ton No. (คอลัมน์ -- แก้ได้จาก Edit Bag; QR ยังเป็นค่าเดิมตามป้ายจริง)
        b.cost_center,
        b.grade,
        b.lot,
        b.qr_text_data,
        b.bag_status_id,
        p.unit_ratio AS qty
    FROM   dbo.tr_bag b
    JOIN   dbo.tr_pallet p ON p.id = b.pallet_id
    WHERE  b.pallet_id   = @pallet_id
      AND  b.is_active   = 'Y'
      AND  b.status_flag = 'A'
    ORDER BY b.bag_no, b.id;
END
GO

/* ---------------------------------------------------------------------
   2) pProcessPalletMgmtFindBag
   สแกน : @qr_code
   กรอกเอง : ต้องครบทั้ง 5 ส่วนของ QR ถุง -- @cost_center + @grade + @lot
             + @bag_no (QR ส่วนที่ 4) + @pallet_running_no (Ton No., QR ส่วนที่ 5)
             เทียบกับค่าที่แกะจาก qr_text_data (ป้ายจริง) ทุกส่วน -> ได้ถุงเดียวเสมอ
   dbResult  : status / message
   dbResult1 : ถุง orphan ที่พบ (1 แถว)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtFindBag]
    @qr_code           VARCHAR(100) = NULL,
    @cost_center       VARCHAR(20)  = NULL,
    @grade             VARCHAR(30)  = NULL,
    @lot               VARCHAR(20)  = NULL,
    @bag_no            INT          = NULL,
    @pallet_running_no INT          = NULL,
    --  1 = Replace (สลับ): รับถุงที่อยู่บนพาเลทอื่นได้ แต่ห้ามอยู่บน @current_pallet_id
    @allow_on_pallet   BIT          = 0,
    @current_pallet_id BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @qr_code     = NULLIF(LTRIM(RTRIM(@qr_code)), '');
    SET @cost_center = NULLIF(LTRIM(RTRIM(@cost_center)), '');
    SET @grade       = NULLIF(LTRIM(RTRIM(@grade)), '');
    SET @lot         = NULLIF(LTRIM(RTRIM(@lot)), '');

    --  COLLATE DATABASE_DEFAULT: temp table ใช้ collation ของ tempdb (Thai_CI_AI) ซึ่งต่างจาก
    --  IRPC_QTRACK (Thai_100_CI_AI_KS) -- ไม่ระบุจะ error collation conflict ตอน JOIN ct_grade_package_ratio
    CREATE TABLE #cand (
        id BIGINT, bag_no INT, pallet_running_no INT,
        cost_center  VARCHAR(20)  COLLATE DATABASE_DEFAULT,
        grade        VARCHAR(30)  COLLATE DATABASE_DEFAULT,
        lot          VARCHAR(20)  COLLATE DATABASE_DEFAULT,
        qr_text_data VARCHAR(100) COLLATE DATABASE_DEFAULT,
        pallet_id BIGINT,
        is_active    CHAR(1)      COLLATE DATABASE_DEFAULT);

    IF @qr_code IS NOT NULL
    BEGIN
        INSERT INTO #cand
        SELECT b.id, q.bag_no, q.pallet_running_no, b.cost_center, b.grade, b.lot,
               b.qr_text_data, b.pallet_id, b.is_active
        FROM   dbo.tr_bag b
        OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.qr_text_data = @qr_code
          AND  b.status_flag  = 'A';
    END
    ELSE IF @cost_center IS NOT NULL AND @grade IS NOT NULL AND @lot IS NOT NULL
        AND ISNULL(@bag_no, 0) > 0 AND ISNULL(@pallet_running_no, 0) > 0
    BEGIN
        --  b.grade/b.lot ช่วยให้ใช้ index ได้ + เทียบทุกส่วนกับ QR (ป้ายจริง)
        INSERT INTO #cand
        SELECT b.id, q.bag_no, q.pallet_running_no, b.cost_center, b.grade, b.lot,
               b.qr_text_data, b.pallet_id, b.is_active
        FROM   dbo.tr_bag b
        CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.grade             = @grade
          AND  b.lot               = @lot
          AND  q.cost_center       = @cost_center
          AND  q.grade             = @grade
          AND  q.lot               = @lot
          AND  q.bag_no            = @bag_no
          AND  q.pallet_running_no = @pallet_running_no
          AND  b.status_flag       = 'A';
    END
    ELSE
    BEGIN
        SELECT 'error' AS status, N'กรุณาสแกน QR ถุง หรือกรอก Cost Center, Grade, Lot, Bag No. และ Running Pallet No. (Ton No.) ให้ครบ' AS message;
        SELECT * FROM #cand;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM #cand)
    BEGIN
        SELECT 'error' AS status, N'ไม่พบถุงนี้ในระบบ' AS message;
        SELECT * FROM #cand;
        RETURN;
    END

    --  Replace (สลับ): ถุงดีที่ไม่อยู่พาเลทใด หรืออยู่บนพาเลทอื่น -- ห้ามพาเลทเดียวกัน
    IF @allow_on_pallet = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #cand
                       WHERE is_active = 'Y'
                         AND (pallet_id IS NULL OR @current_pallet_id IS NULL OR pallet_id <> @current_pallet_id))
        BEGIN
            SELECT 'error' AS status,
                   CASE WHEN EXISTS (SELECT 1 FROM #cand WHERE is_active = 'Y')
                        THEN N'ถุงนี้อยู่ในพาเลทเดียวกันอยู่แล้ว ไม่สามารถสลับได้'
                        ELSE N'ถุงนี้ถูก Reject/ยกเลิกแล้ว ไม่สามารถนำมาใช้ได้' END AS message;
            DELETE FROM #cand;
            SELECT * FROM #cand;
            RETURN;
        END

        DELETE FROM #cand
        WHERE NOT (is_active = 'Y'
                   AND (pallet_id IS NULL OR @current_pallet_id IS NULL OR pallet_id <> @current_pallet_id));
    END
    --  Add: เหลือเฉพาะถุงที่นำมาใช้ได้ (ดี + ยังไม่อยู่พาเลทใด)
    ELSE IF NOT EXISTS (SELECT 1 FROM #cand WHERE is_active = 'Y' AND pallet_id IS NULL)
    BEGIN
        DECLARE @on_pallet VARCHAR(50);
        SELECT TOP 1 @on_pallet = p.pallet_no
        FROM   #cand c JOIN dbo.tr_pallet p ON p.id = c.pallet_id
        WHERE  c.is_active = 'Y';

        SELECT 'error' AS status,
               CASE WHEN @on_pallet IS NOT NULL THEN N'ถุงนี้อยู่บนพาเลท ' + @on_pallet + N' แล้ว'
                    ELSE N'ถุงนี้ถูก Reject/ยกเลิกแล้ว ไม่สามารถนำมาใช้ได้' END AS message;
        DELETE FROM #cand;
        SELECT * FROM #cand;
        RETURN;
    END

    IF @allow_on_pallet = 0
        DELETE FROM #cand WHERE NOT (is_active = 'Y' AND pallet_id IS NULL);

    IF (SELECT COUNT(*) FROM #cand) > 1
    BEGIN
        SELECT 'error' AS status, N'พบถุงที่ตรงเงื่อนไขมากกว่า 1 ถุง กรุณาสแกน QR ถุงแทน' AS message;
        DELETE FROM #cand;
        SELECT * FROM #cand;
        RETURN;
    END

    SELECT 'success' AS status, N'Data retrieved successfully.' AS message;

    --  pallet_id / pallet_no = พาเลทที่ถุงอยู่ตอนนี้ (NULL = ถุง orphan) -- ใช้แสดงตอนสลับข้ามพาเลท
    SELECT c.id, c.bag_no, c.pallet_running_no, c.cost_center, c.grade, c.lot, c.qr_text_data,
           r.unit_ratio AS qty,
           c.pallet_id, p.pallet_no
    FROM   #cand c
    LEFT JOIN dbo.ct_grade_package_ratio r ON r.grade = c.grade
    LEFT JOIN dbo.tr_pallet p ON p.id = c.pallet_id;
END
GO

/* ---------------------------------------------------------------------
   3) pProcessPalletMgmtReplaceBag
   @ResultCode : 0 = success , > 0 = business error , -1 = system error
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtReplaceBag]
    @PalletId      BIGINT,
    @OldBagId      BIGINT,
    @NewBagId      BIGINT,
    @Reason        NVARCHAR(255) = NULL,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletNo VARCHAR(50), @SlotNo INT, @OldQr VARCHAR(100), @NewQr VARCHAR(100);
        DECLARE @NewPalletId BIGINT, @NewSlotNo INT, @NewPalletNo VARCHAR(50);

        SELECT @PalletNo = pallet_no
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @PalletNo IS NULL
        BEGIN
            SET @ResultCode = 1;  SET @ResultMessage = N'ไม่พบพาเลท';
            ROLLBACK TRANSACTION;  RETURN;
        END

        SELECT @SlotNo = bag_no, @OldQr = qr_text_data
        FROM   dbo.tr_bag WITH (UPDLOCK)
        WHERE  id = @OldBagId AND pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @OldQr IS NULL
        BEGIN
            SET @ResultCode = 2;  SET @ResultMessage = N'ไม่พบถุงเดิมบนพาเลทนี้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        --  ถุงใหม่: orphan หรืออยู่บนพาเลทอื่นก็ได้ (สลับที่กัน)
        SELECT @NewQr = qr_text_data, @NewPalletId = pallet_id, @NewSlotNo = bag_no
        FROM   dbo.tr_bag WITH (UPDLOCK)
        WHERE  id = @NewBagId AND is_active = 'Y' AND status_flag = 'A';

        IF @NewQr IS NULL
        BEGIN
            SET @ResultCode = 3;  SET @ResultMessage = N'ไม่พบข้อมูลถุงใหม่ หรือถุงถูก Reject แล้ว';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @OldBagId = @NewBagId
        BEGIN
            SET @ResultCode = 4;  SET @ResultMessage = N'ถุงใหม่ต้องไม่ใช่ถุงเดิม';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @NewPalletId = @PalletId
        BEGIN
            SET @ResultCode = 5;  SET @ResultMessage = N'ถุงใหม่อยู่ในพาเลทเดียวกัน ไม่สามารถสลับได้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        DECLARE @LogDetail NVARCHAR(MAX);

        --  ถุงใหม่อยู่บนพาเลทอื่น -> สลับที่กันจริง: ถุงเดิมไปแทนช่องของถุงใหม่ (ไม่ Reject ถุงใด)
        IF @NewPalletId IS NOT NULL
        BEGIN
            SELECT @NewPalletNo = pallet_no
            FROM   dbo.tr_pallet WITH (UPDLOCK)
            WHERE  id = @NewPalletId AND is_active = 'Y' AND status_flag = 'A';

            IF @NewPalletNo IS NULL
            BEGIN
                SET @ResultCode = 6;  SET @ResultMessage = N'ไม่พบพาเลทของถุงใหม่ หรือพาเลทถูกยกเลิกแล้ว';
                ROLLBACK TRANSACTION;  RETURN;
            END

            UPDATE dbo.tr_bag
            SET    pallet_id       = @NewPalletId,
                   bag_no          = @NewSlotNo,
                   bag_status_id   = 3,   -- MANUAL_MATCHED
                   update_user_id  = @UserId,
                   update_datetime = GETDATE()
            WHERE  id = @OldBagId;

            UPDATE dbo.tr_bag
            SET    pallet_id       = @PalletId,
                   bag_no          = @SlotNo,
                   bag_status_id   = 3,   -- MANUAL_MATCHED
                   update_user_id  = @UserId,
                   update_datetime = GETDATE()
            WHERE  id = @NewBagId;

            --  *PL002* #4 ↔ *PL001* #2  (รูปแบบ log กระชับ ดู 81_)
            SET @LogDetail = N'*' + @NewPalletNo + N'* #' + ISNULL(CAST(@NewSlotNo AS VARCHAR(10)), N'-') + N' ↔ *' + @PalletNo + N'* #' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N'-');

            EXEC dbo.pInsertTransactionLog
                 @topic    = 'Pallet Management',
                 @activity = 'Swap Bag',
                 @detail   = @LogDetail,
                 @user_id  = @UserId;

            SET @ResultCode = 0;  SET @ResultMessage = N'สลับถุงกับพาเลท ' + @NewPalletNo + N' สำเร็จ';
            COMMIT TRANSACTION;
            RETURN;
        END

        --  ถุงเดิม -> Reject (6 = REPLACED, ดู 00_master_bag_status.sql)
        UPDATE dbo.tr_bag
        SET    is_active       = 'R',
               pallet_id       = NULL,
               bag_no          = NULL,
               bag_status_id   = 6,
               remark          = COALESCE(NULLIF(LTRIM(RTRIM(@Reason)), ''), remark, N'Replace bag'),
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @OldBagId;

        --  ถุงใหม่ -> ช่องเดิม
        UPDATE dbo.tr_bag
        SET    pallet_id       = @PalletId,
               bag_no          = @SlotNo,
               bag_status_id   = 3,   -- MANUAL_MATCHED
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @NewBagId;

        --  *PL001* #2: <QR เดิม> → <QR ใหม่> (ถุงเดิม Reject) เหตุผล: ...
        SET @LogDetail = N'*' + @PalletNo + N'* #' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N'-') + N': ' + @OldQr + N' → ' + @NewQr + N' (ถุงเดิม Reject)'
                         + ISNULL(N' เหตุผล: ' + NULLIF(LTRIM(RTRIM(@Reason)), ''), N'');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Replace Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;  SET @ResultMessage = N'เปลี่ยนถุงสำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;  SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   4) pProcessPalletMgmtEditBag
   ต้องกรอกครบ: cost_center, grade, lot, bag_no, pallet_running_no (Ton No.)
   bag_no ต้องอยู่ในช่วง 1..unit_pallet และไม่ซ้ำกับถุงอื่นบนพาเลทเดียวกัน
   แก้เฉพาะคอลัมน์ของ tr_bag -- qr_text_data ไม่เปลี่ยน (ต้องตรงกับป้าย QR จริงที่ติดถุง)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtEditBag]
    @BagId           BIGINT,
    @CostCenter      VARCHAR(20),
    @BagNo           INT,
    @PalletRunningNo INT,
    @Grade           VARCHAR(30),
    @Lot             VARCHAR(20),
    @UserId          INT,
    @ResultCode      INT           OUTPUT,
    @ResultMessage   NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CostCenter = NULLIF(LTRIM(RTRIM(@CostCenter)), '');
    SET @Grade      = NULLIF(LTRIM(RTRIM(@Grade)), '');
    SET @Lot        = NULLIF(LTRIM(RTRIM(@Lot)), '');

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletId BIGINT, @PalletNo VARCHAR(50), @UnitPallet INT,
                @OldBagNo INT, @OldGrade VARCHAR(30), @OldLot VARCHAR(20),
                @OldCostCenter VARCHAR(20), @OldPalletRunningNo INT;

        SELECT @PalletId = b.pallet_id, @OldBagNo = b.bag_no, @OldGrade = b.grade, @OldLot = b.lot,
               @OldCostCenter = b.cost_center, @OldPalletRunningNo = b.pallet_running_no,
               @PalletNo = p.pallet_no, @UnitPallet = p.unit_pallet
        FROM   dbo.tr_bag b WITH (UPDLOCK)
        JOIN   dbo.tr_pallet p ON p.id = b.pallet_id
        WHERE  b.id = @BagId AND b.is_active = 'Y' AND b.status_flag = 'A';

        IF @PalletId IS NULL
        BEGIN
            SET @ResultCode = 1;  SET @ResultMessage = N'ไม่พบถุงบนพาเลท';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @CostCenter IS NULL OR @Grade IS NULL OR @Lot IS NULL
           OR ISNULL(@BagNo, 0) <= 0 OR ISNULL(@PalletRunningNo, 0) <= 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'กรุณากรอก Cost Center, Grade, Lot, Bag No. และ Running Pallet No. (Ton No.) ให้ครบ';
            ROLLBACK TRANSACTION;  RETURN;
        END

        --  รูปแบบเดียวกับ QR ถุง: cost_center 4 หลัก, bag_no 2 หลัก (1-99), Ton No. 3 หลัก (1-999)
        IF LEN(@CostCenter) > 4 OR @PalletRunningNo > 999
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'รูปแบบข้อมูลไม่ถูกต้อง (Cost Center ไม่เกิน 4 หลัก, Ton No. 1 - 999)';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @BagNo > 99 OR (@UnitPallet > 0 AND @BagNo > @UnitPallet)
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'Bag No. ต้องอยู่ระหว่าง 1 - ' + CAST(CASE WHEN ISNULL(@UnitPallet, 0) BETWEEN 1 AND 99 THEN @UnitPallet ELSE 99 END AS NVARCHAR(10));
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.tr_bag
                   WHERE pallet_id = @PalletId AND bag_no = @BagNo AND id <> @BagId
                     AND is_active = 'Y' AND status_flag = 'A')
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'Bag No. ' + CAST(@BagNo AS NVARCHAR(10)) + N' มีอยู่แล้วบนพาเลทนี้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        UPDATE dbo.tr_bag
        SET    cost_center       = @CostCenter,
               bag_no            = @BagNo,
               pallet_running_no = @PalletRunningNo,
               ton_no            = @PalletRunningNo,   -- Ton No. ที่ user กรอกเอง
               grade             = @Grade,
               lot               = @Lot,
               bag_status_id     = 3,   -- MANUAL_MATCHED
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @BagId;

        DECLARE @LogDetail NVARCHAR(MAX);
        --  *PL001* ถุง #5: Grade A → B, Ton 1 → 2   (เฉพาะช่องที่เปลี่ยน)
        SET @LogDetail = N'*' + ISNULL(@PalletNo, N'-') + N'* ถุง #' + CAST(@BagNo AS VARCHAR(10)) + N': ' + ISNULL(STUFF(
              CASE WHEN ISNULL(@OldCostCenter, '') <> @CostCenter THEN N', CC ' + ISNULL(@OldCostCenter, N'-') + N' → ' + @CostCenter ELSE N'' END
            + CASE WHEN ISNULL(@OldGrade, '') <> @Grade THEN N', Grade ' + ISNULL(@OldGrade, N'-') + N' → ' + @Grade ELSE N'' END
            + CASE WHEN ISNULL(@OldLot, '') <> @Lot THEN N', Lot ' + ISNULL(@OldLot, N'-') + N' → ' + @Lot ELSE N'' END
            + CASE WHEN ISNULL(@OldBagNo, -1) <> @BagNo THEN N', Bag ' + ISNULL(CAST(@OldBagNo AS VARCHAR(10)), N'-') + N' → ' + CAST(@BagNo AS VARCHAR(10)) ELSE N'' END
            + CASE WHEN ISNULL(@OldPalletRunningNo, -1) <> @PalletRunningNo THEN N', Ton ' + ISNULL(CAST(@OldPalletRunningNo AS VARCHAR(10)), N'-') + N' → ' + CAST(@PalletRunningNo AS VARCHAR(10)) ELSE N'' END
            , 1, 2, N''), N'ไม่มีการเปลี่ยนแปลง');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Edit Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;  SET @ResultMessage = N'แก้ไขข้อมูลสำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;  SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   Index: 13_pServiceMatchBagToPallet ค้นถุงจัดการด้วยมือ (bag_status_id 3/6)
   ทุกกลุ่มทุกรอบ -- filtered index เล็ก ไม่ต้อง scan tr_bag ทั้งตาราง
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_manual_status' AND object_id = OBJECT_ID('dbo.tr_bag'))
    CREATE NONCLUSTERED INDEX IX_tr_bag_manual_status
        ON dbo.tr_bag (bag_status_id)
        INCLUDE (qr_text_data, pallet_id, bag_no, is_active, status_flag)
        WHERE bag_status_id IN (3, 6);
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessPalletMgmtGetPallet @qr_code = '1312|1126NK|0260805036|09|001';
-- EXEC dbo.pProcessPalletMgmtGetPallet @qr_code = 'PA2609250001';
-- EXEC dbo.pProcessPalletMgmtFindBag @qr_code = '1312|1126NK|0260805036|10|001';
-- EXEC dbo.pProcessPalletMgmtFindBag @grade = '1126NK', @lot = '0260805036', @bag_no = 10;
-- EXEC dbo.pProcessPalletMgmtFindBag @qr_code = '1312|1126NK|0260805036|10|001', @allow_on_pallet = 1, @current_pallet_id = 4;
-- DECLARE @rc INT, @msg NVARCHAR(255);
-- EXEC dbo.pProcessPalletMgmtReplaceBag @PalletId = 4, @OldBagId = 100, @NewBagId = 200, @Reason = N'ถุงแตก',
--      @UserId = 1, @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT;
-- SELECT @rc, @msg;
