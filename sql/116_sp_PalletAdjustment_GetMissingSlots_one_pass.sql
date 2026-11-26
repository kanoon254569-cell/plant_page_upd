/* =====================================================================
   116_sp_PalletAdjustment_GetMissingSlots_one_pass.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   ต่อจาก 112_ (logic ขนาดต่อตัน / ช่วงตัน เหมือนเดิมทุกอย่าง) -- ลดเวลา GET pallet-adjustment/bag
   วัดบน prod 2026-11-11 (112_) : lot 760 ถุง ~70 ms , lot 7,472 ถุง ~340 ms
     ต้นทุนหลัก = แกะ QR ทุกถุงใน lot ลง #qp แล้ว #g (INSERT ทุกแถว) + UPDATE #g.pos + index
   แก้ (ผลลัพธ์เหมือน 112_ ทุกแถว -- ตรวจบน prod แล้ว) :
     - src 1 (ถุง Y/R ของกลุ่มตามคอลัมน์) : QR ขึ้นต้นด้วย 'cc|grade|lot|' ของพาเลท (เทียบ Thai_BIN2)
         -> แกะแค่ท้าย 'bag|ton[|time]' ; ไม่ตรง prefix -> แกะเต็มแบบเดิม (fallback)
     - src 2 (ถุงจัดการด้วยมือ 3/6 กลุ่มตาม QR) แกะเต็มแบบเดิม
     - GROUP BY GROUPING SETS ครั้งเดียว -> #agg เก็บแค่
         (ton)          = bag_no สูงสุดของตัน (#cap)
         (ton, bag_no)  = ตำแหน่ง reject ที่นับ (#rk : มี R ยกเว้น 6 และไม่มีถุง Y / 6 ครอง)
                        + ตำแหน่งที่มีถุงของตัน @o .. @o + @rub (#gp : ใช้แค่ NOT EXISTS ในช่วง @from .. @to)
       @rub = จำนวนถุง R ของกลุ่ม (>= จำนวน reject ที่นับ @rjc) ; ทุกตันมี >= 1 ช่อง
         -> ช่วง @from .. @to (= cum_before(@o) + 1 .. cum_end(@o) + @rjc) อยู่ในตัน @o .. @o + @rjc เสมอ
     - ตำแหน่ง '|' หาจาก qr_text_data COLLATE Thai_BIN2 ; ค่า cc / grade / lot ที่เทียบ ใช้ collation เดิม (CI)
       ทุก SUBSTRING ครอบ CASE (กัน Msg 537 -- ดู 10_)
   ผลลัพธ์ / คอลัมน์ / ลำดับ เหมือน 112_ (ผู้เรียก INSERT ... EXEC ได้เหมือนเดิม : 98_ / 103_)

   Rollback: 116_rollback_sp_PalletAdjustment_GetMissingSlots.sql (= 112_ = definition บน prod 2026-11-11)
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
            @pmax INT, @ptop INT, @from INT, @to INT, @pre VARCHAR(100), @L INT, @rub INT;

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

        -- prefix ของกลุ่ม (fast path) ; cc / grade / lot มี '|' -> ปิด fast path (แกะเต็มทุกถุง)
        --   (@cc / @grade / @lot ตัดจาก ref_pallet ระหว่าง '|' จึงไม่มี '|' อยู่แล้ว -- กันไว้เผื่อ)
        SET @pre = CASE WHEN CHARINDEX('|', CONCAT(@cc, @grade, @lot)) = 0
                        THEN CONCAT(@cc, '|', @grade, '|', @lot, '|') END;
        SET @L   = ISNULL(DATALENGTH(@pre), 0);

        -- ขอบบนของจำนวน reject ที่นับ : ถุง R ทั้งหมดของกลุ่ม (src 1 ตามคอลัมน์ + src 2 ถุงจัดการด้วยมือ)
        SET @rub = (SELECT COUNT(*) FROM dbo.tr_bag b
                    WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                      AND  b.status_flag = 'A' AND b.is_active = 'R')
                 + (SELECT COUNT(*) FROM dbo.tr_bag b
                    WHERE  b.bag_status_id IN (3, 6) AND b.is_active = 'R' AND b.status_flag = 'A');

        -- 1) ถุงของกลุ่ม (ตาม QR) -> #agg  (เงื่อนไขเดียวกับ #g ของ 112_ : qr_format = @fmt , ton > 0 , bag_no >= 1)
        CREATE TABLE #agg (ton INT NOT NULL, bag_no INT NULL, is_ton BIT NOT NULL, mx INT, is_rk BIT NOT NULL);

        INSERT INTO #agg (ton, bag_no, is_ton, mx, is_rk)
        SELECT y.ton,
               CASE WHEN GROUPING(y.bag_no) = 1 THEN NULL ELSE y.bag_no END,
               GROUPING(y.bag_no),
               MAX(y.bag_no),
               CASE WHEN GROUPING(y.bag_no) = 0
                     AND MAX(CASE WHEN y.is_active = 'R' AND ISNULL(y.bag_status_id, 0) <> 6 THEN 1 ELSE 0 END) = 1
                     AND MAX(CASE WHEN y.is_active = 'Y' OR y.bag_status_id = 6 THEN 1 ELSE 0 END) = 0
                    THEN 1 ELSE 0 END
        FROM  (-- 1a) src 1 fast path : QR = prefix ของกลุ่ม + 'bag|ton[|time]'
               SELECT b.is_active, b.bag_status_id,
                      fmt    = CAST(CASE WHEN t2.t2 > 0 THEN 6 ELSE 5 END AS TINYINT),
                      bag_no = CASE WHEN t1.t1 > 0 THEN TRY_CONVERT(INT, LEFT(t.t, t1.t1 - 1)) END,
                      ton    = CASE WHEN t1.t1 > 0 AND t2.t2 > 0 THEN TRY_CONVERT(INT, SUBSTRING(t.t, t1.t1 + 1, t2.t2 - t1.t1 - 1))
                                    WHEN t1.t1 > 0 THEN TRY_CONVERT(INT, SUBSTRING(t.t, t1.t1 + 1, 100)) END
               FROM   dbo.tr_bag b
               CROSS APPLY (SELECT t  = SUBSTRING(b.qr_text_data COLLATE Thai_BIN2, @L + 1, 100)) t
               CROSS APPLY (SELECT t1 = CHARINDEX('|', t.t)) t1
               CROSS APPLY (SELECT t2 = CASE WHEN t1.t1 > 0 THEN CHARINDEX('|', t.t, t1.t1 + 1) ELSE 0 END) t2
               WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                 AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
                 AND  @pre IS NOT NULL
                 AND  LEFT(b.qr_text_data COLLATE Thai_BIN2, @L) = @pre COLLATE Thai_BIN2
                 AND  t1.t1 > 0
               UNION ALL
               -- 1b) src 1 fallback : QR ไม่ขึ้นต้นด้วย prefix ของกลุ่ม -> แกะเต็ม
               SELECT b.is_active, b.bag_status_id, f.fmt, f.bag_no, f.ton
               FROM   dbo.tr_bag b
               CROSS APPLY (SELECT q  = b.qr_text_data COLLATE Thai_BIN2) q
               CROSS APPLY (SELECT p1 = CHARINDEX('|', q.q)) a1
               CROSS APPLY (SELECT p2 = CHARINDEX('|', q.q, a1.p1 + 1)) a2
               CROSS APPLY (SELECT p3 = CHARINDEX('|', q.q, a2.p2 + 1)) a3
               CROSS APPLY (SELECT p4 = CHARINDEX('|', q.q, a3.p3 + 1)) a4
               CROSS APPLY (SELECT p5 = CHARINDEX('|', q.q, a4.p4 + 1)) a5
               CROSS APPLY (SELECT ok = CASE WHEN a1.p1 > 0 AND a2.p2 > 0 AND a3.p3 > 0 AND a4.p4 > 0 THEN 1 ELSE 0 END) ok
               CROSS APPLY (SELECT fmt    = CAST(CASE WHEN a5.p5 > 0 THEN 6 ELSE 5 END AS TINYINT),
                                   bag_no = CASE WHEN ok.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a3.p3 + 1, a4.p4 - a3.p3 - 1)) END,
                                   ton    = CASE WHEN ok.ok = 1 AND a5.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, a5.p5 - a4.p4 - 1))
                                                 WHEN ok.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, LEN(b.qr_text_data) - a4.p4)) END) f
               WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
                 AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
                 AND  b.qr_text_data IS NOT NULL
                 AND  (@pre IS NULL OR LEFT(b.qr_text_data COLLATE Thai_BIN2, @L) <> @pre COLLATE Thai_BIN2)
                 AND  ok.ok = 1
               UNION ALL
               -- 1c) src 2 : ถุงจัดการด้วยมือ 3/6 ใช้กลุ่มตาม QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว -- เหมือน 13_)
               SELECT b.is_active, b.bag_status_id, f.fmt, f.bag_no, f.ton
               FROM   dbo.tr_bag b
               CROSS APPLY (SELECT q  = b.qr_text_data COLLATE Thai_BIN2) q
               CROSS APPLY (SELECT p1 = CHARINDEX('|', q.q)) a1
               CROSS APPLY (SELECT p2 = CHARINDEX('|', q.q, a1.p1 + 1)) a2
               CROSS APPLY (SELECT p3 = CHARINDEX('|', q.q, a2.p2 + 1)) a3
               CROSS APPLY (SELECT p4 = CHARINDEX('|', q.q, a3.p3 + 1)) a4
               CROSS APPLY (SELECT p5 = CHARINDEX('|', q.q, a4.p4 + 1)) a5
               CROSS APPLY (SELECT ok = CASE WHEN a1.p1 > 0 AND a2.p2 > 0 AND a3.p3 > 0 AND a4.p4 > 0 THEN 1 ELSE 0 END) ok
               CROSS APPLY (SELECT fmt     = CAST(CASE WHEN a5.p5 > 0 THEN 6 ELSE 5 END AS TINYINT),
                                   q_cc    = CASE WHEN ok.ok = 1 THEN SUBSTRING(b.qr_text_data, 1, a1.p1 - 1) END,
                                   q_grade = CASE WHEN ok.ok = 1 THEN SUBSTRING(b.qr_text_data, a1.p1 + 1, a2.p2 - a1.p1 - 1) END,
                                   q_lot   = CASE WHEN ok.ok = 1 THEN SUBSTRING(b.qr_text_data, a2.p2 + 1, a3.p3 - a2.p2 - 1) END,
                                   bag_no  = CASE WHEN ok.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a3.p3 + 1, a4.p4 - a3.p3 - 1)) END,
                                   ton     = CASE WHEN ok.ok = 1 AND a5.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, a5.p5 - a4.p4 - 1))
                                                  WHEN ok.ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, LEN(b.qr_text_data) - a4.p4)) END) f
               WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A'
                 AND  ok.ok = 1
                 AND  f.q_cc = @cc AND f.q_grade = @grade AND f.q_lot = @lot
              ) y
        WHERE  y.fmt = @fmt
          AND  y.ton > 0 AND y.bag_no >= 1
        GROUP BY GROUPING SETS ((y.ton), (y.ton, y.bag_no))
        HAVING GROUPING(y.bag_no) = 1
            OR y.ton BETWEEN @o AND @o + @rub
            OR (    MAX(CASE WHEN y.is_active = 'R' AND ISNULL(y.bag_status_id, 0) <> 6 THEN 1 ELSE 0 END) = 1
                AND MAX(CASE WHEN y.is_active = 'Y' OR y.bag_status_id = 6 THEN 1 ELSE 0 END) = 0);

        -- 3) reject ที่นับ (ตามตัน/bag_no) : R ยกเว้น 6 และไม่นับช่องที่มีถุงดี/ถุง 6 อยู่
        CREATE TABLE #rk (ton INT NOT NULL, bag_no INT NOT NULL, PRIMARY KEY (ton, bag_no));
        INSERT INTO #rk (ton, bag_no)
        SELECT ton, bag_no FROM #agg WHERE is_ton = 0 AND is_rk = 1;
        SET @rjc = (SELECT COUNT(*) FROM #rk);

        -- 4) ขนาดต่อตัน (เหมือน 111_) : ตัน 1 .. max(ตันสูงสุด , พาเลทนี้ + reject + 1)
        --    ตันหลังตันที่มีถุง ครอบตำแหน่งที่ reject ดึงขึ้นมา (ทุกตัน >= 1 ช่อง -> พอเสมอ)
        CREATE TABLE #cap (prn INT PRIMARY KEY, mx INT, cap INT, cum_before INT, cum_end INT,
                           has_bag BIT NOT NULL DEFAULT 0, seg_lo INT);
        INSERT INTO #cap (prn, mx, has_bag)
        SELECT ton, mx, 1 FROM #agg WHERE is_ton = 1;

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

        -- (ช่วงตัน เหมือน 111_) seg_lo = cum_before ของตันแรกในช่วงตันที่มีถุงติดกัน
        --   ตันว่าง : seg_lo = NULL -> ใช้ cum_end ของตัวเอง (ไม่นับ reject = ไม่เลื่อน)
        ;WITH s AS (
            SELECT seg_lo, cum_before,
                   prn - ROW_NUMBER() OVER (ORDER BY prn) AS isl
            FROM   #cap WHERE has_bag = 1
        ), s2 AS (
            SELECT seg_lo, MIN(cum_before) OVER (PARTITION BY isl) AS lo FROM s
        )
        UPDATE s2 SET seg_lo = lo;

        -- 5) ตำแหน่งของถุง (เฉพาะตัน @o .. @o + @rub ครอบช่วง @from .. @to แล้ว) / reject
        CREATE TABLE #gp (pos INT PRIMARY KEY);
        INSERT INTO #gp (pos)
        SELECT c.cum_before + g.bag_no
        FROM   #agg g JOIN #cap c ON c.prn = g.ton
        WHERE  g.is_ton = 0 AND g.ton BETWEEN @o AND @o + @rub;

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
        CROSS APPLY (SELECT TOP 1 c.prn AS ton, n.pos - c.cum_before AS bag_no,
                            ISNULL(c.seg_lo, c.cum_end) AS seg_lo                  -- (ช่วงตัน)
                     FROM #cap c WHERE c.cum_end >= n.pos ORDER BY c.prn) m
        CROSS APPLY (SELECT n.pos - (SELECT COUNT(*) FROM #rj r
                                     WHERE r.pos < n.pos AND r.pos > m.seg_lo) AS good_pos) gp
        WHERE  NOT EXISTS (SELECT 1 FROM #gp g WHERE g.pos = n.pos)
          AND  (SELECT MIN(c.prn) FROM #cap c WHERE c.cum_end >= gp.good_pos) = @o;
    END

    SELECT qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos
    FROM   #m
    ORDER BY planned_pos;
END
GO
