/* =====================================================================
   122_rollback_pJira_FR001.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   คืน pJira_FR001 กลับเป็นเวอร์ชันก่อน 122_
   = OBJECT_DEFINITION จาก .75 (RY19-OPS13DBQAS) วันที่ 2026-11-13 , modify_date 2026-11-05 14:15
   ===================================================================== */
GO
-- pJira_FR001 '2026-09-01 01:00:00'

ALTER PROC [dbo].[pJira_FR001]
    @datetime           DATETIME            = NULL,
    @idle_minutes       INT                 = 60
AS
BEGIN
    SET NOCOUNT ON;

    SET @datetime = ISNULL(@datetime, GETDATE());
    DECLARE @idle_before DATETIME = DATEADD(MINUTE, -ISNULL(@idle_minutes, 60), GETDATE());

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
    INNER JOIN [IRPC_QTRACK].[dbo].[tr_bag] tb
        ON tb.[cost_center] = ss.[from_plant_cc_code] COLLATE DATABASE_DEFAULT
        AND REPLACE(tb.[grade], ' ', '') = ss.grade COLLATE DATABASE_DEFAULT
        AND tb.lot = ss.lot_no COLLATE DATABASE_DEFAULT
        AND tb.[create_datetime] >= ss.wh_pre_approve_datetime
        AND tb.[create_datetime] < ISNULL(ss.next_same_lot_datetime, ss.shift_end_datetime)
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
        FROM [IRPC_QTRACK].[dbo].[tr_bag] pb
        WHERE pb.[pallet_id]   = p.pallet_id
          AND pb.[is_active]   = 'Y'
          AND pb.[status_flag] = 'A'
    ) last_bag
    WHERE
        tp.[pallet_status_id] IN (2, 3)
        OR last_bag.last_bag_datetime < @idle_before
        OR EXISTS
        (
            SELECT 1
            FROM [IRPC_QTRACK].[dbo].[tr_bag] next_bag
            WHERE next_bag.[cost_center]     = p.cost_center
              AND next_bag.[create_datetime] > last_bag.last_bag_datetime
              AND next_bag.[pallet_id]      <> p.pallet_id
              AND next_bag.[is_active]       = 'Y'
              AND next_bag.[status_flag]     = 'A'
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
