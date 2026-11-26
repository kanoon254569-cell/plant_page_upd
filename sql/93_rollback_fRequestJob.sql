-- =============================================================
-- 93_rollback_fRequestJob.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 93_fRequestJob_drop_hash_hint.sql : the definition of
-- dbo.fRequestJob on IRPC_QTRACK before 93 (2026-10-25),
-- SHA-256 of OBJECT_DEFINITION (NVARCHAR, CRLF) =
--   0EE6FEB20205AED2DE3B6BA07D1764492115288910D047E085C0FDBE0139F1ED
-- Only change from that text: CREATE -> ALTER.
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
ALTER FUNCTION dbo.fRequestJob (@job_main_id INT = NULL, @date DATE = NULL, @date_to DATE = NULL)
RETURNS TABLE
AS
RETURN
(
WITH rq_location AS (
    SELECT ID, cc_code, cc_desc AS cc_location
    FROM IRPC_E_TRANSFER.dbo.ct_request_cost_center
    WHERE (is_active = 'Y')
),
bag_pallet AS (
    SELECT
        pp.job_main_id, pp.job_header_id, pp.job_item_id, pp.job_type_id, pp.job_from_location_id, pp.job_to_location_id,
        COALESCE(pp.pallet_seq, pp.pallet_id) AS pallet_group_key,
        MIN(pp.from_location_datetime) AS start_datetime, MAX(pp.to_location_datetime) AS end_datetime,
        SUM(pp.bag_qty) AS pallet_qty,
        MAX(CASE WHEN pp.is_complete = 'Y' THEN 1 ELSE 0 END) AS pallet_is_complete
    FROM (
        SELECT id FROM dbo.tr_job_main
        WHERE job_type_id = 3
          AND (status_flag IS NULL OR status_flag = 'A')
          AND (is_active IS NULL OR is_active = 'Y')
          AND (@job_main_id IS NULL OR id = @job_main_id)
          AND (@date IS NULL OR CAST(create_datetime AS DATE) BETWEEN @date AND ISNULL(@date_to, @date))
    ) jm3
    CROSS APPLY dbo.fRequestBags(jm3.id) pp
    GROUP BY pp.job_main_id, pp.job_header_id, pp.job_item_id, pp.job_type_id, pp.job_from_location_id, pp.job_to_location_id, COALESCE(pp.pallet_seq, pp.pallet_id)
),
pallet AS (
    SELECT
        job_main_id, job_header_id, job_item_id, job_type_id, job_from_location_id, job_to_location_id,
        MIN(start_datetime) AS start_datetime, MAX(end_datetime) AS end_datetime,
        SUM(CASE WHEN pallet_is_complete = 0 THEN pallet_qty ELSE 0 END) AS receive_bag,
        SUM(CASE WHEN pallet_is_complete = 1 THEN pallet_qty ELSE 0 END) AS complete_bag
    FROM bag_pallet
    GROUP BY job_main_id, job_header_id, job_item_id, job_type_id, job_from_location_id, job_to_location_id
),
jm_bypass AS (
    SELECT
        jm.id, CAST(NULL AS INT) AS ref_id, jm.interface_job_id AS header_id, CAST(NULL AS INT) AS ref_header_id,
        rq.item_id, CAST(NULL AS INT) AS ref_item_id, jm.job_type_id, jt.topic AS job_type_topic, jt.short_name AS job_type_short_name, jt.name AS job_type_name,
        jm.is_urgent, jm.is_multi_forklift, jm.job_status_id, js.name AS job_status_name,
        jm.start_datetime AS job_start_datetime, jm.end_datetime AS job_end_datetime,
        fl.id AS job_from_location_id, fl.from_location_id, fl.from_location_type,
        fl.qty AS qty_from_location, fl.actual_qty AS actual_qty_from_location,
        tl.id AS job_to_location_id, tl.to_location_id, tl.to_location_type, tl.qty AS qty_to_location, tl.actual_qty AS actual_qty_to_location,
        jm.create_datetime
    FROM dbo.tr_job_main AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VRequestForm AS rq ON rq.header_id = jm.interface_job_id AND jm.job_type_id = 3
    LEFT JOIN dbo.tr_job_from_location AS fl ON fl.job_main_id = jm.id AND fl.interface_job_item_id = rq.item_id AND (fl.is_active IS NULL OR fl.is_active = 'Y') AND (fl.status_flag IS NULL OR fl.status_flag = 'A')
    LEFT JOIN dbo.tr_job_to_location AS tl ON tl.job_main_id = jm.id AND tl.interface_job_item_id = rq.item_id AND (tl.is_active IS NULL OR tl.is_active = 'Y') AND (tl.status_flag IS NULL OR tl.status_flag = 'A')
    LEFT JOIN dbo.ct_job_status AS js ON js.id = jm.job_status_id
    LEFT JOIN dbo.ct_job_type AS jt ON jt.id = jm.job_type_id
    WHERE (jm.status_flag IS NULL OR jm.status_flag = 'A') AND (jm.is_active IS NULL OR jm.is_active = 'Y')
      AND (jt.is_active IS NULL OR jt.is_active = 'Y') AND (js.is_active IS NULL OR js.is_active = 'Y')
      AND (jt.status_flag IS NULL OR jt.status_flag = 'A') AND (js.status_flag IS NULL OR js.status_flag = 'A')
      AND rq.item_id IS NOT NULL
      AND (@job_main_id IS NULL OR jm.id = @job_main_id)
      AND (@date IS NULL OR CAST(jm.create_datetime AS DATE) BETWEEN @date AND ISNULL(@date_to, @date))
)
SELECT
    jm.id,
    rq.header_id,
    rq.system_no,
    rq.document_wms_no COLLATE Thai_CI_AI AS wms_no,
    jm.job_type_id,
    jm.job_type_topic,
    jm.job_type_short_name,
    jm.job_type_name,
    rq.process_order,
    rq.movement_type,
    rq.from_sloc_id,
    jm.job_from_location_id,
    jm.from_location_id,
    rq.wh_name COLLATE Thai_100_CI_AI_KS AS from_location_type,
    from_rq.cc_location COLLATE Thai_100_CI_AI_KS AS from_location_name,
    rq.wh_to_cc_code AS from_location_cc_code,
    rq.wh_to_cc_desc AS from_location_cc_desc,
    ll.lot_no AS from_location_lot_no,
    jm.qty_from_location,
    jm.actual_qty_from_location,
    p.start_datetime AS from_location_datetime,
    jm.job_to_location_id,
    jm.to_location_id,
    COALESCE(jm.to_location_type, 'RQ-PLANT') COLLATE Thai_100_CI_AI_KS AS to_location_type,
    to_rq.cc_location COLLATE Thai_100_CI_AI_KS AS to_location_name,
    rq.from_plant_cc_code AS to_location_cc_code,
    rq.from_plant_cc_desc AS to_location_cc_desc,
    llt.lot_no AS to_location_lot_no,
    jm.qty_to_location,
    jm.actual_qty_to_location,
    p.end_datetime AS to_location_datetime,
    jm.is_urgent,
    jm.is_multi_forklift,
    jm.job_status_id,
    jm.job_status_name,
    rq.item_id,
    CAST(NULL AS NVARCHAR(100)) AS do_no,
    rq.code_t,
    rq.grade,
    rq.lot_no,
    rq.from_cc_code_wms AS pd_cc_code,
    rq.qty,
    rq.confirm_qty,
    'kg' AS qty_unit,
    'kg' AS movement_unit,
    ISNULL(p.receive_bag, 0) AS receive_qty,
    ISNULL(p.complete_bag, 0) AS complete_qty,
    ISNULL(rq.qty, 0) AS total_qty,
    rq.remark,
    NULL AS source_id,
    jm.job_start_datetime,
    jm.job_end_datetime,
    jm.create_datetime AS job_create_datetime,
    CAST(NULL AS VARCHAR(50)) COLLATE Thai_CI_AI AS shipment_no,
    CAST(NULL AS INT) AS code_pallet_id,
    CAST(NULL AS VARCHAR(30)) COLLATE Thai_CI_AI AS pallet_lot,
    CAST(NULL AS INT) AS pallet_qty,
    CAST(NULL AS DECIMAL(20, 6)) AS pallet_weight,
    CAST(NULL AS INT) AS special_type_package_id
FROM jm_bypass AS jm
INNER JOIN IRPC_E_TRANSFER.dbo.VRequestForm AS rq
    ON rq.header_id = jm.header_id AND rq.item_id = jm.item_id
LEFT HASH JOIN pallet AS p
    ON p.job_main_id = jm.id AND p.job_header_id = jm.header_id AND p.job_item_id = jm.item_id
    AND p.job_type_id = jm.job_type_id AND p.job_to_location_id = jm.job_to_location_id AND p.job_from_location_id = jm.job_from_location_id
LEFT OUTER JOIN dbo.tr_lot_location AS llt
    ON llt.job_main_id = jm.id AND llt.job_item_id = jm.item_id AND llt.job_location_type = 'TO'
    AND llt.job_location_id = jm.job_to_location_id AND llt.is_active = 'Y' AND llt.status_flag = 'A'
LEFT OUTER JOIN dbo.tr_lot_location AS ll
    ON ll.job_main_id = jm.id AND ll.job_item_id = jm.item_id AND ll.job_location_type = 'FROM'
    AND ll.job_location_id = jm.job_from_location_id AND rq.lot_no IS NULL
    AND ll.is_active = 'Y' AND ll.status_flag = 'A' AND (llt.lot_no IS NULL OR ll.lot_no = llt.lot_no)
LEFT OUTER JOIN rq_location AS from_rq
    ON from_rq.ID = jm.from_location_id AND from_rq.cc_code COLLATE Thai_100_CI_AI_KS = rq.wh_to_cc_code COLLATE Thai_100_CI_AI_KS
    AND jm.from_location_type = 'RQ-PLANT'
LEFT OUTER JOIN rq_location AS to_rq
    ON to_rq.ID = jm.to_location_id AND to_rq.cc_code COLLATE Thai_100_CI_AI_KS = rq.from_plant_cc_code COLLATE Thai_100_CI_AI_KS
    AND jm.to_location_type = 'RQ-PLANT'
)
GO
