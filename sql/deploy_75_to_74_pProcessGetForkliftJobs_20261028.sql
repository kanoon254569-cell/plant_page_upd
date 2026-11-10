-- =============================================================
-- deploy_75_to_74_pProcessGetForkliftJobs_20261028.sql  (IRPC_QTRACK)
-- =============================================================
-- Copy pProcessGetForkliftJobs (forklift job list) from 10.31.1.75
-- to 10.31.1.74. Body is the .75 definition as of 2026-10-27 15:56,
-- with CREATE PROC changed to CREATE OR ALTER PROC.
--
-- Depends on (must exist on .74 with the same columns):
--   index  dbo.tr_job_assigness.IX_tr_job_assigness_forklift_lookup
--   TVFs   fTransferSlipJob, fReceiveJob, fTransferWhJob, fRequestJob,
--          fPickingJob, fShippingJob, fSpecialJob, fBrokenBagJob,
--          fInternalTransferJob, fTransferSlipPallets, fReceivePallets,
--          fTransferWhBags, fRequestBags, fPickingPallets,
--          fShippingPallets, fSpecialBags, fBrokenBagBags,
--          fInternalTransferBags, fManualPallets
-- =============================================================

-- pProcessGetForkliftJobs : #pallet_summary dedupe fix (group by p.bag_id, MAX not SUM).
CREATE OR ALTER PROC [dbo].[pProcessGetForkliftJobs]
    @fl_id                INT             = NULL,
    @date                 NVARCHAR(50)    = NULL, --2026-08-26
    @type_ids             VARCHAR(50)     = NULL,
    @status_ids           VARCHAR(50)     = NULL,
    @user_id			  INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @fl_id IS NULL
    BEGIN
        SELECT 'error' AS status, 'Forklift ID is required.' AS message;
        RETURN;
    END

    DECLARE @dateJob                   DATE;
    SET @dateJob = CAST(COALESCE(@date, GETDATE()) AS DATE);

    DECLARE @inbound_transfer_slip     NVARCHAR(10) = 'N';
    DECLARE @inbound_receive           NVARCHAR(10) = 'N';
    DECLARE @outbound_request          NVARCHAR(10) = 'N';
    DECLARE @outbound_picking          NVARCHAR(10) = 'N';
    DECLARE @outbound_shipping         NVARCHAR(10) = 'N';
    DECLARE @outbound_special_package  NVARCHAR(10) = 'N';
    DECLARE @outbound_breakage_replacement       NVARCHAR(10) = 'N';

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

    IF OBJECT_ID('tempdb..#job_type_filter') IS NOT NULL
        DROP TABLE #job_type_filter;

    SELECT CAST(value AS INT) AS job_type_id
    INTO #job_type_filter
    FROM STRING_SPLIT(@type_ids, ',');

    IF OBJECT_ID('tempdb..#job_status_filter') IS NOT NULL
        DROP TABLE #job_status_filter;

    SELECT CAST(value AS INT) AS job_status_id
    INTO #job_status_filter
    FROM STRING_SPLIT(@status_ids, ',');

    IF OBJECT_ID('tempdb..#forklift_jobs') IS NOT NULL
        DROP TABLE #forklift_jobs;

    SELECT DISTINCT ja.job_main_id
    INTO #forklift_jobs
    FROM dbo.tr_job_assigness ja WITH (INDEX(IX_tr_job_assigness_forklift_lookup))
    LEFT JOIN dbo.vJobMain jm ON ja.job_main_id = jm.id
    WHERE assignee_forklift_id = @fl_id
        AND is_active = 'Y'
        AND status_flag = 'A'
        AND (@type_ids IS NULL OR jm.job_type_id IN (SELECT job_type_id FROM #job_type_filter))
        AND (@status_ids IS NULL OR jm.job_status_id IN (SELECT job_status_id FROM #job_status_filter))
        AND (@dateJob IS NULL OR CAST(jm.create_datetime AS DATE) = @dateJob);

    IF NOT EXISTS (SELECT 1 FROM #forklift_jobs)
    BEGIN
        SELECT 'error' AS status, 'No jobs found for this forklift.' AS message;
        RETURN;
    END


    SELECT 'success' AS status, 'Data retrieved successfully.' AS message;

    IF OBJECT_ID('tempdb..#recent_jobs') IS NOT NULL
        DROP TABLE #recent_jobs;

    --  One INSERT per job TVF into a table variable, then a copy into
    --  #recent_jobs. The old single "SELECT INTO #recent_jobs FROM (UNION
    --  ALL of 9 TVFs)" recompiled on every call (~6-7s) and, as one
    --  statement, let fRequestJob's LEFT HASH JOIN force the join order of
    --  every branch (20-30s; 393s on a busy day). See
    --  sql/perf_pProcessGetForkliftJobs_split_union.sql.
    DECLARE @recent_jobs TABLE (
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

    IF @inbound_transfer_slip = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fTransferSlipJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @inbound_receive = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fReceiveJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @inbound_receive = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fTransferWhJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @outbound_request = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fRequestJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @outbound_picking = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fPickingJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @outbound_shipping = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fShippingJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @outbound_special_package = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fSpecialJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    IF @outbound_breakage_replacement = 'Y'
        INSERT INTO @recent_jobs SELECT * FROM dbo.fBrokenBagJob(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);
    INSERT INTO @recent_jobs SELECT * FROM dbo.fInternalTransferJob(NULL, @dateJob) OPTION (KEEPFIXED PLAN);

    SELECT j.*
    INTO #recent_jobs
    FROM @recent_jobs AS j;


    IF OBJECT_ID('tempdb..#filter_jobs') IS NOT NULL
        DROP TABLE #filter_jobs;

    SELECT
        j.id,
        j.header_id,
        j.item_id,
        j.job_type_id,
        j.job_type_topic,
        j.job_type_name,
        j.system_no,
        j.wms_no,
        j.is_urgent,
        j.is_multi_forklift,
        j.job_status_id,
        j.job_status_name,
        j.grade,
        j.lot_no,
        j.from_location_lot_no AS from_addon_lot,
        j.to_location_lot_no AS to_addon_lot,
        j.qty,
        j.confirm_qty,
        j.qty_unit,
        j.receive_qty,
        j.complete_qty,
        j.total_qty,
        j.movement_unit,
        j.job_from_location_id,
        j.from_location_id,
        j.from_location_type,
        j.from_location_name,
        j.from_location_cc_code,
        j.from_location_cc_desc,
        j.qty_from_location,
        j.actual_qty_from_location,
        j.from_location_datetime,
        j.job_to_location_id,
        j.to_location_id,
        j.to_location_type,
        j.to_location_name,
        j.to_location_cc_code,
        j.to_location_cc_desc,
        j.qty_to_location,
        j.actual_qty_to_location,
        j.to_location_datetime,
        j.remark,
        j.job_create_datetime,
        ROW_NUMBER() OVER (
            PARTITION BY j.id, j.job_from_location_id, j.job_to_location_id, j.from_location_lot_no
            ORDER BY (SELECT NULL)
        ) AS lot_seq
    INTO #filter_jobs
    FROM #recent_jobs j
    INNER JOIN #forklift_jobs f
        ON f.job_main_id = j.id;


    IF OBJECT_ID('tempdb..#item_summary') IS NOT NULL
        DROP TABLE #item_summary;

    SELECT
        header_id,
        job_type_id,
        item_id,
        MIN(from_location_datetime) AS item_start_datetime,
        CASE WHEN SUM(complete_qty) >= MAX(total_qty)
             THEN MAX(to_location_datetime)
             ELSE NULL
        END AS item_end_datetime,
        SUM(receive_qty) AS item_receive_qty,
        SUM(complete_qty) AS item_complete_qty,
        MAX(total_qty) AS item_total_qty,
        MAX(grade) AS grade,
        --  Created here, not by ALTER TABLE afterwards: DDL on a #temp
        --  table after it is created makes every statement that uses it
        --  recompile on each call (sql/perf_pProcessGetForkliftJobs_temp_table_recompile.sql).
        CAST(NULL AS INT) AS scan_qty
    INTO #item_summary
    FROM (
        SELECT DISTINCT
            header_id,
            job_type_id,
            item_id,
            job_from_location_id,
            from_location_datetime,
            to_location_datetime,
            ISNULL(receive_qty,0) AS receive_qty,
            ISNULL(complete_qty,0) AS complete_qty,
            ISNULL(total_qty,0) AS total_qty,
            grade
        FROM #filter_jobs
    ) dedup
    GROUP BY header_id, job_type_id, item_id;



    UPDATE ism
    SET scan_qty = CASE WHEN ism.job_type_id IN (1, 2) THEN sps.scan_qty ELSE 1 END
    FROM #item_summary ism
    LEFT JOIN dbo.sys_pallet_scan_setting sps
        ON sps.pallet_type = CASE
            WHEN EXISTS (
                SELECT 1 FROM dbo.tr_pallet_manual_item pmi
                WHERE pmi.job_type_id = ism.job_type_id
                    AND pmi.wms_plus_item_id = ism.item_id
                    AND pmi.is_active = 'Y'
                    AND pmi.status_flag = 'A'
            ) THEN 'M'
            WHEN EXISTS (
                SELECT 1 FROM dbo.ct_grade_package_ratio gpr
                WHERE gpr.grade = ism.grade COLLATE DATABASE_DEFAULT
                    AND UPPER(LTRIM(RTRIM(gpr.unit_code))) = 'JB'
            ) THEN 'J'
            ELSE 'A'
        END
        AND sps.is_active = 'Y';

    IF OBJECT_ID('tempdb..#job_summary') IS NOT NULL
        DROP TABLE #job_summary;

    SELECT
        header_id,
        job_type_id,
        MIN(item_start_datetime) AS job_start_datetime,
        CASE WHEN SUM(item_complete_qty) >= SUM(item_total_qty)
             THEN MAX(item_end_datetime)
             ELSE NULL
        END AS job_end_datetime,
        SUM(item_receive_qty) AS job_receive_qty,
        SUM(item_complete_qty) AS job_complete_qty,
        SUM(item_total_qty) AS job_total_qty
    INTO #job_summary
    FROM #item_summary
    GROUP BY header_id, job_type_id;


    IF OBJECT_ID('tempdb..#pallet_cal') IS NOT NULL
        DROP TABLE #pallet_cal;

    ;WITH location_counts AS
    (
        SELECT            header_id,
            job_type_id,
            item_id,
            COUNT(DISTINCT job_from_location_id) AS from_location_count,
            COUNT(DISTINCT job_to_location_id) AS to_location_count
        FROM #filter_jobs
        GROUP BY
            header_id,
            job_type_id,
            item_id
    ),
    location_base AS
    (
        SELECT
            fj.header_id,
            fj.job_type_id,
            fj.item_id,
            fj.job_from_location_id,
            fj.job_to_location_id,
            fj.from_addon_lot AS from_location_lot_no,
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
                PARTITION BY
                    fj.header_id,
                    fj.job_type_id,
                    fj.item_id
            )
        FROM #filter_jobs fj
        INNER JOIN #item_summary ism
            ON ism.header_id = fj.header_id
            AND ism.job_type_id = fj.job_type_id
            AND ism.item_id = fj.item_id
        INNER JOIN location_counts lc
            ON lc.header_id = fj.header_id
            AND lc.job_type_id = fj.job_type_id
            AND lc.item_id = fj.item_id
    ),
    location_ratio AS
    (
        SELECT
            *,
            pallet_exact =
                CASE
                    WHEN total_qty > 0
                    THEN CAST(qty_location AS DECIMAL(18, 6))
                         * item_total_qty / total_qty
                    ELSE 0
                END
        FROM location_base
    ),
    pallet_allocation AS
    (
        SELECT
            *,
            pallet_floor = FLOOR(pallet_exact),
            remainder = pallet_exact - FLOOR(pallet_exact),

            floor_total = SUM(FLOOR(pallet_exact)) OVER (
                PARTITION BY
                    header_id,
                    job_type_id,
                    item_id
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
                    PARTITION BY
                        header_id,
                        job_type_id,
                        item_id
                    ORDER BY
                        remainder DESC,
                        job_from_location_id,
                        job_to_location_id
                ) <= item_total_qty - floor_total
                THEN 1
                ELSE 0
            END
            AS INT
        ) AS location_total_qty
    INTO #pallet_cal
    FROM pallet_allocation;


    SELECT
        dj.id,
        dj.header_id,
        dj.item_id,
        dj.job_type_id,
        dj.job_type_topic,
        dj.job_type_name,
        dj.system_no,
        dj.wms_no,
        jsm.job_receive_qty,
        jsm.job_complete_qty,
        jsm.job_total_qty,
        dj.movement_unit,
        dj.is_urgent,
        dj.is_multi_forklift,
        dj.job_status_id,
        COALESCE(NULLIF(js.name_th, N''), dj.job_status_name) AS job_status_name,
        ism.scan_qty,
        CONCAT(dj.grade, ' ', dj.lot_no, ' ', CAST(COALESCE(dj.confirm_qty, dj.qty) AS INT)) AS document_job,
        dj.grade,
        dj.lot_no,
        dj.from_addon_lot,
        dj.to_addon_lot,
        dj.lot_seq,
        COALESCE(dj.confirm_qty, dj.qty) AS qty,
        dj.qty_unit,
        ism.item_receive_qty,
        ism.item_complete_qty,
        ism.item_total_qty,
        dj.movement_unit AS item_movement_unit,
        dj.job_from_location_id,
        dj.from_location_id,
        dj.from_location_type,
        dj.from_location_name,
        dj.from_location_cc_code,
        dj.from_location_cc_desc,
        ISNULL(dj.qty_from_location, 0) AS qty_from_location,
        ISNULL(dj.actual_qty_from_location, 0) AS actual_qty_from_location,
        dj.qty_unit AS from_location_qty_unit,
        dj.job_to_location_id,
        dj.to_location_id,
        dj.to_location_type,
        dj.to_location_name,
        dj.to_location_cc_code,
        dj.to_location_cc_desc,
        ISNULL(dj.qty_to_location, 0) AS qty_to_location,
        ISNULL(dj.actual_qty_to_location, 0) AS actual_qty_to_location,
        dj.qty_unit AS to_location_qty_unit,
        ISNULL(dj.receive_qty, 0) AS location_receive_qty,
        CASE WHEN dj.job_status_id = 5
             THEN pc.location_total_qty
             ELSE ISNULL(dj.complete_qty, 0)
        END AS location_complete_qty,
        dj.movement_unit AS location_movement_unit,
        pc.location_total_qty,
        dj.remark,
        itdFrom.pallet_json AS from_pallet_json,
        itdTo.pallet_json AS to_pallet_json,
        jsm.job_start_datetime,
        jsm.job_end_datetime,
        dj.job_create_datetime
    FROM #filter_jobs dj
    LEFT JOIN dbo.ct_job_status js
        ON js.id = dj.job_status_id
    INNER JOIN #item_summary ism
        ON ism.header_id = dj.header_id
        AND ism.job_type_id = dj.job_type_id
        AND ism.item_id = dj.item_id
    INNER JOIN #job_summary jsm
        ON jsm.header_id = dj.header_id
        AND jsm.job_type_id = dj.job_type_id
    LEFT JOIN #pallet_cal pc
        ON pc.header_id = dj.header_id
        AND pc.job_type_id = dj.job_type_id
        AND pc.item_id = dj.item_id
        AND pc.job_from_location_id = dj.job_from_location_id
        AND (dj.job_to_location_id IS NULL OR pc.job_to_location_id = dj.job_to_location_id)
        AND ISNULL(pc.from_location_lot_no, '') = ISNULL(dj.from_addon_lot, '')
        AND pc.lot_seq = dj.lot_seq
    LEFT JOIN dbo.tr_internal_transfer_detail itdFrom
        ON itdFrom.job_location_id = dj.job_from_location_id AND itdFrom.job_location_type = 'FROM' AND itdFrom.is_active = 'Y' AND itdFrom.status_flag = 'A'
    LEFT JOIN dbo.tr_internal_transfer_detail itdTo
        ON itdTo.job_location_id = dj.job_to_location_id AND itdTo.job_location_type = 'TO' AND itdTo.is_active = 'Y' AND itdTo.status_flag = 'A'
    ORDER BY dj.id DESC;

    IF OBJECT_ID('tempdb..#SpecialPalletStatus') IS NOT NULL
        DROP TABLE #SpecialPalletStatus;

    SELECT
        v.job_main_id,
        v.job_item_id,
        COALESCE(v.pallet_seq, v.pallet_id) AS pallet_group_key,
        MAX(CASE WHEN v.is_complete = 'Y' THEN 1 ELSE 0 END) AS pallet_is_complete
    INTO #SpecialPalletStatus
    FROM (SELECT DISTINCT id FROM #filter_jobs) fj
    CROSS APPLY dbo.fSpecialBags(fj.id) v
    GROUP BY v.job_main_id, v.job_item_id, COALESCE(v.pallet_seq, v.pallet_id);


    IF OBJECT_ID('tempdb..#job_pallet_data') IS NOT NULL
        DROP TABLE #job_pallet_data;

    SELECT *
    INTO #job_pallet_data
    FROM (
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            NULL AS bag_id,
            NULL AS pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.qty,
            v.is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fTransferSlipPallets(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            NULL AS bag_id,
            NULL AS pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.qty,
            v.is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fReceivePallets(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            v.bag_id,
            v.pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.bag_qty AS qty,
            'N' AS is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fTransferWhBags(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            v.bag_id,
            v.pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.bag_qty AS qty,
            'N' AS is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fRequestBags(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            NULL AS bag_id,
            NULL AS pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot_no,
            v.bag_count,
            v.qty,
            v.is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fPickingPallets(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            NULL AS bag_id,
            NULL AS pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.qty,
            v.is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fShippingPallets(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            v.bag_id,
            v.pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.bag_qty AS qty,
            v.is_prepare,
            CASE WHEN sps.pallet_is_complete = 1 THEN 'N' ELSE v.is_received END AS is_received,
            CASE WHEN sps.pallet_is_complete = 1 THEN 'Y' ELSE v.is_complete END AS is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fSpecialBags(fj.id) v
        LEFT JOIN #SpecialPalletStatus sps
            ON sps.job_main_id = v.job_main_id
            AND sps.job_item_id = v.job_item_id
            AND sps.pallet_group_key = COALESCE(v.pallet_seq, v.pallet_id)
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            v.bag_id,
            v.pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.bag_qty AS qty,
            'N' AS is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fBrokenBagBags(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
        UNION ALL
        SELECT
            v.job_main_id,
            v.job_item_id,
            v.pallet_id,
            v.bag_id,
            v.pallet_seq,
            v.unit_pallet,
            v.unit_ratio,
            v.grade,
            v.lot,
            v.bag_count,
            v.bag_qty AS qty,
            'N' AS is_prepare,
            v.is_received,
            v.is_complete
        FROM (SELECT DISTINCT id, is_multi_forklift FROM #filter_jobs) fj
        CROSS APPLY dbo.fInternalTransferBags(fj.id) v
        WHERE v.is_complete = 'Y' OR fj.is_multi_forklift = 'Y' OR (fj.is_multi_forklift = 'N' AND v.from_location_user_id = @user_id)
    ) AS p;


    IF OBJECT_ID('tempdb..#pallet_summary') IS NOT NULL
        DROP TABLE #pallet_summary;

    SELECT
        p.job_main_id,
        p.pallet_id,
        MAX(p.pallet_seq) AS pallet_seq,
        MAX(p.unit_pallet) AS unit_pallet,
        MAX(p.unit_ratio) AS unit_ratio,
        MAX(p.grade) AS grade,
        MAX(p.lot) AS lot,
        MAX(p.bag_count) AS bag_count,
        MAX(tp.pallet_no) AS pallet_no,
        MAX(p.qty) AS total_qty,
        MAX(CONCAT(p.grade, ' ', p.lot, ' ', p.qty)) AS pallet_text,
        MAX(p.is_prepare) AS is_prepare,
        MAX(p.is_received) AS is_received,
        MAX(p.is_complete) AS is_complete,
        MAX(
            CASE WHEN tp.pallet_type = 'M'
                THEN CONCAT(tp.pallet_no COLLATE Thai_CI_AI, '|', p.grade, '|', p.lot, '|', CAST(p.qty AS INT))
                ELSE b.qr_text_data
            END
        ) AS scanned_qr_code
    INTO #pallet_summary
    FROM #job_pallet_data p
    LEFT JOIN dbo.tr_bag b
        ON b.pallet_id = p.pallet_id
        AND (p.bag_id IS NULL OR b.id = p.bag_id)
        AND b.is_active = 'Y'
        AND b.status_flag = 'A'
    LEFT JOIN dbo.tr_pallet tp
        ON tp.id = p.pallet_id
    GROUP BY p.job_main_id, p.pallet_id, p.bag_id;


    SELECT *
    FROM #pallet_summary
    WHERE is_prepare = 'Y' AND is_received <> 'Y' AND is_complete <> 'Y';

    SELECT *
    FROM #pallet_summary
    WHERE is_received = 'Y' AND is_complete <> 'Y';

    SELECT *
    FROM #pallet_summary
    WHERE is_complete = 'Y';

    IF OBJECT_ID('tempdb..#pallet_manual_summary') IS NOT NULL
        DROP TABLE #pallet_manual_summary;

    SELECT
        fj.id AS job_main_id,
        fj.item_id AS job_item_id,
        m.pallet_id,
        m.pallet_no,
        m.unit_pallet,
        m.unit_ratio,
        m.grade,
        m.lot,
        m.bag_count,
        m.qty AS total_qty,
        CONCAT(m.grade, ' ', m.lot, ' ',  m.qty) AS pallet_text,
        m.job_item_id AS wms_plus_manual_item_id,
        CONCAT(m.pallet_no COLLATE Thai_CI_AI, '|', m.grade, '|', m.lot, '|', m.qty) AS scanned_qr_code
    INTO #pallet_manual_summary
    FROM (SELECT DISTINCT id, item_id, job_type_id FROM #filter_jobs) fj
    CROSS APPLY dbo.fManualPallets(fj.item_id, fj.job_type_id) m
    OUTER APPLY (
        SELECT TOP (1) qr_text_data
        FROM dbo.tr_bag
        WHERE pallet_id = m.pallet_id AND is_active = 'Y' AND status_flag = 'A'
    ) b
    WHERE EXISTS (
        SELECT 1 FROM dbo.tr_pallet_manual_item pmi
        WHERE pmi.job_type_id = fj.job_type_id
            AND pmi.wms_plus_item_id = fj.item_id
            AND pmi.pallet_id = m.pallet_id
            AND pmi.is_active = 'Y'
            AND pmi.status_flag = 'A'
    )
    AND NOT EXISTS (
        SELECT 1 FROM #pallet_summary ps
        WHERE ps.pallet_id = m.pallet_id
            AND (ps.is_received = 'Y' OR ps.is_complete = 'Y')
    );

    SELECT * FROM #pallet_manual_summary;
END
GO
