/* =====================================================================
   107_dummy_pallet.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   Dummy Pallet (Boardman หน้า /pallet-management แท็บ "Dummy Pallet")
   พาเลทเปล่าสำหรับหมุนเวียนใน Warehouse -- ใช้ตอนเบิกของออกจาก Warehouse
   ได้ทั้งของจาก Auto pallet (QR ข้างถุง) และ Manual pallet (พิมพ์เหมาทั้งพาเลท)

     tr_pallet.pallet_type = 'D'
     pallet_no = PLD + yyMMdd (วันที่สร้าง) + running 4 หลัก (PLDxxxxxxxxxx)
       running วิ่งต่อเนื่องไม่เริ่มใหม่ทุกวัน: PLD2611030001, PLD2611040002, PLD2611040003
       (ต่างจาก fGetPalletNo ที่เริ่ม 0001 ใหม่ทุกวัน ; เกิน 9999 จะเป็น 5 หลักเอง)
     ไม่มี grade/lot/ratio ตอนสร้าง (pd_group_code, unit_ratio, unit_pallet = NULL)
     ใส่ของได้แค่ Grade / Lot เดียวต่อพาเลท -- qty ใช้ package ratio ตาม grade (ct_grade_package_ratio)
     ตำแหน่งเริ่มต้น = NULL (= Bagging Area เหมือนพาเลทใหม่)

   1) pProcessGetDummyPalletList  -- รายการ dummy pallet (แบ่งหน้า) พร้อม grade / lot / qty ของถุงบนพาเลท
        dbResult  : status / message
        dbResult1 : รายการ
        dbResult2 : total_count
   2) pProcessCreateDummyPallet   -- สร้าง dummy pallet ใหม่ @Qty พาเลท (1-100) ในครั้งเดียว
        dbResult  : status / message
        dbResult1 : พาเลทที่สร้าง (id, pallet_no)
   3) pProcessClearDummyPallet    -- ล้างพาเลท: ปลด + ปิดใช้งานถุงบนพาเลท แล้วกลับ Bagging Area
                                     ให้นำไปใช้กับ Grade / Lot อื่นได้

   Flow การเบิก (forklift PWA / SP) ยังไม่ใช้ dummy pallet -- ไฟล์นี้มีแค่ส่วนของ Boardman
   Dependencies: 20_tr_transaction_log.sql (pInsertTransactionLog), 09_ct_grade_package_ratio.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--  1) รายการ dummy pallet
--     @pallet_no     : ค้นบางส่วนของเลขพาเลท (LIKE)
--     @location_type : ct_location_type.code (NULL ตำแหน่ง = 'BG-PLANT' เหมือน pProcessGetPalletList)
--     ชื่อ location ของ MWH อยู่ใน WMS -- API เติมให้ (PalletController.GetDummyPalletList)
CREATE OR ALTER PROCEDURE [dbo].[pProcessGetDummyPalletList]
    @pallet_no     NVARCHAR(100) = NULL,
    @location_type NVARCHAR(255) = NULL,
    @page          INT = 1,
    @page_size     INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @total_count INT;

    SELECT @total_count = COUNT(*)
    FROM   dbo.tr_pallet tp
    WHERE  tp.pallet_type = 'D'
      AND  tp.is_active = 'Y'
      AND  tp.status_flag = 'A'
      AND  (@pallet_no IS NULL OR tp.pallet_no LIKE '%' + @pallet_no + '%')
      AND  (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type);

    SELECT 'success' AS status,
           CASE WHEN @total_count > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    ;WITH pg AS (
        SELECT tp.id
        FROM   dbo.tr_pallet tp
        WHERE  tp.pallet_type = 'D'
          AND  tp.is_active = 'Y'
          AND  tp.status_flag = 'A'
          AND  (@pallet_no IS NULL OR tp.pallet_no LIKE '%' + @pallet_no + '%')
          AND  (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
        ORDER BY tp.create_datetime DESC, tp.id DESC
        OFFSET (@page - 1) * @page_size ROWS
        FETCH NEXT @page_size ROWS ONLY
    )
    SELECT
        tp.id                    AS id,
        tp.pallet_no             AS pallet_no,
        tp.current_location_id   AS current_location_id,
        COALESCE(clt.name, 'Bagging Area') AS location_type,
        tp.current_location_type AS location_type_code,
        COALESCE(
            cpl.bg_plant_desc COLLATE DATABASE_DEFAULT,
            rqcc.cc_desc COLLATE DATABASE_DEFAULT,
            csz.zone_name COLLATE DATABASE_DEFAULT,
            csl.cc_desc COLLATE DATABASE_DEFAULT,
            sd.dock_name COLLATE DATABASE_DEFAULT,
            vm.VEHICLE COLLATE DATABASE_DEFAULT,
            IIF(tp.current_location_id IS NULL, 'Bagging Area', NULL)
        ) AS current_location,
        tp.current_job_id        AS current_job_id,
        ISNULL(bc.bag_count, 0)  AS bag_count,
        bc.grade                 AS grade,
        bc.lot                   AS lot,
        r.unit_ratio             AS unit_ratio,
        ISNULL(bc.bag_count, 0) * ISNULL(r.unit_ratio, 0) AS qty,
        tp.create_datetime       AS create_datetime
    FROM pg
    INNER JOIN dbo.tr_pallet tp
        ON tp.id = pg.id
    --  Dummy pallet มีได้แค่ Grade / Lot เดียว (flow เบิกต้องกันไม่ให้ใส่ grade/lot อื่นเพิ่ม)
    --  -> เอา grade/lot ของถุงบนพาเลท, qty = จำนวนถุง x unit_ratio ของ grade นั้น
    OUTER APPLY (
        SELECT COUNT(*) AS bag_count, MIN(b.grade) AS grade, MIN(b.lot) AS lot
        FROM   dbo.tr_bag b
        WHERE  b.pallet_id = tp.id AND b.is_active = 'Y' AND b.status_flag = 'A'
    ) bc
    --  ct_grade_package_ratio เก็บ grade แบบตัด space เหมือน 12_/79_
    LEFT JOIN dbo.ct_grade_package_ratio r
        ON r.grade = REPLACE(bc.grade, ' ', '')
    LEFT JOIN dbo.ct_location_type clt
        ON clt.code = tp.current_location_type
        AND clt.is_active = 'Y'
        AND clt.status_flag = 'A'
    LEFT JOIN dbo.ct_bg_plant_location cpl
        ON cpl.id = tp.current_location_id
        AND cpl.is_active = 'Y'
        AND cpl.status_flag = 'A'
        AND tp.current_location_type = 'BG-PLANT'
    LEFT JOIN IRPC_E_TRANSFER.dbo.ct_request_cost_center rqcc
        ON rqcc.id = tp.current_location_id
        AND rqcc.is_active = 'Y'
        AND rqcc.status_flag = 'A'
        AND tp.current_location_type = 'RQ-PLANT'
    LEFT JOIN [IRPC].[dbo].[ct_strorage_dock] sd
        ON sd.id = tp.current_location_id
        AND sd.is_active = 'Y'
        AND sd.status_flag = 'A'
        AND tp.current_location_type = 'DOCK'
    LEFT JOIN [IRPC].[dbo].[ct_strorage_zone] csz
        ON csz.id = tp.current_location_id
        AND csz.is_active = 'Y'
        AND csz.status_flag = 'A'
        AND tp.current_location_type = 'PRE-ZONE'
    LEFT JOIN dbo.ct_special_location csl
        ON csl.id = tp.current_location_id
        AND csl.is_active = 'Y'
        AND csl.status_flag = 'A'
        AND tp.current_location_type = 'SPC-ZONE'
    LEFT JOIN [IRPC].[dbo].[VVehicleMaster] vm
        ON vm.vechicle_id = tp.current_location_id
        AND tp.current_location_type = 'VEHICLE'
    ORDER BY tp.create_datetime DESC, tp.id DESC;

    SELECT @total_count AS total_count;
END
GO

--  2) สร้าง dummy pallet @Qty พาเลท
--     เลขพาเลทคิดครั้งเดียวจาก MAX running ของ dummy pallet ทั้งหมด แล้วนับต่อ -- ถือ app lock
--     ระหว่างสร้าง กันสองคนกดพร้อมกันได้เลขซ้ำ (prefix PLD ไม่ชนกับ A/M/S/J ของ matching)
CREATE OR ALTER PROCEDURE [dbo].[pProcessCreateDummyPallet]
    @Qty    INT,
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @created TABLE (id BIGINT, pallet_no VARCHAR(50));

    IF ISNULL(@Qty, 0) < 1 OR @Qty > 100
    BEGIN
        SELECT 'error' AS status, N'จำนวนพาเลทต้องอยู่ระหว่าง 1 - 100' AS message;
        SELECT id, pallet_no FROM @created;
        RETURN;
    END

    DECLARE @prefix VARCHAR(20) = 'PLD' + FORMAT(GETDATE(), 'yyMMdd');
    DECLARE @last INT, @lk INT, @LogDetail NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @lk = sp_getapplock @Resource = 'QTRACK_CreateDummyPallet',
                                 @LockMode = 'Exclusive', @LockOwner = 'Transaction',
                                 @LockTimeout = 15000;
        IF @lk < 0
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'มีผู้ใช้อื่นกำลังสร้าง Dummy Pallet อยู่ กรุณาลองใหม่' AS message;
            SELECT id, pallet_no FROM @created;
            RETURN;
        END

        --  running no ต่อจากเลขล่าสุดของ dummy pallet ทั้งหมด ไม่เริ่มใหม่ทุกวัน
        --  (PLD2611030001 -> PLD2611040002) ; running เริ่มตัวที่ 10 หลัง 'PLD' + yyMMdd
        SELECT @last = MAX(TRY_CONVERT(INT, SUBSTRING(x.pallet_no, 10, 20)))
        FROM   dbo.tr_pallet x
        WHERE  x.pallet_type = 'D'
          AND  x.pallet_no LIKE 'PLD%';

        ;WITH n AS (
            SELECT TOP (@Qty) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
            FROM   sys.all_objects
        )
        INSERT INTO dbo.tr_pallet
            ( pallet_no, pallet_type, pallet_status_id, is_active, remark,
              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
        OUTPUT inserted.id, inserted.pallet_no INTO @created (id, pallet_no)
        SELECT @prefix + FORMAT(ISNULL(@last, 0) + n.i, 'D4'), 'D', 1, 'Y', N'Dummy pallet',
               @UserId, GETDATE(), @UserId, GETDATE(), 'A'
        FROM   n;

        --  *PLD2611030001* - *PLD2611030005* (5 พาเลท)
        SELECT @LogDetail = N'*' + MIN(pallet_no) + N'*'
                            + CASE WHEN COUNT(*) > 1 THEN N' - *' + MAX(pallet_no) + N'*' ELSE N'' END
                            + N' (' + CAST(COUNT(*) AS NVARCHAR(10)) + N' พาเลท)'
        FROM   @created;

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Create Dummy Pallet',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, LEFT(ERROR_MESSAGE(), 255) AS message;
        SELECT id, pallet_no FROM @created WHERE 1 = 0;
        RETURN;
    END CATCH

    SELECT 'success' AS status, N'สร้าง Dummy Pallet ' + CAST(@Qty AS NVARCHAR(10)) + N' พาเลทสำเร็จ' AS message;
    SELECT id, pallet_no FROM @created ORDER BY pallet_no;
END
GO

--  3) ล้าง dummy pallet ให้นำไปใช้กับ Grade / Lot อื่นได้ (หลายพาเลทได้ คั่นด้วย comma)
--     ทำทีละพาเลทคนละ transaction เหมือน 102_ -- พาเลทที่ไม่ผ่านเงื่อนไขถูกข้าม พาเลทอื่นยังล้างต่อ
--     ถุงบนพาเลท = ของที่เบิกออกไปแล้ว -> ปลดออก (pallet_id / bag_no = NULL) และปิดใช้งาน
--       (is_active = 'N') ไม่โผล่เป็นถุงค้างใน Pallet Adjustment และ matching (13_) ไม่หยิบไปจับคู่ใหม่
--       remark เก็บเลข dummy pallet เดิมไว้ให้ตามย้อนได้ ; bag_status_id ไม่เปลี่ยน
--     พาเลทกลับ Bagging Area : current_location / current_job = NULL, pallet_status_id = 1
--     ไม่ล้าง: ไม่ใช่ dummy pallet / อยู่ในงานที่ยังไม่จบ (job_status_id <> 5)
--     dbResult  : status / message
--     dbResult1 : ผลรายพาเลท (pallet_id, pallet_no, bag_count, is_success, message)
CREATE OR ALTER PROCEDURE [dbo].[pProcessClearDummyPallet]
    @PalletIds NVARCHAR(MAX),
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ids TABLE (pallet_id BIGINT PRIMARY KEY);
    DECLARE @results TABLE (pallet_id BIGINT, pallet_no VARCHAR(50), bag_count INT, is_success BIT, message NVARCHAR(255));

    INSERT INTO @ids (pallet_id)
    SELECT DISTINCT TRY_CAST(value AS BIGINT)
    FROM   STRING_SPLIT(@PalletIds, ',')
    WHERE  TRY_CAST(value AS BIGINT) > 0;

    IF NOT EXISTS (SELECT 1 FROM @ids)
    BEGIN
        SELECT 'error' AS status, N'กรุณาเลือกพาเลท' AS message;
        SELECT pallet_id, pallet_no, bag_count, is_success, message FROM @results;
        RETURN;
    END

    DECLARE @PalletId BIGINT = 0;
    DECLARE @PalletNo VARCHAR(50), @LocationType VARCHAR(10), @LocationId BIGINT, @JobId BIGINT;
    DECLARE @BagCount INT, @Grade VARCHAR(30), @Lot VARCHAR(20), @LogDetail NVARCHAR(MAX);

    WHILE 1 = 1
    BEGIN
        SELECT @PalletId = MIN(pallet_id) FROM @ids WHERE pallet_id > @PalletId;
        IF @PalletId IS NULL BREAK;

        SET @PalletNo = NULL;
        SET @LocationType = NULL;
        SET @LocationId = NULL;
        SET @JobId = NULL;
        SET @BagCount = 0;
        SET @Grade = NULL;
        SET @Lot = NULL;

        BEGIN TRY
            BEGIN TRANSACTION;

            SELECT @PalletNo = pallet_no, @LocationType = current_location_type,
                   @LocationId = current_location_id, @JobId = current_job_id
            FROM   dbo.tr_pallet WITH (UPDLOCK)
            WHERE  id = @PalletId AND pallet_type = 'D' AND is_active = 'Y' AND status_flag = 'A';

            IF @PalletNo IS NULL
            BEGIN
                INSERT INTO @results VALUES (@PalletId, NULL, 0, 0, N'ไม่พบ Dummy Pallet หรือพาเลทถูกยกเลิกแล้ว');
                ROLLBACK TRANSACTION;
                CONTINUE;
            END

            IF EXISTS (SELECT 1 FROM dbo.tr_job_main
                       WHERE id = @JobId AND job_status_id <> 5
                         AND is_active = 'Y' AND status_flag = 'A')
            BEGIN
                INSERT INTO @results VALUES (@PalletId, @PalletNo, 0, 0,
                    N'พาเลทอยู่ในงานที่ยังไม่จบ (Job ID ' + CAST(@JobId AS NVARCHAR(20)) + N') กรุณาจบงานก่อน');
                ROLLBACK TRANSACTION;
                CONTINUE;
            END

            SELECT @BagCount = COUNT(*), @Grade = MIN(grade), @Lot = MIN(lot)
            FROM   dbo.tr_bag WITH (UPDLOCK, ROWLOCK)
            WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

            UPDATE dbo.tr_bag
            SET    pallet_id       = NULL,
                   bag_no          = NULL,
                   is_active       = 'N',
                   remark          = LEFT(CONCAT(NULLIF(remark, '') + ' | ', 'Cleared from dummy ', @PalletNo), 255),
                   update_user_id  = @UserId,
                   update_datetime = GETDATE()
            WHERE  pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

            UPDATE dbo.tr_pallet
            SET    current_location_id   = NULL,
                   current_location_type = NULL,
                   current_job_id        = NULL,
                   current_job_item_id   = NULL,
                   pallet_status_id      = 1,
                   update_user_id        = @UserId,
                   update_datetime       = GETDATE()
            WHERE  id = @PalletId;

            --  *PLD2611030001*: 40 ถุง 1100NK / L1, DOCK #5 → Bagging Area
            SET @LogDetail = N'*' + @PalletNo + N'*: ' + CAST(@BagCount AS NVARCHAR(10)) + N' ถุง'
                             + ISNULL(N' ' + @Grade + N' / ' + @Lot, N'')
                             + N', ' + COALESCE(@LocationType, N'Bagging Area')
                             + ISNULL(N' #' + CAST(@LocationId AS NVARCHAR(20)), N'') + N' → Bagging Area';

            EXEC dbo.pInsertTransactionLog
                 @topic    = 'Pallet Management',
                 @activity = 'Clear Dummy Pallet',
                 @detail   = @LogDetail,
                 @user_id  = @UserId;

            COMMIT TRANSACTION;

            INSERT INTO @results VALUES (@PalletId, @PalletNo, @BagCount, 1, N'ล้างพาเลทสำเร็จ');
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            INSERT INTO @results VALUES (@PalletId, @PalletNo, 0, 0, LEFT(ERROR_MESSAGE(), 255));
        END CATCH
    END

    SELECT 'success' AS status, N'ดำเนินการเรียบร้อย' AS message;
    SELECT pallet_id, pallet_no, bag_count, is_success, message FROM @results ORDER BY pallet_id;
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessGetDummyPalletList @page = 1, @page_size = 25;
-- EXEC dbo.pProcessCreateDummyPallet @Qty = 5, @UserId = 101;
-- EXEC dbo.pProcessClearDummyPallet @PalletIds = '10,11', @UserId = 101;
