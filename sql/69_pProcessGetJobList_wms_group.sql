/* =====================================================================
   pProcessGetJobList -- return the WMS product group (wms_group, eg. '0T')
   ---------------------------------------------------------------------
   Base: sql/52 (same as live on IRPC_QTRACK as of 2026-10-07).

   Change (69): adds wms_group on the paginated detail rows (dbResult1).
   It is the item's code_t (or, when empty, tr_job_main.product_type)
   mapped through [IRPC_E_TRANSFER].dbo.ct_bagging_code_t, eg.
   'Code T' / 'Code T (QC)' -> '0T', 'Film' -> '0F', 'FG' -> 'FG'.
   The value can already be a wms_group (tr_job_main.product_type holds
   both 'Film' and '0F'), so a match on wms_group itself is kept too.
   Why: WMS stock inquiry filters on prodType = wms_group, not on the
   ct_bagging_code_t.code text, so the select-location stockInquiryForm
   needs this value instead of pd_type.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pProcessGetJobList]
    @id                 INT             = NULL,
    @date               DATE            = NULL,
    @system_no          NVARCHAR(255)   = NULL,
    @from_cc_code       NVARCHAR(255)   = NULL,
    @to_cc_code         NVARCHAR(255)   = NULL,
    @product_cc         NVARCHAR(255)   = NULL,
    @to_wh_code         NVARCHAR(255)   = NULL,
    @from_location_type NVARCHAR(100)   = NULL,
    @from_location_key  NVARCHAR(255)   = NULL,
    @to_location_type   NVARCHAR(100)   = NULL,
    @to_location_key    NVARCHAR(255)   = NULL,
    @status_id          INT             = NULL,
    @type_id            INT             = NULL,
    @topic_name         NVARCHAR(255)   = NULL,
    @page               INT             = 1,
    @page_size          INT             = 10,
    @user_id            INT             = 6
AS
BEGIN
    SET NOCOUNT ON;

    -- =============================================================
    -- Enforce Date for Null to Default Date
    -- =============================================================
    IF @date IS NULL AND @id IS NULL
    BEGIN
        SET @date = CAST(GETDATE() AS DATE);
    END

    -- =============================================================
    -- Enable Job Display for User
    -- =============================================================

    DECLARE @inbound_transfer_slip     NVARCHAR(10) = 'N';
    DECLARE @inbound_receive           NVARCHAR(10) = 'N';
    DECLARE @outbound_request          NVARCHAR(10) = 'N';
    DECLARE @outbound_picking          NVARCHAR(10) = 'N';
    DECLARE @outbound_shipping         NVARCHAR(10) = 'N';
    DECLARE @outbound_special_package  NVARCHAR(10) = 'N';
    DECLARE @outbound_breakage_replacement NVARCHAR(10) = 'N';

    SELECT
        @inbound_transfer_slip      = ISNULL(rp.[inbound_transfer_slip], 'N'),
        @inbound_receive            = ISNULL(rp.[inbound_receive], 'N'),
        @outbound_request           = ISNULL(rp.[outbound_request], 'N'),
        @outbound_picking           = ISNULL(rp.[outbound_picking], 'N'),
        @outbound_shipping          = ISNULL(rp.[outbound_shipping], 'N'),
        @outbound_special_package   = ISNULL(rp.[outbound_special_package], 'N'),
        @outbound_breakage_replacement = ISNULL(rp.[outbound_breakage_replacement], 'N')
    FROM [IRPC_E_TRANSFER].[dbo].[VUserloginMaster] um
    LEFT JOIN [IRPC_E_TRANSFER].[dbo].[VRolePermission] rp
        ON rp.role_id = um.defualt_role
        AND rp.department_id = um.department_id
    WHERE um.user_id = @user_id;

    -- =============================================================
    -- Combine all job types into a unified result set
    -- =============================================================

    IF OBJECT_ID('tempdb..#data_jobs') IS NOT NULL
        DROP TABLE #data_jobs;

    SELECT
        j.*,
        CASE WHEN j.is_urgent = 'Y' AND j.job_status_id <> 5 THEN 0 ELSE 1 END AS sort_priority
    INTO #data_jobs
    FROM (
        SELECT * FROM dbo.fTransferSlipJob(@id, @date) WHERE (@inbound_transfer_slip = 'Y') AND (@type_id IS NULL OR @type_id = 1)
        UNION ALL
        SELECT * FROM dbo.fReceiveJob(@id, @date) WHERE (@inbound_receive = 'Y') AND (@type_id IS NULL OR @type_id = 2)
        UNION ALL
        SELECT * FROM dbo.fTransferWhJob(@id, @date) WHERE (@inbound_receive = 'Y') AND (@id IS NOT NULL)
        UNION ALL
        SELECT * FROM dbo.fRequestJob(@id, @date) WHERE (@outbound_request = 'Y') AND (@type_id IS NULL OR @type_id = 3)
        UNION ALL
        SELECT * FROM dbo.fPickingJob(@id, @date) WHERE (@outbound_picking = 'Y') AND (@type_id IS NULL OR @type_id = 4)
        UNION ALL
        SELECT * FROM dbo.fShippingJob(@id, @date) WHERE (@outbound_shipping = 'Y') AND (@type_id IS NULL OR @type_id = 5)
        UNION ALL
        SELECT * FROM dbo.fSpecialJob(@id, @date) WHERE (@outbound_special_package = 'Y') AND (@type_id IS NULL OR @type_id = 7)
        UNION ALL
        SELECT * FROM dbo.fBrokenBagJob(@id, @date) WHERE (@outbound_breakage_replacement = 'Y') AND (@type_id IS NULL OR @type_id = 6)
    ) AS j;

    CREATE NONCLUSTERED INDEX idx_data_jobs_system_no ON #data_jobs(system_no, job_type_id, from_location_cc_code, to_location_cc_code, job_create_datetime);

    -- =============================================================
    -- Return status and message
    -- =============================================================

    SELECT
        CASE WHEN COUNT(*) > 0 THEN 'success' ELSE 'success' END AS status,
        CASE WHEN COUNT(*) > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message
    FROM #data_jobs;

    -- =============================================================
    -- Filter Locations on input parameters
    -- =============================================================

    IF OBJECT_ID('tempdb..#filter_loc') IS NOT NULL
        DROP TABLE #filter_loc;

    SELECT DISTINCT
        loc.id
    INTO #filter_loc
    FROM dbo.tr_job_to_location jt
    LEFT JOIN dbo.ct_location loc
        ON loc.id = to_location_id
        AND loc.is_active = 'Y'
        AND loc.status_flag = 'A'
    LEFT JOIN dbo.ct_wh_cc_code whcc
        ON whcc.wh_code = loc.wh_code
        AND whcc.is_active = 'Y'
        AND whcc.status_flag = 'A'
    WHERE (@to_cc_code IS NULL OR whcc.cc_code = @to_cc_code)
        AND jt.is_active = 'Y'
        AND jt.status_flag = 'A';

    CREATE NONCLUSTERED INDEX idx_filter_loc_id ON #filter_loc(id);

    -- =============================================================
    -- Jobs with at least one MWH to-location in @to_wh_code
    -- =============================================================
    -- Job-level (not row-level): a job PUT into several warehouses keeps
    -- ALL its rows when any one of them is in @to_wh_code, so the card's
    -- other locations and qty summaries aren't cut down. to_location_type
    -- = 'MWH' guard: other location types' ids aren't ct_location ids.

    IF OBJECT_ID('tempdb..#filter_wh_jobs') IS NOT NULL
        DROP TABLE #filter_wh_jobs;

    SELECT DISTINCT dj.id
    INTO #filter_wh_jobs
    FROM #data_jobs dj
    INNER JOIN dbo.ct_location loc
        ON loc.id = dj.to_location_id
    WHERE @to_wh_code IS NOT NULL
        AND dj.to_location_type = 'MWH'
        AND loc.wh_code = @to_wh_code;

    CREATE NONCLUSTERED INDEX idx_filter_wh_jobs_id ON #filter_wh_jobs(id);

    -- =============================================================
    -- Jobs matching @from_location_type/_key, @to_location_type/_key
    -- =============================================================
    -- WH02 Outbound "From / To Location" (options: sql/36). _type alone =
    -- any location of that type; with _key = one location: wh_code for
    -- MWH (ct_location.wh_code), otherwise the location name (by name:
    -- one plant can have several ids, e.g. HD Plant). Job-level like
    -- #filter_wh_jobs: a job keeps all its rows when any one matches.

    IF OBJECT_ID('tempdb..#filter_from_jobs') IS NOT NULL
        DROP TABLE #filter_from_jobs;

    SELECT DISTINCT dj.id
    INTO #filter_from_jobs
    FROM #data_jobs dj
    LEFT JOIN dbo.ct_location loc
        ON dj.from_location_type = 'MWH'
        AND loc.id = dj.from_location_id
    WHERE @from_location_type IS NOT NULL
        AND dj.from_location_type = @from_location_type
        AND (
            @from_location_key IS NULL
            OR (@from_location_type = 'MWH' AND loc.wh_code = @from_location_key)
            OR (@from_location_type <> 'MWH' AND dj.from_location_name = @from_location_key)
        );

    IF OBJECT_ID('tempdb..#filter_to_jobs') IS NOT NULL
        DROP TABLE #filter_to_jobs;

    SELECT DISTINCT dj.id
    INTO #filter_to_jobs
    FROM #data_jobs dj
    LEFT JOIN dbo.ct_location loc
        ON dj.to_location_type = 'MWH'
        AND loc.id = dj.to_location_id
    WHERE @to_location_type IS NOT NULL
        AND dj.to_location_type = @to_location_type
        AND (
            @to_location_key IS NULL
            OR (@to_location_type = 'MWH' AND loc.wh_code = @to_location_key)
            OR (@to_location_type <> 'MWH' AND dj.to_location_name = @to_location_key)
        );

    -- =============================================================
    -- Filter jobs based on input parameters and filtered locations
    -- =============================================================

    IF OBJECT_ID('tempdb..#filter_jobs') IS NOT NULL
        DROP TABLE #filter_jobs;

    SELECT
        dj.*,
        ROW_NUMBER() OVER (
            PARTITION BY dj.id, dj.job_from_location_id, dj.job_to_location_id, dj.from_location_lot_no
            ORDER BY (SELECT NULL)
        ) AS lot_seq
    INTO #filter_jobs
    FROM #data_jobs dj
    WHERE (@id IS NULL OR dj.id = @id)
        AND (@date IS NULL OR CAST(dj.job_create_datetime AS DATE) = @date)
        AND (@system_no IS NULL OR dj.system_no LIKE '%' + @system_no + '%')
        AND (@from_cc_code IS NULL OR dj.from_location_cc_code = @from_cc_code)
        AND (@to_cc_code IS NULL OR dj.to_location_id IN (SELECT id FROM #filter_loc))
        AND (@product_cc IS NULL OR EXISTS (
                SELECT 1 FROM dbo.tr_job_main jm
                WHERE jm.id = dj.id AND jm.product_cc = @product_cc))
        AND (@to_wh_code IS NULL OR dj.id IN (SELECT id FROM #filter_wh_jobs))
        AND (@from_location_type IS NULL OR dj.id IN (SELECT id FROM #filter_from_jobs))
        AND (@to_location_type IS NULL OR dj.id IN (SELECT id FROM #filter_to_jobs))
        AND (@status_id IS NULL OR dj.job_status_id = @status_id)
        AND (@topic_name IS NULL OR dj.job_type_topic LIKE '%' + @topic_name + '%')
        AND (@type_id IS NULL OR dj.job_type_id = @type_id);

    CREATE NONCLUSTERED INDEX idx_filter_jobs_system_no ON #filter_jobs(system_no, header_id, item_id, job_type_id, job_status_id);

    -- =============================================================
    -- Return paginated job list
    -- =============================================================

    IF OBJECT_ID('tempdb..#job_page') IS NOT NULL
        DROP TABLE #job_page;

    SELECT DISTINCT id, sort_priority
    INTO #job_page
    FROM #filter_jobs
    ORDER BY sort_priority, id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    CREATE NONCLUSTERED INDEX idx_job_page_id ON #job_page(id);

    -- ==============================================================
    -- Join filtered jobs with paginated job IDs to get the final result set
    -- ==============================================================

    IF OBJECT_ID('tempdb..#page_job') IS NOT NULL
        DROP TABLE #page_job;

    SELECT f.*
    INTO #page_job
    FROM #filter_jobs f
    INNER JOIN #job_page jp
        ON jp.id = f.id;

    CREATE NONCLUSTERED INDEX idx_page_job_id ON #page_job(id);
    CREATE NONCLUSTERED INDEX idx_page_job_header ON #page_job(header_id, job_type_id, item_id, job_from_location_id);

    -- =============================================================
    -- Summarize item data
    -- =============================================================
    -- Sourced from #page_job (this page's rows only), not #filter_jobs
    -- (every matching row across every page): header_id/item_id map 1:1 to
    -- a single job id in this schema, so a given (header_id, job_type_id,
    -- item_id) key's rows are identical whether pulled from #filter_jobs or
    -- from #page_job -- #page_job is just far smaller to aggregate over.

    IF OBJECT_ID('tempdb..#item_summary') IS NOT NULL
        DROP TABLE #item_summary;

    SELECT
        header_id,
        job_type_id,
        item_id,
        SUM(receive_qty) AS item_receive_qty,
        CASE WHEN job_status_id = 5 THEN total_qty ELSE SUM(complete_qty) END AS item_complete_qty,
        MAX(total_qty) AS item_total_qty
    INTO #item_summary
    FROM (
        -- dedupe to one row per (header, type, item, from-location) first:
        -- shipping/loading repeat the same receive/complete/total_qty across
        -- every lot row that shares one from-location (collapsed here so a
        -- later SUM doesn't multiply them), while picking already has a
        -- genuinely distinct value per from-location (kept as-is), so this
        -- one dedupe step makes SUM correct for both cases at once.
        SELECT DISTINCT
            header_id,
            job_type_id,
            item_id,
            job_status_id,
            job_from_location_id,
            ISNULL(receive_qty, 0) AS receive_qty,
            ISNULL(complete_qty, 0) AS complete_qty,
            ISNULL(total_qty, 0) AS total_qty
        FROM #page_job
    ) dedup
    GROUP BY
        header_id,
        job_type_id,
        item_id,
        job_status_id,
        total_qty;

    CREATE NONCLUSTERED INDEX idx_item_summary ON #item_summary(header_id, job_type_id, item_id);

    -- =============================================================
    -- Summarize job data
    -- =============================================================

    IF OBJECT_ID('tempdb..#job_summary') IS NOT NULL
        DROP TABLE #job_summary;

    SELECT
        header_id,
        job_type_id,
        SUM(item_receive_qty) AS job_receive_qty,
        SUM(item_complete_qty) AS job_complete_qty,
        SUM(item_total_qty) AS job_total_qty
    INTO #job_summary
    FROM #item_summary
    GROUP BY
        header_id,
        job_type_id;

    CREATE NONCLUSTERED INDEX idx_job_summary ON #job_summary(header_id, job_type_id);

    -- =============================================================
    -- Calculate location pallet data for each job
    -- =============================================================

    IF OBJECT_ID('tempdb..#qty_cal') IS NOT NULL
        DROP TABLE #qty_cal;

    ;WITH location_counts AS (
        SELECT
            header_id,
            job_type_id,
            item_id,
            COUNT(DISTINCT job_from_location_id) AS from_location_count,
            COUNT(DISTINCT job_to_location_id) AS to_location_count
        FROM #page_job
        GROUP BY
            header_id,
            job_type_id,
            item_id
    ),
    location_base AS (
        SELECT
            fj.header_id,
            fj.job_type_id,
            fj.item_id,
            fj.job_from_location_id,
            fj.job_to_location_id,
            fj.from_location_lot_no,
            fj.lot_seq,
            qty_location =
                CASE
                    WHEN lc.to_location_count > lc.from_location_count
                        THEN COALESCE(NULLIF(fj.qty_to_location, 0), NULLIF(fj.qty_from_location, 0), 0)
                    ELSE COALESCE(NULLIF(fj.qty_from_location, 0), NULLIF(fj.qty_to_location, 0), 0)
                END,
            ism.item_total_qty,
            total_qty = SUM(
                CASE
                    WHEN lc.to_location_count > lc.from_location_count
                        THEN COALESCE(NULLIF(fj.qty_to_location, 0), NULLIF(fj.qty_from_location, 0), 0)
                    ELSE COALESCE(NULLIF(fj.qty_from_location, 0), NULLIF(fj.qty_to_location, 0), 0)
                END
            ) OVER (
                PARTITION BY fj.header_id, fj.job_type_id, fj.item_id
            )
        FROM #page_job fj
        INNER JOIN #item_summary ism
            ON ism.header_id = fj.header_id
            AND ism.job_type_id = fj.job_type_id
            AND ism.item_id = fj.item_id
        INNER JOIN location_counts lc
            ON lc.header_id = fj.header_id
            AND lc.job_type_id = fj.job_type_id
            AND lc.item_id = fj.item_id
    ),
    location_ratio AS (
        SELECT
            *,
            pallet_exact =
                CASE
                    WHEN total_qty > 0
                        THEN CAST(qty_location AS DECIMAL(18, 6)) * item_total_qty / total_qty
                    ELSE 0
                END
        FROM location_base
    ),
    pallet_allocation AS (
        SELECT
            *,
            pallet_floor = FLOOR(pallet_exact),
            remainder = pallet_exact - FLOOR(pallet_exact),
            floor_total = SUM(FLOOR(pallet_exact)) OVER (
                PARTITION BY header_id, job_type_id, item_id
            )
        FROM location_ratio
    )
    SELECT
        header_id,
        job_type_id,
        item_id,
        job_from_location_id,
        job_to_location_id,
        from_location_lot_no,
        lot_seq,
        CAST(
            pallet_floor +
            CASE
                WHEN ROW_NUMBER() OVER (
                    PARTITION BY header_id, job_type_id, item_id
                    ORDER BY remainder DESC, job_from_location_id, job_to_location_id
                ) <= item_total_qty - floor_total
                    THEN 1
                ELSE 0
            END
            AS INT
        ) AS location_total_qty
    INTO #qty_cal
    FROM pallet_allocation;

    CREATE NONCLUSTERED INDEX idx_pallet_cal ON #qty_cal(header_id, job_type_id, item_id, job_from_location_id, job_to_location_id, from_location_lot_no, lot_seq);

    -- =============================================================
    -- Return paginated job detail rows
    -- =============================================================

    SELECT
        pj.id,
        pj.header_id,
        pj.item_id,
        pj.do_no,
        pj.job_type_id,
        pj.job_type_topic,
        pj.job_type_short_name,
        pj.job_type_name,
        pj.system_no,
        pj.wms_no,
        pj.movement_unit,
        jsm.job_receive_qty,
        jsm.job_complete_qty,
        jsm.job_total_qty,
        pj.is_urgent,
        pj.is_multi_forklift,
        pj.job_status_id,
        pj.job_status_name,
        CONCAT(pj.grade, ' ', pj.lot_no, ' ', CAST(COALESCE(pj.confirm_qty, pj.qty) AS INT)) AS document_job,
        pj.grade,
        pj.lot_no,
        pj.from_location_lot_no AS from_addon_lot,
        pj.to_location_lot_no AS to_addon_lot,
        pj.lot_seq,
        pj.pd_cc_code,
        pj.code_t,
        COALESCE(pj.confirm_qty, pj.qty) AS qty,
        pj.qty_unit,
        pj.movement_unit AS item_movement_unit,
        ism.item_receive_qty,
        ism.item_complete_qty,
        ism.item_total_qty,
        pj.job_from_location_id,
        pj.from_location_id,
        pj.from_location_type,
        pj.from_location_name,
        pj.from_location_cc_code,
        pj.from_location_cc_desc,
        ISNULL(pj.qty_from_location, 0) AS qty_from_location,
        ISNULL(pj.actual_qty_from_location, 0) AS actual_qty_from_location,
        pj.qty_unit AS from_location_qty_unit,
        pj.job_to_location_id,
        pj.to_location_id,
        pj.to_location_type,
        pj.to_location_name,
        pj.to_location_cc_code,
        pj.to_location_cc_desc,
        ISNULL(pj.qty_to_location, 0) AS qty_to_location,
        ISNULL(pj.actual_qty_to_location, 0) AS actual_qty_to_location,
        pj.qty_unit AS to_location_qty_unit,
        pj.movement_unit AS location_movement_unit,
        ISNULL(pj.receive_qty, 0) AS location_receive_qty,
        CASE WHEN pj.job_status_id = 5 THEN pc.location_total_qty ELSE ISNULL(pj.complete_qty, 0) END AS location_complete_qty,
        pc.location_total_qty,
        pj.remark,
        pj.source_id,
        pj.job_start_datetime,
        pj.job_end_datetime,
        pj.job_create_datetime,
        --  Job-level Product CC (set on Approve) -- shown on the job-list card
        --  and the same value @product_cc filters on.
        jm.product_cc AS job_product_cc,
        --  Job-level Product Type (set on Approve, eg. 'FG'). Picking items
        --  carry no code_t (tr_delivery.code_t is never filled by the WMS/
        --  iLogistic shipment sync), so the item-level pd_type is empty there.
        jm.product_type AS job_product_type,
        --  WMS product group of the item (eg. '0T') -- see header (69).
        pg.wms_group
    FROM #page_job pj
    LEFT JOIN dbo.tr_job_main jm
        ON jm.id = pj.id
    OUTER APPLY (
        SELECT TOP 1 bct.wms_group
        FROM [IRPC_E_TRANSFER].dbo.ct_bagging_code_t bct
        --  code_t and tr_job_main.product_type have different collations,
        --  so each side is collated before COALESCE (else "Cannot resolve
        --  collation conflict").
        CROSS APPLY (
            SELECT TRIM(COALESCE(
                NULLIF(TRIM(pj.code_t COLLATE DATABASE_DEFAULT), ''),
                jm.product_type COLLATE DATABASE_DEFAULT
            )) AS product_type
        ) src
        WHERE bct.is_active = 'Y'
            AND bct.status_flag = 'A'
            AND (bct.code COLLATE DATABASE_DEFAULT = src.product_type
                OR bct.wms_group COLLATE DATABASE_DEFAULT = src.product_type)
        ORDER BY CASE WHEN bct.code COLLATE DATABASE_DEFAULT = src.product_type THEN 0 ELSE 1 END
    ) pg
    INNER JOIN #item_summary ism
        ON ism.header_id = pj.header_id
        AND ism.job_type_id = pj.job_type_id
        AND ism.item_id = pj.item_id
    INNER JOIN #job_summary jsm
        ON jsm.header_id = pj.header_id
        AND jsm.job_type_id = pj.job_type_id
    LEFT JOIN #qty_cal pc
        ON pc.header_id = pj.header_id
        AND pc.job_type_id = pj.job_type_id
        AND pc.item_id = pj.item_id
        AND pc.job_from_location_id = pj.job_from_location_id
        AND (pj.job_to_location_id IS NULL OR pc.job_to_location_id = pj.job_to_location_id)
        AND ISNULL(pc.from_location_lot_no, '') = ISNULL(pj.from_location_lot_no, '')
        AND pc.lot_seq = pj.lot_seq
    ORDER BY pj.id DESC;

    -- ============================================================
    -- Set id job_main_id for each find forklift in job
    -- ============================================================

    IF OBJECT_ID('tempdb..#ids_job_main') IS NOT NULL
        DROP TABLE #ids_job_main;

    SELECT DISTINCT
        vjm.id,
        CASE
            WHEN dj.job_type_id IN (4, 7) THEN COALESCE(vjm.ref_id, vjm.id)
            ELSE vjm.id
        END AS job_main_id
    INTO #ids_job_main
    FROM dbo.vJobMain vjm
    INNER JOIN #page_job dj
        ON dj.id = vjm.id;

    -- ============================================================
    -- Count each forklift's system-wide active (non-Complete) job queue
    -- ============================================================
    -- job_count used to be COUNT(DISTINCT dj.id) grouped alongside dj.id
    -- itself in the #forklift query below, which made it always evaluate
    -- to 1 (each group could only ever contain the one dj.id it was keyed
    -- on). This computes a real per-forklift count instead, using the same
    -- ref_id/id resolution #ids_job_main uses above so Picking(4)/
    -- Special(7) jobs -- whose tr_job_assigness rows are keyed by the
    -- referenced job's id, not their own -- are counted correctly.

    IF OBJECT_ID('tempdb..#queue_job') IS NOT NULL
        DROP TABLE #queue_job;

    ;WITH job_main_map AS
    (
        SELECT DISTINCT
            CASE
                WHEN vjm.job_type_id IN (4, 7) THEN COALESCE(vjm.ref_id, vjm.id)
                ELSE vjm.id
            END AS job_main_id
        FROM dbo.vJobMain vjm
        WHERE vjm.job_status_id <> 5
    )
    SELECT
        ja.assignee_forklift_id AS forklift_id,
        COUNT(*) AS job_count
    INTO #queue_job
    FROM job_main_map jmm
    INNER JOIN dbo.tr_job_assigness ja
        ON ja.job_main_id = jmm.job_main_id
        AND ja.is_active = 'Y'
        AND ja.status_flag = 'A'
    GROUP BY ja.assignee_forklift_id;

    CREATE NONCLUSTERED INDEX idx_queue_job_forklift_id ON #queue_job(forklift_id);

    -- ============================================================
    -- Summarize forklift data
    -- ============================================================

    IF OBJECT_ID('tempdb..#forklift') IS NOT NULL
        DROP TABLE #forklift;

    SELECT
        fl.id,
        fl.name,
        whn.wh_name AS wh_code,
        dj.id AS job_main_id,
        ul.id AS assignee_user_id,
        ul.user_name AS assignee_user_name,
        ul.Thia_name AS assignee_user_thai_name,
        ul.eng_name AS assignee_user_eng_name,
        au.id AS assigner_user_id,
        au.user_name AS assigner_user_name,
        au.Thia_name AS assigner_thai_name,
        au.eng_name AS assigner_eng_name,
        fl.forklift_status_id AS status_id,
        fs.name AS status_name,
        fl.section_id,
        sec.section_name,
        MAX(ISNULL(qj.job_count, 0)) AS job_count
    INTO #forklift
    FROM #page_job dj
    LEFT JOIN #ids_job_main ijm
        ON ijm.id = dj.id
    LEFT JOIN dbo.tr_job_assigness ja
        ON ja.job_main_id = ijm.job_main_id
        AND ja.is_active = 'Y'
        AND ja.status_flag = 'A'
    LEFT JOIN dbo.ct_forklift fl
        ON fl.id = ja.assignee_forklift_id
        AND fl.is_active = 'Y'
        AND fl.status_flag = 'A'
        AND fl.forklift_status_id = 1
    LEFT JOIN #queue_job qj
        ON qj.forklift_id = fl.id
    -- Was ON ul.id = fl.current_user_id (live join to whoever's logged into
    -- the forklift right now) -- that made an old job's driver silently
    -- change to whoever drives that forklift today. ja.assignee_user_id is
    -- the snapshot taken when the forklift was assigned to this job, so the
    -- displayed driver stays fixed to who actually worked it.
    LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
        ON ul.id = ja.assignee_user_id
        AND ul.status_flag = 'A'
    LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login au
        ON au.id = ja.assigner_user_id
        AND au.status_flag = 'A'
    LEFT JOIN dbo.ct_wh_cc_code whcc
        ON whcc.wh_code = fl.wh_code
        AND whcc.is_active = 'Y'
        AND whcc.status_flag = 'A'
    OUTER APPLY (
        SELECT STRING_AGG(ISNULL(cs.storage_name, TRIM(w.value)), ', ') WITHIN GROUP (ORDER BY TRIM(w.value)) AS wh_name
        FROM STRING_SPLIT(ISNULL(fl.wh_code, ''), ',') w
        LEFT JOIN [IRPC].dbo.ct_storage cs
            ON cs.wms_name COLLATE Thai_100_CI_AI_KS = TRIM(w.value)
            AND cs.is_active = 'Y'
            AND cs.status_flag = 'A'
        WHERE TRIM(w.value) <> ''
    ) whn
    LEFT JOIN dbo.ct_forklift_status fs
        ON fs.id = fl.forklift_status_id
        AND fs.is_active = 'Y'
        AND fs.status_flag = 'A'
    OUTER APPLY (
        SELECT STRING_AGG(
            CASE LTRIM(RTRIM(s.value))
                WHEN '1' THEN 'Warehouse'
                WHEN '2' THEN 'Loading'
                WHEN '3' THEN 'Pallet'
            END, ',') AS section_name
        FROM STRING_SPLIT(fl.section_id, ',') s
        WHERE LTRIM(RTRIM(s.value)) <> ''
    ) sec
    WHERE fl.id IS NOT NULL
    GROUP BY
        fl.id,
        fl.name,
        whn.wh_name,
        dj.id,
        ul.id,
        ul.user_name,
        ul.Thia_name,
        ul.eng_name,
        au.id,
        au.user_name,
        au.Thia_name,
        au.eng_name,
        fl.forklift_status_id,
        fs.name,
        fl.section_id,
        sec.section_name;

    CREATE NONCLUSTERED INDEX idx_forklift_id ON #forklift(id, job_main_id);

    SELECT *
    FROM #forklift;

    -- =============================================================
    -- Return total count
    -- =============================================================

    SELECT COUNT(DISTINCT dj.id) AS total_count
    FROM #data_jobs dj
    WHERE (@id IS NULL OR dj.id = @id)
        AND (@date IS NULL OR CAST(dj.job_create_datetime AS DATE) = @date)
        AND (@system_no IS NULL OR dj.system_no LIKE '%' + @system_no + '%')
        AND (@from_cc_code IS NULL OR dj.from_location_cc_code = @from_cc_code)
        AND (@to_cc_code IS NULL OR dj.to_location_id IN (SELECT id FROM #filter_loc))
        AND (@product_cc IS NULL OR EXISTS (
                SELECT 1 FROM dbo.tr_job_main jm
                WHERE jm.id = dj.id AND jm.product_cc = @product_cc))
        AND (@to_wh_code IS NULL OR dj.id IN (SELECT id FROM #filter_wh_jobs))
        AND (@from_location_type IS NULL OR dj.id IN (SELECT id FROM #filter_from_jobs))
        AND (@to_location_type IS NULL OR dj.id IN (SELECT id FROM #filter_to_jobs))
        AND (@status_id IS NULL OR dj.job_status_id = @status_id)
        AND (@topic_name IS NULL OR dj.job_type_topic LIKE '%' + @topic_name + '%')
        AND (@type_id IS NULL OR dj.job_type_id = @type_id);
END

GO
