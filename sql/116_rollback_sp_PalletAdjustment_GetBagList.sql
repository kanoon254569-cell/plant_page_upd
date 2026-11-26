/* =====================================================================
   116_rollback_sp_PalletAdjustment_GetBagList.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   Rollback ของ 116_ : คืน dbo.sp_PalletAdjustment_GetBagList เป็น definition บน prod ก่อน deploy 116_
   (= 114_sp_PalletAdjustment_GetBagList_bin2.sql ; ตรวจแล้ว 2026-11-11 ว่าตรงกับ OBJECT_DEFINITION บน prod ทุกตัวอักษร
    ยกเว้นช่องว่าง)
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

    -- 1) ถุงบนพาเลทนี้ + ตำแหน่งตาม QR (ไม่เปลี่ยน : ถุงบนพาเลทมีไม่กี่สิบใบ)
    CREATE TABLE #b (
        id BIGINT PRIMARY KEY, bag_no INT, ton_no INT,
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, qr_text_data VARCHAR(100) COLLATE DATABASE_DEFAULT,
        remark VARCHAR(255) COLLATE DATABASE_DEFAULT, bag_status_id INT, pallet_id BIGINT,
        q_fmt TINYINT, q_ton INT, q_bag_no INT);

    INSERT INTO #b (id, bag_no, ton_no, grade, cost_center, lot, qr_text_data, remark, bag_status_id, pallet_id,
                    q_fmt, q_ton, q_bag_no)
    SELECT b.id, b.bag_no, b.ton_no, b.grade, b.cost_center, b.lot, b.qr_text_data, b.remark, b.bag_status_id, b.pallet_id,
           q.qr_format, q.pallet_running_no, q.bag_no
    FROM   dbo.tr_bag b
    OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
    WHERE  b.pallet_id = @PalletId
      AND  b.is_active = 'Y';

    -- 2) กลุ่มของถุงบนพาเลท (grade + cost_center + lot + QR format -- QR 5/6 ส่วน คนละกลุ่ม ดู 13_)
    CREATE TABLE #k (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT);
    INSERT INTO #k (grade, cost_center, lot, fmt)
    SELECT DISTINCT grade, cost_center, lot, q_fmt FROM #b WHERE q_fmt IS NOT NULL;

    -- 3) ถุงทั้งกลุ่ม (ตาม QR) : Y/R ของกลุ่มตามคอลัมน์ (src 1) + ถุงจัดการด้วยมือ 3/6 ตาม QR (src 2)
    --    3a) ตำแหน่ง '|' ของ QR (BIN2 , แกะครั้งเดียว) -- k_* = ค่าของกลุ่มที่ src 1 ดึงมา
    CREATE TABLE #qp (
        src TINYINT NOT NULL,
        k_grade VARCHAR(30) COLLATE DATABASE_DEFAULT, k_cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        k_lot VARCHAR(20) COLLATE DATABASE_DEFAULT,
        qr VARCHAR(100) COLLATE DATABASE_DEFAULT, is_active VARCHAR(1), bag_status_id INT,
        p1 INT, p2 INT, p3 INT, p4 INT, p5 INT);

    DECLARE @g VARCHAR(30), @cc VARCHAR(20), @lot VARCHAR(20);
    DECLARE kc CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT grade, cost_center, lot FROM #k;
    OPEN kc;
    FETCH NEXT FROM kc INTO @g, @cc, @lot;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO #qp (src, k_grade, k_cost_center, k_lot, qr, is_active, bag_status_id, p1, p2, p3, p4, p5)
        SELECT 1, @g, @cc, @lot, b.qr_text_data, b.is_active, b.bag_status_id, a1.p1, a2.p2, a3.p3, a4.p4,
               CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)
        FROM   dbo.tr_bag b
        CROSS APPLY (SELECT p1 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1
        CROSS APPLY (SELECT p2 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2
        CROSS APPLY (SELECT p3 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3
        CROSS APPLY (SELECT p4 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4
        WHERE  b.grade = @g AND b.cost_center = @cc AND b.lot = @lot
          AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
          AND  b.qr_text_data IS NOT NULL
          AND  a1.p1 > 0 AND a2.p2 > 0 AND a3.p3 > 0 AND a4.p4 > 0;

        FETCH NEXT FROM kc INTO @g, @cc, @lot;
    END
    CLOSE kc;
    DEALLOCATE kc;

    INSERT INTO #qp (src, qr, is_active, bag_status_id, p1, p2, p3, p4, p5)
    SELECT 2, b.qr_text_data, b.is_active, b.bag_status_id, a1.p1, a2.p2, a3.p3, a4.p4,
           CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)
    FROM   dbo.tr_bag b
    CROSS APPLY (SELECT p1 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1
    CROSS APPLY (SELECT p2 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2
    CROSS APPLY (SELECT p3 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3
    CROSS APPLY (SELECT p4 = CHARINDEX('|' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4
    WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A'
      AND  b.qr_text_data IS NOT NULL
      AND  a1.p1 > 0 AND a2.p2 > 0 AND a3.p3 > 0 AND a4.p4 > 0
      AND  EXISTS (SELECT 1 FROM #k);

    --    3b) ตัด field (สูตรเดียวกับ fParseBagQr ; #qp มีแต่แถวที่ p1..p4 > 0 -> SUBSTRING ปลอดภัย)
    CREATE TABLE #t (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT,
        ton INT, bag_no INT, is_active VARCHAR(1), bag_status_id INT);

    ;WITH x AS (
        SELECT q.src, q.k_grade, q.k_cost_center, q.k_lot, q.is_active, q.bag_status_id,
               q_cc      = CASE WHEN q.src = 2 THEN SUBSTRING(q.qr, 1, q.p1 - 1) END,
               q_grade   = CASE WHEN q.src = 2 THEN SUBSTRING(q.qr, q.p1 + 1, q.p2 - q.p1 - 1) END,
               q_lot     = CASE WHEN q.src = 2 THEN SUBSTRING(q.qr, q.p2 + 1, q.p3 - q.p2 - 1) END,
               bag_no    = TRY_CONVERT(INT, SUBSTRING(q.qr, q.p3 + 1, q.p4 - q.p3 - 1)),
               ton       = CASE WHEN q.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(q.qr, q.p4 + 1, q.p5 - q.p4 - 1))
                                ELSE TRY_CONVERT(INT, SUBSTRING(q.qr, q.p4 + 1, LEN(q.qr) - q.p4)) END,
               fmt       = CAST(CASE WHEN q.p5 > 0 THEN 6 ELSE 5 END AS TINYINT)
        FROM   #qp q
    )
    INSERT INTO #t (grade, cost_center, lot, fmt, ton, bag_no, is_active, bag_status_id)
    SELECT k.grade, k.cost_center, k.lot, k.fmt, x.ton, x.bag_no, x.is_active, x.bag_status_id
    FROM   x
    JOIN   #k k ON k.grade = x.k_grade AND k.cost_center = x.k_cost_center AND k.lot = x.k_lot
               AND k.fmt = x.fmt
    WHERE  x.src = 1 AND x.ton > 0
    UNION ALL
    SELECT k.grade, k.cost_center, k.lot, k.fmt, x.ton, x.bag_no, x.is_active, x.bag_status_id
    FROM   x
    JOIN   #k k ON k.grade = x.q_grade AND k.cost_center = x.q_cc AND k.lot = x.q_lot
               AND k.fmt = x.fmt
    WHERE  x.src = 2 AND x.ton > 0;

    -- 4) ช่วงตัน : ตันที่มีถุงติดกัน = isl เดียวกัน (gaps-and-islands)
    CREATE TABLE #seg (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT, ton INT, isl INT);
    INSERT INTO #seg (grade, cost_center, lot, fmt, ton, isl)
    SELECT grade, cost_center, lot, fmt, ton,
           ton - ROW_NUMBER() OVER (PARTITION BY grade, cost_center, lot, fmt ORDER BY ton)
    FROM  (SELECT DISTINCT grade, cost_center, lot, fmt, ton FROM #t) d;

    -- 5) reject ที่นับ : R ยกเว้น 6 , ไม่นับตำแหน่งที่มีถุงดี / ถุง 6 ครองอยู่ (เหมือน 111_ / 112_)
    CREATE TABLE #rk (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT, ton INT, bag_no INT, isl INT);
    INSERT INTO #rk (grade, cost_center, lot, fmt, ton, bag_no, isl)
    SELECT DISTINCT r.grade, r.cost_center, r.lot, r.fmt, r.ton, r.bag_no, s.isl
    FROM   #t r
    JOIN   #seg s ON s.grade = r.grade AND s.cost_center = r.cost_center AND s.lot = r.lot
                 AND s.fmt = r.fmt AND s.ton = r.ton
    WHERE  r.is_active = 'R' AND ISNULL(r.bag_status_id, 0) <> 6 AND r.bag_no > 0
      AND  NOT EXISTS (SELECT 1 FROM #t h
                       WHERE h.grade = r.grade AND h.cost_center = r.cost_center AND h.lot = r.lot
                         AND h.fmt = r.fmt AND h.ton = r.ton AND h.bag_no = r.bag_no
                         AND (h.is_active = 'Y' OR h.bag_status_id = 6));

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
