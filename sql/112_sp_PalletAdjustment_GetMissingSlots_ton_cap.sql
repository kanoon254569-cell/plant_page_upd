/* =====================================================================
   112_sp_PalletAdjustment_GetMissingSlots_ton_cap.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   คู่กับ 111_pServiceMatchBagToPallet_ton_cap.sql : lot เดียวกันมีตัน 40 / 60 ถุงปนกัน
   110_ คิดทุกตันเป็น unit_pallet ของพาเลทที่เลือก -> lot ปนขนาด ช่องว่างผิดตำแหน่ง/ผิดตัน
   แก้ : ใช้ขนาดต่อตันแบบเดียวกับ 111_ ทุกอย่าง
     - cap ของตัน = bag_no สูงสุดใน QR ของตัน ปัดขึ้นเป็นขนาดมาตรฐาน (40 , 60 , unit_pallet ของ grade)
       เกินทุกขนาด -> bag_no สูงสุด ; ตันที่ไม่มีถุง -> ตันก่อนหน้า -> ตันถัดไป -> unit_pallet ของ grade
     - pos = ผลรวม cap ของตันก่อนหน้า + bag_no ; ตันของ good_pos = ตันแรกที่ cum_end >= good_pos
     - ตันหลังตันสุดท้ายที่มีถุง (ช่องที่ reject ดึงขึ้นมา) ใช้ขนาดของตันสุดท้าย
   ตัน 60 ที่ถุงท้ายหาย (เช่น 58-60) -> cap 60 -> ช่อง 58-60 ยังแสดงเป็นช่องว่าง (กด Reject / เพิ่มข้อมูลได้)
   ผลลัพธ์ / คอลัมน์ / ลำดับ เหมือน 110_ (ผู้เรียก INSERT ... EXEC ได้เหมือนเดิม : 98_ / 103_)
   แกะ QR ครั้งเดียวแบบ 110_ (BIN2)

   Rollback: 112_rollback_sp_PalletAdjustment_GetMissingSlots.sql (= 110_)
   Dependencies: 98_sp_PalletAdjustment_RejectMissingSlot.sql ; deploy คู่กับ 111_
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.sp_PalletAdjustment_GetMissingSlots
    @PalletId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ref VARCHAR(100), @n INT, @p1 INT, @p2 INT, @p3 INT, @p4 INT,
            @cc VARCHAR(20), @grade VARCHAR(30), @lot VARCHAR(20), @o INT, @fmt TINYINT, @rjc INT,
            @pmax INT, @ptop INT, @from INT, @to INT;

    CREATE TABLE #m (
        qr_text_data VARCHAR(100), cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20),
        qr_format TINYINT, qr_ton INT, qr_bag_no INT, planned_pos INT);

    SELECT @ref = ref_pallet, @n = unit_pallet
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

    -- unit_pallet ของ grade (เหมือน 111_) ; ไม่มี -> unit_pallet ของพาเลทนี้
    SELECT @n = ISNULL(NULLIF(r.unit_pallet, 0), @n)
    FROM   dbo.ct_grade_package_ratio r
    WHERE  r.grade = REPLACE(@grade, ' ', '');

    IF @o > 0 AND @fmt IS NOT NULL AND @n > 0
    BEGIN
        DECLARE @std TABLE (s INT PRIMARY KEY);
        INSERT INTO @std (s) SELECT DISTINCT v FROM (VALUES (40), (60), (@n)) x(v);

        -- 1) ตำแหน่ง '|' ของ QR : ถุง Y/R ของกลุ่มตามคอลัมน์ (src 1) + ถุงจัดการด้วยมือ 3/6 (src 2 กรองกลุ่มตาม QR ทีหลัง)
        CREATE TABLE #qp (src TINYINT NOT NULL, qr VARCHAR(100), is_active VARCHAR(1), bag_status_id INT,
                          p1 INT, p2 INT, p3 INT, p4 INT, p5 INT);

        INSERT INTO #qp (src, qr, is_active, bag_status_id, p1, p2, p3, p4, p5)
        SELECT 1, b.qr_text_data, b.is_active, b.bag_status_id, a1.p1, a2.p2, a3.p3, a4.p4,
               CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)
        FROM   dbo.tr_bag b
        CROSS APPLY (SELECT p1 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1
        CROSS APPLY (SELECT p2 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2
        CROSS APPLY (SELECT p3 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3
        CROSS APPLY (SELECT p4 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4
        WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
          AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
        UNION ALL
        SELECT 2, b.qr_text_data, b.is_active, b.bag_status_id, a1.p1, a2.p2, a3.p3, a4.p4,
               CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)
        FROM   dbo.tr_bag b
        CROSS APPLY (SELECT p1 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1
        CROSS APPLY (SELECT p2 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2
        CROSS APPLY (SELECT p3 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3
        CROSS APPLY (SELECT p4 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4
        WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A';

        -- 2) ตัด field ด้วย guard เดียวกับ fParseBagQr -> ตัน / bag_no ของถุงในกลุ่ม
        --    ทุก SUBSTRING ครอบ CASE WHEN ok = 1 (กัน Msg 537 ถ้า plan คำนวณก่อนกรอง -- ดู 10_)
        CREATE TABLE #g (ton INT NOT NULL, bag_no INT NOT NULL, pos INT NULL, is_active VARCHAR(1), bag_status_id INT);

        INSERT INTO #g (ton, bag_no, is_active, bag_status_id)
        SELECT y.ton, y.bag_no, y.is_active, y.bag_status_id
        FROM  (SELECT x.src, x.is_active, x.bag_status_id,
                      bag_no    = CASE WHEN x.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(x.qr, x.p3 + 1, x.p4 - x.p3 - 1)) END,
                      ton       = CASE WHEN x.ok = 1 AND x.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(x.qr, x.p4 + 1, x.p5 - x.p4 - 1))
                                       WHEN x.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(x.qr, x.p4 + 1, LEN(x.qr) - x.p4)) END,
                      qr_format = CASE WHEN x.ok = 1 AND x.p5 > 0 THEN 6 WHEN x.ok = 1 THEN 5 END,
                      q_cc      = CASE WHEN x.ok = 1 AND x.src = 2 THEN SUBSTRING(x.qr, 1, x.p1 - 1) END,
                      q_grade   = CASE WHEN x.ok = 1 AND x.src = 2 THEN SUBSTRING(x.qr, x.p1 + 1, x.p2 - x.p1 - 1) END,
                      q_lot     = CASE WHEN x.ok = 1 AND x.src = 2 THEN SUBSTRING(x.qr, x.p2 + 1, x.p3 - x.p2 - 1) END
               FROM  (SELECT q.*, ok = CASE WHEN q.qr IS NOT NULL AND q.p1 > 0 AND q.p2 > 0 AND q.p3 > 0 AND q.p4 > 0
                                            THEN 1 ELSE 0 END
                      FROM   #qp q) x) y
        WHERE  y.qr_format = @fmt
          AND  y.ton > 0 AND y.bag_no >= 1
          -- ถุงจัดการด้วยมือ ใช้กลุ่มตาม QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว -- เหมือน 13_)
          AND  (y.src = 1 OR (y.q_cc = @cc AND y.q_grade = @grade AND y.q_lot = @lot));

        -- 3) reject ที่นับ (ตามตัน/bag_no) : R ยกเว้น 6 และไม่นับช่องที่มีถุงดี/ถุง 6 อยู่
        CREATE TABLE #rk (ton INT NOT NULL, bag_no INT NOT NULL, PRIMARY KEY (ton, bag_no));
        INSERT INTO #rk (ton, bag_no)
        SELECT DISTINCT r.ton, r.bag_no
        FROM   #g r
        WHERE  r.is_active = 'R' AND ISNULL(r.bag_status_id, 0) <> 6
          AND  NOT EXISTS (SELECT 1 FROM #g h
                           WHERE h.ton = r.ton AND h.bag_no = r.bag_no
                             AND (h.is_active = 'Y' OR h.bag_status_id = 6));
        SET @rjc = (SELECT COUNT(*) FROM #rk);

        -- 4) ขนาดต่อตัน (เหมือน 111_) : ตัน 1 .. max(ตันสูงสุด , พาเลทนี้ + reject + 1)
        --    ตันหลังตันที่มีถุง ครอบตำแหน่งที่ reject ดึงขึ้นมา (ทุกตัน >= 1 ช่อง -> พอเสมอ)
        CREATE TABLE #cap (prn INT PRIMARY KEY, mx INT, cap INT, cum_before INT, cum_end INT);
        INSERT INTO #cap (prn, mx)
        SELECT ton, MAX(bag_no) FROM #g GROUP BY ton;

        SET @pmax = ISNULL((SELECT MAX(prn) FROM #cap), 0);
        SET @ptop = CASE WHEN @pmax > @o + @rjc + 1 THEN @pmax ELSE @o + @rjc + 1 END;
        INSERT INTO #cap (prn)
        SELECT n.prn
        FROM  (SELECT TOP (@ptop) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS prn
               FROM   sys.all_columns a CROSS JOIN sys.all_columns b) n
        WHERE  NOT EXISTS (SELECT 1 FROM #cap c WHERE c.prn = n.prn);

        UPDATE c SET c.cap = ISNULL((SELECT MIN(s.s) FROM @std s WHERE s.s >= c.mx), c.mx)
        FROM   #cap c WHERE c.mx > 0;
        UPDATE c
        SET    c.cap = COALESCE(
                   (SELECT TOP 1 p.cap FROM #cap p WHERE p.prn < c.prn AND p.cap > 0 ORDER BY p.prn DESC),
                   (SELECT TOP 1 p.cap FROM #cap p WHERE p.prn > c.prn AND p.cap > 0 ORDER BY p.prn),
                   @n)
        FROM   #cap c WHERE c.cap IS NULL;

        ;WITH c AS (
            SELECT cap, cum_before, cum_end,
                   SUM(cap) OVER (ORDER BY prn ROWS UNBOUNDED PRECEDING) AS run
            FROM   #cap
        )
        UPDATE c SET cum_end = run, cum_before = run - cap;

        -- 5) ตำแหน่งของถุง / reject
        UPDATE g SET g.pos = c.cum_before + g.bag_no
        FROM   #g g JOIN #cap c ON c.prn = g.ton;
        CREATE CLUSTERED INDEX cx ON #g (pos);

        CREATE TABLE #rj (pos INT PRIMARY KEY);
        INSERT INTO #rj (pos)
        SELECT c.cum_before + r.bag_no FROM #rk r JOIN #cap c ON c.prn = r.ton;

        -- 6) ตำแหน่งที่อาจตกบนพาเลทนี้ : ช่วงของตัน o .. + จำนวน reject (reject ดึงตำแหน่งถัดไปขึ้นมา)
        SELECT @from = cum_before + 1, @to = cum_end + @rjc FROM #cap WHERE prn = @o;

        ;WITH n AS (
            SELECT TOP (@to - @from + 1)
                   @from - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pos
            FROM   sys.all_columns a CROSS JOIN sys.all_columns b
        )
        INSERT INTO #m (qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos)
        SELECT CONCAT(@cc, '|', @grade, '|', @lot, '|',
                      RIGHT(CONCAT('0', m.bag_no), CASE WHEN m.bag_no > 9 THEN LEN(m.bag_no) ELSE 2 END), '|',
                      RIGHT(CONCAT('00', m.ton), CASE WHEN m.ton > 99 THEN LEN(m.ton) ELSE 3 END),
                      CASE WHEN @fmt = 6 THEN '|000000' ELSE '' END),
               @cc, @grade, @lot, @fmt, m.ton, m.bag_no, n.pos
        FROM   n
        CROSS APPLY (SELECT TOP 1 c.prn AS ton, n.pos - c.cum_before AS bag_no
                     FROM #cap c WHERE c.cum_end >= n.pos ORDER BY c.prn) m
        CROSS APPLY (SELECT n.pos - (SELECT COUNT(*) FROM #rj r WHERE r.pos < n.pos) AS good_pos) gp
        WHERE  NOT EXISTS (SELECT 1 FROM #g g WHERE g.pos = n.pos)
          AND  (SELECT MIN(c.prn) FROM #cap c WHERE c.cum_end >= gp.good_pos) = @o;
    END

    SELECT qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos
    FROM   #m
    ORDER BY planned_pos;
END
GO
