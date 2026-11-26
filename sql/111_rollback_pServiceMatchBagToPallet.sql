/* =====================================================================
   111_rollback_pServiceMatchBagToPallet.sql  (IRPC_QTRACK)
   ย้อน 111_ กลับเป็น definition ของ 97_ (unit pallet เดียวทั้ง lot)
   ถ้าย้อน ต้องย้อน 112_ ด้วย (112_rollback_sp_PalletAdjustment_GetMissingSlots.sql)
   หมายเหตุ : unit_pallet ของพาเลทจะถูกแก้กลับเป็นค่าทั้ง lot เมื่อ lot ถูกประมวลผลรอบถัดไป
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.pServiceMatchBagToPallet
    @grade            VARCHAR(30),
    @create_user_id   INT = 0,
    @max_groups       INT = 30,
    @lot_idle_minutes INT = 30,
    @preview          BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ตัวแปรทั้งหมด ประกาศครั้งเดียว (T-SQL ห้าม DECLARE ซ้ำในลูป)
    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = '',
            @n INT, @ratio INT, @lk INT,
            @cc VARCHAR(20), @lot VARCHAR(20), @fmt TINYINT, @ref_sfx VARCHAR(5),
            @o INT, @omax INT, @ref VARCHAR(100),   -- VARCHAR ให้ตรงคอลัมน์ ref_pallet -> seek IX_tr_pallet_ref ได้
            @pid BIGINT, @pno VARCHAR(50), @isclosed BIT, @nl INT,
            @lots_done INT = 0, @busy BIT = 0;      -- (97_) lot ที่ COMMIT แล้ว / lock ไม่ว่าง

    DECLARE @out TABLE (
        cost_center VARCHAR(20), lot VARCHAR(20),
        ordinal INT, pallet_id BIGINT, pallet_no VARCHAR(50),
        is_new BIT, is_closed BIT,
        matched INT,    -- ถุงดีที่ตกบนพาเลทนี้ (รวมที่อยู่ถูกอยู่แล้ว)
        changed INT,    -- ถุงที่ SP แก้ tr_bag จริงรอบนี้
        moved INT,      -- ถุงที่ย้ายมาจากพาเลทอื่น
        qr_format TINYINT);

    -- audit : ถุงที่ถูก re-point เข้า/ออก พาเลทที่ "ปิด" (ยกไปแล้ว) - ให้ warehouse ไปเทียบของจริง
    DECLARE @audit TABLE (
        cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20), bag_id BIGINT,
        planned_pos INT, from_pallet_id BIGINT, to_pallet_id BIGINT, to_slot INT, note VARCHAR(200),
        qr_format TINYINT);

    IF @max_groups IS NULL OR @max_groups <= 0 SET @max_groups = 30;

    SELECT @n = unit_pallet, @ratio = unit_ratio
    FROM   dbo.ct_grade_package_ratio WHERE grade = REPLACE(@grade, ' ', '');   -- ratio ถูก stamp แบบตัด space (ดู 12_)

    IF @n IS NULL OR @n <= 0
    BEGIN
        SELECT 'warning' AS status, CONCAT('no package ratio for grade ', @grade) AS message;
        SELECT * FROM @out;
        SELECT * FROM @audit;
        RETURN;
    END

    BEGIN TRY
        -- (97_) preview : transaction เดียวครอบทั้ง SP แล้ว ROLLBACK ตอนจบ (dry-run เหมือนเดิม)
        --       ทำจริง  : ไม่มี transaction ครอบ -- เปิด/COMMIT ทีละ lot ในลูปด้านล่าง
        IF @preview = 1 BEGIN TRAN;

        ------------------------------------------------------------
        -- groups ที่ต้องประมวลผล : มีถุงค้าง หรือ มี reject ที่ยังไม่ถูกประมวลผล
        --   (ยัง match อยู่ หรือ reject ตอนยังไม่ match ที่ bag_status_id ยังไม่เป็น 9 --
        --    ต้องหยิบกลุ่มมาด้วย เพราะถุงหลังจากนั้นต้องเลื่อนขึ้น)
        --   (97_) อ่านนอก lock ได้ : เป็นแค่รายการ lot ที่ต้องดู -- แต่ละ lot คำนวณใหม่จาก
        --         ข้อมูลล่าสุดภายใต้ lock อีกที lot ที่ถูกทำไปแล้วจะไม่มีอะไรเปลี่ยน
        ------------------------------------------------------------
        CREATE TABLE #grp (cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
                           lot         VARCHAR(20) COLLATE DATABASE_DEFAULT,
                           qr_format   TINYINT);
        INSERT INTO #grp (cost_center, lot, qr_format)
        SELECT TOP (@max_groups) x.cost_center, x.lot, x.qr_format
        FROM (
            SELECT DISTINCT b.cost_center, b.lot, ISNULL(q.qr_format, 5) AS qr_format
            FROM   dbo.tr_bag b
            OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
            WHERE  b.grade = @grade AND b.status_flag = 'A'
              AND ( (b.is_active = 'Y' AND b.bag_status_id = 1 AND b.pallet_id IS NULL)
                 OR (b.is_active = 'R' AND b.pallet_id IS NOT NULL)
                 OR (b.is_active = 'R' AND ISNULL(b.bag_status_id, 0) NOT IN (6, 9)) )
        ) x
        ORDER BY x.cost_center, x.lot, x.qr_format;

        IF NOT EXISTS (SELECT 1 FROM #grp)
        BEGIN
            IF @preview = 1 ROLLBACK TRAN;
            SELECT 'success' AS status, 'nothing to do' AS message;
            SELECT * FROM @out;  SELECT * FROM @audit;
            RETURN;
        END

        -- ถุงดีที่ "จับได้รอบนี้" + ordinal/slot ที่ควรเป็น
        --  is_fixed = 1 : ถุง "จัดการด้วยมือ" ที่นับเป็นเจ้าของช่อง แต่ห้าม re-point (ดู step 3)
        CREATE TABLE #asg (
            id BIGINT PRIMARY KEY, planned_pos INT, good_pos INT, ordinal INT, slot INT,
            cur_pallet_id BIGINT, cur_bag_no INT, cur_status INT, is_fixed BIT);
        -- แม็พ ordinal -> tr_pallet
        CREATE TABLE #pm (ordinal INT PRIMARY KEY, pallet_id BIGINT, pallet_no VARCHAR(50),
                          is_new BIT, is_closed BIT);
        -- ตำแหน่ง (planned_pos) ของถุง reject ในกลุ่ม -> ถุงหลังจากนั้นเลื่อนขึ้น
        CREATE TABLE #rj (planned_pos INT PRIMARY KEY);
        -- QR ของถุงทั้ง lot แกะครั้งเดียวต่อกลุ่ม (85_) : ตำแหน่ง '|' -> #bq_pos , ค่าที่แกะ -> #bq
        CREATE TABLE #bq_pos (id BIGINT PRIMARY KEY, qr VARCHAR(100) COLLATE Thai_100_CI_AI_KS,
                              p1 INT, p2 INT, p3 INT, p4 INT, p5 INT);
        CREATE TABLE #bq (id BIGINT PRIMARY KEY, bag_no INT, pallet_running_no INT, qr_format TINYINT);

        ------------------------------------------------------------
        -- วนแต่ละ group
        ------------------------------------------------------------
        DECLARE gc CURSOR LOCAL FAST_FORWARD FOR SELECT cost_center, lot, qr_format FROM #grp;
        OPEN gc; FETCH NEXT FROM gc INTO @cc, @lot, @fmt;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- (97_) transaction ของ lot นี้ lot เดียว + lock กันรันซ้อน (ปล่อยเองตอน COMMIT)
            BEGIN TRAN;
            EXEC @lk = sp_getapplock @Resource = 'QTRACK_MatchBagToPallet',
                                     @LockMode = 'Exclusive', @LockOwner = 'Transaction',
                                     @LockTimeout = 15000;
            IF @lk < 0
            BEGIN
                COMMIT TRAN;        -- ยังไม่ได้แก้อะไรใน lot นี้ (preview : แค่ลด nesting)
                SET @busy = 1;
                BREAK;              -- lot ที่เหลือ -> job รอบถัดไป
            END

            -- ต่อท้าย ref_pallet ของ QR format ใหม่ -- พาเลทคนละชุดกับ format เดิม
            SET @ref_sfx = CASE WHEN @fmt = 6 THEN '|F6' ELSE '' END;

            -- 0) ปลด reject ออกจากพาเลท (ยัง match อยู่) + mark 9 ให้ reject ที่ยังไม่ประมวลผล
            --    (กันไม่ให้ถูกหยิบเข้า #grp ซ้ำทุกรอบ) ; ถุง 6 (REPLACED) ไม่แตะ
            UPDATE b
            SET    b.pallet_id = NULL, b.bag_no = NULL, b.ton_no = NULL, b.bag_status_id = 9,
                   b.update_user_id = @create_user_id, b.update_datetime = GETDATE()
            FROM   dbo.tr_bag b
            OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
            WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
              AND  ISNULL(q.qr_format, 5) = @fmt
              AND  b.is_active = 'R'
              AND  ( b.pallet_id IS NOT NULL OR ISNULL(b.bag_status_id, 0) NOT IN (6, 9) );

            -- 1) (85_) แกะ QR ของถุงทั้ง lot ครั้งเดียว -> #bq ใช้ใน 2) 3) 3.1) แทน fParseBagQr
            --    ผลเท่า fParseBagQr ทุกแถว : หาตำแหน่ง '|' ต่อกันเป็นทอด (BIN2) เก็บลง #bq_pos ก่อน
            --    แล้วค่อยตัด field ด้วย guard เดียวกับ fParseBagQr -- fParseBagQr แบบ inline ขยาย
            --    CHARINDEX (collation Thai) เป็นร้อยครั้งต่อแถว ; ตำแหน่งไม่ต้อง guard เพราะแถวที่
            --    ใช้ได้ต้องมี p1..p4 > 0 ครบ (ไม่มี 0 คั่น -> ตำแหน่งเท่าแบบ guard)
            DELETE FROM #bq_pos;  DELETE FROM #bq;
            INSERT INTO #bq_pos (id, qr, p1, p2, p3, p4, p5)
            SELECT b.id, b.qr_text_data, a1.p1, a2.p2, a3.p3, a4.p4,
                   CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)
            FROM   dbo.tr_bag b
            CROSS APPLY (SELECT p1 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1
            CROSS APPLY (SELECT p2 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2
            CROSS APPLY (SELECT p3 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3
            CROSS APPLY (SELECT p4 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4
            WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot;

            INSERT INTO #bq (id, bag_no, pallet_running_no, qr_format)
            SELECT id,
                   CASE WHEN ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(qr, p3 + 1, p4 - p3 - 1)) END,
                   CASE WHEN ok = 1 AND p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(qr, p4 + 1, p5 - p4 - 1))
                        WHEN ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(qr, p4 + 1, LEN(qr) - p4)) END,
                   CASE WHEN ok = 1 AND p5 > 0 THEN 6 WHEN ok = 1 THEN 5 END
            FROM  (SELECT id, qr, p3, p4, p5,
                          ok = CASE WHEN qr IS NOT NULL AND p1 > 0 AND p2 > 0 AND p3 > 0 AND p4 > 0
                                    THEN 1 ELSE 0 END
                   FROM   #bq_pos) x;

            -- 2) unit pallet ของ lot : nl = bag_no สูงสุดใน QR ของ lot (lot เดียวกัน unit pallet เท่ากันเสมอ ;
            --    grade เดียวกันมี 40 / 60 ถุงปนกันได้) -- นับถุง Y/R ทุกใบของ cc+grade+lot ตามคอลัมน์ ทุก format
            --    + ถุงจัดการด้วยมือ (3/6) ตาม QR (คอลัมน์อาจถูก Edit Bag แก้) -- ทุก bag_no ในกลุ่ม <= nl เสมอ
            --    แยก 2 ส่วน (UNION ALL) แทน OR ให้แต่ละส่วน seek index ได้ (83_)
            --    bag_no แกะไม่ได้ทั้ง lot -> n ของ grade
            SELECT @nl = MAX(x.bno)
            FROM (
                SELECT COALESCE(q.bag_no, b.bag_no) AS bno
                FROM   dbo.tr_bag b
                JOIN   #bq q ON q.id = b.id
                WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                  AND  b.is_active IN ('Y', 'R')
                UNION ALL
                SELECT q.bag_no
                FROM   dbo.tr_bag b
                CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
                WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R')
                  AND  q.cost_center = @cc AND q.grade = @grade AND q.lot = @lot
            ) x;
            IF ISNULL(@nl, 0) <= 0 SET @nl = @n;

            -- 3) canonical : planned_pos จาก QR -> good_pos = planned_pos - จำนวน reject ก่อนหน้า
            --    -> ordinal = CEILING(good_pos / nl) , slot = ลำดับ good_pos ใน ordinal
            --    reject -> ถุงหลังจากนั้นเลื่อนขึ้นทีละ 1 ต่อเนื่องข้ามพาเลท (รวมถุงที่สแกนตามมาทีหลัง)
            --    ถุงที่ยังไม่สแกน (ไม่มีแถว) ยังครองตำแหน่ง -- จับทุกถุงที่มีแล้วทันที ไม่รอ
            --    pallet_running_no/bag_no แกะจาก qr_text_data (ข้อ 5 / ข้อ 4) ก่อน
            --    fallback : QR แกะไม่ได้ -> คอลัมน์ tr_bag.pallet_running_no (set ตอน insert ไม่ถูก SP นี้แก้)
            --               + tr_bag.bag_no -- ถุงที่ไม่มีเลขตันทั้งสองทางยังค้าง (นับใน message)
            --
            --    reject ที่นับ : is_active='R' ทุกใบในกลุ่ม ยกเว้น 6 (REPLACED ครองช่องให้ถุงใหม่)
            --    และไม่นับตำแหน่งที่มีถุงดี/ถุง fixed อยู่แล้ว (เช่น ปริ้น QR เดิมซ้ำมาแทน)
            --
            --    ถุง "จัดการด้วยมือ" (หน้า Pallet Management / Pallet Adjustment) ไม่ถูก re-point อีก:
            --    - bag_status_id = 3 (MANUAL_MATCHED) ที่อยู่บนพาเลทของกลุ่มตัวเอง (ref_pallet = cc|grade|lot|*)
            --      -> is_fixed = 1 : ยังนับครองช่องตาม QR (ถุงอื่นไม่เลื่อน) แต่ไม่แตะแถว
            --    - bag_status_id = 3 ที่อยู่บนพาเลทของกลุ่มอื่น -> ไม่นับในกลุ่มนี้เลย (ถุงย้ายออกไปแล้วจริง)
            --    - bag_status_id = 6 (REPLACED, is_active='R' ถูก Replace ออก) -> is_fixed = 1 : ครองช่องเดิมไว้
            --      ให้ถุงใหม่ที่ใส่แทน พาเลทจึงไม่เกิน unit_pallet
            --    กลุ่มของถุงจัดการด้วยมือใช้ cost_center/grade/lot จาก QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว)
            DELETE FROM #asg;  DELETE FROM #rj;
            ;WITH g AS (
                SELECT b.id,
                       COALESCE(q.pallet_running_no, b.pallet_running_no) AS prn,
                       COALESCE(q.bag_no, b.bag_no, 1)                    AS qr_bag_no,
                       b.pallet_id AS cur_pallet_id, b.bag_no AS cur_bag_no, b.bag_status_id AS cur_status,
                       CAST(0 AS BIT) AS is_fixed
                FROM   dbo.tr_bag b
                JOIN   #bq q ON q.id = b.id
                WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                  AND  ISNULL(q.qr_format, 5) = @fmt
                  AND  b.is_active = 'Y'
                  AND  ISNULL(b.bag_status_id, 1) <> 3
                  AND  COALESCE(q.pallet_running_no, b.pallet_running_no) > 0
                UNION ALL
                SELECT b.id,
                       q.pallet_running_no,
                       q.bag_no,
                       b.pallet_id, b.bag_no, b.bag_status_id,
                       CAST(1 AS BIT)
                FROM   dbo.tr_bag b
                CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
                LEFT JOIN dbo.tr_pallet p ON p.id = b.pallet_id
                WHERE  b.status_flag = 'A'
                  AND  b.is_active IN ('Y', 'R') AND b.bag_status_id IN (3, 6)   -- ซ้ำกับเงื่อนไขด้านล่าง แต่ seek index
                                                                                 -- ได้ (83_) ไม่ต้องแกะ QR ทั้งตาราง
                  AND  q.cost_center = @cc AND q.grade = @grade AND q.lot = @lot
                  AND  q.qr_format = @fmt
                  AND  q.pallet_running_no > 0 AND q.bag_no IS NOT NULL
                  AND  (   (b.bag_status_id = 6 AND b.is_active = 'R')
                        OR (b.bag_status_id = 3 AND b.is_active = 'Y'
                            AND p.ref_pallet LIKE @cc + '|' + @grade + '|' + @lot + '|%'
                            AND CASE WHEN p.ref_pallet LIKE '%|F6' THEN 6 ELSE 5 END = @fmt) )
            )
            INSERT INTO #asg (id, planned_pos, cur_pallet_id, cur_bag_no, cur_status, is_fixed)
            SELECT id,
                   (prn - 1) * @nl + CASE WHEN qr_bag_no > 0 THEN qr_bag_no ELSE 1 END,   -- ตำแหน่งตาม QR
                   cur_pallet_id, cur_bag_no, cur_status, is_fixed
            FROM   g;

            IF NOT EXISTS (SELECT 1 FROM #asg)
            BEGIN
                COMMIT TRAN;                                            -- (97_) step 0 ของ lot นี้
                SET @lots_done += 1;
                FETCH NEXT FROM gc INTO @cc, @lot, @fmt;  CONTINUE;
            END

            -- 3.1) ตำแหน่งของถุง reject (bag_no ถูก NULL ไปแล้วตอนปลด -> ใช้จาก QR เท่านั้น)
            INSERT INTO #rj (planned_pos)
            SELECT DISTINCT x.planned_pos
            FROM (
                SELECT (COALESCE(q.pallet_running_no, b.pallet_running_no) - 1) * @nl + q.bag_no AS planned_pos
                FROM   dbo.tr_bag b
                JOIN   #bq q ON q.id = b.id
                WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                  AND  ISNULL(q.qr_format, 5) = @fmt
                  AND  b.status_flag = 'A' AND b.is_active = 'R'
                  AND  ISNULL(b.bag_status_id, 0) <> 6
                  AND  COALESCE(q.pallet_running_no, b.pallet_running_no) > 0
                  AND  q.bag_no > 0
            ) x
            WHERE  NOT EXISTS (SELECT 1 FROM #asg a WHERE a.planned_pos = x.planned_pos);

            -- 3.2) good_pos = planned_pos - reject ก่อนหน้า -> ordinal (ไม่ต่ำกว่า 1 เพราะ reject ก่อนหน้า
            --      มีได้มากสุด planned_pos - 1 ตำแหน่ง)
            UPDATE a
            SET    a.good_pos = a.planned_pos - (SELECT COUNT(*) FROM #rj r WHERE r.planned_pos < a.planned_pos)
            FROM   #asg a;

            UPDATE #asg SET ordinal = (good_pos - 1) / @nl + 1;                          -- = CEILING(good_pos / nl)

            -- 3.3) slot = bag_no 1..k ต่อพาเลท ไม่เว้นช่อง
            ;WITH s AS (
                SELECT slot, ROW_NUMBER() OVER (PARTITION BY ordinal ORDER BY good_pos, id) AS rn
                FROM   #asg
            )
            UPDATE s SET slot = rn;

            -- 4) แม็พ ordinal -> tr_pallet (ต้องทีละใบ เพราะ fGetPalletNo นับ)
            DELETE FROM #pm;
            SET @o = 1;  SET @omax = (SELECT MAX(ordinal) FROM #asg);
            WHILE @o <= @omax
            BEGIN
                IF EXISTS (SELECT 1 FROM #asg WHERE ordinal = @o)
                BEGIN
                    SET @ref = CONCAT(@cc, '|', @grade, '|', @lot, '|', @o, @ref_sfx);
                    SET @pid = NULL;  SET @pno = NULL;  SET @isclosed = 0;

                    -- หาพาเลทเดิมของ ordinal นี้ "แม้จะถูกปิดไปแล้ว" (is_active='N')
                    -- is_active='N' บน tr_pallet เกิดจากขั้นที่ 8 ของ SP นี้เท่านั้น (พาเลทเปิดที่เคยว่างเปล่า)
                    -- ปลอดภัยที่จะฟื้นคืน ถ้าตอนนี้มีถุงต้องมาลงที่ ordinal เดิมอีกครั้ง (เช่น un-reject เลื่อนถุงกลับ)
                    SELECT TOP 1 @pid = p.id, @pno = p.pallet_no,
                                 @isclosed = CASE WHEN p.inbound_to_wh_id IS NOT NULL THEN 1 ELSE 0 END
                    FROM   dbo.tr_pallet p
                    WHERE  p.ref_pallet = @ref AND p.status_flag = 'A'
                    ORDER BY p.id;

                    IF @pid IS NULL
                    BEGIN
                        SET @pno = dbo.fGetPalletNo('A');
                        INSERT dbo.tr_pallet
                            ( ref_pallet, pallet_no, pallet_type, pd_group_code, unit_ratio, unit_pallet,
                              pallet_status_id, is_active, remark,
                              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
                        VALUES
                            ( @ref, @pno, 'A', 'A', @ratio, @nl,
                              1, 'Y', CONCAT('Auto match: ', @grade, ' / ', @lot, ' #', @o,
                                             CASE WHEN @fmt = 6 THEN ' (QR+time)' ELSE '' END),
                              @create_user_id, GETDATE(), @create_user_id, GETDATE(), 'A' );
                        SET @pid = SCOPE_IDENTITY();  SET @isclosed = 0;
                        INSERT INTO #pm VALUES (@o, @pid, @pno, 1, 0);
                    END
                    ELSE
                    BEGIN
                        -- ฟื้นพาเลทที่เคยถูกปิด (is_active='N') กลับมาใช้งาน เพราะกำลังจะมีถุงมาลงอีกครั้ง
                        UPDATE dbo.tr_pallet
                        SET    is_active = 'Y', update_user_id = @create_user_id, update_datetime = GETDATE()
                        WHERE  id = @pid AND is_active = 'N';

                        -- unit pallet ของ lot เปลี่ยน (เช่น ถุงใบสุดท้ายเพิ่งสแกน / พาเลทเดิมสร้างด้วย n ของ grade)
                        -- -> step 6.5 ใช้ unit_pallet นี้ตัดสิน COMPLETED
                        UPDATE dbo.tr_pallet
                        SET    unit_pallet = @nl, update_user_id = @create_user_id, update_datetime = GETDATE()
                        WHERE  id = @pid AND ISNULL(unit_pallet, -1) <> @nl;

                        INSERT INTO #pm VALUES (@o, @pid, @pno, 0, @isclosed);
                    END
                END
                SET @o += 1;
            END

            -- 5) audit : ถุงที่จะถูก re-point และเกี่ยวกับพาเลท "ปิด" (ก่อน UPDATE)
            INSERT INTO @audit (cost_center, grade, lot, bag_id, planned_pos, from_pallet_id, to_pallet_id, to_slot, note, qr_format)
            SELECT @cc, @grade, @lot, a.id, a.planned_pos, a.cur_pallet_id, pm.pallet_id, a.slot,
                   CASE WHEN pm.is_closed = 1 AND ISNULL(a.cur_pallet_id, -1) <> pm.pallet_id THEN 're-point ONTO closed pallet'
                        WHEN pm.is_closed = 1 THEN 're-number ON closed pallet'
                        ELSE 're-point OFF closed pallet' END,
                   @fmt
            FROM   #asg a
            JOIN   #pm  pm ON pm.ordinal = a.ordinal
            WHERE  a.is_fixed = 0
              AND  ( ISNULL(a.cur_pallet_id, -1) <> pm.pallet_id OR ISNULL(a.cur_bag_no, -1) <> a.slot OR a.cur_status <> 2 )
              AND  ( pm.is_closed = 1
                  OR EXISTS (SELECT 1 FROM dbo.tr_pallet p2
                             WHERE p2.id = a.cur_pallet_id AND p2.inbound_to_wh_id IS NOT NULL) );

            -- 6) re-point ถุงทุกใบให้ตรง canonical (เปิด/ปิด เหมือนกัน) + re-run ton_no = ordinal
            UPDATE b
            SET    b.pallet_id       = pm.pallet_id,
                   b.bag_no          = a.slot,
                   b.ton_no          = a.ordinal,
                   b.bag_status_id   = 2,
                   b.update_user_id  = @create_user_id,
                   b.update_datetime = GETDATE()
            FROM   dbo.tr_bag b
            JOIN   #asg a ON a.id = b.id
            JOIN   #pm  pm ON pm.ordinal = a.ordinal
            WHERE  a.is_fixed = 0
              AND  (   ISNULL(b.pallet_id, -1) <> pm.pallet_id
                    OR ISNULL(b.bag_no, -1)    <> a.slot
                    OR ISNULL(b.ton_no, -1)    <> a.ordinal
                    OR b.bag_status_id         <> 2 );

            -- 7) สรุปต่อพาเลท
            INSERT INTO @out (cost_center, lot, ordinal, pallet_id, pallet_no, is_new, is_closed, matched, changed, moved, qr_format)
            SELECT @cc, @lot, pm.ordinal, pm.pallet_id, pm.pallet_no, pm.is_new, pm.is_closed,
                   COUNT(a.id),
                   SUM(CASE WHEN a.is_fixed = 0
                             AND ( ISNULL(a.cur_pallet_id, -1) <> pm.pallet_id
                                OR ISNULL(a.cur_bag_no, -1) <> a.slot
                                OR a.cur_status <> 2 ) THEN 1 ELSE 0 END),
                   SUM(CASE WHEN a.is_fixed = 0 AND ISNULL(a.cur_pallet_id, -1) NOT IN (-1, pm.pallet_id) THEN 1 ELSE 0 END),
                   @fmt
            FROM   #pm pm
            JOIN   #asg a ON a.ordinal = pm.ordinal
            GROUP BY pm.ordinal, pm.pallet_id, pm.pallet_no, pm.is_new, pm.is_closed;

            COMMIT TRAN;                                                -- (97_) จบ lot นี้ -> ปล่อย lock ทันที
            SET @lots_done += 1;

            FETCH NEXT FROM gc INTO @cc, @lot, @fmt;
        END
        CLOSE gc;  DEALLOCATE gc;

        ------------------------------------------------------------
        -- 6.5) sync pallet_status_id (dbo.ct_pallet_status: 1=CREATED, 2=COMPLETED)
        --      ของ "ทุกพาเลทของ grade นี้" ไม่ใช่แค่พาเลทที่ถูกประมวลผลรอบนี้ (#pm) --
        --      #pm มีแค่พาเลทของกลุ่ม (cost_center,lot) ที่ #grp หยิบมา (คือกลุ่มที่ยังมี
        --      ถุงค้าง/reject เหลืออยู่ ณ ตอนต้น SP เท่านั้น) พาเลทที่ครบแล้วเต็มที่และ
        --      ไม่มีถุงค้าง/reject เหลือในกลุ่มเดียวกันเลยจะไม่ถูกหยิบเข้า #grp อีกต่อไป
        --      -- ทำให้ step เดิม (ที่ scope แค่ #pm) ไม่มีวันเห็น/แก้พาเลทนั้นอีกเลย แม้จะ
        --      ครบจำนวนถุงจริงแล้วก็ตาม จึงย้ายมาสแกนทั้ง grade ตรงนี้แทน (pattern เดียว
        --      กับ step 8 ด้านล่างที่สแกนทั้ง grade เหมือนกัน)
        --      ไม่แตะพาเลทที่ถูก 3=CONFIRMED (ยืนยันพาเลทเศษผ่านหน้า Pallet Adjustment
        --      แล้ว) หรือ 4=VOID (ยกเลิก) ไม่ว่ากรณีใด -- คงสถานะที่ผู้ใช้ยืนยัน/ยกเลิก
        --      ไว้แล้วเสมอ แม้ auto-matching จะรันซ้ำกี่ครั้งก็ตาม
        --      (97_) transaction แยกของตัวเอง ; ข้ามถ้า lock ไม่ว่าง (lot ยังทำไม่ครบ -> รอบหน้า)
        ------------------------------------------------------------
        IF @busy = 0
        BEGIN
            BEGIN TRAN;
            EXEC @lk = sp_getapplock @Resource = 'QTRACK_MatchBagToPallet',
                                     @LockMode = 'Exclusive', @LockOwner = 'Transaction',
                                     @LockTimeout = 15000;
            IF @lk < 0
                SET @busy = 1;
            ELSE
            BEGIN
                --  เริ่มจากพาเลท (น้อยกว่าถุงหลายสิบเท่า) แล้วนับถุงต่อพาเลทด้วย index pallet_id (83_)
                --  แทนการ GROUP BY ถุงทั้ง grade ทุกรอบ ; cnt > 0 = เทียบเท่า INNER JOIN เดิม
                UPDATE p
                SET    p.pallet_status_id = CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END,
                       p.update_user_id   = @create_user_id,
                       p.update_datetime  = GETDATE()
                FROM   dbo.tr_pallet p
                CROSS APPLY (
                    SELECT COUNT(*) AS cnt
                    FROM   dbo.tr_bag x
                    WHERE  x.pallet_id = p.id AND x.grade = @grade AND x.is_active = 'Y'
                ) bc
                WHERE  p.pallet_type = 'A' AND p.status_flag = 'A' AND p.is_active = 'Y'
                  AND  p.ref_pallet LIKE '%|' + @grade + '|%'
                  AND  ISNULL(p.pallet_status_id, 1) IN (1, 2)
                  AND  bc.cnt > 0
                  AND  p.pallet_status_id <> CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END;

                ------------------------------------------------------------
                -- 8) พาเลท "เปิด" ของ grade นี้ที่ไม่เหลือถุง -> ปิด (is_active='N') ; พาเลทปิดไม่แตะ
                ------------------------------------------------------------
                UPDATE p
                SET    p.is_active = 'N', p.update_user_id = @create_user_id, p.update_datetime = GETDATE()
                FROM   dbo.tr_pallet p
                WHERE  p.pallet_type = 'A' AND p.status_flag = 'A' AND p.is_active = 'Y'
                  AND  p.inbound_to_wh_id IS NULL
                  AND  p.ref_pallet LIKE '%|' + @grade + '|%'
                  AND  NOT EXISTS (SELECT 1 FROM dbo.tr_bag x WHERE x.pallet_id = p.id);
            END
            COMMIT TRAN;
        END

        IF @busy = 1 SET @status = 'warning';
        SET @message = CONCAT(CASE WHEN @busy = 1 THEN 'busy, another run in progress - stopped early; ' ELSE '' END,
                              'groups=', (SELECT COUNT(*) FROM #grp),
                              ' lots_done=', @lots_done,
                              ' pallets=', (SELECT COUNT(*) FROM @out),
                              ' closed_touched=', (SELECT COUNT(*) FROM @audit),
                              ' unmatched=', (SELECT COUNT(*) FROM dbo.tr_bag b
                                              OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
                                              JOIN #grp g ON g.cost_center = b.cost_center AND g.lot = b.lot
                                                         AND g.qr_format = ISNULL(q.qr_format, 5)
                                              WHERE b.grade = @grade AND b.status_flag = 'A'
                                                AND b.is_active = 'Y' AND b.bag_status_id = 1
                                                AND b.pallet_id IS NULL));

        IF @preview = 1 ROLLBACK TRAN;      -- (97_) ทำจริง : COMMIT ไปทีละ lot แล้ว ไม่มี transaction ค้าง
    END TRY
    BEGIN CATCH
        -- (97_) ทำจริง : ย้อนแค่ lot ที่กำลังทำ ; lot ก่อนหน้า COMMIT ไปแล้ว
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        IF CURSOR_STATUS('local', 'gc') >= 0 BEGIN CLOSE gc;  DEALLOCATE gc; END
        SET @status = 'error';
        SET @message = CONCAT(CASE WHEN @preview = 0 THEN CONCAT('lots_committed_before_error=', @lots_done, ' : ') ELSE '' END,
                              ERROR_MESSAGE());
    END CATCH

    SELECT @status AS status, @message AS message;                        -- dbResult
    SELECT * FROM @out   ORDER BY cost_center, lot, qr_format, ordinal;      -- dbResult1
    SELECT * FROM @audit ORDER BY cost_center, lot, qr_format, planned_pos;  -- dbResult2
END
GO
SET NOEXEC OFF;
GO

-- ทดสอบ (dry-run ก่อน แล้วค่อยทำจริง) :
-- EXEC dbo.pServiceMatchBagToPallet @grade = '1126NK', @create_user_id = 0, @preview = 1;
-- EXEC dbo.pServiceMatchBagToPallet @grade = '1126NK', @create_user_id = 0, @preview = 0;
