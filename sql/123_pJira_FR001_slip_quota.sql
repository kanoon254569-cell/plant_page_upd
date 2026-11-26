/* =====================================================================
   123_pJira_FR001_slip_quota.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   base     = 122_pJira_FR001_no_block_bag_insert.sql (ROWLOCK + @cutoff kept)
   rollback = 123_rollback_pJira_FR001.sql
   *** NOT DEPLOYED -- review / test before running on any environment ***

   ปัญหา (ตรวจบน .75 2026-11-13) :
     - ถุงถูกผลิต "ก่อน" ใบ TransferSlip ถูก pre-approve บ่อยมาก
       เช่น lot 1301/P921BK/0261106021 ผลิต 6,211 ถุง 11-12 06:31-12:54
       แต่ใบ 4 ใบ approve 08:57 / 18:14 / 06:04(+1) / 08:52(+1)
     - เดิมแบ่งถุงด้วยช่วงเวลา (approve -> approve ใบถัดไป / สิ้นกะ)
       -> TS261100191 ได้ 3,824 ถุง (โควตา 2,400) , อีก 3 ใบได้ 0 ,
          ถุงก่อน 08:57 2,387 ถุงไม่ถูกส่งเลย ; รอยต่อกะทำถุงหลุดเพิ่ม
     - SUM(qty_bag) ของใบใน CC+grade+lot เดียวกัน = จำนวนถุงจริง (6,210 vs 6,211)
     - เดิมกรองใบ status_id 2,3 -> ใบที่เดินไป 6 SAP Success หลุด
       (เช่น TS261100207 qty_bag 5,400 -> lot ส่งไปแค่ 5 จาก 5,875 ถุง)

   แก้ : แบ่ง "พาเลท" ให้ใบตามโควตา qty_bag แบบ FIFO คำนวณใหม่ทุกรอบ
         (ไม่เพิ่ม column / table -- SP อ่านอย่างเดียวเหมือนเดิม)
     key       = from_plant_cc_code + grade + lot_no (wh_name = 'A41')
     สถานะใบ   = "นับโควตา" status_id 2-6 , "ส่ง" เฉพาะ status_id 2,3
                 (1 Create / 7 Cancel ไม่นับ)
     ใบ        = เรียง wh_pre_approve_datetime, header_id ;
                 โควตา = SUM(qty_bag) ต่อ header_id (บางใบมี 2 item)
                 ช่วงโควตาสะสมของใบ = [cum_start, cum_end)
     used      = ถุงของ key ที่ sync แล้ว (sync_wms_datetime NOT NULL)
     พาเลท     = พาเลทที่เสร็จแล้ว (กติกาเดิมของ 122) ที่ยังมีถุงไม่ sync
                 เรียงตามเวลาถุงแรก ; ขนาด = จำนวนถุงที่ยังไม่ sync
     ตำแหน่ง   = used + ถุงของพาเลทก่อนหน้า (ใน key เดียวกัน)
     ใบของพาเลท = ใบที่ cum_start <= ตำแหน่งเริ่มของพาเลท < cum_end
                 -> ทั้งพาเลทไปใบนั้น ไม่แยกถุง ; ถ้าเกินโควตา ส่วนเกินไปกินโควตาใบถัดไป
     รอ        = ตำแหน่ง >= โควตารวม (ยังไม่มีใบรองรับ) หรือใบนั้นยังไม่มี wms_tr_tran_no
                 -> พาเลทนั้น "และพาเลทถัดไปใน key เดียวกัน" รอรอบหน้า
     ส่ง       = พาเลทก่อนจุดรอ ที่ใบเป็น status 2,3
                 พาเลทของใบ 4-6 นับตำแหน่ง (กินโควตา) แต่ไม่ส่ง AWH
     ไม่ผูกกับกะ : ดู key ที่มีใบ approve ภายใน @lookback_days ; ใช้ทุกใบของ key นั้น
                 ถุงของ key ตั้งแต่ (approve ใบแรกของ key - @pre_approve_hours) ถึง @cutoff

   ไม่เปลี่ยน (C# PalletConfirmService ไม่ต้องแก้) :
     result set 2 ชุด : dbResult = ใบ (debug) , dbResult1 = ถุง คอลัมน์/ชื่อเหมือนเดิม
     parameter เดิมยังรับได้ (@datetime ไม่ใช้แล้ว -- ไม่ผูกกับกะ)
     bag_weight = สูตรเดียวกับ fGetPalletQty (คำนวณครั้งเดียวต่อพาเลทจากถุงที่อ่านมาแล้ว
                  ไม่เรียก function ที่ scan tr_bag ซ้ำทีละแถว) , bag_weight_unit = 'KG' , rc_type = '-'
     ไม่เขียน table ใด ๆ
   เปลี่ยน :
     dbResult1 ส่งเป็น "ทั้งพาเลท" ไม่เกิน @max_bags (200) ต่อรอบ (อย่างน้อย 1 พาเลท)

   ข้อจำกัดที่รู้ (เพราะไม่เก็บผลการแบ่ง) :
     - TRTRANNO ของพาเลทที่ "ยังส่งไม่สำเร็จ" อาจเปลี่ยนในรอบถัดไป ถ้า
       พาเลทที่ถุงแรกเก่ากว่าเพิ่งเสร็จทีหลัง / ใบถูก Cancel หรือแก้ qty_bag /
       จำนวนถุงในพาเลทเปลี่ยน (พาเลทที่ sync แล้วไม่กระทบ)
     - พาเลท legacy ที่ sync ไปแล้วครึ่งพาเลท : ถุงที่เหลือถูกจัดใบตามตำแหน่ง (อาจคนละใบ)
     - พาเลทที่มีถุงหลาย key ข้ามไป (ไม่ส่ง) -- ดูได้ใน dbResult คอลัมน์ skipped_mixed_pallets
     - key ที่ไม่มีใบ approve ใน @lookback_days แล้ว จะไม่ถูกดูอีก
   ===================================================================== */
USE [IRPC_QTRACK];
GO

-- pJira_FR001
-- pJira_FR001 @lookback_days = 2, @max_bags = 200
ALTER PROC [dbo].[pJira_FR001]
    @datetime           DATETIME    = NULL,     -- (123_) unused, kept so C# still binds
    @idle_minutes       INT         = 60,
    @hold_back_minutes  INT         = 3,        -- (122_)
    @lookback_days      INT         = 2,        -- (123_) keys with a slip approved this recently
    @pre_approve_hours  INT         = 24,       -- (123_) bags made up to this long before a key's first slip
    @max_bags           INT         = 200,      -- (123_) whole pallets up to this many bags per run
    --  (123_) send only pallets whose first bag is at/after this time.
    --  NULL = also send the backlog never sent by the old time-window
    --  logic. Older pallets are then ignored and take no quota.
    @send_from          DATETIME    = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @now         DATETIME = GETDATE();
    DECLARE @idle_before DATETIME = DATEADD(MINUTE, -ISNULL(@idle_minutes, 60), @now);
    DECLARE @cutoff      DATETIME = DATEADD(MINUTE, -ISNULL(@hold_back_minutes, 3), @now);   -- (122_)
    DECLARE @recent_from DATETIME = DATEADD(DAY, -ISNULL(@lookback_days, 2), @now);
    SET @max_bags = ISNULL(NULLIF(@max_bags, 0), 200);

    -- ========================================================
    -- 1. Slips per key, quota = SUM(qty_bag) per header
    -- ========================================================

    --  Keys (cc + grade + lot) with a slip approved recently.
    SELECT DISTINCT
        tsf.from_plant_cc_code AS cc,
        tsf.grade,
        tsf.lot_no
    INTO #key
    FROM [IRPC_E_TRANSFER].[dbo].[VTransferSlip] tsf
    WHERE tsf.wh_name = 'A41'
      AND tsf.status_id IN (2, 3, 4, 5, 6)     -- (123_) same set as the quota below
      AND tsf.wh_pre_approve_datetime >= @recent_from;

    --  EVERY slip of those keys (no date filter): the FIFO order
    --  must start from the key's first slip or the quotas shift.
    SELECT
        tsf.header_id,
        tsf.from_plant_cc_code             AS cc,
        tsf.grade,
        tsf.lot_no,
        MIN(tsf.wh_pre_approve_datetime)   AS approve_datetime,
        MIN(tsf.wms_tr_tran_no)            AS tr_tran_no,
        MIN(tsf.wh_name)                   AS wh_name,
        MIN(tsf.wms_group)                 AS wms_group,
        MIN(tsf.from_cc_code_wms)          AS from_cc_code_wms,
        MAX(tsf.status_id)                 AS status_id,   -- header status (same on every item)
        SUM(ISNULL(tsf.qty_bag, 0))        AS quota
    INTO #slip_raw
    FROM [IRPC_E_TRANSFER].[dbo].[VTransferSlip] tsf
    INNER JOIN #key k
        ON  k.cc     = tsf.from_plant_cc_code
        AND k.grade  = tsf.grade
        AND k.lot_no = tsf.lot_no
    WHERE tsf.wh_name = 'A41'
      --  QUOTA counts 2-6: a slip that moved on (6 = SAP Success)
      --  still holds its place in the FIFO. SENDING is 2,3 only (step 5).
      --  1 Create / 7 Cancel out.
      AND tsf.status_id IN (2, 3, 4, 5, 6)
      AND tsf.wh_pre_approve_datetime IS NOT NULL
    GROUP BY tsf.header_id, tsf.from_plant_cc_code, tsf.grade, tsf.lot_no;

    SELECT
        s.*,
        SUM(s.quota) OVER
        (
            PARTITION BY s.cc, s.grade, s.lot_no
            ORDER BY s.approve_datetime, s.header_id
            ROWS UNBOUNDED PRECEDING
        ) AS cum_end
    INTO #slip
    FROM #slip_raw s;

    --  Bag window per key.
    SELECT
        s.cc,
        s.grade,
        s.lot_no,
        DATEADD(HOUR, -ISNULL(@pre_approve_hours, 24), MIN(s.approve_datetime)) AS bag_from
    INTO #key_win
    FROM #slip s
    GROUP BY s.cc, s.grade, s.lot_no;

    -- ========================================================
    -- 2. Bags of those keys (synced too: they count as used quota)
    -- ========================================================
    SELECT
        kw.cc,
        kw.grade,
        kw.lot_no,
        tb.id,
        tb.pallet_id,
        tb.pallet_running_no,
        tb.qr_text_data,
        tb.grade AS bag_grade,
        tb.create_datetime,
        tb.sync_wms_datetime
    INTO #bag
    FROM #key_win kw
    INNER JOIN [dbo].[tr_bag] tb WITH (ROWLOCK)                     -- (122_)
        ON  tb.[cost_center]     = kw.cc COLLATE DATABASE_DEFAULT
        AND tb.[create_datetime] >= kw.bag_from
        AND tb.[create_datetime] <  @cutoff                         -- (122_)
        AND REPLACE(tb.[grade], ' ', '') = kw.grade COLLATE DATABASE_DEFAULT
        AND tb.[lot] = kw.lot_no COLLATE DATABASE_DEFAULT
        AND tb.[is_active] = 'Y' AND tb.[status_flag] = 'A'
        AND tb.[pallet_id] IS NOT NULL;

    --  used = bags of the key already sent.
    SELECT
        b.cc,
        b.grade,
        b.lot_no,
        SUM(CASE WHEN b.sync_wms_datetime IS NOT NULL THEN 1 ELSE 0 END) AS used_bags
    INTO #used
    FROM #bag b
    GROUP BY b.cc, b.grade, b.lot_no;

    -- ========================================================
    -- 3. Pallets
    -- ========================================================
    SELECT
        b.pallet_id,
        MIN(b.cc)       AS cc,
        MIN(b.grade)    AS grade,
        MIN(b.lot_no)   AS lot_no,
        COUNT(DISTINCT CONCAT(b.cc, '|', b.grade, '|', b.lot_no)) AS key_count,
        SUM(CASE WHEN b.sync_wms_datetime IS NULL THEN 1 ELSE 0 END) AS unsynced_bags,
        MIN(b.create_datetime) AS first_bag_datetime,
        tp.pallet_type,
        tp.pallet_status_id,
        --  (123_) same formula as fGetPalletQty, from bags already read:
        --  fGetPalletQty re-scans tr_bag by pallet_id (~0.3 s, no
        --  ROWLOCK) and was called once per output bag row.
        CASE WHEN tp.pallet_type IN ('M', 'S')
             THEN ISNULL(tp.unit_ratio, 0) * ISNULL(tp.unit_pallet, 0)
             ELSE COUNT(*) * ISNULL(tp.unit_ratio, 0)
        END AS pallet_qty
    INTO #pal
    FROM #bag b
    INNER JOIN [dbo].[tr_pallet] tp
        ON  tp.[id] = b.pallet_id
        AND tp.[is_active] = 'Y' AND tp.[status_flag] = 'A'
    GROUP BY b.pallet_id, tp.pallet_type, tp.pallet_status_id, tp.unit_ratio, tp.unit_pallet;

    -- ========================================================
    -- 4. Finished pallets with unsent bags -> FIFO position -> slip
    -- ========================================================
    SELECT
        p.pallet_id,
        p.cc,
        p.grade,
        p.lot_no,
        p.unsynced_bags,
        p.pallet_qty,
        p.first_bag_datetime
    INTO #cand
    FROM #pal p
    CROSS APPLY
    (
        SELECT MAX(pb.[create_datetime]) AS last_bag_datetime
        FROM [dbo].[tr_bag] pb WITH (ROWLOCK)                       -- (122_)
        WHERE pb.[pallet_id]   = p.pallet_id
          AND pb.[is_active]   = 'Y'
          AND pb.[status_flag] = 'A'
    ) last_bag
    WHERE p.unsynced_bags > 0
      AND (@send_from IS NULL OR p.first_bag_datetime >= @send_from)   -- (123_)
      AND p.key_count = 1
      AND p.pallet_type = 'A'
      -- finished pallet (same rules as before 123_)
      AND last_bag.last_bag_datetime < @cutoff                       -- (122_)
      AND
      (
          p.pallet_status_id IN (2, 3)
          OR last_bag.last_bag_datetime < @idle_before
          OR EXISTS
          (
              SELECT 1
              FROM [dbo].[tr_bag] next_bag WITH (ROWLOCK)            -- (122_)
              WHERE next_bag.[cost_center]     = p.cc COLLATE DATABASE_DEFAULT
                AND next_bag.[create_datetime] > last_bag.last_bag_datetime
                AND next_bag.[pallet_id]      <> p.pallet_id
                AND next_bag.[is_active]       = 'Y'
                AND next_bag.[status_flag]     = 'A'
          )
      );

    SELECT
        c.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY c.cc, c.grade, c.lot_no
            ORDER BY c.first_bag_datetime, c.pallet_id
        ) AS rn,
        ISNULL(u.used_bags, 0)
          + SUM(c.unsynced_bags) OVER
            (
                PARTITION BY c.cc, c.grade, c.lot_no
                ORDER BY c.first_bag_datetime, c.pallet_id
                ROWS UNBOUNDED PRECEDING
            )
          - c.unsynced_bags AS start_pos
    INTO #pos
    FROM #cand c
    LEFT JOIN #used u
        ON u.cc = c.cc AND u.grade = c.grade AND u.lot_no = c.lot_no;

    --  Slip whose quota range holds the pallet's FIRST bag: the whole
    --  pallet goes there even if it runs past that slip's quota.
    SELECT
        ps.*,
        s.header_id,
        s.tr_tran_no,
        s.status_id,
        s.wh_name,
        s.wms_group,
        s.from_cc_code_wms
    INTO #assign
    FROM #pos ps
    OUTER APPLY
    (
        SELECT TOP 1 sl.header_id, sl.tr_tran_no, sl.status_id, sl.wh_name, sl.wms_group, sl.from_cc_code_wms
        FROM #slip sl
        WHERE sl.cc = ps.cc AND sl.grade = ps.grade AND sl.lot_no = ps.lot_no
          AND ps.start_pos >= sl.cum_end - sl.quota
          AND ps.start_pos <  sl.cum_end
        ORDER BY sl.approve_datetime, sl.header_id
    ) s;

    --  Use only the unbroken run from the first pallet of each key:
    --  stop at the first pallet with no slip yet (past total quota)
    --  or whose slip has no wms_tr_tran_no yet.
    ;WITH first_block AS
    (
        SELECT a.cc, a.grade, a.lot_no, MIN(a.rn) AS block_rn
        FROM #assign a
        WHERE a.header_id IS NULL OR a.tr_tran_no IS NULL
        GROUP BY a.cc, a.grade, a.lot_no
    )
    SELECT
        a.*,
        CASE WHEN a.header_id IS NOT NULL
              AND a.tr_tran_no IS NOT NULL
              AND (fb.block_rn IS NULL OR a.rn < fb.block_rn)
             THEN 1 ELSE 0 END AS in_run,
        CASE WHEN a.header_id IS NOT NULL
              AND a.tr_tran_no IS NOT NULL
              AND (fb.block_rn IS NULL OR a.rn < fb.block_rn)
              AND a.status_id IN (2, 3)                         -- (123_) send: status 2,3 only
             THEN 1 ELSE 0 END AS to_send
    INTO #plan
    FROM #assign a
    LEFT JOIN first_block fb
        ON fb.cc = a.cc AND fb.grade = a.grade AND fb.lot_no = a.lot_no;

    -- ========================================================
    -- 5. Result 1 (dbResult) : slips + quota use (debug only)
    -- ========================================================
    SELECT
        s.cc                AS from_plant_cc_code,
        s.grade,
        s.lot_no,
        s.header_id,
        s.tr_tran_no        AS wms_tr_tran_no,
        s.status_id,
        CASE WHEN s.status_id IN (2, 3) THEN 'Y' ELSE 'N' END AS send_to_wms,
        s.approve_datetime  AS wh_pre_approve_datetime,
        s.quota             AS qty_bag,
        s.cum_end - s.quota AS cum_start,
        s.cum_end,
        ISNULL(u.used_bags, 0) AS key_used_bags,
        (SELECT COUNT(*) FROM #plan pl
          WHERE pl.header_id = s.header_id AND pl.in_run = 1
            AND pl.cc = s.cc AND pl.grade = s.grade AND pl.lot_no = s.lot_no) AS pallets_this_run,
        (SELECT COUNT(*) FROM #pal p WHERE p.cc = s.cc AND p.grade = s.grade AND p.lot_no = s.lot_no
                                       AND p.key_count > 1) AS skipped_mixed_pallets
    FROM #slip s
    LEFT JOIN #used u
        ON u.cc = s.cc AND u.grade = s.grade AND u.lot_no = s.lot_no
    ORDER BY s.cc, s.grade, s.lot_no, s.approve_datetime, s.header_id;

    -- ========================================================
    -- 6. Result 2 (dbResult1) : bags to send -- whole pallets,
    --    oldest first, up to @max_bags per run (at least one).
    -- ========================================================
    ;WITH send_pal AS
    (
        SELECT
            pl.*,
            SUM(pl.unsynced_bags) OVER
            (
                ORDER BY pl.first_bag_datetime, pl.pallet_id
                ROWS UNBOUNDED PRECEDING
            ) AS cum_bags,
            ROW_NUMBER() OVER (ORDER BY pl.first_bag_datetime, pl.pallet_id) AS send_rn
        FROM #plan pl
        WHERE pl.to_send = 1
    )
    SELECT
        sp.tr_tran_no                      AS tr_tran_no,
        sp.wh_name                         AS wh_code,
        '-'                                AS rc_type,
        REPLACE(b.bag_grade, ' ', '')      AS bag_grade,
        b.pallet_running_no                AS pallet_running,
        sp.wms_group                       AS pallet_pd_type,
        sp.from_cc_code_wms                AS product_cc,
        b.id                               AS bag_id,
        b.qr_text_data                     AS bag_qr_code,
        sp.pallet_qty                      AS bag_weight,      -- (123_) = fGetPalletQty, computed once per pallet
        'KG'                               AS bag_weight_unit
    FROM send_pal sp
    INNER JOIN #bag b
        ON  b.pallet_id = sp.pallet_id
        AND b.sync_wms_datetime IS NULL
    WHERE sp.cum_bags <= @max_bags OR sp.send_rn = 1
    ORDER BY sp.send_rn, b.create_datetime, b.id;
END
GO
