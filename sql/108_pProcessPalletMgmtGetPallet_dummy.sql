/* =====================================================================
   108_pProcessPalletMgmtGetPallet_dummy.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   PWA Forklift หน้า /pallet-management สแกน QR Dummy Pallet (PLDyyMMddNNNN, 107_)
   เพื่อดูข้อมูลถุงที่อยู่บนพาเลท

   Dummy pallet (pallet_type = 'D') สร้างมาไม่มี unit_ratio / unit_pallet (NULL)
   -> ของเดิม qty พาเลท = ถุง x ISNULL(unit_ratio, 0) = 0 และ qty ถุง = NULL
   แก้: ถ้าเป็น dummy pallet และ unit_ratio ว่าง ใช้ package ratio ตาม grade ของถุงบนพาเลท
        (ct_grade_package_ratio เก็บ grade แบบตัด space เหมือน 107_) -- คืน unit_ratio ค่านี้ด้วย
        คืน pallet_type เพิ่ม (A / M / S / J / D) ให้ PWA แสดงป้าย Dummy
        คืน package_ratio (กก./ถุง ตาม grade) ทุกพาเลท -- PWA ใช้คิดจำนวนถุงที่เบิกได้จากพาเลท Manual (109_)

   ส่วนอื่นเหมือน 27_ (= definition บน prod, OBJECT_DEFINITION 2026-11-03) ทุกอย่าง
   Dependencies: 27_pProcessPalletManagement.sql, 09_ct_grade_package_ratio.sql
   ย้อนกลับ: 108_rollback_pProcessPalletMgmtGetPallet.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtGetPallet]
    @qr_code VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @code VARCHAR(100) = LTRIM(RTRIM(ISNULL(@qr_code, '')));
    DECLARE @pallet_id BIGINT, @bag_pallet_id BIGINT, @bag_found BIT = 0;
    DECLARE @is_bag_qr BIT = 0;
    DECLARE @pallet_type VARCHAR(10), @unit_ratio INT, @package_ratio INT;

    IF LEN(@code) = 0
    BEGIN
        SELECT 'error' AS status, N'กรุณาสแกน QR Code' AS message;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        SELECT TOP 0 CAST(NULL AS BIGINT) AS id;
        RETURN;
    END

    --  QR ถุง = 5 ส่วน (มี '|' 4 ตัว) หรือ 6 ส่วน (format ใหม่ต่อท้าย |ddHHmm) และส่วน
    --  bag_no/pallet_running_no เป็นตัวเลข
    --  นอกนั้นถือเป็น pallet_no (เช่น PLA2609250001, PLD2611030001) -- เช็คจำนวน '|' ก่อนเรียก fParseBagQr
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

    --  package ratio ตาม grade ของถุงบนพาเลท (grade ที่มีถุงมากที่สุด)
    --  Dummy pallet ไม่มี unit_ratio -> ใช้ค่านี้แทน (dummy มี Grade / Lot เดียว)
    SELECT @pallet_type = pallet_type, @unit_ratio = unit_ratio
    FROM   dbo.tr_pallet
    WHERE  id = @pallet_id;

    SELECT TOP 1 @package_ratio = r.unit_ratio
    FROM   dbo.tr_bag b
    JOIN   dbo.ct_grade_package_ratio r ON r.grade = REPLACE(b.grade, ' ', '')
    WHERE  b.pallet_id = @pallet_id AND b.is_active = 'Y' AND b.status_flag = 'A'
    GROUP BY r.unit_ratio
    ORDER BY COUNT(*) DESC;

    IF @pallet_type = 'D' AND @unit_ratio IS NULL
        SET @unit_ratio = @package_ratio;

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
        p.pallet_type,
        COALESCE(g.cost_center, r.cost_center) AS cost_center,
        COALESCE(g.grade, r.grade)             AS grade,
        COALESCE(g.lot, r.lot)                 AS lot,
        p.unit_pallet,
        @unit_ratio                                               AS unit_ratio,
        @package_ratio                                            AS package_ratio,
        (SELECT COUNT(*) FROM bags)                               AS bag_count,
        (SELECT COUNT(*) FROM bags) * ISNULL(@unit_ratio, 0)      AS qty,
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
        @unit_ratio AS qty
    FROM   dbo.tr_bag b
    WHERE  b.pallet_id   = @pallet_id
      AND  b.is_active   = 'Y'
      AND  b.status_flag = 'A'
    ORDER BY b.bag_no, b.id;
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessPalletMgmtGetPallet @qr_code = 'PLD2611030001';
