-- =============================================================
-- 85_pServiceMatchBagToPallet_parse_once.sql  (IRPC_QTRACK)
-- =============================================================
-- pServiceMatchBagToPallet took 5-30s per call, and held its
-- transaction (+ X locks on tr_bag / tr_pallet) for all of it, so
-- Pallet Adjustment / Pallet List / CreatePallet waited on its locks.
--
-- Cause: QR parsing, not reading. For one cc+grade+lot group
-- (1126NK / 1312 / 0261005033, 14,542 bags, 2026-10-22):
--   seek the lot's bags                      10 ms
--   step 2  @nl   (fParseBagQr, whole lot)   2,700 ms CPU
--   step 3  g     (fParseBagQr, whole lot)   5,500 ms CPU
-- fParseBagQr is inline: every guarded CASE (p2 uses p1 twice, p3 uses
-- p2 twice, ...) is expanded, so one row runs CHARINDEX ~100+ times,
-- each a Thai_100_CI_AI_KS (linguistic) compare.
--
-- Change (85): parse the lot's QR once per group into #bq, right after
-- step 0, and use it in step 2 (@nl, lot part), step 3 (g, lot part)
-- and step 3.1 (#rj) instead of OUTER APPLY dbo.fParseBagQr.
--   1. #bq_pos : '|' positions, each from the one before
--      (CHARINDEX('|' COLLATE Latin1_General_BIN2, qr, p_prev + 1)).
--   2. #bq     : bag_no / pallet_running_no / qr_format cut from those
--      positions with fParseBagQr's own guards.
--   Same lot (12k-15k bags): 312 ms instead of ~7,000 ms per parse.
--
-- Same result as fParseBagQr:
--   - No guards on the positions: a 0 makes the next search restart
--     from 1, but the row is valid only when p1..p4 are all > 0, i.e.
--     no 0 came up, so valid rows get the same positions; invalid
--     rows give NULLs, the same as OUTER APPLY finding no row.
--   - BIN2 '|' vs Thai_100_CI_AI_KS '|': same '|' count on every
--     tr_bag row (1.08M); field-by-field compare with fParseBagQr on
--     9,295 rows (3,010 odd QRs, 405 format-6, all 3/6/9 bags, edge
--     cases like 'a|b|c|', '||||', 'PLA2609250001'): 0 differences.
--   - Columns of tr_bag are still read live in each step; #bq only
--     carries values parsed from qr_text_data, which this proc never
--     changes. Steps join #bq with INNER JOIN, so a bag inserted after
--     #bq was built is left for the next run (instead of being parsed
--     with no #bq row).
-- Not changed: step 0, the 3/6 parts of steps 2/3 (QR-matched bags of
-- the whole table, ~300 rows), #grp, message, steps 4-8, the
-- transaction and the applock.
--
-- Patched from the live definition with REPLACE (same way as sql/47):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when #bq_pos is already there. @proc lets the
-- same patch run on a copy for the @preview = 1 compare.
--
-- Backup of the definition before this patch (SHA-256 checked):
--   ..\scratch_backup_pServiceMatchBagToPallet_20261022.sql
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @proc SYSNAME       = N'dbo.pServiceMatchBagToPallet';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @nl   NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%#bq_pos%'
BEGIN
    PRINT 'pServiceMatchBagToPallet already parses once (#bq_pos) - skipped.';
    RETURN;
END

DECLARE @apply NVARCHAR(200) = @nl + N'                FROM   dbo.tr_bag b'
                             + @nl + N'                OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q';
DECLARE @join  NVARCHAR(200) = @nl + N'                FROM   dbo.tr_bag b'
                             + @nl + N'                JOIN   #bq q ON q.id = b.id';

--  1. #bq_pos / #bq, created next to #rj
DECLARE @o1 NVARCHAR(400)  = N'CREATE TABLE #rj (planned_pos INT PRIMARY KEY);';
DECLARE @n1 NVARCHAR(1000) = @o1 + @nl
    + N'        -- QR ของถุงทั้ง lot แกะครั้งเดียวต่อกลุ่ม (85_) : ตำแหน่ง ''|'' -> #bq_pos , ค่าที่แกะ -> #bq' + @nl
    + N'        CREATE TABLE #bq_pos (id BIGINT PRIMARY KEY, qr VARCHAR(100) COLLATE Thai_100_CI_AI_KS,' + @nl
    + N'                              p1 INT, p2 INT, p3 INT, p4 INT, p5 INT);' + @nl
    + N'        CREATE TABLE #bq (id BIGINT PRIMARY KEY, bag_no INT, pallet_running_no INT, qr_format TINYINT);';

--  2. fill #bq right after step 0
DECLARE @o2 NVARCHAR(400)  = N'AND  ( b.pallet_id IS NOT NULL OR ISNULL(b.bag_status_id, 0) NOT IN (6, 9) );';
DECLARE @n2 NVARCHAR(MAX)  = @o2 + @nl
    + @nl
    + N'            -- 1) (85_) แกะ QR ของถุงทั้ง lot ครั้งเดียว -> #bq ใช้ใน 2) 3) 3.1) แทน fParseBagQr' + @nl
    + N'            --    ผลเท่า fParseBagQr ทุกแถว : หาตำแหน่ง ''|'' ต่อกันเป็นทอด (BIN2) เก็บลง #bq_pos ก่อน' + @nl
    + N'            --    แล้วค่อยตัด field ด้วย guard เดียวกับ fParseBagQr -- fParseBagQr แบบ inline ขยาย' + @nl
    + N'            --    CHARINDEX (collation Thai) เป็นร้อยครั้งต่อแถว ; ตำแหน่งไม่ต้อง guard เพราะแถวที่' + @nl
    + N'            --    ใช้ได้ต้องมี p1..p4 > 0 ครบ (ไม่มี 0 คั่น -> ตำแหน่งเท่าแบบ guard)' + @nl
    + N'            DELETE FROM #bq_pos;  DELETE FROM #bq;' + @nl
    + N'            INSERT INTO #bq_pos (id, qr, p1, p2, p3, p4, p5)' + @nl
    + N'            SELECT b.id, b.qr_text_data, a1.p1, a2.p2, a3.p3, a4.p4,' + @nl
    + N'                   CHARINDEX(''|'' COLLATE Latin1_General_BIN2, b.qr_text_data, a4.p4 + 1)' + @nl
    + N'            FROM   dbo.tr_bag b' + @nl
    + N'            CROSS APPLY (SELECT p1 = CHARINDEX(''|'' COLLATE Latin1_General_BIN2, b.qr_text_data)) a1' + @nl
    + N'            CROSS APPLY (SELECT p2 = CHARINDEX(''|'' COLLATE Latin1_General_BIN2, b.qr_text_data, a1.p1 + 1)) a2' + @nl
    + N'            CROSS APPLY (SELECT p3 = CHARINDEX(''|'' COLLATE Latin1_General_BIN2, b.qr_text_data, a2.p2 + 1)) a3' + @nl
    + N'            CROSS APPLY (SELECT p4 = CHARINDEX(''|'' COLLATE Latin1_General_BIN2, b.qr_text_data, a3.p3 + 1)) a4' + @nl
    + N'            WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot;' + @nl
    + @nl
    + N'            INSERT INTO #bq (id, bag_no, pallet_running_no, qr_format)' + @nl
    + N'            SELECT id,' + @nl
    + N'                   CASE WHEN ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(qr, p3 + 1, p4 - p3 - 1)) END,' + @nl
    + N'                   CASE WHEN ok = 1 AND p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(qr, p4 + 1, p5 - p4 - 1))' + @nl
    + N'                        WHEN ok = 1 THEN TRY_CONVERT(INT, SUBSTRING(qr, p4 + 1, LEN(qr) - p4)) END,' + @nl
    + N'                   CASE WHEN ok = 1 AND p5 > 0 THEN 6 WHEN ok = 1 THEN 5 END' + @nl
    + N'            FROM  (SELECT id, qr, p3, p4, p5,' + @nl
    + N'                          ok = CASE WHEN qr IS NOT NULL AND p1 > 0 AND p2 > 0 AND p3 > 0 AND p4 > 0' + @nl
    + N'                                    THEN 1 ELSE 0 END' + @nl
    + N'                   FROM   #bq_pos) x;';

--  3. step 2 (@nl), lot part
DECLARE @o3 NVARCHAR(400) = N'SELECT COALESCE(q.bag_no, b.bag_no) AS bno' + @apply;
DECLARE @n3 NVARCHAR(400) = N'SELECT COALESCE(q.bag_no, b.bag_no) AS bno' + @join;

--  4. step 3 (g), lot part
DECLARE @o4 NVARCHAR(400) = N'CAST(0 AS BIT) AS is_fixed' + @apply;
DECLARE @n4 NVARCHAR(400) = N'CAST(0 AS BIT) AS is_fixed' + @join;

--  5. step 3.1 (#rj)
DECLARE @o5 NVARCHAR(400) = N'SELECT (COALESCE(q.pallet_running_no, b.pallet_running_no) - 1) * @nl + q.bag_no AS planned_pos' + @apply;
DECLARE @n5 NVARCHAR(400) = N'SELECT (COALESCE(q.pallet_running_no, b.pallet_running_no) - 1) * @nl + q.bag_no AS planned_pos' + @join;

IF   (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o3, N''))) / DATALENGTH(@o3) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o4, N''))) / DATALENGTH(@o4) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o5, N''))) / DATALENGTH(@o5) <> 1
BEGIN
    RAISERROR('pServiceMatchBagToPallet: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = REPLACE(@d, @o4, @n4);
SET @d = REPLACE(@d, @o5, @n5);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pServiceMatchBagToPallet patched (parse QR once per group).';
GO
