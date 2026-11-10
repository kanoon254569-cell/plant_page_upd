-- =============================================================
-- 49_pProcessGetTransferWhJobList_detail.sql  (IRPC_QTRACK)
-- =============================================================
-- WH04 list and WH04 detail now use the same SP:
--
--   GET job/transfer-wh            -> list mode   (@id NULL)
--   GET job/transfer-wh?id={id}    -> detail mode (@id set)
--
-- List mode is unchanged from sql/48: one row per TW job.
--
-- Detail mode returns the same 4 result sets pProcessGetJobList returns
-- for @id, so JobService.BuildJobResponse and job-detail's template work
-- unchanged:
--   dbResult   status / message
--   dbResult1  one row per item / from-location / to-location / lot,
--              same columns as pProcessGetJobList
--   dbResult2  forklifts assigned to the job
--   dbResult3  total_count
-- It reads dbo.fTransferWhJob only (no 8-way UNION of every job type).
-- Item / job summaries, the per-location pallet split (#qty_cal) and the
-- forklift block are copied from pProcessGetJobList -- keep them in step
-- when that logic changes there.
--
-- @user_id (detail mode only): the job is returned only when the user's
-- role has inbound_receive = 'Y', the same rule pProcessGetJobList applies
-- to TW jobs.
--
-- Idempotent. Needs 46 / 47 / 48 deployed first.
-- =============================================================
USE IRPC_QTRACK;
GO

CREATE OR ALTER PROC dbo.pProcessGetTransferWhJobList
    @id             INT             = NULL,
    @system_no      NVARCHAR(255)   = NULL,
    @date           DATE            = NULL,
    @job_status_id  INT             = NULL,
    @page           INT             = 1,
    @page_size      INT             = 25,
    @user_id        INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;

    -- =============================================================
    -- Detail mode: one job, pProcessGetJobList's result shape
    -- =============================================================
    IF @id IS NOT NULL
    BEGIN
        DECLARE @inbound_receive NVARCHAR(10) = 'N';

        SELECT @inbound_receive = ISNULL(rp.[inbound_receive], 'N')
        FROM [IRPC_E_TRANSFER].[dbo].[VUserloginMaster] um
        LEFT JOIN [IRPC_E_TRANSFER].[dbo].[VRolePermission] rp
            ON rp.role_id = um.defualt_role
            AND rp.department_id = um.department_id
        WHERE um.user_id = @user_id;

        IF OBJECT_ID('tempdb..#data_jobs') IS NOT NULL
            DROP TABLE #data_jobs;

        SELECT j.*
        INTO #data_jobs
        FROM dbo.fTransferWhJob(@id, NULL) j
        WHERE @inbound_receive = 'Y';

        SELECT
            'success' AS status,
            CASE WHEN EXISTS (SELECT 1 FROM #data_jobs) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

        IF OBJECT_ID('tempdb..#page_job') IS NOT NULL
            DROP TABLE #page_job;

        SELECT
            dj.*,
            ROW_NUMBER() OVER (
                PARTITION BY dj.id, dj.job_from_location_id, dj.job_to_location_id, dj.from_location_lot_no
                ORDER BY (SELECT NULL)
            ) AS lot_seq
        INTO #page_job
        FROM #data_jobs dj;

        -- item / job summaries (same as pProcessGetJobList)
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
        GROUP BY header_id, job_type_id, item_id, job_status_id, total_qty;

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
        GROUP BY header_id, job_type_id;

        -- pallet split per location (same as pProcessGetJobList's #qty_cal)
        IF OBJECT_ID('tempdb..#qty_cal') IS NOT NULL
            DROP TABLE #qty_cal;

        ;WITH location_counts AS (
            SELECT
                header_id, job_type_id, item_id,
                COUNT(DISTINCT job_from_location_id) AS from_location_count,
                COUNT(DISTINCT job_to_location_id) AS to_location_count
            FROM #page_job
            GROUP BY header_id, job_type_id, item_id
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
                ) OVER (PARTITION BY fj.header_id, fj.job_type_id, fj.item_id)
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
                floor_total = SUM(FLOOR(pallet_exact)) OVER (PARTITION BY header_id, job_type_id, item_id)
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

        -- detail rows (same columns as pProcessGetJobList)
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
            jm.product_cc AS job_product_cc
        FROM #page_job pj
        LEFT JOIN dbo.tr_job_main jm
            ON jm.id = pj.id
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

        -- forklifts (same columns as pProcessGetJobList). TW is not type 4/7,
        -- so its tr_job_assigness rows are keyed by its own id.
        IF OBJECT_ID('tempdb..#queue_job') IS NOT NULL
            DROP TABLE #queue_job;

        ;WITH job_forklifts AS (
            SELECT DISTINCT ja.assignee_forklift_id
            FROM dbo.tr_job_assigness ja
            WHERE ja.job_main_id IN (SELECT id FROM #page_job)
              AND ja.is_active = 'Y'
              AND ja.status_flag = 'A'
        ),
        job_main_map AS (
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
        WHERE ja.assignee_forklift_id IN (SELECT assignee_forklift_id FROM job_forklifts)
        GROUP BY ja.assignee_forklift_id;

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
        FROM (SELECT DISTINCT id FROM #page_job) dj
        LEFT JOIN dbo.tr_job_assigness ja
            ON ja.job_main_id = dj.id
            AND ja.is_active = 'Y'
            AND ja.status_flag = 'A'
        LEFT JOIN dbo.ct_forklift fl
            ON fl.id = ja.assignee_forklift_id
            AND fl.is_active = 'Y'
            AND fl.status_flag = 'A'
            AND fl.forklift_status_id = 1
        LEFT JOIN #queue_job qj
            ON qj.forklift_id = fl.id
        LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
            ON ul.id = ja.assignee_user_id
            AND ul.status_flag = 'A'
        LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login au
            ON au.id = ja.assigner_user_id
            AND au.status_flag = 'A'
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
            fl.id, fl.name, whn.wh_name, dj.id,
            ul.id, ul.user_name, ul.Thia_name, ul.eng_name,
            au.id, au.user_name, au.Thia_name, au.eng_name,
            fl.forklift_status_id, fs.name, fl.section_id, sec.section_name;

        SELECT COUNT(DISTINCT id) AS total_count FROM #data_jobs;

        RETURN;
    END

    -- =============================================================
    -- List mode: one row per TW job (unchanged from sql/48)
    -- =============================================================
    IF OBJECT_ID('tempdb..#rows') IS NOT NULL
        DROP TABLE #rows;

    SELECT *
    INTO #rows
    FROM dbo.fTransferWhJob(NULL, @date) j
    WHERE (@system_no IS NULL OR j.system_no LIKE '%' + @system_no + '%')
      AND (@job_status_id IS NULL OR j.job_status_id = @job_status_id);

    -- one row per item: pallet counts are repeated on every location row
    IF OBJECT_ID('tempdb..#items') IS NOT NULL
        DROP TABLE #items;

    SELECT
        r.id,
        r.item_id,
        MAX(r.grade) AS grade,
        MAX(r.lot_no) AS lot_no,
        MAX(COALESCE(r.confirm_qty, r.qty)) AS qty,
        MAX(r.total_qty) AS total_pallet,
        SUM(r.receive_qty) AS receive_pallet,
        SUM(r.complete_qty) AS complete_pallet
    INTO #items
    FROM (
        SELECT DISTINCT id, item_id, grade, lot_no, confirm_qty, qty,
               job_to_location_id, total_qty, receive_qty, complete_qty
        FROM #rows
    ) r
    GROUP BY r.id, r.item_id;

    IF OBJECT_ID('tempdb..#jobs') IS NOT NULL
        DROP TABLE #jobs;

    SELECT
        r.id,
        MAX(r.header_id) AS header_id,
        MAX(r.system_no) AS system_no,
        MAX(r.wms_no) AS wms_no,
        MAX(r.job_type_id) AS job_type_id,
        MAX(r.job_type_short_name) AS job_type_short_name,
        MAX(r.job_type_name) AS job_type_name,
        MAX(r.job_status_id) AS job_status_id,
        MAX(r.job_status_name) AS job_status_name,
        MAX(r.is_urgent) AS is_urgent,
        MAX(r.movement_type) AS movement_type,
        MAX(r.from_location_cc_code) AS from_cc_code,
        MAX(r.from_location_cc_desc) AS from_cc_desc,
        MAX(r.to_location_type) AS to_location_type,
        MAX(r.to_location_cc_code) AS to_cc_code,
        MAX(r.to_location_cc_desc) AS to_cc_desc,
        MAX(r.qty_unit) AS qty_unit,
        MAX(r.movement_unit) AS movement_unit,
        MAX(r.job_start_datetime) AS job_start_datetime,
        MAX(r.job_end_datetime) AS job_end_datetime,
        MAX(r.job_create_datetime) AS job_create_datetime
    INTO #jobs
    FROM #rows r
    GROUP BY r.id;

    SELECT
        'success' AS status,
        CASE WHEN EXISTS (SELECT 1 FROM #jobs) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    SELECT
        j.id,
        j.header_id,
        j.system_no,
        j.wms_no,
        j.job_type_id,
        j.job_type_short_name,
        j.job_type_name,
        j.job_status_id,
        j.job_status_name,
        j.is_urgent,
        j.movement_type,
        fi.grade,
        fi.lot_no,
        fi.qty,
        j.qty_unit,
        it.item_count,
        it.total_qty,
        it.total_pallet,
        it.receive_pallet,
        it.complete_pallet,
        j.movement_unit,
        j.from_cc_code,
        j.from_cc_desc,
        j.to_location_type,
        j.to_cc_code,
        j.to_cc_desc,
        tw.wh_code,
        tw.area_code,
        tw.level_code,
        tw.location_code,
        jm.product_cc,
        j.job_start_datetime,
        j.job_end_datetime,
        j.job_create_datetime
    FROM #jobs j
    CROSS APPLY (
        SELECT
            COUNT(*) AS item_count,
            SUM(i.qty) AS total_qty,
            SUM(ISNULL(i.total_pallet, 0)) AS total_pallet,
            SUM(ISNULL(i.receive_pallet, 0)) AS receive_pallet,
            SUM(ISNULL(i.complete_pallet, 0)) AS complete_pallet
        FROM #items i
        WHERE i.id = j.id
    ) it
    OUTER APPLY (
        SELECT TOP (1) i.item_id, i.grade, i.lot_no, i.qty
        FROM #items i
        WHERE i.id = j.id
        ORDER BY i.item_id
    ) fi
    LEFT JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm tw
        ON tw.item_id = fi.item_id
    LEFT JOIN dbo.tr_job_main jm
        ON jm.id = j.id
    ORDER BY
        CASE WHEN j.is_urgent = 'Y' AND j.job_status_id <> 5 THEN 0 ELSE 1 END,
        j.id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    SELECT COUNT(*) AS total_count FROM #jobs;
END
GO
