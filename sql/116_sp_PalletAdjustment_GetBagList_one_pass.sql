/* =====================================================================
   116_sp_PalletAdjustment_GetBagList_one_pass.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   ต่อจาก 114_ : GET pallet-adjustment/bag ช้าตามขนาด lot (CPU ล้วน)
   วัดบน prod 2026-11-11 (114_) : lot 760 ถุง ~80 ms , lot 7,472 ถุง ~340 ms
     - ต้นทุนหลัก = แกะ QR ทุกถุงใน lot (CHARINDEX ซ้อน 5 ชั้น ถูก expand ซ้ำทุกจุดที่อ้าง p3/p4/p5)
       + INSERT ทุกถุงลง #qp แล้ว #t (~8 us/แถว)
     - ขั้นที่ 1 ยังใช้ dbo.fParseBagQr (collation Thai_100_CI_AI_KS ~250 ms / 760 แถว) -> ~13 ms ทุกครั้ง
   แก้ (ผลลัพธ์เหมือน 114_ ทุกแถว -- ตรวจบน prod แล้ว) :
     - ขั้นที่ 1 แกะ QR ของถุงบนพาเลทแบบ inline (Thai_BIN2) แทน fParseBagQr ; guard เหมือน fParseBagQr
     - ขั้นที่ 3 src 1 (ถุง Y/R ของกลุ่มตามคอลัมน์) : QR ขึ้นต้นด้วย 'cc|grade|lot|' ของกลุ่ม (เทียบ Thai_BIN2)
         -> แกะแค่ท้าย 'bag|ton[|time]' (CHARINDEX 2 ครั้ง) ; ไม่ตรง prefix -> แกะเต็มแบบเดิม (fallback)
         prefix ตรง => p1..p3 = ตำแหน่ง '|' ใน prefix (cc / grade / lot ไม่มี '|' -- ถ้ามี ปิด fast path)
     - src 2 (ถุงจัดการด้วยมือ 3/6 กลุ่มตาม QR) แกะเต็มแบบเดิม (มีไม่กี่ร้อยใบทั้งตาราง)
     - ไม่เก็บทุกถุงลง temp : GROUP BY GROUPING SETS ครั้งเดียวต่อกลุ่ม -> #agg เก็บแค่
         (fmt, ton)          = ตันที่มีถุง (สำหรับช่วงตัน #seg)
         (fmt, ton, bag_no)  = ตำแหน่ง reject ที่นับ : มี R (ยกเว้น 6) และไม่มีถุง Y / 6 ครอง , bag_no > 0
       = เงื่อนไขเดียวกับ #rk ของ 114_ (R ... AND NOT EXISTS (Y OR 6) ที่ตำแหน่งเดียวกัน)
     - ตำแหน่ง '|' หาจาก qr_text_data COLLATE Thai_BIN2 (code page 874 เดิม ไม่ต้องแปลง ; QR เป็น ASCII ล้วน)
       ค่า cc / grade / lot ที่เทียบ ใช้ collation เดิม (CI) ทุกจุด ; ทุก SUBSTRING ครอบ CASE กัน Msg 537
   ผลลัพธ์ / คอลัมน์ / ลำดับ เหมือน 114_ ทุกอย่าง

   Rollback: 116_rollback_sp_PalletAdjustment_GetBagList.sql (= 114_ = definition บน prod 2026-11-11)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_GetBagList]
    @PalletId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) ถุงบนพาเลทนี้ + ตำแหน่งตาม QR (สูตร / guard เดียวกับ fParseBagQr : p1..p4 > 0 , p5 = '|' ตัวที่ 5)
    CREATE TABLE #b (
        id BIGINT PRIMARY KEY, bag_no INT, ton_no INT,
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, qr_text_data VARCHAR(100) COLLATE DATABASE_DEFAULT,
        remark VARCHAR(255) COLLATE DATABASE_DEFAULT, bag_status_id INT, pallet_id BIGINT,
        q_fmt TINYINT, q_ton INT, q_bag_no INT);

    INSERT INTO #b (id, bag_no, ton_no, grade, cost_center, lot, qr_text_data, remark, bag_status_id, pallet_id,
                    q_fmt, q_ton, q_bag_no)
    SELECT b.id, b.bag_no, b.ton_no, b.grade, b.cost_center, b.lot, b.qr_text_data, b.remark, b.bag_status_id, b.pallet_id,
           CASE WHEN a4.p4 > 0 AND a5.p5 > 0 THEN 6 WHEN a4.p4 > 0 THEN 5 END,
           CASE WHEN a4.p4 > 0 AND a5.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, a5.p5 - a4.p4 - 1))
                WHEN a4.p4 > 0 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a4.p4 + 1, LEN(b.qr_text_data) - a4.p4)) END,
           CASE WHEN a4.p4 > 0 THEN TRY_CONVERT(INT, SUBSTRING(b.qr_text_data, a3.p3 + 1, a4.p4 - a3.p3 - 1)) END
    FROM   dbo.tr_bag b
    CROSS APPLY (SELECT q  = b.qr_text_data COLLATE Thai_BIN2) q
    CROSS APPLY (SELECT p1 = ISNULL(CHARINDEX('|', q.q), 0)) a1
    CROSS APPLY (SELECT p2 = CASE WHEN a1.p1 > 0 THEN CHARINDEX('|', q.q, a1.p1 + 1) ELSE 0 END) a2
    CROSS APPLY (SELECT p3 = CASE WHEN a2.p2 > 0 THEN CHARINDEX('|', q.q, a2.p2 + 1) ELSE 0 END) a3
    CROSS APPLY (SELECT p4 = CASE WHEN a3.p3 > 0 THEN CHARINDEX('|', q.q, a3.p3 + 1) ELSE 0 END) a4
    CROSS APPLY (SELECT p5 = CASE WHEN a4.p4 > 0 THEN CHARINDEX('|', q.q, a4.p4 + 1) ELSE 0 END) a5
    WHERE  b.pallet_id = @PalletId
      AND  b.is_active = 'Y';

    -- 2) กลุ่มของถุงบนพาเลท (grade + cost_center + lot + QR format -- QR 5/6 ส่วน คนละกลุ่ม ดู 13_)
    CREATE TABLE #k (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT);
    INSERT INTO #k (grade, cost_center, lot, fmt)
    SELECT DISTINCT grade, cost_center, lot, q_fmt FROM #b WHERE q_fmt IS NOT NULL;

    -- 3) ถุงทั้งกลุ่ม (ตาม QR) -> #agg : ตันที่มีถุง (is_ton = 1) + ตำแหน่ง reject ที่นับ (is_ton = 0)
    CREATE TABLE #agg (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT, ton INT, bag_no INT, is_ton BIT);

    DECLARE @g VARCHAR(30), @cc VARCHAR(20), @lot VARCHAR(20), @pre VARCHAR(100), @L INT;
    DECLARE kc CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT grade, cost_center, lot FROM #k;
    OPEN kc;
    FETCH NEXT FROM kc INTO @g, @cc, @lot;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- prefix ของกลุ่ม (fast path) ; cc / grade / lot มี '|' หรือเป็น NULL -> ปิด fast path (แกะเต็มทุกถุง)
        SET @pre = CASE WHEN CHARINDEX('|', CONCAT(@cc, @g, @lot)) = 0 AND @cc IS NOT NULL AND @g IS NOT NULL AND @lot IS NOT NULL
                        THEN CONCAT(@cc, '|', @g, '|', @lot, '|') END;
        SET @L   = ISNULL(DATALENGTH(@pre), 0);

        INSERT INTO #agg (grade, cost_center, lot, fmt, ton, bag_no, is_ton)
        SELECT @g, @cc, @lot, y.fmt, y.ton,
               CASE WHEN GROUPING(y.bag_no) = 1 THEN NULL ELSE y.bag_no END,
               GROUPING(y.bag_no)
        FROM  (-- 3a) src 1 fast path : QR = prefix ของกลุ่ม + 'bag|ton[|time]'
               SELECT b.is_active, b.bag_status_id,
                      fmt    = CAST(CASE WHEN t2.t2 > 0 THEN 6 ELSE 5 END AS TINYINT),
                      bag_no = CASE WHEN t1.t1 > 0 THEN TRY_CONVERT(INT, LEFT(t.t, t1.t1 - 1)) END,
                      ton    = CASE WHEN t1.t1 > 0 AND t2.t2 > 0 THEN TRY_CONVERT(INT, SUBSTRING(t.t, t1.t1 + 1, t2.t2 - t1.t1 - 1))
                                    WHEN t1.t1 > 0 THEN TRY_CONVERT(INT, SUBSTRING(t.t, t1.t1 + 1, 100)) END
               FROM   dbo.tr_bag b
               CROSS APPLY (SELECT t  = SUBSTRING(b.qr_text_data COLLATE Thai_BIN2, @L + 1, 100)) t
               CROSS APPLY (SELECT t1 = CHARINDEX('|', t.t)) t1
               CROSS APPLY (SELECT t2 = CASE WHEN t1.t1 > 0 THEN CHARINDEX('|', t.t, t1.t1 + 1) ELSE 0 END) t2
               WHERE  b.grade = @g AND b.cost_center = @cc AND b.lot = @lot
                 AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
                 AND  @pre IS NOT NULL
                 AND  LEFT(b.qr_text_data COLLATE Thai_BIN2, @L) = @pre COLLATE Thai_BIN2
                 AND  t1.t1 > 0
               UNION ALL
               -- 3b) src 1 fallback : QR ไม่ขึ้นต้นด้วย prefix ของกลุ่ม (เช่น ตัวพิมพ์ต่าง / ถูก Edit Bag) -> แกะเต็ม
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
               WHERE  b.grade = @g AND b.cost_center = @cc AND b.lot = @lot
                 AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
                 AND  b.qr_text_data IS NOT NULL
                 AND  (@pre IS NULL OR LEFT(b.qr_text_data COLLATE Thai_BIN2, @L) <> @pre COLLATE Thai_BIN2)
                 AND  ok.ok = 1
               UNION ALL
               -- 3c) src 2 : ถุงจัดการด้วยมือ 3/6 -- กลุ่มตาม QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว -- ดู 13_)
               --     cc / grade / lot ตัดจาก qr_text_data เดิม -> เทียบด้วย collation เดิม (CI) เหมือน 114_
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
                 AND  b.qr_text_data IS NOT NULL
                 AND  ok.ok = 1
                 AND  f.q_cc = @cc AND f.q_grade = @g AND f.q_lot = @lot
              ) y
        WHERE  y.ton > 0
          AND  y.fmt IN (SELECT k.fmt FROM #k k WHERE k.grade = @g AND k.cost_center = @cc AND k.lot = @lot)
        GROUP BY GROUPING SETS ((y.fmt, y.ton), (y.fmt, y.ton, y.bag_no))
        HAVING GROUPING(y.bag_no) = 1
            OR (    y.bag_no > 0
                AND MAX(CASE WHEN y.is_active = 'R' AND ISNULL(y.bag_status_id, 0) <> 6 THEN 1 ELSE 0 END) = 1
                AND MAX(CASE WHEN y.is_active = 'Y' OR y.bag_status_id = 6 THEN 1 ELSE 0 END) = 0);

        FETCH NEXT FROM kc INTO @g, @cc, @lot;
    END
    CLOSE kc;
    DEALLOCATE kc;

    -- 4) ช่วงตัน : ตันที่มีถุงติดกัน = isl เดียวกัน (gaps-and-islands)
    CREATE TABLE #seg (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT, ton INT, isl INT);
    INSERT INTO #seg (grade, cost_center, lot, fmt, ton, isl)
    SELECT grade, cost_center, lot, fmt, ton,
           ton - ROW_NUMBER() OVER (PARTITION BY grade, cost_center, lot, fmt ORDER BY ton)
    FROM   #agg
    WHERE  is_ton = 1;

    -- 5) reject ที่นับ : R ยกเว้น 6 , ไม่นับตำแหน่งที่มีถุงดี / ถุง 6 ครองอยู่ (กรองแล้วใน HAVING ขั้นที่ 3)
    CREATE TABLE #rk (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT, ton INT, bag_no INT, isl INT);
    INSERT INTO #rk (grade, cost_center, lot, fmt, ton, bag_no, isl)
    SELECT r.grade, r.cost_center, r.lot, r.fmt, r.ton, r.bag_no, s.isl
    FROM   #agg r
    JOIN   #seg s ON s.grade = r.grade AND s.cost_center = r.cost_center AND s.lot = r.lot
                 AND s.fmt = r.fmt AND s.ton = r.ton
    WHERE  r.is_ton = 0;

    SELECT
        b.id, b.bag_no, b.ton_no, b.grade, b.lot, b.qr_text_data,
        CASE WHEN EXISTS (
                SELECT 1
                FROM   #seg s
                JOIN   #rk r ON r.grade = s.grade AND r.cost_center = s.cost_center AND r.lot = s.lot
                            AND r.fmt = s.fmt AND r.isl = s.isl                 -- ช่วงตันเดียวกันเท่านั้น
                WHERE  s.grade = b.grade AND s.cost_center = b.cost_center AND s.lot = b.lot
                  AND  s.fmt = b.q_fmt AND s.ton = b.q_ton
                  AND  (   r.ton < b.q_ton
                        OR (r.ton = b.q_ton AND r.bag_no < b.q_bag_no) )
             ) THEN 1 ELSE 0 END AS reject_before,
        -- ถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" (ข้อความเดียวกับที่ 103_ บันทึก ; mode_id = 2 แยกไม่ได้เพราะงานพิมพ์ก็ใช้)
        CASE WHEN b.remark LIKE 'เพิ่มข้อมูลด้วยมือ%' THEN 1 ELSE 0 END AS is_manual_added,
        CASE
            WHEN b.bag_status_id = 4    THEN 'missing'
            WHEN b.pallet_id IS NULL    THEN 'orphan'
            ELSE 'matched'
        END AS status
    FROM    #b b
    ORDER BY b.bag_no;
END
GO
