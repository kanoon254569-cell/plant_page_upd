-- =============================================================
-- 46_job_type_transfer_wh.sql  (IRPC_QTRACK)
-- =============================================================
-- New inbound job type 11 'TW' (Transfer WH), fed by
-- IRPC_E_TRANSFER.dbo.VTransferWhForm the same way RC (2) is fed by
-- VReceiveForm:
--
--   tr_job_main.job_type_id      = 11
--   tr_job_main.interface_job_id = VTransferWhForm.header_id
--   tr_job_from/to_location.interface_job_item_id = VTransferWhForm.item_id
--
-- Objects (clones of the RC objects, only the source view / type id differ):
--   ct_job_type id 11           Inbound / TW / Transfer WH / is_list = 'Y'
--   dbo.fTransferWhPallets      <- fReceivePallets
--   dbo.vTransferWhPallets      <- vReceivePallets
--   dbo.fTransferWhJob          <- fReceiveJob
--   dbo.vTransferWhJob          <- vReceiveJob
--
-- Differences from RC, because VTransferWhForm has fewer columns than
-- VReceiveForm:
--   wh_name     not in the view -> ct_wh_to.wh_name via to_wh_id
--   total_pallet not in the view -> CEILING(qty / (unit_ratio * unit_pallet))
--               from ct_grade_package_ratio (25 * 40 = 1000 kg when the
--               grade has no ratio yet). Same result as RC's form value
--               for the RC rows checked (1000 kg -> 1, 1500 kg -> 2).
--
-- fTransferWhJob / fTransferWhPallets return exactly the same columns in
-- the same order as fReceiveJob / fReceivePallets, so the SELECT * UNION ALL
-- in pProcessGetJobList / pProcessGetForkliftJobs / pProcessInboundPutAway
-- keeps working. Those procs (and vJobMain) are patched in 47.
--
-- Idempotent. Run 46 before 47.
-- =============================================================
USE IRPC_QTRACK;
GO

-- -------------------------------------------------------------
-- ct_job_type 11
-- -------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.ct_job_type WHERE id = 11)
BEGIN
    SET IDENTITY_INSERT dbo.ct_job_type ON;

    INSERT INTO dbo.ct_job_type
        (id, topic, short_name, name, is_list, is_active,
         create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
    VALUES
        (11, 'Inbound', 'TW', 'Transfer WH', 'Y', 'Y',
         0, GETDATE(), 0, GETDATE(), 'A');

    SET IDENTITY_INSERT dbo.ct_job_type OFF;
END
GO

-- -------------------------------------------------------------
-- fTransferWhPallets  (clone of fReceivePallets)
-- -------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fTransferWhPallets (@job_main_id INT)
RETURNS TABLE
AS
RETURN
(
    WITH cte_pallet_history AS
    (
        SELECT
            job_main_id,
            job_item_id,
            pallet_id,

            MAX(CASE WHEN process_id = 1 THEN location_id END)     AS from_location_id,
            MAX(CASE WHEN process_id = 1 THEN location_type END)   AS from_location_type,
            MAX(CASE WHEN process_id = 1 THEN create_datetime END) AS from_location_datetime,
            MAX(CASE WHEN process_id = 1 THEN create_user_id END)  AS from_location_user_id,

            MAX(CASE WHEN process_id = 2 THEN location_id END)     AS to_location_id,
            MAX(CASE WHEN process_id = 2 THEN location_type END)   AS to_location_type,
            MAX(CASE WHEN process_id = 2 THEN create_datetime END) AS to_location_datetime,
            MAX(CASE WHEN process_id = 2 THEN create_user_id END)  AS to_location_user_id

        FROM
        (
            SELECT
                ph.*,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        ph.job_main_id,
                        ph.job_item_id,
                        ph.pallet_id,
                        ph.process_id
                    ORDER BY ph.create_datetime DESC
                ) AS rn
            FROM dbo.tr_pallet_history ph
            WHERE ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND ph.process_id IN (1, 2)
              AND ph.job_main_id = @job_main_id
        ) ranked
        WHERE ranked.rn = 1
        GROUP BY job_main_id, job_item_id, pallet_id
        HAVING MAX(CASE WHEN process_id = 1 THEN 1 ELSE 0 END) = 1
    )

    SELECT
        p.id AS pallet_id,
        p.pallet_no,
        p.pd_group_code,
        p.pd_type_code,
        p.pallet_type,
        pmi.wms_plus_item_id AS wms_plus_manual_item_id,

        b.grade,
        b.lot,

        p.unit_ratio,
        p.unit_pallet,

        COUNT(*) AS bag_count,
        dbo.fGetPalletQty(p.id) AS qty,

        jm.id AS job_main_id,
        jm.header_id AS job_header_id,
        jm.item_id AS job_item_id,
        jm.job_type_id,
        jm.job_type_topic,
        jm.job_type_name,
        jm.job_from_location_id,

        ph.from_location_id,
        ph.from_location_type,
        ph.from_location_datetime,
        ph.from_location_user_id,

        jm.job_to_location_id,

        ph.to_location_id,
        ph.to_location_type,
        ph.to_location_datetime,
        ph.to_location_user_id,

        CAST(NULL AS VARCHAR(1)) AS is_prepare,

        CASE
            WHEN ph.from_location_id IS NOT NULL
             AND ph.from_location_datetime IS NOT NULL
             AND ph.from_location_user_id IS NOT NULL
             AND jm.from_location_id = ph.from_location_id
             AND ph.to_location_id IS NULL
             AND ph.to_location_datetime IS NULL
             AND ph.to_location_user_id IS NULL
            THEN 'Y'
            ELSE 'N'
        END AS is_received,

        CASE
            WHEN ph.from_location_id IS NOT NULL
             AND ph.from_location_datetime IS NOT NULL
             AND ph.from_location_user_id IS NOT NULL
             AND ph.to_location_id IS NOT NULL
             AND ph.to_location_datetime IS NOT NULL
             AND ph.to_location_user_id IS NOT NULL
             AND jm.from_location_id = ph.from_location_id
             AND jm.to_location_id = ph.to_location_id
            THEN 'Y'
            ELSE 'N'
        END AS is_complete

    FROM dbo.tr_pallet p

    INNER JOIN dbo.tr_bag b
        ON b.pallet_id = p.id
       AND
       (
            (b.status_flag IS NULL AND b.is_active IS NULL)
            OR
            (b.status_flag = 'A' AND b.is_active = 'Y')
       )

    INNER JOIN cte_pallet_history ph
        ON ph.pallet_id = p.id

    LEFT JOIN dbo.tr_pallet_manual_item pmi
        ON pmi.pallet_id = p.id

    CROSS APPLY
    (
        SELECT TOP (1)
            jm2.id,
            jm2.interface_job_id AS header_id,
            tw2.item_id,
            jm2.job_type_id,
            jt2.topic AS job_type_topic,
            jt2.name AS job_type_name,
            fl2.id AS job_from_location_id,
            fl2.from_location_id,
            fl2.from_location_type,
            tl2.id AS job_to_location_id,
            tl2.to_location_id,
            tl2.to_location_type
        FROM dbo.tr_job_main jm2
        INNER JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm AS tw2
            ON tw2.header_id = jm2.interface_job_id AND jm2.job_type_id = 11
        LEFT JOIN dbo.tr_job_from_location fl2
            ON fl2.job_main_id = jm2.id AND fl2.interface_job_item_id = tw2.item_id
            AND (fl2.is_active IS NULL OR fl2.is_active = 'Y') AND (fl2.status_flag IS NULL OR fl2.status_flag = 'A')
        LEFT JOIN dbo.tr_job_to_location tl2
            ON tl2.job_main_id = jm2.id AND tl2.interface_job_item_id = tw2.item_id
            AND (tl2.is_active IS NULL OR tl2.is_active = 'Y') AND (tl2.status_flag IS NULL OR tl2.status_flag = 'A')
        LEFT JOIN dbo.ct_job_type jt2 ON jt2.id = jm2.job_type_id
        WHERE jm2.id = ph.job_main_id
          AND tw2.item_id = ph.job_item_id
          AND fl2.from_location_id = ph.from_location_id
          AND fl2.from_location_type = ph.from_location_type

          AND
          (
              (
                  ph.to_location_id IS NOT NULL
                  AND tl2.to_location_id = ph.to_location_id
                  AND tl2.to_location_type = ph.to_location_type
              )
              OR
              ph.to_location_id IS NULL
          )

        ORDER BY
            CASE
                WHEN tl2.to_location_id = ph.to_location_id
                THEN 0
                ELSE 1
            END,
            tl2.id

    ) jm

    WHERE
    (
        (p.status_flag IS NULL AND p.is_active IS NULL)
        OR
        (p.status_flag = 'A' AND p.is_active = 'Y')
    )

    GROUP BY
        p.id,
        p.pallet_no,
        p.pd_group_code,
        p.pd_type_code,
        p.pallet_type,
        pmi.wms_plus_item_id,

        b.grade,
        b.lot,

        p.unit_ratio,
        p.unit_pallet,

        jm.id,
        jm.header_id,
        jm.item_id,
        jm.job_type_id,
        jm.job_type_topic,
        jm.job_type_name,

        jm.job_from_location_id,
        jm.job_to_location_id,

        ph.from_location_id,
        ph.from_location_type,
        ph.from_location_datetime,
        ph.from_location_user_id,

        ph.to_location_id,
        ph.to_location_type,
        ph.to_location_datetime,
        ph.to_location_user_id,

        jm.from_location_id,
        jm.to_location_id,
        jm.to_location_type
);
GO

-- -------------------------------------------------------------
-- vTransferWhPallets  (clone of vReceivePallets)
-- -------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vTransferWhPallets
AS
SELECT v.*
FROM (
    SELECT id FROM dbo.tr_job_main
    WHERE job_type_id = 11
      AND (status_flag IS NULL OR status_flag = 'A')
      AND (is_active IS NULL OR is_active = 'Y')
) jm
CROSS APPLY dbo.fTransferWhPallets(jm.id) v;
GO

-- -------------------------------------------------------------
-- fTransferWhJob  (clone of fReceiveJob)
-- -------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fTransferWhJob (@job_main_id INT = NULL, @date DATE = NULL)
RETURNS TABLE
AS
RETURN
(
WITH pallet AS (
    SELECT
        p.job_main_id, p.job_header_id, p.job_item_id, p.job_type_id, p.job_to_location_id,
        MIN(p.from_location_datetime) AS start_datetime, MAX(p.to_location_datetime) AS end_datetime,
        SUM(CASE WHEN p.is_received = 'Y' THEN 1 ELSE 0 END) AS receive_pallet,
        SUM(CASE WHEN p.is_complete = 'Y' THEN 1 ELSE 0 END) AS complete_pallet
    FROM (
        SELECT id FROM dbo.tr_job_main
        WHERE job_type_id = 11
          AND (status_flag IS NULL OR status_flag = 'A')
          AND (is_active IS NULL OR is_active = 'Y')
          AND (@job_main_id IS NULL OR id = @job_main_id)
          AND (@date IS NULL OR CAST(create_datetime AS DATE) = @date)
    ) jm3
    CROSS APPLY dbo.fTransferWhPallets(jm3.id) p
    GROUP BY p.job_main_id, p.job_header_id, p.job_item_id, p.job_type_id, p.job_to_location_id
),
bg_location AS (
    SELECT id, bg_plant_code, bg_plant_desc AS bg_plant_location
    FROM dbo.ct_bg_plant_location
    WHERE (is_active = 'Y') AND (status_flag = 'A')
),
jm_bypass AS (
    SELECT
        jm.id, CAST(NULL AS INT) AS ref_id, jm.interface_job_id AS header_id, CAST(NULL AS INT) AS ref_header_id,
        tw.item_id, CAST(NULL AS INT) AS ref_item_id, jm.job_type_id, jt.topic AS job_type_topic, jt.short_name AS job_type_short_name, jt.name AS job_type_name,
        jm.is_urgent, jm.is_multi_forklift, jm.job_status_id, js.name AS job_status_name,
        jm.start_datetime AS job_start_datetime, jm.end_datetime AS job_end_datetime,
        fl.id AS job_from_location_id, fl.from_location_id, fl.from_location_type,
        fl.qty AS qty_from_location, fl.actual_qty AS actual_qty_from_location,
        tl.id AS job_to_location_id, tl.to_location_id, tl.to_location_type, tl.qty AS qty_to_location, tl.actual_qty AS actual_qty_to_location,
        jm.create_datetime
    FROM dbo.tr_job_main AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm AS tw ON tw.header_id = jm.interface_job_id AND jm.job_type_id = 11
    LEFT JOIN dbo.tr_job_from_location AS fl ON fl.job_main_id = jm.id AND fl.interface_job_item_id = tw.item_id AND (fl.is_active IS NULL OR fl.is_active = 'Y') AND (fl.status_flag IS NULL OR fl.status_flag = 'A')
    LEFT JOIN dbo.tr_job_to_location AS tl ON tl.job_main_id = jm.id AND tl.interface_job_item_id = tw.item_id AND (tl.is_active IS NULL OR tl.is_active = 'Y') AND (tl.status_flag IS NULL OR tl.status_flag = 'A')
    LEFT JOIN dbo.ct_job_status AS js ON js.id = jm.job_status_id
    LEFT JOIN dbo.ct_job_type AS jt ON jt.id = jm.job_type_id
    WHERE (jm.status_flag IS NULL OR jm.status_flag = 'A') AND (jm.is_active IS NULL OR jm.is_active = 'Y')
      AND (jt.is_active IS NULL OR jt.is_active = 'Y') AND (js.is_active IS NULL OR js.is_active = 'Y')
      AND (jt.status_flag IS NULL OR jt.status_flag = 'A') AND (js.status_flag IS NULL OR js.status_flag = 'A')
      AND tw.item_id IS NOT NULL
      AND (@job_main_id IS NULL OR jm.id = @job_main_id)
      AND (@date IS NULL OR CAST(jm.create_datetime AS DATE) = @date)
)
SELECT
    jm.id,
    rf.header_id,
    rf.system_no,
    rf.document_wms_no COLLATE Thai_CI_AI AS wms_no,
    jm.job_type_id,
    jm.job_type_topic,
    jm.job_type_short_name,
    jm.job_type_name,
    rf.process_order,
    rf.movement_type,
    rf.from_sloc_id,
    jm.job_from_location_id,
    jm.from_location_id,
    COALESCE(jm.from_location_type, 'BG-PLANT') COLLATE Thai_100_CI_AI_KS AS from_location_type,
    from_bg.bg_plant_location AS from_location_name,
    rf.from_plant_cc_code AS from_location_cc_code,
    rf.from_plant_cc_desc AS from_location_cc_desc,
    ll.lot_no AS from_location_lot_no,
    jm.qty_from_location,
    jm.actual_qty_from_location,
    cp.start_datetime AS from_location_datetime,
    jm.job_to_location_id,
    jm.to_location_id,
    wt.wh_name COLLATE Thai_100_CI_AI_KS AS to_location_type,
    to_bg.bg_plant_location AS to_location_name,
    rf.wh_to_cc_code AS to_location_cc_code,
    rf.wh_to_cc_desc AS to_location_cc_desc,
    llt.lot_no AS to_location_lot_no,
    jm.qty_to_location,
    jm.actual_qty_to_location,
    cp.end_datetime AS to_location_datetime,
    jm.is_urgent,
    jm.is_multi_forklift,
    jm.job_status_id,
    jm.job_status_name,
    rf.item_id,
    CAST(NULL AS NVARCHAR(100)) AS do_no,
    rf.code_t,
    rf.grade,
    rf.lot_no,
    CAST(NULL AS VARCHAR(50)) COLLATE Thai_CI_AI AS pd_cc_code,
    rf.qty,
    rf.confirm_qty,
    'kg' AS qty_unit,
    'Pallet' AS movement_unit,
    ISNULL(cp.receive_pallet, 0) AS receive_qty,
    ISNULL(cp.complete_pallet, 0) AS complete_qty,
    ISNULL(tp.total_pallet, 0) AS total_qty,
    rf.remark,
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
INNER JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm AS rf
    ON rf.header_id = jm.header_id AND rf.item_id = jm.item_id
LEFT JOIN IRPC_E_TRANSFER.dbo.ct_wh_to AS wt
    ON wt.ID = rf.to_wh_id
OUTER APPLY (
    SELECT TOP (1) gpr.unit_ratio, gpr.unit_pallet
    FROM dbo.ct_grade_package_ratio AS gpr
    WHERE gpr.grade = rf.grade COLLATE DATABASE_DEFAULT
    ORDER BY gpr.id DESC
) gpr
CROSS APPLY (
    SELECT CAST(CEILING(rf.qty / NULLIF(ISNULL(gpr.unit_ratio, 25) * ISNULL(gpr.unit_pallet, 40), 0)) AS INT) AS total_pallet
) tp
LEFT HASH JOIN pallet AS cp
    ON cp.job_main_id = jm.id AND cp.job_header_id = jm.header_id AND cp.job_item_id = jm.item_id
    AND cp.job_type_id = jm.job_type_id AND cp.job_to_location_id = jm.job_to_location_id
LEFT OUTER JOIN dbo.tr_lot_location AS llt
    ON llt.job_main_id = jm.id AND llt.job_item_id = jm.item_id AND llt.job_location_type = 'TO'
    AND llt.job_location_id = jm.job_to_location_id AND llt.is_active = 'Y' AND llt.status_flag = 'A'
LEFT OUTER JOIN dbo.tr_lot_location AS ll
    ON ll.job_main_id = jm.id AND ll.job_item_id = jm.item_id AND ll.job_location_type = 'FROM'
    AND ll.job_location_id = jm.job_from_location_id AND rf.lot_no IS NULL
    AND ll.is_active = 'Y' AND ll.status_flag = 'A' AND (llt.lot_no IS NULL OR ll.lot_no = llt.lot_no)
LEFT OUTER JOIN bg_location AS from_bg
    ON from_bg.id = jm.from_location_id AND from_bg.bg_plant_code = rf.from_plant_cc_code COLLATE Thai_100_CI_AI_KS
    AND jm.from_location_type = 'BG-PLANT'
LEFT OUTER JOIN bg_location AS to_bg
    ON to_bg.id = jm.to_location_id AND to_bg.bg_plant_code = rf.wh_to_cc_code COLLATE Thai_100_CI_AI_KS
    AND jm.to_location_type = 'BG-PLANT'
);
GO

-- -------------------------------------------------------------
-- vTransferWhJob  (clone of vReceiveJob)
-- -------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vTransferWhJob
AS
SELECT * FROM dbo.fTransferWhJob(NULL, NULL);
GO
