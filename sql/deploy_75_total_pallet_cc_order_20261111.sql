/* =====================================================================
   Deploy to 10.31.1.75 -- total pallet "source changed" false positive
   ---------------------------------------------------------------------
   Problem: picking / shipping jobs show "ข้อมูลต้นทางเปลี่ยนหลัง approve"
   right after approve although grade / qty did not change (eg. job 1999
   DO-3031015238: GA800 15,000 (120101) -> GA800 15,000 (1420)).

   Cause: on approve, pProcessGetJobItemsForTotalPallet snapshots the CC
   from tr_delivery.cc_code first (the WMS-synced value, eg. 120101). The
   board then calls PATCH do (pProcessInsertUpdateTrDo), which rewrites
   tr_delivery.cc_code to the picked product CC (1420). The source-changed
   SP compares the new cc_code with the snapshot and flags the job.

   Fix: both SPs use the same CC order for picking / shipping:
   tr_job_main.product_cc first (saved by pProcessApproveJob before the
   snapshot), then the shipping job's referenced picking job product_cc,
   then tr_delivery.cc_code.

   Also: picking / shipping returned pd_group NULL, so the WMS master
   grade lookup was skipped and total_pallet stayed NULL (0 Pallet).
   pProcessGetJobItemsForTotalPallet now maps tr_job_main.product_type
   to its wms_group (ct_bagging_code_t), same as 10.31.1.74.

   After deploy: jobs approved before this keep their old snapshot. Press
   save (re-approve) on them once to rebuild the snapshot.
   ===================================================================== */
GO
--  @job_main_ids = '101,102,...'. One row per item whose grade / qty / CC
--  differs from the snapshot (change_type 'changed'), was removed from the
--  source ('removed') or added to it ('added'). No row = unchanged.
CREATE OR ALTER PROCEDURE [dbo].[pProcessGetJobTotalPalletSourceChanged]
    @job_main_ids NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#jm') IS NOT NULL DROP TABLE #jm;
    IF OBJECT_ID('tempdb..#cur') IS NOT NULL DROP TABLE #cur;

    SELECT jm.id AS job_main_id, jm.job_type_id, jm.interface_job_id AS header_id,
           NULLIF(LTRIM(RTRIM(jm.product_cc)), '') AS product_cc
    INTO #jm
    FROM dbo.tr_job_main AS jm
    WHERE jm.id IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@job_main_ids, ''), ','))
      AND jm.status_flag = 'A'
      AND EXISTS (SELECT 1 FROM dbo.tr_job_total_pallet_snapshot AS s WHERE s.job_main_id = jm.id);

    CREATE TABLE #cur
    (
        job_main_id INT,
        item_id     INT,
        grade       VARCHAR(50) COLLATE DATABASE_DEFAULT,
        qty         DECIMAL(18, 3),
        cost_center VARCHAR(50) COLLATE DATABASE_DEFAULT
    );

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VTransferSlip AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 1 AND ISNULL(v.q_track_mode, 'A') <> 'M';

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VReceiveForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 2 AND ISNULL(v.q_track_mode, 'A') <> 'M';

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VRequestForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 3;

    --  Picking / shipping: same CC order as pProcessGetJobItemsForTotalPallet
    --  (the job's product CC first, the delivery's cc_code only as fallback).
    --  The delivery's cc_code is rewritten by the board's DO edit right after
    --  approve, so comparing it first flagged every approve as changed.
    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.cc_code)), ''))
    FROM #jm AS jm
    INNER JOIN dbo.vPickingForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 4;

    --  Shipping without its own product CC falls back to the picking job it
    --  refers to (ref_id), same as pProcessGetJobItemsForTotalPallet.
    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(rj.product_cc)), ''), NULLIF(LTRIM(RTRIM(v.cc_code)), ''))
    FROM #jm AS jm
    INNER JOIN dbo.vShippingForm AS v ON v.header_id = jm.header_id
    LEFT JOIN dbo.tr_job_main AS rj ON rj.id = v.ref_id AND rj.status_flag = 'A'
    WHERE jm.job_type_id = 5;

    SELECT
        COALESCE(s.job_main_id, c.job_main_id) AS job_main_id,
        COALESCE(s.item_id, c.item_id) AS item_id,
        CASE WHEN c.item_id IS NULL THEN 'removed'
             WHEN s.item_id IS NULL THEN 'added'
             ELSE 'changed' END AS change_type,
        s.grade AS old_grade, s.qty AS old_qty, s.cost_center AS old_cost_center, s.total_pallet AS old_total_pallet,
        c.grade AS new_grade, c.qty AS new_qty, c.cost_center AS new_cost_center,
        s.create_datetime AS calc_datetime
    FROM (SELECT * FROM dbo.tr_job_total_pallet_snapshot WHERE job_main_id IN (SELECT job_main_id FROM #jm)) AS s
    FULL OUTER JOIN #cur AS c ON c.job_main_id = s.job_main_id AND c.item_id = s.item_id
    WHERE c.item_id IS NULL
       OR s.item_id IS NULL
       OR ISNULL(s.grade, '') <> ISNULL(c.grade, '')
       OR ISNULL(s.qty, -1) <> ISNULL(c.qty, -1)
       OR ISNULL(s.cost_center, '') <> ISNULL(c.cost_center, '')
    ORDER BY job_main_id, item_id;
END
GO

--  Items of a TS / RC / RQ / picking / shipping job with what the
--  total-pallet calculation needs. TS / RC / RQ: cost_center = the product
--  CC picked on approve (tr_job_main.product_cc, saved by
--  pProcessApproveJob), falling back to the form header's from_cc_code_wms
--  -- same CC WMS Plus used before. Any other job type returns no rows.
--  Same as live on 10.31.1.74.
CREATE OR ALTER PROCEDURE [dbo].[pProcessGetJobItemsForTotalPallet]
    @job_main_id INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @job_type_id INT, @header_id INT, @product_cc VARCHAR(50), @product_type VARCHAR(50);

    SELECT
        @job_type_id = job_type_id,
        @header_id = interface_job_id,
        @product_cc = NULLIF(LTRIM(RTRIM(product_cc)), ''),
        @product_type = NULLIF(LTRIM(RTRIM(product_type)), '')
    FROM dbo.tr_job_main
    WHERE id = @job_main_id
      AND status_flag = 'A';

    IF @job_type_id = 1
        SELECT @job_type_id AS job_type_id, v.item_id, v.grade, v.qty, v.wms_group AS pd_group,
               COALESCE(@product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms)), '')) AS cost_center
        FROM IRPC_E_TRANSFER.dbo.VTransferSlip AS v
        WHERE v.header_id = @header_id
          AND ISNULL(v.q_track_mode, 'A') <> 'M';   -- manual mode: pallet count typed on the form
    ELSE IF @job_type_id = 2
        SELECT @job_type_id AS job_type_id, v.item_id, v.grade, v.qty, v.wms_group AS pd_group,
               COALESCE(@product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms)), '')) AS cost_center
        FROM IRPC_E_TRANSFER.dbo.VReceiveForm AS v
        WHERE v.header_id = @header_id
          AND ISNULL(v.q_track_mode, 'A') <> 'M';
    ELSE IF @job_type_id = 3
        SELECT @job_type_id AS job_type_id, v.item_id, v.grade, v.qty, v.wms_group AS pd_group,
               COALESCE(@product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms)), '')) AS cost_center
        FROM IRPC_E_TRANSFER.dbo.VRequestForm AS v
        WHERE v.header_id = @header_id;
    --  Picking / shipping: same as TS / RC / RQ -- the Product Cost Center
    --  and Product Type picked on the job detail / approve
    --  (tr_job_main.product_cc / product_type) first; the delivery's own
    --  cc_code only when no product CC was picked. pd_group = WMS group of
    --  the product type (e.g. 'Film' -> '0F', via IRPC_E_TRANSFER
    --  ct_bagging_code_t -- same list as pWmsPlus_ProcessCBGetProductType);
    --  a stored WMS group code is used as is. Shipping without its own
    --  product CC / type falls back to the picking job it refers to
    --  (ref_id). No product type -> pd_group NULL and the item is skipped,
    --  same as TS / RC / RQ without wms_group.
    ELSE IF @job_type_id = 4
        SELECT @job_type_id AS job_type_id, v.item_id, v.grade, v.qty, pt.wms_group AS pd_group,
               COALESCE(@product_cc, NULLIF(LTRIM(RTRIM(v.cc_code)), '')) AS cost_center
        FROM dbo.vPickingForm AS v
        OUTER APPLY (
            SELECT TOP (1) c.wms_group COLLATE DATABASE_DEFAULT AS wms_group
            FROM IRPC_E_TRANSFER.dbo.ct_bagging_code_t AS c
            WHERE c.is_active = 'Y' AND c.status_flag = 'A'
              AND (c.code COLLATE DATABASE_DEFAULT = @product_type OR c.wms_group COLLATE DATABASE_DEFAULT = @product_type)
            ORDER BY CASE WHEN c.code COLLATE DATABASE_DEFAULT = @product_type THEN 0 ELSE 1 END
        ) AS pt
        WHERE v.header_id = @header_id;
    ELSE IF @job_type_id = 5
        SELECT @job_type_id AS job_type_id, v.item_id, v.grade, v.qty, pt.wms_group AS pd_group,
               COALESCE(jp.product_cc, NULLIF(LTRIM(RTRIM(v.cc_code)), '')) AS cost_center
        FROM dbo.vShippingForm AS v
        OUTER APPLY (
            SELECT COALESCE(@product_type, NULLIF(LTRIM(RTRIM(rj.product_type)), '')) AS product_type,
                   COALESCE(@product_cc, NULLIF(LTRIM(RTRIM(rj.product_cc)), '')) AS product_cc
            FROM (SELECT 1 AS x) AS one
            LEFT JOIN dbo.tr_job_main AS rj ON rj.id = v.ref_id AND rj.status_flag = 'A'
        ) AS jp
        OUTER APPLY (
            SELECT TOP (1) c.wms_group COLLATE DATABASE_DEFAULT AS wms_group
            FROM IRPC_E_TRANSFER.dbo.ct_bagging_code_t AS c
            WHERE c.is_active = 'Y' AND c.status_flag = 'A'
              AND (c.code COLLATE DATABASE_DEFAULT = jp.product_type OR c.wms_group COLLATE DATABASE_DEFAULT = jp.product_type)
            ORDER BY CASE WHEN c.code COLLATE DATABASE_DEFAULT = jp.product_type THEN 0 ELSE 1 END
        ) AS pt
        WHERE v.header_id = @header_id;
    ELSE
        SELECT @job_type_id AS job_type_id, CAST(NULL AS INT) AS item_id, CAST(NULL AS VARCHAR(50)) AS grade,
               CAST(NULL AS DECIMAL(18, 3)) AS qty, CAST(NULL AS VARCHAR(50)) AS pd_group, CAST(NULL AS VARCHAR(50)) AS cost_center
        WHERE 1 = 0;
END
GO
