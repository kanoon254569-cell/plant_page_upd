/* =====================================================================
   114_rollback_sp_PalletAdjustment_GetBagList.sql  (IRPC_QTRACK)
   คืน sp_PalletAdjustment_GetBagList เป็น definition เดิมบน prod (ก่อน 114_)
   ดึงจาก OBJECT_DEFINITION 2026-11-11
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

    -- 1) ถุงบนพาเลทนี้ + ตำแหน่งตาม QR
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

    -- 3) ถุงทั้งกลุ่ม (ตาม QR) : Y/R ของกลุ่มตามคอลัมน์ + ถุงจัดการด้วยมือ 3/6 ตาม QR (เหมือน 111_)
    CREATE TABLE #t (
        grade VARCHAR(30) COLLATE DATABASE_DEFAULT, cost_center VARCHAR(20) COLLATE DATABASE_DEFAULT,
        lot VARCHAR(20) COLLATE DATABASE_DEFAULT, fmt TINYINT,
        ton INT, bag_no INT, is_active VARCHAR(1), bag_status_id INT);

    INSERT INTO #t (grade, cost_center, lot, fmt, ton, bag_no, is_active, bag_status_id)
    SELECT k.grade, k.cost_center, k.lot, k.fmt, q.pallet_running_no, q.bag_no, b.is_active, b.bag_status_id
    FROM   #k k
    JOIN   dbo.tr_bag b ON b.grade = k.grade AND b.cost_center = k.cost_center AND b.lot = k.lot
    CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
    WHERE  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
      AND  q.qr_format = k.fmt AND q.pallet_running_no > 0
    UNION ALL
    SELECT k.grade, k.cost_center, k.lot, k.fmt, q.pallet_running_no, q.bag_no, b.is_active, b.bag_status_id
    FROM   dbo.tr_bag b
    CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
    JOIN   #k k ON k.grade = q.grade AND k.cost_center = q.cost_center AND k.lot = q.lot AND k.fmt = q.qr_format
    WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A'
      AND  q.pallet_running_no > 0;

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
