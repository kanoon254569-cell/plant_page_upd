/* =====================================================================
   109_dummy_pallet_transfer.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   PWA Forklift หน้า /pallet-management : เบิกของออกจาก Warehouse เป็นรายถุง ลง Dummy Pallet
   (pallet_type = 'D', PLDyyMMddNNNN -- 107_) พาเลทหมุนเวียนใช้ซ้ำ

   ย้ายของเข้า Dummy Pallet ได้จาก 3 แหล่ง -- เงื่อนไขหลัก: Grade / Lot ต้องตรงกับของที่อยู่บน dummy
   (dummy ยังว่าง -> ของชุดแรกเป็นตัวกำหนด Grade / Lot)
     1) Auto pallet / ถุงที่มี QR ข้างถุง : ต้องสแกน QR ข้างถุงทุกใบ (ไม่รับ QR พาเลท Auto)
                       -> pProcessDummyPalletAddBag (รับถุง orphan ด้วย)
     2) Manual pallet: สแกน QR พาเลท (WMS+ พิมพ์รายพาเลท มีแค่น้ำหนักรวม) + กรอกจำนวนถุง
                       -> pProcessDummyPalletTransferBags
     3) Dummy อื่น   : สแกน QR พาเลท + เลือกทั้งหมด / กรอกจำนวนถุง -> pProcessDummyPalletTransferBags
                       ย้ายตามจำนวนได้เฉพาะถุงที่ไม่มี QR ข้างถุง (แถวที่เบิกมาจาก Manual)
                       ถุงที่มี QR ข้างถุงต้องสแกนทีละใบด้วย 1)

   ไม่แก้ SP เดิม (05 AddBagIn / 80 MoveBag / 81 MergePallet) -- dummy ไม่มี unit_pallet / unit_ratio
   ทำให้ 05/80 ตอบ "ไม่พบพาเลทปลายทาง" ; แยก SP ใหม่ไม่กระทบพาเลท Auto / Manual ปกติ

   น้ำหนักบน dummy = จำนวนถุง x package ratio ตาม grade (ct_grade_package_ratio) -- 107_ / 108_
   -> ทุกแถว tr_bag บน dummy = 1 ถุง

   Manual pallet (tr_bag 1 แถวแทนทั้งพาเลท, น้ำหนักรวม = unit_pallet x unit_ratio):
     - เบิก @BagCount ถุง = @BagCount x package ratio กก. (ต้องไม่เกินน้ำหนักที่เหลือ)
     - สร้างแถว tr_bag ใหม่ @BagCount แถวบน dummy: cost_center / grade / lot / qr_text_data / mode_id
       คัดลอกจากแถวของพาเลท Manual (qr_text_data = ป้าย WMS+ เดิม ตามย้อนได้ ; ไม่ใช่ QR ถุง 5 ส่วน
       จึงไม่ชน flow สแกน QR ถุง), remark = 'Withdrawn from <PLM>' , bag_status_id = 3
     - หักน้ำหนักออกจากพาเลท Manual:
         unit_ratio = package ratio -> unit_pallet -= @BagCount
         อื่นๆ (ส่วนใหญ่ unit_pallet = 1 , unit_ratio = น้ำหนักรวม) -> unit_pallet = 1 , unit_ratio = ที่เหลือ
         เหลือ 0 -> ปิดพาเลท Manual (tr_pallet + tr_bag is_active = 'N') เหมือนต้นทางของ 81
   Dummy ต้นทาง (TransferBags): ย้ายถุงท้ายพาเลท (bag_no มากสุด) ที่ไม่มี QR ข้างถุง @BagCount ใบ
     แล้วเรียง bag_no ต้นทางที่เหลือใหม่ 1..n เหมือน 80 ; ต้นทาง Auto / อื่นๆ ไม่รับ (ต้องสแกนทีละถุง)
   QR ข้างถุง = 5 / 6 ส่วน และ fParseBagQr ได้ bag_no + pallet_running_no (เหมือน 27 / 108)

   ถุงที่ย้ายเข้า dummy: bag_status_id = 3 (MANUAL_MATCHED -> matching 13 ไม่ re-point)
   bag_no บน dummy ต่อจาก MAX(bag_no) เดิม
   @ResultCode : 0 = success , > 0 = business error , -1 = system error
   Dependencies: 107_dummy_pallet.sql, 09_ct_grade_package_ratio.sql, 10_fParseBagQr.sql, 20_tr_transaction_log.sql
   ย้อนกลับ: 109_rollback_dummy_pallet_transfer.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* ---------------------------------------------------------------------
   1) pProcessDummyPalletAddBag -- ย้ายถุง 1 ใบ (orphan หรืออยู่บนพาเลท Auto / Dummy อื่น) เข้า Dummy Pallet
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessDummyPalletAddBag]
    @BagId         BIGINT,
    @PalletId      BIGINT,          --  Dummy Pallet ปลายทาง
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

        DECLARE @PalletNo VARCHAR(30), @BagFound BIT = 0, @BagQr VARCHAR(100);
        DECLARE @SrcPalletId BIGINT, @SrcPalletNo VARCHAR(30), @SrcType VARCHAR(10), @SrcBagNo INT;
        DECLARE @BagGrade VARCHAR(30), @BagLot VARCHAR(20), @TgtGrade VARCHAR(30), @TgtLot VARCHAR(20);

        SELECT @PalletNo = pallet_no
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND pallet_type = 'D' AND is_active = 'Y' AND status_flag = 'A';

        IF @PalletNo IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบ Dummy Pallet ปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @BagFound    = 1,
               @SrcPalletId = b.pallet_id,
               @SrcBagNo    = b.bag_no,
               @BagGrade    = b.grade,
               @BagLot      = b.lot,
               @BagQr       = b.qr_text_data
        FROM   dbo.tr_bag b WITH (UPDLOCK)
        WHERE  b.id = @BagId AND b.is_active = 'Y' AND b.status_flag = 'A';

        IF @BagFound = 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'ไม่พบข้อมูลถุง หรือถุงถูก Reject/ยกเลิกแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SrcPalletId = @PalletId
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ถุงนี้อยู่บนพาเลทนี้อยู่แล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SrcPalletId IS NOT NULL
        BEGIN
            SELECT @SrcPalletNo = pallet_no, @SrcType = pallet_type
            FROM   dbo.tr_pallet WITH (UPDLOCK)
            WHERE  id = @SrcPalletId;

            --  แถวของพาเลท Manual = ทั้งพาเลท ไม่ใช่ 1 ถุง -> ต้องเบิกด้วยจำนวนถุง
            IF @SrcType = 'M'
            BEGIN
                SET @ResultCode = 4;
                SET @ResultMessage = N'ถุงนี้คือพาเลท Manual ' + ISNULL(@SrcPalletNo, N'-')
                                     + N' กรุณาสแกน QR พาเลท Manual แล้วกรอกจำนวนถุงแทน';
                ROLLBACK TRANSACTION;
                RETURN;
            END
        END

        --  Grade/Lot ของ dummy = กลุ่มที่มีถุงมากที่สุด (เหมือน 27 / 80) ; dummy ยังว่าง -> ไม่เช็ค
        SELECT TOP 1 @TgtGrade = grade, @TgtLot = lot
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot
        ORDER BY COUNT(*) DESC;

        IF @TgtGrade IS NOT NULL
           AND (UPPER(LTRIM(RTRIM(@TgtGrade))) <> UPPER(LTRIM(RTRIM(ISNULL(@BagGrade, ''))))
             OR UPPER(LTRIM(RTRIM(ISNULL(@TgtLot, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(@BagLot, '')))))
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'Grade/Lot ของถุง (' + ISNULL(@BagGrade, N'-') + N' / ' + ISNULL(@BagLot, N'-')
                                 + N') ไม่ตรงกับ Dummy Pallet (' + @TgtGrade + N' / ' + ISNULL(@TgtLot, N'-') + N')';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @AssignedBagNo = ISNULL(MAX(bag_no), 0) + 1
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        UPDATE dbo.tr_bag
        SET    pallet_id        = @PalletId,
               bag_no           = @AssignedBagNo,
               bag_status_id    = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @BagId;

        IF @SrcPalletId IS NOT NULL
        BEGIN
            --  ต้นทาง: เรียง bag_no ที่เหลือใหม่ 1..n (เหมือน 80)
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

            --  sync pallet_status_id ของต้นทาง (Auto) ตามจำนวนถุงจริง เหมือน 80 -- dummy ไม่มี unit_pallet ไม่แตะ
            UPDATE p
            SET    p.pallet_status_id = CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END,
                   p.update_user_id   = @UserId,
                   p.update_datetime  = GETDATE()
            FROM   dbo.tr_pallet p
            OUTER APPLY (
                SELECT COUNT(*) AS cnt FROM dbo.tr_bag WHERE pallet_id = p.id AND is_active = 'Y'
            ) bc
            WHERE  p.id = @SrcPalletId
              AND  p.unit_pallet IS NOT NULL
              AND  ISNULL(p.pallet_status_id, 1) IN (1, 2)
              AND  p.pallet_status_id <> CASE WHEN ISNULL(bc.cnt, 0) >= p.unit_pallet THEN 2 ELSE 1 END;
        END

        --  *PLA2610160001* #3 → *PLD2611030001* #7   |   Orphan <QR> → *PLD2611030001* #7
        DECLARE @LogDetail NVARCHAR(MAX) =
            CASE WHEN @SrcPalletId IS NULL
                 THEN N'Orphan ' + ISNULL(@BagQr, N'-')
                 ELSE N'*' + ISNULL(@SrcPalletNo, N'-') + N'* #' + ISNULL(CAST(@SrcBagNo AS VARCHAR(10)), N'-') END
            + N' → *' + @PalletNo + N'* #' + CAST(@AssignedBagNo AS VARCHAR(10));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Dummy Pallet Add Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = LEFT(ERROR_MESSAGE(), 255);
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   2) pProcessDummyPalletTransferBags -- เบิก @BagCount ถุงจากพาเลท Manual / Dummy อื่น เข้า Dummy Pallet
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessDummyPalletTransferBags]
    @SrcPalletId   BIGINT,          --  พาเลทต้นทาง (ที่สแกน QR)
    @PalletId      BIGINT,          --  Dummy Pallet ปลายทาง
    @BagCount      INT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @RemainQty     INT           OUTPUT   --  น้ำหนัก (กก.) ที่เหลือบนพาเลท Manual ต้นทาง ; Dummy = ถุงที่ย้ายตามจำนวนได้ที่เหลือ
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletNo VARCHAR(30);
        DECLARE @SrcNo VARCHAR(30), @SrcType VARCHAR(10), @SrcRatio INT, @SrcUnitPallet INT;
        DECLARE @SrcGrade VARCHAR(30), @SrcLot VARCHAR(20), @TgtGrade VARCHAR(30), @TgtLot VARCHAR(20);
        DECLARE @Base INT, @PkgRatio INT, @SrcTotal INT, @Need INT, @Avail INT;
        DECLARE @Moved TABLE (id BIGINT PRIMARY KEY, bag_no INT, create_datetime DATETIME);

        IF ISNULL(@BagCount, 0) < 1 OR @BagCount > 1000
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'จำนวนถุงต้องอยู่ระหว่าง 1 - 1000';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SrcPalletId = @PalletId
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'พาเลทต้นทางเป็นพาเลทเดียวกับปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @PalletNo = pallet_no
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND pallet_type = 'D' AND is_active = 'Y' AND status_flag = 'A';

        IF @PalletNo IS NULL
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ไม่พบ Dummy Pallet ปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @SrcNo = pallet_no, @SrcType = pallet_type, @SrcRatio = unit_ratio, @SrcUnitPallet = unit_pallet
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @SrcNo IS NULL
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'ไม่พบพาเลทต้นทาง หรือพาเลทถูกปิดแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  พาเลท Auto (ถุงมี QR ข้างถุง) ต้องสแกนทีละถุงด้วย pProcessDummyPalletAddBag
        IF ISNULL(@SrcType, '') NOT IN ('M', 'D')
        BEGIN
            SET @ResultCode = 11;
            SET @ResultMessage = N'พาเลท ' + @SrcNo + N' เป็นพาเลท Auto กรุณาสแกน QR ข้างถุงทุกใบ';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  Grade/Lot ต้นทาง / ปลายทาง = กลุ่มที่มีถุงมากที่สุด (เหมือน 27 / 80 / 81)
        SELECT TOP 1 @SrcGrade = grade, @SrcLot = lot
        FROM   dbo.tr_bag WITH (UPDLOCK)
        WHERE  pallet_id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot ORDER BY COUNT(*) DESC;

        IF @SrcGrade IS NULL
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'พาเลท ' + @SrcNo + N' ไม่มีถุงให้ย้าย';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT TOP 1 @TgtGrade = grade, @TgtLot = lot
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A'
        GROUP BY grade, lot ORDER BY COUNT(*) DESC;

        IF @TgtGrade IS NOT NULL
           AND (UPPER(LTRIM(RTRIM(@TgtGrade))) <> UPPER(LTRIM(RTRIM(@SrcGrade)))
             OR UPPER(LTRIM(RTRIM(ISNULL(@TgtLot, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(@SrcLot, '')))))
        BEGIN
            SET @ResultCode = 6;
            SET @ResultMessage = N'Grade/Lot ของพาเลท ' + @SrcNo + N' (' + @SrcGrade + N' / ' + ISNULL(@SrcLot, N'-')
                                 + N') ไม่ตรงกับ Dummy Pallet (' + @TgtGrade + N' / ' + ISNULL(@TgtLot, N'-') + N')';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @Base = ISNULL(MAX(bag_no), 0)
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        IF @SrcType = 'M'
        BEGIN
            --  ct_grade_package_ratio เก็บ grade แบบตัด space เหมือน 107_ / 108_
            SELECT @PkgRatio = unit_ratio
            FROM   dbo.ct_grade_package_ratio
            WHERE  grade = REPLACE(@SrcGrade, ' ', '');

            IF ISNULL(@PkgRatio, 0) <= 0
            BEGIN
                SET @ResultCode = 7;
                SET @ResultMessage = N'ไม่พบ Package Ratio (กก./ถุง) ของ Grade ' + @SrcGrade;
                ROLLBACK TRANSACTION;
                RETURN;
            END

            SET @SrcTotal = ISNULL(@SrcUnitPallet, 0) * ISNULL(@SrcRatio, 0);
            SET @Need     = @BagCount * @PkgRatio;

            IF @Need > @SrcTotal
            BEGIN
                SET @ResultCode = 8;
                SET @ResultMessage = N'พาเลท Manual ' + @SrcNo + N' เหลือ ' + CAST(@SrcTotal AS NVARCHAR(20)) + N' กก. ('
                                     + CAST(@SrcTotal / @PkgRatio AS NVARCHAR(20)) + N' ถุง x ' + CAST(@PkgRatio AS NVARCHAR(10))
                                     + N' กก.) ไม่พอเบิก ' + CAST(@BagCount AS NVARCHAR(10)) + N' ถุง';
                ROLLBACK TRANSACTION;
                RETURN;
            END

            --  1 แถว = 1 ถุง บน dummy -- คัดลอกข้อมูลจากแถวของพาเลท Manual (ป้าย WMS+ เดิม)
            ;WITH n AS (
                SELECT TOP (@BagCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM   sys.all_objects
            )
            INSERT INTO dbo.tr_bag
                ( cost_center, pallet_id, grade, lot, qr_text_data, mode_id, bag_no, bag_status_id, remark,
                  is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
            SELECT src.cost_center, @PalletId, src.grade, src.lot, src.qr_text_data, src.mode_id, @Base + n.i, 3,
                   LEFT(N'Withdrawn from ' + @SrcNo, 255),
                   'Y', @UserId, GETDATE(), @UserId, GETDATE(), 'A'
            FROM   n
            CROSS JOIN (
                SELECT TOP 1 cost_center, grade, lot, qr_text_data, mode_id
                FROM   dbo.tr_bag
                WHERE  pallet_id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A'
                ORDER BY id
            ) src;

            SET @RemainQty = @SrcTotal - @Need;

            IF @RemainQty = 0
            BEGIN
                --  เบิกหมดพาเลท -> ปิดพาเลท Manual (เหมือนต้นทางของ 81)
                UPDATE dbo.tr_bag
                SET    is_active       = 'N',
                       remark          = LEFT(CONCAT(NULLIF(remark, '') + ' | ', 'Withdrawn all to ', @PalletNo), 255),
                       update_user_id  = @UserId,
                       update_datetime = GETDATE()
                WHERE  pallet_id = @SrcPalletId AND is_active = 'Y' AND status_flag = 'A';

                UPDATE dbo.tr_pallet
                SET    is_active       = 'N',
                       update_user_id  = @UserId,
                       update_datetime = GETDATE()
                WHERE  id = @SrcPalletId;
            END
            ELSE IF @SrcRatio = @PkgRatio
                UPDATE dbo.tr_pallet
                SET    unit_pallet     = @SrcUnitPallet - @BagCount,
                       update_user_id  = @UserId,
                       update_datetime = GETDATE()
                WHERE  id = @SrcPalletId;
            ELSE
                --  ส่วนใหญ่ unit_pallet = 1 , unit_ratio = น้ำหนักรวม -> เก็บน้ำหนักที่เหลือไว้ที่ unit_ratio
                UPDATE dbo.tr_pallet
                SET    unit_pallet     = 1,
                       unit_ratio      = @RemainQty,
                       update_user_id  = @UserId,
                       update_datetime = GETDATE()
                WHERE  id = @SrcPalletId;
        END
        ELSE
        BEGIN
            --  ย้ายตามจำนวนได้เฉพาะแถวที่ไม่มี QR ข้างถุง (เบิกมาจาก Manual) -- ถุงที่มี QR ต้องสแกนทีละใบ
            DECLARE @Movable TABLE (id BIGINT PRIMARY KEY, bag_no INT, create_datetime DATETIME);
            INSERT INTO @Movable (id, bag_no, create_datetime)
            SELECT b.id, b.bag_no, b.create_datetime
            FROM   dbo.tr_bag b
            WHERE  b.pallet_id = @SrcPalletId AND b.is_active = 'Y' AND b.status_flag = 'A'
              AND  NOT (LEN(b.qr_text_data) - LEN(REPLACE(b.qr_text_data, '|', '')) IN (4, 5)
                        AND EXISTS (SELECT 1 FROM dbo.fParseBagQr(b.qr_text_data) q
                                    WHERE q.bag_no IS NOT NULL AND q.pallet_running_no IS NOT NULL));

            SELECT @Avail = COUNT(*) FROM @Movable;

            IF @BagCount > @Avail
            BEGIN
                SET @ResultCode = 9;
                SET @ResultMessage = CASE WHEN @Avail = 0
                    THEN N'ถุงบนพาเลท ' + @SrcNo + N' มี QR ข้างถุงทั้งหมด กรุณาสแกน QR ข้างถุงทุกใบ'
                    ELSE N'พาเลท ' + @SrcNo + N' มีถุงที่ไม่มี QR ข้างถุง ' + CAST(@Avail AS NVARCHAR(10))
                         + N' ถุง ไม่พอย้าย ' + CAST(@BagCount AS NVARCHAR(10)) + N' ถุง (ถุงที่มี QR ต้องสแกนทีละใบ)' END;
                ROLLBACK TRANSACTION;
                RETURN;
            END

            --  ย้ายถุงท้ายพาเลท (bag_no มากสุด) ก่อน
            INSERT INTO @Moved (id, bag_no, create_datetime)
            SELECT TOP (@BagCount) id, bag_no, create_datetime
            FROM   @Movable
            ORDER BY bag_no DESC, id DESC;

            --  ทุกถุงที่ย้ายต้อง Grade/Lot เดียวกัน (= ของ dummy ปลายทาง หรือของต้นทางถ้า dummy ยังว่าง)
            IF EXISTS (
                SELECT 1 FROM @Moved m JOIN dbo.tr_bag b ON b.id = m.id
                WHERE UPPER(LTRIM(RTRIM(ISNULL(b.grade, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(@TgtGrade, @SrcGrade))))
                   OR UPPER(LTRIM(RTRIM(ISNULL(b.lot, '')))) <> UPPER(LTRIM(RTRIM(ISNULL(ISNULL(@TgtLot, @SrcLot), '')))))
            BEGIN
                SET @ResultCode = 10;
                SET @ResultMessage = N'ถุงบนพาเลท ' + @SrcNo + N' มี Grade/Lot ปนกัน ไม่สามารถย้ายรวมได้';
                ROLLBACK TRANSACTION;
                RETURN;
            END

            ;WITH ordered AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY bag_no, id) AS rn FROM @Moved
            )
            UPDATE b
            SET    b.pallet_id        = @PalletId,
                   b.bag_no           = @Base + o.rn,
                   b.bag_status_id    = 3,   -- MANUAL_MATCHED
                   b.update_user_id   = @UserId,
                   b.update_datetime  = GETDATE()
            FROM   dbo.tr_bag b
            INNER JOIN ordered o ON o.id = b.id;

            --  ต้นทาง: เรียง bag_no ที่เหลือใหม่ 1..n (เหมือน 80)
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

            SET @RemainQty = @Avail - @BagCount;
        END

        --  *PLM2610250004* → *PLD2611030001* 4 ถุง 1126NK / 0260804021 (เหลือ 366 กก.)
        DECLARE @LogDetail NVARCHAR(MAX) =
            N'*' + @SrcNo + N'* → *' + @PalletNo + N'* ' + CAST(@BagCount AS NVARCHAR(10)) + N' ถุง '
            + @SrcGrade + N' / ' + ISNULL(@SrcLot, N'-')
            + N' (เหลือ ' + CAST(@RemainQty AS NVARCHAR(20)) + CASE WHEN @SrcType = 'M' THEN N' กก.)' ELSE N' ถุง)' END;

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Dummy Pallet Transfer',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'ย้าย ' + CAST(@BagCount AS NVARCHAR(10)) + N' ถุงจากพาเลท ' + @SrcNo + N' สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = LEFT(ERROR_MESSAGE(), 255);
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- DECLARE @rc INT, @msg NVARCHAR(255), @n INT;
-- EXEC dbo.pProcessDummyPalletAddBag @BagId = 9990, @PalletId = 47878, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @AssignedBagNo = @n OUTPUT;
-- EXEC dbo.pProcessDummyPalletTransferBags @SrcPalletId = 47020, @PalletId = 47878, @BagCount = 4, @UserId = 101,
--      @ResultCode = @rc OUTPUT, @ResultMessage = @msg OUTPUT, @RemainQty = @n OUTPUT;
-- SELECT @rc, @msg, @n;
