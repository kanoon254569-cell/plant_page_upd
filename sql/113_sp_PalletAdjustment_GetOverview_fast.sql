/* =====================================================================
   113_sp_PalletAdjustment_GetOverview_fast.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   เร่งความเร็ว Pallet Adjustment overview (หน้า pallet-adjustment ของ Boardman)
   ผลลัพธ์ทั้ง 4 result sets เหมือนเดิม (คอลัมน์/ลำดับ/ความหมายเดิม) -- rollback: 113_rollback_

   สาเหตุที่ช้า (วัดบน QAS 10.31.1.75, 2026-11-06, filter = วันนี้ ~59k ถุง / ~1.36k พาเลท):
     - SP ทั้งตัว เฉลี่ย 5.3 s, สูงสุด 26 s (CPU เฉลี่ย 4.6 s)
     - statement สร้าง #PalletInfo = 18.2 s (CPU 11 s) -- เกือบทั้งหมดของเวลา
     - ต้นเหตุ: OUTER APPLY rn เรียก dbo.fParseBagQr(qr_text_data) แกะ QR ทุกถุงใน
       #FilteredBag (CHARINDEX/SUBSTRING หลายรอบบน VARCHAR collation Thai_CI_AI)
       เฉพาะการแกะ QR ของ ~59k แถวอย่างเดียวใช้ ~9.6 s ; แล้วยังทำทีละพาเลทแบบ nested
       loop (plan ประเมินไว้ 6 พาเลท แต่จริง 1.36k -> memory grant ของ sort เล็กเกิน)
     - รองลงมา: SELECT INTO #FilteredBag เขียนถุงทุกใบ (~59k แถว รวม qr_text_data) ลง
       tempdb = 2.3 s (CPU แค่ 0.2 s ที่เหลือรอ I/O) ทั้งที่ใช้จริงแค่ยอดรวมต่อพาเลท

   แก้:
     1) ใช้คอลัมน์ tr_bag.pallet_running_no ที่บันทึกไว้แล้วแทนการแกะ QR
        (ตรวจบน QAS: 780,064 แถว is_active Y/R ย้อนหลัง 14 วัน ค่าคอลัมน์ = ค่าที่แกะจาก
        QR ทุกแถว รวม NULL ด้วย -- diff = 0)
     2) ไม่เก็บถุงรายใบลง tempdb แล้ว -- อ่าน tr_bag รอบเดียวแล้ว GROUP BY ลง #BagGroup
        (pallet_id, grade, lot, running no, จำนวนถุง) เหลือ ~1-2 พันแถวแทน ~59k แถว
        แล้วคำนวณ summary / grade-lot / running no ต่อพาเลทจาก #BagGroup
     3) ถุง orphan (result set #3) ดึงจาก tr_bag ตรง ๆ เฉพาะ pallet_id IS NULL (มีไม่กี่ใบ)
     4) query ที่เป็น catch-all filter (@x IS NULL OR ...) ใส่ OPTION (RECOMPILE) ทุกตัว

   หมายเหตุ grade/lot ของพาเลท: เดิม TOP (1) ไม่มี ORDER BY (ได้แถวไหนก็ได้) -> ตอนนี้ใช้
   MIN() ซึ่งให้ค่าแน่นอน ; ปกติถุงบนพาเลทเดียวกันมี grade/lot เดียวกันอยู่แล้ว
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_GetOverview]
    @PrintDate   DATE          = NULL,
    @CcCode      VARCHAR(20)   = NULL,
    @Grade       VARCHAR(30)   = NULL,
    @Lot         VARCHAR(20)   = NULL,
    @PrintDateFrom DATE        = NULL,
    @PrintDateTo   DATE        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @PrintDateFrom IS NULL AND @PrintDateTo IS NULL AND @PrintDate IS NOT NULL
    BEGIN
        SET @PrintDateFrom = @PrintDate;
        SET @PrintDateTo   = @PrintDate;
    END;

    --  [start, end) -- sargable บน create_datetime ; ฝั่งใดเป็น NULL = ไม่จำกัดฝั่งนั้น
    DECLARE @PrintDateStart DATETIME = @PrintDateFrom;
    DECLARE @PrintDateEnd   DATETIME = DATEADD(DAY, 1, @PrintDateTo);

    --  ถุง is_active = 'Y' ตรง filter สรุปเป็นกลุ่ม (pallet_id NULL = ถุง orphan)
    IF OBJECT_ID('tempdb..#BagGroup') IS NOT NULL DROP TABLE #BagGroup;
    SELECT  b.pallet_id, b.grade, b.lot, b.pallet_running_no, COUNT(*) AS n
    INTO    #BagGroup
    FROM    dbo.tr_bag b WITH (NOLOCK)
    WHERE   b.is_active = 'Y'
      AND   (@PrintDateStart IS NULL OR b.create_datetime >= @PrintDateStart)
      AND   (@PrintDateEnd   IS NULL OR b.create_datetime <  @PrintDateEnd)
      AND   (@CcCode    IS NULL OR b.cost_center = @CcCode)
      AND   (@Grade     IS NULL OR b.grade = @Grade)
      AND   (@Lot       IS NULL OR b.lot LIKE @Lot + '%')
    GROUP BY b.pallet_id, b.grade, b.lot, b.pallet_running_no
    OPTION (RECOMPILE);

    --  ต่อพาเลท: grade/lot และ running pallet no ที่ถุงบนพาเลทใช้มากที่สุด (เท่ากันเอาค่าน้อย)
    IF OBJECT_ID('tempdb..#PalletAgg') IS NOT NULL DROP TABLE #PalletAgg;
    SELECT  g.pallet_id, g.grade, g.lot, r.pallet_running_no
    INTO    #PalletAgg
    FROM   (SELECT  pallet_id, MIN(grade) AS grade, MIN(lot) AS lot
            FROM    #BagGroup
            WHERE   pallet_id IS NOT NULL
            GROUP BY pallet_id) g
    LEFT JOIN (
            SELECT  pallet_id, pallet_running_no,
                    ROW_NUMBER() OVER (PARTITION BY pallet_id
                                       ORDER BY SUM(n) DESC, pallet_running_no) AS rk
            FROM    #BagGroup
            WHERE   pallet_id IS NOT NULL AND pallet_running_no IS NOT NULL
            GROUP BY pallet_id, pallet_running_no
           ) r ON r.pallet_id = g.pallet_id AND r.rk = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_temp_PalletAgg ON #PalletAgg (pallet_id);

    IF OBJECT_ID('tempdb..#PalletInfo') IS NOT NULL DROP TABLE #PalletInfo;
    SELECT  p.id, p.pallet_no, p.pd_group_code, p.unit_pallet, p.pallet_type,
            p.current_location_type, p.current_location_id,
            p.pallet_status_id, p.create_datetime,
            ac.bag_count,
            pa.grade, pa.lot,
            RIGHT('000' + CAST(pa.pallet_running_no AS VARCHAR(10)), 3) AS pallet_running_no,
            CASE
                WHEN p.pallet_status_id = 2 THEN 'complete'
                WHEN p.pallet_status_id = 3 THEN 'confirmed'
                ELSE 'wh_process'
            END AS status
    INTO    #PalletInfo
    FROM    #PalletAgg pa
    INNER JOIN dbo.tr_pallet p WITH (NOLOCK) ON p.id = pa.pallet_id
    --  จำนวนถุงจริงทั้งพาเลท (ไม่กรองวันที่) ให้ตรงกับ Bag List (02_GetBagList)
    CROSS APPLY (
        SELECT  COUNT(*) AS bag_count
        FROM    dbo.tr_bag ab WITH (NOLOCK)
        WHERE   ab.pallet_id = p.id AND ab.is_active = 'Y'
    ) ac
    WHERE   p.is_active = 'Y'
      AND   p.pallet_type = 'A'
      AND   ISNULL(p.pallet_status_id, 1) <> 4;

    --  Result Set #1 = summary
    SELECT
        (SELECT COUNT(*) FROM #PalletInfo)                                    AS total_pallets,
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'wh_process')        AS wh_process,
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'complete')          AS complete,
        (SELECT ISNULL(SUM(n), 0) FROM #BagGroup)                              AS total_bags,
        (SELECT ISNULL(SUM(n), 0) FROM #BagGroup WHERE pallet_id IS NULL)      AS orphan_bags,
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'confirmed')          AS confirmed_remainder;

    --  Result Set #2 = pallets grouped by grade
    SELECT  grade, unit_pallet, id, pallet_no, lot, pallet_running_no, pallet_type,
            bag_count, unit_pallet AS pallet_unit_pallet,
            current_location_type, current_location_id, create_datetime, status
    FROM    #PalletInfo
    ORDER BY grade, pallet_no;

    --  Result Set #3 = orphan bags (มีน้อย -- แกะ QR เฉพาะถุงที่ไม่มีพาเลทเท่านั้น)
    SELECT  b.id, b.bag_no, b.grade, b.lot, b.qr_text_data, 'orphan' AS status
    FROM    dbo.tr_bag b WITH (NOLOCK)
    OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
    WHERE   b.is_active = 'Y'
      AND   b.pallet_id IS NULL
      AND   (@PrintDateStart IS NULL OR b.create_datetime >= @PrintDateStart)
      AND   (@PrintDateEnd   IS NULL OR b.create_datetime <  @PrintDateEnd)
      AND   (@CcCode    IS NULL OR b.cost_center = @CcCode)
      AND   (@Grade     IS NULL OR b.grade = @Grade)
      AND   (@Lot       IS NULL OR b.lot LIKE @Lot + '%')
    ORDER BY b.cost_center, b.grade, b.lot,
             ISNULL(q.pallet_running_no, 2147483647),
             COALESCE(q.bag_no, b.bag_no, 2147483647),
             b.create_datetime, b.id
    OPTION (RECOMPILE);

    --  Result Set #4 = rejected bags (is_active = 'R')
    SELECT  b.id, b.bag_no, b.grade, b.lot, b.qr_text_data,
            b.remark AS reject_reason, b.update_datetime AS reject_datetime,
            'rejected' AS status
    FROM    dbo.tr_bag b WITH (NOLOCK)
    WHERE   b.is_active = 'R'
      AND   (@PrintDateStart IS NULL OR b.create_datetime >= @PrintDateStart)
      AND   (@PrintDateEnd   IS NULL OR b.create_datetime <  @PrintDateEnd)
      AND   (@CcCode    IS NULL OR b.cost_center = @CcCode)
      AND   (@Grade     IS NULL OR b.grade = @Grade)
      AND   (@Lot       IS NULL OR b.lot LIKE @Lot + '%')
    ORDER BY b.update_datetime DESC
    OPTION (RECOMPILE);

    DROP TABLE #BagGroup;
    DROP TABLE #PalletAgg;
    DROP TABLE #PalletInfo;
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.sp_PalletAdjustment_GetOverview @PrintDateFrom = '2026-11-06', @PrintDateTo = '2026-11-06'
