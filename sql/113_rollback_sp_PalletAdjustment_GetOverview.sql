/* =====================================================================
   113_rollback_sp_PalletAdjustment_GetOverview.sql  (IRPC_QTRACK)
   ย้อน 113_ กลับเป็น definition เดิม (= 01_sp_PalletAdjustment_GetOverview.sql ซึ่งตรงกับที่ deploy บน QAS 2026-11-06)
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
    --  วันที่พิมพ์แบบช่วง (inclusive ทั้งสองฝั่ง) -- ต่อท้ายเพื่อไม่ให้การเรียกแบบ
    --  positional เดิมพัง; ถ้าไม่ส่งมาทั้งคู่จะ fallback ไปใช้ @PrintDate วันเดียวแบบเดิม
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

    --  แปลงช่วงวันที่เป็น [start, end) แทนการ CAST(column AS DATE) ที่ column
    --  เพราะการ CAST คอลัมน์จะทำให้ index บน create_datetime ใช้ไม่ได้ (non-sargable)
    --  ฝั่งใดเป็น NULL = ไม่จำกัดฝั่งนั้น
    DECLARE @PrintDateStart DATETIME = @PrintDateFrom;
    DECLARE @PrintDateEnd   DATETIME = DATEADD(DAY, 1, @PrintDateTo);

    ------------------------------------------------------------------
    --  NOTE: ใช้ #temp table แทน CTE เพราะ CTE ใน SQL Server มีผลแค่
    --  statement เดียวถัดไปเท่านั้น ส่วน SP นี้ต้องคืน 3 result sets ที่ต้อง
    --  reuse ผลลัพธ์ชุดเดียวกันซ้ำ -- ทำครั้งเดียว ใส่ index บน temp table
    --  แล้วให้ query ทั้ง 3 อ่านจาก temp table (compile ครั้งเดียว, scan ตาราง
    --  จริงแค่รอบเดียว ไม่ต้อง query tr_bag/tr_pallet ซ้ำ 3 รอบ)
    ------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#FilteredBag') IS NOT NULL DROP TABLE #FilteredBag;
    SELECT  b.id, b.pallet_id, b.bag_no, b.grade, b.lot, b.cost_center,
            b.qr_text_data, b.create_datetime
    INTO    #FilteredBag
    FROM    dbo.tr_bag b WITH (NOLOCK)
    WHERE   b.is_active = 'Y'
      AND   (@PrintDateStart IS NULL OR b.create_datetime >= @PrintDateStart)
      AND   (@PrintDateEnd   IS NULL OR b.create_datetime <  @PrintDateEnd)
      AND   (@CcCode    IS NULL OR b.cost_center = @CcCode)
      AND   (@Grade     IS NULL OR b.grade = @Grade)
      AND   (@Lot       IS NULL OR b.lot LIKE @Lot + '%')
    OPTION (RECOMPILE);

    CREATE CLUSTERED INDEX IX_temp_FilteredBag_pallet ON #FilteredBag (pallet_id);

    IF OBJECT_ID('tempdb..#PalletInfo') IS NOT NULL DROP TABLE #PalletInfo;
    SELECT  p.id, p.pallet_no, p.pd_group_code, p.unit_pallet, p.pallet_type,
            p.current_location_type, p.current_location_id,
            p.pallet_status_id, p.create_datetime,
            ac.bag_count,
            fb.grade, fb.lot,
            --  running pallet no (ส่วนที่ 5 ของ QR ถุง cost_center|grade|lot|bag_no|pallet_running_no)
            --  เอาค่าที่ถุงบนพาเลทใช้มากที่สุด (เท่ากันเอาค่าน้อย) -- แสดง 3 หลักเหมือนใน QR เช่น 001
            RIGHT('000' + CAST(rn.pallet_running_no AS VARCHAR(10)), 3) AS pallet_running_no,
            CASE
                WHEN p.pallet_status_id = 2 THEN 'complete'
                WHEN p.pallet_status_id = 3 THEN 'confirmed'
                ELSE 'wh_process'
            END AS status
    INTO    #PalletInfo
    FROM    dbo.tr_pallet p WITH (NOLOCK)
    --  pc = พาเลทที่มีถุงอย่างน้อย 1 ใบตรง filter (วันที่พิมพ์/cc/grade/lot) -- ใช้เลือกว่าพาเลท
    --  ไหนจะแสดงเท่านั้น
    INNER JOIN (
        SELECT  DISTINCT pallet_id
        FROM    #FilteredBag
        WHERE   pallet_id IS NOT NULL
    ) pc ON pc.pallet_id = p.id
    --  ac = จำนวนถุงจริงทั้งพาเลท (ไม่กรองวันที่) ให้ตรงกับ Bag List (02_GetBagList) --
    --  เดิมนับจาก #FilteredBag ทำให้พาเลทที่ถุงพิมพ์ข้ามวันแสดงขาด (เช่น 14/40 ทั้งที่มีครบ 40
    --  เพราะ 26 ใบพิมพ์วันก่อน) ; ใช้ IX_tr_bag_pallet_bagno (filtered is_active='Y')
    CROSS APPLY (
        SELECT  COUNT(*) AS bag_count
        FROM    dbo.tr_bag ab WITH (NOLOCK)
        WHERE   ab.pallet_id = p.id AND ab.is_active = 'Y'
    ) ac
    OUTER APPLY (
        SELECT TOP (1) grade, lot
        FROM   #FilteredBag fb2
        WHERE  fb2.pallet_id = p.id
    ) fb
    OUTER APPLY (
        SELECT TOP (1) q.pallet_running_no
        FROM   #FilteredBag fb3
        CROSS APPLY dbo.fParseBagQr(fb3.qr_text_data) q
        WHERE  fb3.pallet_id = p.id
          AND  q.pallet_running_no IS NOT NULL
        GROUP BY q.pallet_running_no
        ORDER BY COUNT(*) DESC, q.pallet_running_no
    ) rn
    WHERE   p.is_active = 'Y'
      --  แสดงเฉพาะพาเลท Auto (pallet_type = 'A') -- ไม่รวม Manual (M/S), JB (J) ฯลฯ
      AND   p.pallet_type = 'A'
      AND   ISNULL(p.pallet_status_id, 1) <> 4;

    CREATE CLUSTERED INDEX IX_temp_PalletInfo_grade ON #PalletInfo (grade, pallet_no);

    --  Result Set #1 = summary
    SELECT
        (SELECT COUNT(*) FROM #PalletInfo)                                    AS total_pallets,
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'wh_process')        AS wh_process,
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'complete')          AS complete,
        (SELECT COUNT(*) FROM #FilteredBag)                                    AS total_bags,
        (SELECT COUNT(*) FROM #FilteredBag WHERE pallet_id IS NULL)            AS orphan_bags,
        --  พาเลทที่ถูกกด "จบพาเลท" ยืนยันเป็นพาเลทเศษแล้ว (status = 'confirmed',
        --  pallet_status_id = 3 CONFIRMED, ดู 00_master_pallet_status.sql) -- นับพาเลท
        --  ไม่ใช่ถุง -- ไม่ทับซ้อนกับ complete อีกต่อไป (คนละ status literal กันแล้ว)
        (SELECT COUNT(*) FROM #PalletInfo WHERE status = 'confirmed')          AS confirmed_remainder;

    --  Result Set #2 = pallets grouped by grade
    SELECT  grade, unit_pallet, id, pallet_no, lot, pallet_running_no, pallet_type,
            bag_count, unit_pallet AS pallet_unit_pallet,
            current_location_type, current_location_id, create_datetime, status
    FROM    #PalletInfo
    ORDER BY grade, pallet_no;

    --  Result Set #3 = orphan bags
    --  เรียง cost_center, grade, lot, pallet (ตันใน QR), bag (เลขถุงใน QR) -- ใช้ค่าจาก QR
    --  ก่อน เพราะคอลัมน์ bag_no อาจเป็น NULL/ถูก renumber ; QR แกะไม่ได้ -> fallback คอลัมน์
    --  (pallet_running_no ไม่มีใน #FilteredBag จึงใช้ค่า QR อย่างเดียว ; ไม่มีค่าไว้ท้ายกลุ่ม)
    SELECT  fb.id, fb.bag_no, fb.grade, fb.lot, fb.qr_text_data, 'orphan' AS status
    FROM    #FilteredBag fb
    OUTER APPLY dbo.fParseBagQr(fb.qr_text_data) q
    WHERE   fb.pallet_id IS NULL
    ORDER BY fb.cost_center, fb.grade, fb.lot,
             ISNULL(q.pallet_running_no, 2147483647),
             COALESCE(q.bag_no, fb.bag_no, 2147483647),
             fb.create_datetime, fb.id;

    --  Result Set #4 = rejected bags (dbo.pProcessUpdateBagRejectStatus
    --  @reject=1 sets is_active='R') -- not part of #FilteredBag since that
    --  only keeps is_active='Y', so queried directly against tr_bag here
    --  with the same date/cc/grade/lot filters.
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
    ORDER BY b.update_datetime DESC;

    DROP TABLE #FilteredBag;
    DROP TABLE #PalletInfo;
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.sp_PalletAdjustment_GetOverview @PrintDateFrom = '2026-08-01', @PrintDateTo = '2026-08-30', @CcCode = '1460', @Grade = '1126NK', @Lot = NULL
