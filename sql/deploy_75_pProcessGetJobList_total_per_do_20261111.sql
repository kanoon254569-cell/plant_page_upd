/* =====================================================================
   Deploy to 10.31.1.75 -- pProcessGetJobList: card total per DO
   ---------------------------------------------------------------------
   Problem: WH02 Picking list, a job with several DOs shows the whole job
   qty on every DO card (job 2002: DO-3031015452 / 453 each 7,500 kg,
   both cards 0/15,000 kg; job 2003: 750 + 6,750 -> 0/7,500 on both).

   Cause: #job_summary sums all items of the job; the API groups cards by
   (job, system_no) and takes job_total_qty / job_receive_qty /
   job_complete_qty as the card numbers.

   Fix: #job_summary is grouped by system_no too and joined on it.
   Base: the current .75 definition, only this part changed.
   Rollback: rollback_75_pProcessGetJobList_20261111.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROC [dbo].[pProcessGetJobList]
    @id                 INT             = NULL,
    @date               DATE            = NULL,   -- transition only, see header
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
    @user_id            INT             = 6,
    @date_from          DATE            = NULL,
    @date_to            DATE            = NULL,
    @from_cc_codes      NVARCHAR(MAX)   = NULL,
    @to_cc_codes        NVARCHAR(MAX)   = NULL,
    @to_wh_codes        NVARCHAR(MAX)   = NULL,
    @status_ids         NVARCHAR(MAX)   = NULL,
    @from_locations     NVARCHAR(MAX)   = NULL,
    @to_locations       NVARCHAR(MAX)   = NULL,
    @product_ccs        NVARCHAR(MAX)   = NULL,
    @type_ids           NVARCHAR(MAX)   = NULL,
    @sort_by            NVARCHAR(50)    = NULL,
    @sort_order         NVARCHAR(10)    = NULL
AS
BEGIN
    SET NOCOUNT ON;

    --  Whitelist: any other @sort_by = default order.
    SET @sort_by = CASE WHEN LTRIM(RTRIM(@sort_by)) IN ('system_no', 'job_create_datetime', 'job_status_id') THEN LTRIM(RTRIM(@sort_by)) END;
    SET @sort_order = CASE WHEN UPPER(LTRIM(RTRIM(@sort_order))) = 'DESC' THEN 'DESC' ELSE 'ASC' END;

    -- =============================================================
    -- Enforce Date for Null to Default Date
    -- =============================================================
    IF @date_from IS NULL AND @date_to IS NULL AND @date IS NOT NULL
    BEGIN
        SET @date_from = @date;
        SET @date_to = @date;
    END

    IF @date_from IS NULL SET @date_from = @date_to;
    IF @date_to IS NULL SET @date_to = @date_from;

    IF @date_from IS NOT NULL
    BEGIN
        IF @date_from > @date_to
        BEGIN
            DECLARE @date_swap DATE = @date_from;
            SET @date_from = @date_to;
            SET @date_to = @date_swap;
        END
    END
    ELSE IF @id IS NULL
    BEGIN
        SET @date_from = CAST(GETDATE() AS DATE);
        SET @date_to = @date_from;
    END

    -- =============================================================
    -- Multi-value filters (old single-value params merged in)
    -- =============================================================

    DECLARE @f_from_cc TABLE (code NVARCHAR(255) NOT NULL);
    DECLARE @f_to_cc   TABLE (code NVARCHAR(255) NOT NULL);
    DECLARE @f_to_wh   TABLE (code NVARCHAR(255) NOT NULL);
    DECLARE @f_status  TABLE (id INT NOT NULL);
    DECLARE @f_product_cc TABLE (code NVARCHAR(255) NOT NULL);
    DECLARE @f_type    TABLE (id INT NOT NULL);
    DECLARE @f_from_loc TABLE (loc_type NVARCHAR(100) NOT NULL, loc_key NVARCHAR(255) NULL);
    DECLARE @f_to_loc   TABLE (loc_type NVARCHAR(100) NOT NULL, loc_key NVARCHAR(255) NULL);

    INSERT INTO @f_from_cc (code)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(CONCAT(@from_cc_codes, ',', @from_cc_code), ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    INSERT INTO @f_to_cc (code)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(CONCAT(@to_cc_codes, ',', @to_cc_code), ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    INSERT INTO @f_to_wh (code)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(CONCAT(@to_wh_codes, ',', @to_wh_code), ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    INSERT INTO @f_product_cc (code)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(CONCAT(@product_ccs, ',', @product_cc), ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    INSERT INTO @f_type (id)
    SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(CONCAT(@type_ids, ',', @type_id), ',')
    WHERE TRY_CAST(value AS INT) > 0;

    INSERT INTO @f_status (id)
    SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(CONCAT(@status_ids, ',', @status_id), ',')
    WHERE TRY_CAST(value AS INT) > 0;

    IF ISJSON(@from_locations) = 1
        INSERT INTO @f_from_loc (loc_type, loc_key)
        SELECT DISTINCT j.loc_type, NULLIF(j.loc_key, '')
        FROM OPENJSON(@from_locations) WITH (loc_type NVARCHAR(100) '$.type', loc_key NVARCHAR(255) '$.key') j
        WHERE NULLIF(j.loc_type, '') IS NOT NULL;
    IF @from_location_type IS NOT NULL
        INSERT INTO @f_from_loc (loc_type, loc_key) VALUES (@from_location_type, @from_location_key);

    IF ISJSON(@to_locations) = 1
        INSERT INTO @f_to_loc (loc_type, loc_key)
        SELECT DISTINCT j.loc_type, NULLIF(j.loc_key, '')
        FROM OPENJSON(@to_locations) WITH (loc_type NVARCHAR(100) '$.type', loc_key NVARCHAR(255) '$.key') j
        WHERE NULLIF(j.loc_type, '') IS NOT NULL;
    IF @to_location_type IS NOT NULL
        INSERT INTO @f_to_loc (loc_type, loc_key) VALUES (@to_location_type, @to_location_key);

    DECLARE @has_from_cc  BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_from_cc) THEN 1 ELSE 0 END;
    DECLARE @has_to_cc    BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_to_cc) THEN 1 ELSE 0 END;
    DECLARE @has_to_wh    BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_to_wh) THEN 1 ELSE 0 END;
    DECLARE @has_product_cc BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_product_cc) THEN 1 ELSE 0 END;
    DECLARE @has_type     BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_type) THEN 1 ELSE 0 END;
    DECLARE @has_status   BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_status) THEN 1 ELSE 0 END;
    DECLARE @has_from_loc BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_from_loc) THEN 1 ELSE 0 END;
    DECLARE @has_to_loc   BIT = CASE WHEN EXISTS (SELECT 1 FROM @f_to_loc) THEN 1 ELSE 0 END;

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

    --  Topic of each TVF (ct_job_type): TS/RC = Inbound, rest = Outbound.
    --  Same LIKE as the #filter_jobs WHERE, so skipped TVFs had no rows
    --  that would have passed it (sql/83).
    DECLARE @want_inbound  BIT = CASE WHEN @topic_name IS NULL OR 'Inbound'  LIKE '%' + @topic_name + '%' THEN 1 ELSE 0 END;
    DECLARE @want_outbound BIT = CASE WHEN @topic_name IS NULL OR 'Outbound' LIKE '%' + @topic_name + '%' THEN 1 ELSE 0 END;

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
    -- Union goes into a table variable first: a SELECT INTO #temp here
    -- recompiled on every call (~5.8s compile for the 8 inlined TVFs);
    -- a table-variable INSERT keeps its cached plan. #data_jobs is then
    -- a cheap copy so everything below stays as it was.

    DECLARE @data_jobs TABLE (
        id                       BIGINT          NOT NULL,
        header_id                BIGINT          NULL,
        system_no                NVARCHAR(50)    NULL,
        wms_no                   VARCHAR(30)     NULL,
        job_type_id              INT             NOT NULL,
        job_type_topic           VARCHAR(50)     NULL,
        job_type_short_name      VARCHAR(50)     NULL,
        job_type_name            VARCHAR(50)     NULL,
        process_order            VARCHAR(20)     NULL,
        movement_type            VARCHAR(5)      NULL,
        from_sloc_id             INT             NULL,
        job_from_location_id     BIGINT          NULL,
        from_location_id         INT             NULL,
        from_location_type       VARCHAR(50)     NULL,
        from_location_name       NVARCHAR(500)   NULL,
        from_location_cc_code    VARCHAR(100)    NULL,
        from_location_cc_desc    NVARCHAR(500)   NULL,
        from_location_lot_no     VARCHAR(50)     NULL,
        qty_from_location        INT             NULL,
        actual_qty_from_location INT             NULL,
        from_location_datetime   DATETIME        NULL,
        job_to_location_id       BIGINT          NULL,
        to_location_id           INT             NULL,
        to_location_type         VARCHAR(50)     NULL,
        to_location_name         NVARCHAR(500)   NULL,
        to_location_cc_code      VARCHAR(100)    NULL,
        to_location_cc_desc      NVARCHAR(500)   NULL,
        to_location_lot_no       VARCHAR(50)     NULL,
        qty_to_location          INT             NULL,
        actual_qty_to_location   INT             NULL,
        to_location_datetime     DATETIME        NULL,
        is_urgent                VARCHAR(1)      NULL,
        is_multi_forklift        VARCHAR(1)      NULL,
        job_status_id            INT             NULL,
        job_status_name          VARCHAR(50)     NULL,
        item_id                  BIGINT          NULL,
        do_no                    NVARCHAR(100)   NULL,
        code_t                   NVARCHAR(200)   NULL,
        grade                    NVARCHAR(50)    NULL,
        lot_no                   NVARCHAR(50)    NULL,
        pd_cc_code               VARCHAR(50)     NULL,
        qty                      DECIMAL(38, 2)  NULL,
        confirm_qty              DECIMAL(18, 3)  NULL,
        qty_unit                 VARCHAR(2)      NULL,
        movement_unit            VARCHAR(6)      NULL,
        receive_qty              INT             NULL,
        complete_qty             INT             NULL,
        total_qty                DECIMAL(38, 2)  NULL,
        remark                   NVARCHAR(500)   NULL,
        source_id                INT             NULL,
        job_start_datetime       DATETIME        NULL,
        job_end_datetime         DATETIME        NULL,
        job_create_datetime      DATETIME        NULL,
        shipment_no              VARCHAR(50)     NULL,
        code_pallet_id           INT             NULL,
        pallet_lot               VARCHAR(30)     NULL,
        pallet_qty               INT             NULL,
        pallet_weight            DECIMAL(20, 6)  NULL,
        special_type_package_id  INT             NULL
    );

    --  One INSERT per job type, not one UNION ALL: the job TVFs carry
    --  LEFT HASH JOIN hints, and a join hint forces the join order of the
    --  whole statement -- so in a single UNION, the other TVFs' hints still
    --  forced fTransferSlipJob into its slow plan (~3s). Separate
    --  statements keep each TVF's hints to itself (measured 3.3s -> 0.3s,
    --  same rows). The IF guards are the old per-branch WHERE conditions.

    --  The job TVFs take a create-date range: @date_from..@date_to (both
    --  NULL only for an @id lookup = no date filter).

    IF (@inbound_transfer_slip = 'Y') AND @want_inbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 1))
        INSERT INTO @data_jobs SELECT * FROM dbo.fTransferSlipJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@inbound_receive = 'Y') AND @want_inbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 2))
        INSERT INTO @data_jobs SELECT * FROM dbo.fReceiveJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@inbound_receive = 'Y') AND @want_outbound = 1 AND (@id IS NOT NULL)
        INSERT INTO @data_jobs SELECT * FROM dbo.fTransferWhJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@outbound_request = 'Y') AND @want_outbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 3))
        INSERT INTO @data_jobs SELECT * FROM dbo.fRequestJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@outbound_picking = 'Y') AND @want_outbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 4))
        INSERT INTO @data_jobs SELECT * FROM dbo.fPickingJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@outbound_shipping = 'Y') AND @want_outbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 5))
        INSERT INTO @data_jobs SELECT * FROM dbo.fShippingJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@outbound_special_package = 'Y') AND @want_outbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 7))
        INSERT INTO @data_jobs SELECT * FROM dbo.fSpecialJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF (@outbound_breakage_replacement = 'Y') AND @want_outbound = 1 AND (@has_type = 0 OR EXISTS (SELECT 1 FROM @f_type WHERE id = 6))
        INSERT INTO @data_jobs SELECT * FROM dbo.fBrokenBagJob(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);

    IF OBJECT_ID('tempdb..#data_jobs') IS NOT NULL
        DROP TABLE #data_jobs;

    SELECT
        j.*,
        CASE WHEN j.is_urgent = 'Y' AND j.job_status_id <> 5 THEN 0 ELSE 1 END AS sort_priority
    INTO #data_jobs
    FROM @data_jobs AS j;


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
        loc.location_master_id AS id
    INTO #filter_loc
    FROM dbo.tr_job_to_location jt
    LEFT JOIN dbo.ct_location loc
        ON loc.location_master_id = jt.to_location_id
        AND loc.is_active = 'Y'
        AND loc.status_flag = 'A'
    LEFT JOIN dbo.ct_wh_cc_code whcc
        ON whcc.wh_code = loc.wh_code
        AND whcc.is_active = 'Y'
        AND whcc.status_flag = 'A'
    WHERE @has_to_cc = 1
        AND whcc.cc_code IN (SELECT code FROM @f_to_cc)
        AND jt.is_active = 'Y'
        AND jt.status_flag = 'A';


    -- =============================================================
    -- Jobs with at least one MWH to-location in @f_to_wh
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
        ON loc.location_master_id = dj.to_location_id
    WHERE @has_to_wh = 1
        AND dj.to_location_type = 'MWH'
        AND loc.wh_code IN (SELECT code FROM @f_to_wh);


    -- =============================================================
    -- Jobs matching @f_product_cc
    -- =============================================================
    -- tr_job_main.product_cc (set on Approve) first; only when it's empty
    -- fall back to the item's pd_cc_code (the WMS+ product CC). Job-level
    -- like #filter_wh_jobs: a job keeps all its rows when any one matches.
    -- #data_jobs lives in tempdb, so both sides are collated before
    -- COALESCE (else "Cannot resolve collation conflict").

    IF OBJECT_ID('tempdb..#filter_product_cc_jobs') IS NOT NULL
        DROP TABLE #filter_product_cc_jobs;

    SELECT DISTINCT dj.id
    INTO #filter_product_cc_jobs
    FROM #data_jobs dj
    LEFT JOIN dbo.tr_job_main jm
        ON jm.id = dj.id
    CROSS APPLY (
        SELECT LTRIM(RTRIM(COALESCE(
            NULLIF(LTRIM(RTRIM(jm.product_cc COLLATE DATABASE_DEFAULT)), ''),
            --  pd_cc_code: Inbound TVFs fall back to the item's WMS CC (sql/89).
            NULLIF(LTRIM(RTRIM(dj.pd_cc_code COLLATE DATABASE_DEFAULT)), '')
        ))) AS product_cc
    ) src
    WHERE @has_product_cc = 1
        AND src.product_cc IN (SELECT code COLLATE DATABASE_DEFAULT FROM @f_product_cc);


    -- =============================================================
    -- Jobs matching @f_from_loc / @f_to_loc
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
    INNER JOIN @f_from_loc f
        ON f.loc_type = dj.from_location_type
    WHERE (
            f.loc_key IS NULL
            OR (f.loc_type = 'MWH' AND loc.wh_code = f.loc_key)
            OR (f.loc_type <> 'MWH' AND dj.from_location_name = f.loc_key)
        );

    IF OBJECT_ID('tempdb..#filter_to_jobs') IS NOT NULL
        DROP TABLE #filter_to_jobs;

    SELECT DISTINCT dj.id
    INTO #filter_to_jobs
    FROM #data_jobs dj
    LEFT JOIN dbo.ct_location loc
        ON dj.to_location_type = 'MWH'
        AND loc.location_master_id = dj.to_location_id
    INNER JOIN @f_to_loc f
        ON f.loc_type = dj.to_location_type
    WHERE (
            f.loc_key IS NULL
            OR (f.loc_type = 'MWH' AND loc.wh_code = f.loc_key)
            OR (f.loc_type <> 'MWH' AND dj.to_location_name = f.loc_key)
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
        AND (@date_from IS NULL OR CAST(dj.job_create_datetime AS DATE) BETWEEN @date_from AND @date_to)
        AND (@system_no IS NULL OR dj.system_no LIKE '%' + @system_no + '%')
        AND (@has_from_cc = 0 OR dj.from_location_cc_code IN (SELECT code FROM @f_from_cc))
        AND (@has_to_cc = 0 OR dj.to_location_id IN (SELECT id FROM #filter_loc))
        AND (@has_product_cc = 0 OR dj.id IN (SELECT id FROM #filter_product_cc_jobs))
        AND (@has_to_wh = 0 OR dj.id IN (SELECT id FROM #filter_wh_jobs))
        AND (@has_from_loc = 0 OR dj.id IN (SELECT id FROM #filter_from_jobs))
        AND (@has_to_loc = 0 OR dj.id IN (SELECT id FROM #filter_to_jobs))
        AND (@has_status = 0 OR dj.job_status_id IN (SELECT id FROM @f_status))
        AND (@topic_name IS NULL OR dj.job_type_topic LIKE '%' + @topic_name + '%')
        AND (@has_type = 0 OR dj.job_type_id IN (SELECT id FROM @f_type));


    -- =============================================================
    -- Return paginated job list
    -- =============================================================

    IF OBJECT_ID('tempdb..#job_page') IS NOT NULL
        DROP TABLE #job_page;

    SELECT
        id,
        sort_priority,
        ROW_NUMBER() OVER (ORDER BY
            CASE WHEN @sort_by IS NULL THEN sort_priority END ASC,
            CASE WHEN @sort_by = 'system_no' AND @sort_order = 'ASC' THEN system_no END ASC,
            CASE WHEN @sort_by = 'system_no' AND @sort_order = 'DESC' THEN system_no END DESC,
            CASE WHEN @sort_by = 'job_create_datetime' AND @sort_order = 'ASC' THEN job_create_datetime END ASC,
            CASE WHEN @sort_by = 'job_create_datetime' AND @sort_order = 'DESC' THEN job_create_datetime END DESC,
            CASE WHEN @sort_by = 'job_status_id' AND @sort_order = 'ASC' THEN job_status_id END ASC,
            CASE WHEN @sort_by = 'job_status_id' AND @sort_order = 'DESC' THEN job_status_id END DESC,
            id ASC
        ) AS page_seq
    INTO #job_page
    FROM (
        SELECT id, sort_priority, MIN(system_no) AS system_no, MIN(job_create_datetime) AS job_create_datetime, MIN(job_status_id) AS job_status_id
        FROM #filter_jobs
        GROUP BY id, sort_priority
    ) AS job_sort
    ORDER BY page_seq
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;


    -- ==============================================================
    -- Join filtered jobs with paginated job IDs to get the final result set
    -- ==============================================================

    IF OBJECT_ID('tempdb..#page_job') IS NOT NULL
        DROP TABLE #page_job;

    SELECT f.*, jp.page_seq,
        --  Row order for the tie-break in the main result's ORDER BY.
        IDENTITY(INT, 1, 1) AS page_row_no
    INTO #page_job
    FROM #filter_jobs f
    INNER JOIN #job_page jp
        ON jp.id = f.id;


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
        SUM(complete_qty) AS item_complete_qty,
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
            from_location_datetime,
            to_location_datetime,
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


    -- =============================================================
    -- Summarize job data
    -- =============================================================

    IF OBJECT_ID('tempdb..#job_summary') IS NOT NULL
        DROP TABLE #job_summary;

    --  Per system_no too: the API shows one card per (job, system_no), and a
    --  picking job can hold several DOs (one item each). Summed per job, every
    --  DO card showed the whole job total (job 2002: 2 x 7,500 -> 15,000 on
    --  both cards). Other job types have one system_no per job, so no change.
    SELECT
        ism.header_id,
        ism.job_type_id,
        sn.system_no,
        SUM(ism.item_receive_qty) AS job_receive_qty,
        SUM(ism.item_complete_qty) AS job_complete_qty,
        SUM(ism.item_total_qty) AS job_total_qty
    INTO #job_summary
    FROM #item_summary ism
    INNER JOIN (
        SELECT DISTINCT header_id, job_type_id, item_id, ISNULL(system_no, '') AS system_no
        FROM #page_job
    ) sn
        ON sn.header_id = ism.header_id
        AND sn.job_type_id = ism.job_type_id
        AND sn.item_id = ism.item_id
    GROUP BY
        ism.header_id,
        ism.job_type_id,
        sn.system_no;


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
            fj.from_location_lot_no AS from_location_lot_no,
            fj.lot_seq,
            qty_location =
                CASE
                    WHEN lc.to_location_count > lc.from_location_count
                        THEN COALESCE(NULLIF(fj.qty_to_location, 0), NULLIF(fj.qty_from_location, 0), 0)
                    ELSE COALESCE(NULLIF(fj.qty_from_location, 0), NULLIF(fj.qty_to_location, 0), 0)
                END,
            --  actual_qty of the same side qty_location was taken from.
            actual_location =
                CASE
                    WHEN lc.to_location_count > lc.from_location_count
                        THEN CASE WHEN NULLIF(fj.qty_to_location, 0) IS NOT NULL
                                THEN ISNULL(fj.actual_qty_to_location, 0)
                                ELSE ISNULL(fj.actual_qty_from_location, 0) END
                    ELSE CASE WHEN NULLIF(fj.qty_from_location, 0) IS NOT NULL
                                THEN ISNULL(fj.actual_qty_from_location, 0)
                                ELSE ISNULL(fj.actual_qty_to_location, 0) END
                END,
            --  Pallets already put away at this location. complete_qty only:
            --  a received (picked-up) pallet has no real destination yet, and
            --  receive_qty can sit on any to-location row (job 1373: all 43
            --  on one row). Shipping/loading repeat the same complete_qty on
            --  every lot row of one location pair, so it is shared out over
            --  those rows.
            done_qty =
                CAST(ISNULL(fj.complete_qty, 0) AS DECIMAL(18, 6))
                / COUNT(*) OVER (
                    PARTITION BY fj.header_id, fj.job_type_id, fj.item_id,
                        fj.job_from_location_id, fj.job_to_location_id
                ),
            ism.item_total_qty
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
    location_sum AS (
        SELECT
            *,
            remain_location =
                CASE WHEN qty_location > actual_location THEN qty_location - actual_location ELSE 0 END,
            total_qty = SUM(qty_location) OVER (
                PARTITION BY header_id, job_type_id, item_id
            ),
            remain_total = SUM(
                CASE WHEN qty_location > actual_location THEN qty_location - actual_location ELSE 0 END
            ) OVER (
                PARTITION BY header_id, job_type_id, item_id
            ),
            done_total = SUM(done_qty) OVER (
                PARTITION BY header_id, job_type_id, item_id
            ),
            row_total = COUNT(*) OVER (
                PARTITION BY header_id, job_type_id, item_id
            )
        FROM location_base
    ),
    location_ratio AS (
        SELECT
            *,
            pallet_exact =
                CASE
                    --  Done pallets kept, pallets left split by kg left.
                    WHEN done_total <= item_total_qty AND remain_total > 0
                        THEN done_qty + CAST(remain_location AS DECIMAL(18, 6))
                             * (item_total_qty - done_total) / remain_total
                    --  No kg left anywhere: split pallets left by planned kg.
                    WHEN done_total <= item_total_qty AND total_qty > 0
                        THEN done_qty + CAST(qty_location AS DECIMAL(18, 6))
                             * (item_total_qty - done_total) / total_qty
                    --  No qty on any location yet (shipping job 690: qty 0,
                    --  total 20): split pallets left evenly. The old ELSE 0
                    --  let the remainder step hand out at most 1 per row.
                    WHEN done_total <= item_total_qty
                        THEN done_qty + (item_total_qty - done_total) / row_total
                    --  Done counts past item_total_qty: old kg-ratio split.
                    WHEN total_qty > 0
                        THEN CAST(qty_location AS DECIMAL(18, 6)) * item_total_qty / total_qty
                    ELSE CAST(item_total_qty AS DECIMAL(18, 6)) / row_total
                END
        FROM location_sum
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
        COALESCE(NULLIF(js.name_th, N''), pj.job_status_name) AS job_status_name,
        CONCAT(pj.grade, ' ', pj.lot_no, ' ', CAST(COALESCE(pj.qty, 0) AS INT)) AS document_job,
        pj.grade,
        pj.lot_no,
        pj.from_location_lot_no AS from_addon_lot,
        pj.to_location_lot_no AS to_addon_lot,
        pj.lot_seq,
        pj.pd_cc_code,
        pj.code_t,
        COALESCE(pj.qty, 0) AS qty,
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
        ISNULL(pj.complete_qty, 0) AS location_complete_qty,
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
        --  Advance order flag (set on Approve): completing the job skips the
        --  WMS+ interface; the job-detail "ส่ง Interface" button sends it.
        ISNULL(jm.is_advance_order, 'N') AS is_advance_order,
        --  WMS product group of the item (eg. '0T') -- see header (69).
        pg.wms_group
    FROM #page_job pj
    LEFT JOIN dbo.tr_job_main jm
        ON jm.id = pj.id
    LEFT JOIN dbo.ct_job_status js
        ON js.id = pj.job_status_id
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
        AND jsm.system_no = ISNULL(pj.system_no, '')
    LEFT JOIN #qty_cal pc
        ON pc.header_id = pj.header_id
        AND pc.job_type_id = pj.job_type_id
        AND pc.item_id = pj.item_id
        AND pc.job_from_location_id = pj.job_from_location_id
        AND (pj.job_to_location_id IS NULL OR pc.job_to_location_id = pj.job_to_location_id)
        AND ISNULL(pc.from_location_lot_no, '') = ISNULL(pj.from_location_lot_no, '')
        AND pc.lot_seq = pj.lot_seq
    ORDER BY CASE WHEN @sort_by IS NULL THEN pj.id ELSE pj.page_seq END ASC, pj.id ASC, pj.page_row_no DESC;

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

    --  Only the forklifts assigned to this page's jobs: #forklift below
    --  reads #queue_job for nothing else. Counting every forklift ran
    --  every non-Complete job through vJobMain on every call
    --  (sql/perf_pProcessGetJobList_temp_table_ddl_queue_job.sql).
    DECLARE @queue_assignment TABLE (assignee_forklift_id INT, job_main_id BIGINT);

    INSERT INTO @queue_assignment (assignee_forklift_id, job_main_id)
    SELECT ja.assignee_forklift_id, ja.job_main_id
    FROM dbo.tr_job_assigness ja
    WHERE ja.is_active = 'Y'
        AND ja.status_flag = 'A'
        AND ja.assignee_forklift_id IN (
            SELECT pja.assignee_forklift_id
            FROM #ids_job_main ijm
            INNER JOIN dbo.tr_job_assigness pja
                ON pja.job_main_id = ijm.job_main_id
                AND pja.is_active = 'Y'
                AND pja.status_flag = 'A'
        );

    --  A vJobMain row maps to its own id unless it is a Picking(4)/
    --  Special(7) job (then COALESCE(ref_id, id)), so any other row can
    --  only match an assignment through its own id: look those up by id
    --  instead of running every non-Complete job through the view.
    ;WITH job_main_map AS
    (
        --  tr_job_main filters first; vJobMain (heavy: joins every job
        --  form view) only checks the jobs left, so its rules still apply
        --  (sql/pProcessGetJobList_perf_job_main_map_10.31.1.75.sql).
        SELECT jm.id AS job_main_id
        FROM dbo.tr_job_main jm
        WHERE jm.id IN (SELECT job_main_id FROM @queue_assignment)
            AND jm.job_status_id <> 5
            AND (jm.job_type_id NOT IN (4, 7) OR jm.job_type_id IS NULL)
            AND EXISTS (SELECT 1 FROM dbo.vJobMain vjm WHERE vjm.id = jm.id)
        UNION
        SELECT COALESCE(vjm.ref_id, vjm.id)
        FROM dbo.vJobMain vjm
        WHERE vjm.job_status_id <> 5
            AND vjm.job_type_id IN (4, 7)
    )
    SELECT
        qa.assignee_forklift_id AS forklift_id,
        COUNT(*) AS job_count
    INTO #queue_job
    FROM job_main_map jmm
    INNER JOIN @queue_assignment qa
        ON qa.job_main_id = jmm.job_main_id
    GROUP BY qa.assignee_forklift_id;


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
        MAX(ISNULL(qj.job_count, 0)) AS job_count,
        --  Read flag of this forklift's assignment (pProcessUpdateJobAssigneeRead).
        MAX(ISNULL(ja.is_read, 'N')) AS is_read
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


    SELECT *
    FROM #forklift;

    -- =============================================================
    -- Return total count
    -- =============================================================

    SELECT COUNT(DISTINCT dj.id) AS total_count
    FROM #data_jobs dj
    WHERE (@id IS NULL OR dj.id = @id)
        AND (@date_from IS NULL OR CAST(dj.job_create_datetime AS DATE) BETWEEN @date_from AND @date_to)
        AND (@system_no IS NULL OR dj.system_no LIKE '%' + @system_no + '%')
        AND (@has_from_cc = 0 OR dj.from_location_cc_code IN (SELECT code FROM @f_from_cc))
        AND (@has_to_cc = 0 OR dj.to_location_id IN (SELECT id FROM #filter_loc))
        AND (@has_product_cc = 0 OR dj.id IN (SELECT id FROM #filter_product_cc_jobs))
        AND (@has_to_wh = 0 OR dj.id IN (SELECT id FROM #filter_wh_jobs))
        AND (@has_from_loc = 0 OR dj.id IN (SELECT id FROM #filter_from_jobs))
        AND (@has_to_loc = 0 OR dj.id IN (SELECT id FROM #filter_to_jobs))
        AND (@has_status = 0 OR dj.job_status_id IN (SELECT id FROM @f_status))
        AND (@topic_name IS NULL OR dj.job_type_topic LIKE '%' + @topic_name + '%')
        AND (@has_type = 0 OR dj.job_type_id IN (SELECT id FROM @f_type));
END
GO
