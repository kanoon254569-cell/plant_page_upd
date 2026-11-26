/* =====================================================================
   122_pJira_FR001_no_block_bag_insert.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   base = OBJECT_DEFINITION บน .75 (RY19-OPS13DBQAS) 2026-11-13 , modify_date 2026-11-05 14:15
   rollback = 122_rollback_pJira_FR001.sql

   ปัญหา (ตรวจ 2026-11-13) : ถุงที่พิมพ์ QR แล้วหายไปจาก tr_bag (เช่น 1311|1100RC|0261102018|19|052)
     - วันที่ 11-13 หาย 61+ ใบ , เกือบทุกใบเกิดตอน job FR001 (Hangfire ทุก 5 นาที) กำลังรัน step 2
     - จับได้สด 11:55:03-05 : pProcessInsertTrBag รอ LCK_M_IX บน PAGE ของ IX_tr_bag_match_status
       (สูงสุด 942 ms) โดยมี pJira_FR001 เป็นตัว block -> โปรแกรมพิมพ์ยอมแพ้ภายใน ~1 วินาที
       แล้วทิ้งถุงนั้น -> หาย 2 ใบ (1324|BC03B|02611033|29|083 , 1379|GP150|2611212|33|018)
     - สาเหตุ : step 2 seek ช่วง create_datetime ไปจนถึงเวลาสิ้นสุดกะ (= เลยเวลาปัจจุบัน)
       ด้วย S page lock -> ไปล็อกหน้าสุดท้ายของ index ที่ถุงใหม่กำลัง INSERT เข้าไปพอดี

   แก้ (เฉพาะ SP นี้ ไม่แตะ table / index / DB option) :
   1) @cutoff = GETDATE() - @hold_back_minutes (default 3)
      step 2 อ่านเฉพาะถุงที่ create_datetime < @cutoff -> ไม่ไปแตะหน้าท้ายที่กำลัง insert
      ถุงที่ใหม่กว่านี้ถูกส่งในรอบถัดไป (5 นาที) ; ช่วงเปลี่ยนกะ C# รันกะก่อนซ้ำ 10 นาที (> 3) จึงไม่ตกหล่น
   2) WITH (ROWLOCK) บน tr_bag ทั้ง 3 จุด (step 2 , step 3 pb / next_bag)
      -> lock ระดับแถว ไม่ขึ้นเป็น page ; S lock ของแถวเดิมไม่ชน IX/X ของแถวใหม่ที่ INSERT
      (tr_bag ตั้ง LOCK_ESCALATION = DISABLE แล้ว จึงไม่ escalate เป็น table)
   3) step 3 : พาเลทที่ยังมีถุงใหม่กว่า @cutoff รอรอบถัดไปทั้งพาเลท
      -> ไม่เกิดกรณีส่งถุงของพาเลทเดียวกันครึ่งหนึ่งเพราะ @cutoff

   ไม่เปลี่ยน : result set ทั้ง 2 ชุด (dbResult = slips , dbResult1 = bags) คอลัมน์/ลำดับเหมือนเดิม ,
               parameter เดิม (@datetime , @idle_minutes) -- @hold_back_minutes เป็น optional ตัวใหม่
               C# PalletConfirmService ไม่ต้องแก้
   ===================================================================== */
GO
-- pJira_FR001 '2026-09-01 01:00:00'

ALTER PROC [dbo].[pJira_FR001]
    @datetime           DATETIME            = NULL,
    @idle_minutes       INT                 = 60,
    @hold_back_minutes  INT                 = 3         -- (122_)
AS
BEGIN
    SET NOCOUNT ON;

    SET @datetime = ISNULL(@datetime, GETDATE());
    DECLARE @idle_before DATETIME = DATEADD(MINUTE, -ISNULL(@idle_minutes, 60), GETDATE());

    -- (122_) Leave the newest bags alone. The printing line inserts at the tail of
    -- every create_datetime index; reading up to "now" put S page locks right on
    -- the page being inserted into and the printer's INSERT gave up (bag lost).
    -- Bags newer than this are picked up by the next run (5 min later).
    DECLARE @cutoff DATETIME = DATEADD(MINUTE, -ISNULL(@hold_back_minutes, 3), GETDATE());

    -- ========================================================
    -- 1. Transfer slips approved in the shift of @datetime
    -- ========================================================

    ;WITH shifts AS
    (
        SELECT shift_id, CAST(shift_start_time AS TIME) AS start_time, CAST(shift_end_time AS TIME) AS end_time
        FROM (VALUES
            (1, '06:00:00', '14:00:00'),
            (2, '14:00:00', '22:00:00'),
            (3, '22:00:00', '06:00:00')
        ) s (shift_id, shift_start_time, shift_end_time)
    ),
    current_shift AS
    (
        SELECT TOP 1
            s.shift_id,
            DATEADD(DAY,
                CASE WHEN s.start_time > s.end_time AND CAST(@datetime AS TIME) < s.end_time THEN -1 ELSE 0 END,
                CAST(CAST(@datetime AS DATE) AS DATETIME) + CAST(s.start_time AS DATETIME)
            ) AS shift_start_datetime,
            DATEADD(DAY,
                CASE WHEN s.start_time > s.end_time AND CAST(@datetime AS TIME) >= s.start_time THEN 1 ELSE 0 END,
                CAST(CAST(@datetime AS DATE) AS DATETIME) + CAST(s.end_time AS DATETIME)
            ) AS shift_end_datetime
        FROM shifts s
        WHERE
            (s.start_time < s.end_time
                AND CAST(@datetime AS TIME) >= s.start_time
                AND CAST(@datetime AS TIME) < s.end_time)
            OR
            (s.start_time > s.end_time
                AND (CAST(@datetime AS TIME) >= s.start_time OR CAST(@datetime AS TIME) < s.end_time))
    ),
    shift_items AS
    (
        SELECT
            tsf.*,
            cs.shift_id,
            cs.shift_start_datetime,
            cs.shift_end_datetime,
            ROW_NUMBER() OVER
            (
                PARTITION BY tsf.header_id, tsf.grade, tsf.lot_no
                ORDER BY tsf.item_id ASC
            ) AS item_rn
        FROM [IRPC_E_TRANSFER].[dbo].[VTransferSlip] tsf
        CROSS JOIN current_shift cs
        WHERE
            tsf.wh_pre_approve_datetime >= cs.shift_start_datetime
            AND tsf.wh_pre_approve_datetime < cs.shift_end_datetime
            AND tsf.wh_name IN ('A41')
            AND tsf.status_id IN (2, 3)
    ),
    slips AS
    (
        SELECT
            si.*,
            ROW_NUMBER() OVER
            (
                PARTITION BY si.from_plant_cc_code, si.grade, si.lot_no, si.wh_pre_approve_datetime
                ORDER BY si.header_id ASC
            ) AS same_time_rn
        FROM shift_items si
        WHERE si.item_rn = 1
    ),
    slip_windows AS
    (
        SELECT
            sl.header_id,
            sl.grade,
            sl.lot_no,
            LEAD(sl.wh_pre_approve_datetime) OVER
            (
                PARTITION BY sl.from_plant_cc_code, sl.grade, sl.lot_no
                ORDER BY sl.wh_pre_approve_datetime ASC
            ) AS next_same_lot_datetime
        FROM slips sl
        WHERE sl.same_time_rn = 1
    )
    SELECT
        sl.*,
        sw.next_same_lot_datetime
    INTO #shift_slips
    FROM slips sl
    LEFT JOIN slip_windows sw
        ON sw.header_id = sl.header_id
        AND sw.grade = sl.grade
        AND sw.lot_no = sl.lot_no
        AND sl.same_time_rn = 1;

    SELECT * FROM #shift_slips;

    -- ========================================================
    -- 2. Unsynced bags made in each slip's window
    -- ========================================================

    SELECT
        ss.wms_tr_tran_no,
        ss.wh_name,
        ss.wms_group,
        ss.from_cc_code_wms,
        tb.id,
        tb.cost_center,
        tb.grade,
        tb.pallet_id,
        tb.pallet_running_no,
        tb.qr_text_data,
        tb.create_datetime
    INTO #shift_bags
    FROM #shift_slips ss
    INNER JOIN [IRPC_QTRACK].[dbo].[tr_bag] tb WITH (ROWLOCK)     -- (122_) no S page locks on tr_bag
        ON tb.[cost_center] = ss.[from_plant_cc_code] COLLATE DATABASE_DEFAULT
        AND REPLACE(tb.[grade], ' ', '') = ss.grade COLLATE DATABASE_DEFAULT
        AND tb.lot = ss.lot_no COLLATE DATABASE_DEFAULT
        AND tb.[create_datetime] >= ss.wh_pre_approve_datetime
        -- (122_) one upper bound = MIN(window end, @cutoff) so the index seek itself
        --        stops before the tail instead of reading it and filtering afterwards
        AND tb.[create_datetime] < CASE WHEN ISNULL(ss.next_same_lot_datetime, ss.shift_end_datetime) < @cutoff
                                        THEN ISNULL(ss.next_same_lot_datetime, ss.shift_end_datetime)
                                        ELSE @cutoff END
        AND tb.[is_active] = 'Y' AND tb.[status_flag] = 'A'
        AND tb.[pallet_id] IS NOT NULL
        AND tb.[sync_wms_datetime] IS NULL
    WHERE ss.same_time_rn = 1
        AND ss.wms_tr_tran_no IS NOT NULL;

    -- ========================================================
    -- 3. Finished pallets, checked once per pallet
    -- ========================================================

    SELECT
        p.pallet_id,
        [dbo].[fGetPalletQty](p.pallet_id) AS pallet_qty
    INTO #done_pallets
    FROM
    (
        -- One row per pallet, so no bag comes back twice.
        SELECT pallet_id, MIN(cost_center) AS cost_center
        FROM #shift_bags
        GROUP BY pallet_id
    ) p
    INNER JOIN [IRPC_QTRACK].[dbo].[tr_pallet] tp
        ON tp.[id] = p.pallet_id
        AND tp.[is_active] = 'Y' AND tp.[status_flag] = 'A'
        AND tp.[pallet_type] = 'A'
    CROSS APPLY
    (
        SELECT MAX(pb.[create_datetime]) AS last_bag_datetime
        FROM [IRPC_QTRACK].[dbo].[tr_bag] pb WITH (ROWLOCK)          -- (122_)
        WHERE pb.[pallet_id]   = p.pallet_id
          AND pb.[is_active]   = 'Y'
          AND pb.[status_flag] = 'A'
    ) last_bag
    WHERE
        -- (122_) a pallet with a bag newer than @cutoff waits for the next run,
        -- so its bags are never sent half now and half later because of @cutoff.
        last_bag.last_bag_datetime < @cutoff
        AND
        (
        tp.[pallet_status_id] IN (2, 3)
        OR last_bag.last_bag_datetime < @idle_before
        OR EXISTS
        (
            SELECT 1
            FROM [IRPC_QTRACK].[dbo].[tr_bag] next_bag WITH (ROWLOCK)  -- (122_)
            WHERE next_bag.[cost_center]     = p.cost_center
              AND next_bag.[create_datetime] > last_bag.last_bag_datetime
              AND next_bag.[pallet_id]      <> p.pallet_id
              AND next_bag.[is_active]       = 'Y'
              AND next_bag.[status_flag]     = 'A'
        )
        );

    -- ========================================================
    -- Result: bags of finished pallets
    -- ========================================================

    SELECT TOP 200
        sb.wms_tr_tran_no AS tr_tran_no,
        --NULL AS tr_tran_no,
        sb.wh_name AS wh_code,
        '-' AS rc_type,
        REPLACE(sb.grade, ' ', '') AS bag_grade,
        sb.pallet_running_no AS pallet_running,
        sb.wms_group AS pallet_pd_type,
        sb.from_cc_code_wms AS product_cc,
        sb.id AS bag_id,
        sb.qr_text_data AS bag_qr_code,
        dp.pallet_qty AS bag_weight,
        'KG' AS bag_weight_unit
    FROM #shift_bags sb
    INNER JOIN #done_pallets dp
        ON dp.pallet_id = sb.pallet_id
    ORDER BY sb.create_datetime ASC;
END
GO
