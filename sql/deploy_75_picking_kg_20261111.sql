/* =====================================================================
   Deploy to 10.31.1.75 -- picking flow (kg, pallet_seq, mode_id)
   ---------------------------------------------------------------------
   Problem: forklift confirm source location on picking job fails with
   "Procedure or function pProcessPickingGetPallet has too many
   arguments specified."

   Cause: API (JobController PickingGetPallet / PickingPutAway) sends
   @pallet_seq and @mode_id. 10.31.1.75 still has the old picking SPs
   (6 params). 10.31.1.74 got the new picking set on 2026-11-09.

   Objects (copied from 10.31.1.74):
     fPickingBags            (new on .75)
     vPickingBags            (new on .75)
     fPickingJob             (.74 version, kg; keeps the .75 fix of
                              2026-11-11: system_no uses pk.shipment_no)
     pProcessPickingGetPallet   (+@pallet_seq, +@mode_id)
     pProcessPickingPutAway     (+@pallet_seq)
     pProcessPickingResetPallet
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- ===== dbo.fPickingBags =====
-- ---------------------------------------------------------------------
-- fPickingBags (was fPickingPallets): one row per bag of a picking job (as fRequestBags)
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fPickingBags (@job_main_id INT)
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
            bag_id,

            MAX(CASE WHEN process_id = 1 THEN 1 ELSE 0 END) AS has_get,

            COALESCE(
                MAX(CASE WHEN process_id = 1 THEN pallet_seq END),
                MAX(CASE WHEN process_id = 2 THEN pallet_seq END)
            ) AS pallet_seq,

            MAX(CASE WHEN process_id = 1 THEN location_id END)     AS location_get_id,
            MAX(CASE WHEN process_id = 1 THEN location_type END)   AS location_get_type,
            MAX(CASE WHEN process_id = 1 THEN create_datetime END) AS location_get_datetime,
            MAX(CASE WHEN process_id = 1 THEN create_user_id END)  AS location_get_user_id,

            MAX(CASE WHEN process_id = 2 THEN location_id END)     AS location_put_id,
            MAX(CASE WHEN process_id = 2 THEN location_type END)   AS location_put_type,
            MAX(CASE WHEN process_id = 2 THEN create_datetime END) AS location_put_datetime,
            MAX(CASE WHEN process_id = 2 THEN create_user_id END)  AS location_put_user_id

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
                        ph.bag_id,
                        ph.process_id
                    ORDER BY ph.create_datetime DESC
                ) AS rn
            FROM dbo.tr_pallet_history ph
            WHERE ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND ph.bag_id IS NOT NULL
              AND ph.process_id IN (1, 2)
              AND ph.job_main_id = @job_main_id
        ) ranked
        WHERE ranked.rn = 1
        GROUP BY job_main_id, job_item_id, pallet_id, bag_id
    )

    SELECT
        p.id AS pallet_id,
        p.pallet_no,
        ph.pallet_seq,
        b.id AS bag_id,
        ph.bag_qty,

        p.pd_group_code,
        p.pd_type_code,

        b.grade,
        b.lot,
        b.lot AS lot_no,

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

        ph.location_get_id AS from_location_id,
        ph.location_get_type AS from_location_type,
        ph.location_get_datetime AS from_location_datetime,
        ph.location_get_user_id AS from_location_user_id,

        jm.job_to_location_id,

        IIF(ph.location_get_id IS NULL, NULL, ph.location_put_id) AS to_location_id,
        IIF(ph.location_get_id IS NULL, NULL, ph.location_put_type) AS to_location_type,
        IIF(ph.location_get_id IS NULL, NULL, ph.location_put_datetime) AS to_location_datetime,
        IIF(ph.location_get_id IS NULL, NULL, ph.location_put_user_id) AS to_location_user_id,

        CAST('N' AS VARCHAR(1)) AS is_prepare,

        CASE
            WHEN ph.location_get_id IS NOT NULL
             AND ph.location_get_datetime IS NOT NULL
             AND ph.location_get_user_id IS NOT NULL
             AND jm.from_location_id = ph.location_get_id
             AND ph.location_put_id IS NULL
             AND ph.location_put_datetime IS NULL
             AND ph.location_put_user_id IS NULL
            THEN 'Y'
            ELSE 'N'
        END AS is_received,

        CASE
            WHEN ph.location_get_id IS NOT NULL
             AND ph.location_get_datetime IS NOT NULL
             AND ph.location_get_user_id IS NOT NULL
             AND ph.location_put_id IS NOT NULL
             AND ph.location_put_datetime IS NOT NULL
             AND ph.location_put_user_id IS NOT NULL
             AND jm.from_location_id = ph.location_get_id
             AND jm.to_location_id = ph.location_put_id
            THEN 'Y'
            ELSE 'N'
        END AS is_complete

    FROM dbo.tr_pallet p

    INNER JOIN
    (
        SELECT cph.*,
               IIF(cph.has_get = 1,
                   CASE WHEN pl.pallet_type IN ('M', 'S') THEN dbo.fGetPalletQty(pl.id) ELSE pl.unit_ratio END,
                   NULL) AS bag_qty
        FROM cte_pallet_history cph
        LEFT JOIN dbo.tr_pallet pl
            ON pl.id = cph.pallet_id
            AND pl.is_active = 'Y'
            AND pl.status_flag = 'A'
    ) ph
        ON ph.pallet_id = p.id

    INNER JOIN dbo.tr_bag b
        ON b.pallet_id = ph.pallet_id
       AND CAST(b.id AS INT) = ph.bag_id
       AND
       (
            (b.status_flag IS NULL AND b.is_active IS NULL)
            OR
            (b.status_flag = 'A' AND b.is_active = 'Y')
       )

    CROSS APPLY
    (
        SELECT TOP (1)
            j2.id,
            j2.interface_job_id AS header_id,
            pk2.item_id,
            j2.job_type_id,
            jt2.topic AS job_type_topic,
            jt2.name AS job_type_name,
            fl2.id AS job_from_location_id,
            fl2.from_location_id,
            fl2.from_location_type,
            tl2.id AS job_to_location_id,
            tl2.to_location_id,
            tl2.to_location_type
        FROM dbo.tr_job_main j2
        INNER JOIN dbo.vPickingForm AS pk2
            ON pk2.header_id = j2.interface_job_id
        INNER JOIN dbo.ct_job_type jt2
            ON jt2.id = j2.job_type_id
        LEFT JOIN dbo.tr_job_from_location fl2
            ON fl2.job_main_id = j2.id AND fl2.interface_job_item_id = pk2.item_id
            AND (fl2.is_active IS NULL OR fl2.is_active = 'Y') AND (fl2.status_flag IS NULL OR fl2.status_flag = 'A')
        LEFT JOIN dbo.tr_job_to_location tl2
            ON tl2.job_main_id = j2.id AND tl2.interface_job_item_id = pk2.item_id
            AND (tl2.is_active IS NULL OR tl2.is_active = 'Y') AND (tl2.status_flag IS NULL OR tl2.status_flag = 'A')
        WHERE j2.id = ph.job_main_id
          AND pk2.item_id = ph.job_item_id
          AND j2.job_type_id = 4
          AND (j2.status_flag IS NULL OR j2.status_flag = 'A')

          AND
          (
              ph.location_get_id IS NULL
              OR
              (
                  fl2.from_location_id = ph.location_get_id
                  AND fl2.from_location_type = ph.location_get_type
              )
          )

          AND
          (
              (
                  ph.location_put_id IS NOT NULL
                  AND tl2.to_location_id = ph.location_put_id
                  AND tl2.to_location_type = ph.location_put_type
              )
              OR
              ph.location_put_id IS NULL
          )

        ORDER BY
            CASE
                WHEN tl2.to_location_id = ph.location_put_id
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
        ph.pallet_seq,
        b.id,
        ph.bag_qty,

        p.pd_group_code,
        p.pd_type_code,

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

        ph.location_get_id,
        ph.location_get_type,
        ph.location_get_datetime,
        ph.location_get_user_id,

        ph.location_put_id,
        ph.location_put_type,
        ph.location_put_datetime,
        ph.location_put_user_id,

        jm.from_location_id,
        jm.to_location_id,
        jm.to_location_type
)
GO

-- ===== dbo.vPickingBags =====
-- ---------------------------------------------------------------------
-- vPickingBags (replaces vPickingPallets): bags of every active picking job
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vPickingBags
AS
SELECT v.*
FROM (
    SELECT id FROM dbo.tr_job_main
    WHERE job_type_id = 4
      AND (status_flag IS NULL OR status_flag = 'A')
      AND (is_active IS NULL OR is_active = 'Y')
) jm
CROSS APPLY dbo.fPickingBags(jm.id) v;
GO

-- ===== dbo.fPickingJob =====
-- ---------------------------------------------------------------------
-- fPickingJob: kg like fRequestJob (movement_unit kg, total = delivery qty)
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION [dbo].[fPickingJob] (@job_main_id INT = NULL, @date DATE = NULL, @date_to DATE = NULL)
RETURNS TABLE
AS
RETURN
(
--  Picking counts kg like Request (fRequestJob): one group per pallet_seq
--  (or pallet), received / completed kg from its bags.
WITH bag_pallet AS (
    SELECT
        p.job_main_id, p.job_header_id, p.job_item_id, p.job_type_id, p.job_from_location_id, p.job_to_location_id,
        COALESCE(p.pallet_seq, p.pallet_id) AS pallet_group_key,
        MIN(p.from_location_datetime) AS start_datetime, MAX(p.to_location_datetime) AS end_datetime,
        SUM(p.bag_qty) AS pallet_qty,
        MAX(CASE WHEN p.is_complete = 'Y' THEN 1 ELSE 0 END) AS pallet_is_complete
    FROM (
        SELECT id FROM dbo.tr_job_main
        WHERE job_type_id = 4
          AND (status_flag IS NULL OR status_flag = 'A')
          AND (is_active IS NULL OR is_active = 'Y')
          AND (@job_main_id IS NULL OR id = @job_main_id)
          AND (@date IS NULL OR CAST(create_datetime AS DATE) BETWEEN @date AND ISNULL(@date_to, @date))
    ) jm3
    CROSS APPLY dbo.fPickingBags(jm3.id) p
    GROUP BY p.job_main_id, p.job_header_id, p.job_item_id, p.job_type_id, p.job_from_location_id, p.job_to_location_id, COALESCE(p.pallet_seq, p.pallet_id)
),
pallet AS (
    SELECT
        job_main_id, job_header_id, job_item_id, job_type_id, job_from_location_id, job_to_location_id,
        MIN(start_datetime) AS start_datetime, MAX(end_datetime) AS end_datetime,
        SUM(CASE WHEN pallet_is_complete = 0 THEN pallet_qty ELSE 0 END) AS receive_pallet,
        SUM(CASE WHEN pallet_is_complete = 1 THEN pallet_qty ELSE 0 END) AS complete_pallet
    FROM bag_pallet
    GROUP BY job_main_id, job_header_id, job_item_id, job_type_id, job_from_location_id, job_to_location_id
),
jm_bypass AS (
    SELECT
        jm.id, pk.ref_id, jm.interface_job_id AS header_id, pk.ref_header_id,
        pk.item_id, pk.ref_item_id, jm.job_type_id, jt.topic AS job_type_topic, jt.short_name AS job_type_short_name, jt.name AS job_type_name,
        jm.is_urgent, jm.is_multi_forklift, jm.job_status_id, js.name AS job_status_name,
        jm.start_datetime AS job_start_datetime, jm.end_datetime AS job_end_datetime,
        fl.id AS job_from_location_id, fl.from_location_id, fl.from_location_type,
        fl.qty AS qty_from_location, fl.actual_qty AS actual_qty_from_location,
        tl.id AS job_to_location_id, tl.to_location_id, tl.to_location_type, tl.qty AS qty_to_location, tl.actual_qty AS actual_qty_to_location,
        jm.create_datetime
    FROM dbo.tr_job_main AS jm
    INNER JOIN dbo.vPickingForm AS pk ON pk.header_id = jm.interface_job_id AND jm.job_type_id = 4
    LEFT JOIN dbo.tr_job_from_location AS fl ON fl.job_main_id = COALESCE(pk.ref_id, jm.id) AND fl.interface_job_item_id = COALESCE(pk.ref_item_id, pk.item_id) AND (fl.is_active IS NULL OR fl.is_active = 'Y') AND (fl.status_flag IS NULL OR fl.status_flag = 'A')
    LEFT JOIN dbo.tr_job_to_location AS tl ON tl.job_main_id = COALESCE(pk.ref_id, jm.id) AND tl.interface_job_item_id = COALESCE(pk.ref_item_id, pk.item_id) AND (tl.is_active IS NULL OR tl.is_active = 'Y') AND (tl.status_flag IS NULL OR tl.status_flag = 'A')
    LEFT JOIN dbo.ct_job_status AS js ON js.id = jm.job_status_id
    LEFT JOIN dbo.ct_job_type AS jt ON jt.id = jm.job_type_id
    WHERE (jm.status_flag IS NULL OR jm.status_flag = 'A') AND (jm.is_active IS NULL OR jm.is_active = 'Y')
      AND (jt.is_active IS NULL OR jt.is_active = 'Y') AND (js.is_active IS NULL OR js.is_active = 'Y')
      AND (jt.status_flag IS NULL OR jt.status_flag = 'A') AND (js.status_flag IS NULL OR js.status_flag = 'A')
      AND pk.item_id IS NOT NULL
      AND (@job_main_id IS NULL OR jm.id = @job_main_id)
      AND (@date IS NULL OR CAST(jm.create_datetime AS DATE) BETWEEN @date AND ISNULL(@date_to, @date))
)
SELECT
    jm.id,
    CAST(pk.header_id AS INT) AS header_id,
    CAST(COALESCE(CASE WHEN pk.shipment_no IS NULL THEN NULL ELSE 'DO-' + pk.do_no END, pk.ddo, pk.system_no) AS VARCHAR(15)) COLLATE Thai_CI_AI AS system_no,
    CAST(NULL AS VARCHAR(30)) COLLATE Thai_CI_AI AS wms_no,
    jm.job_type_id,
    jm.job_type_topic,
    jm.job_type_short_name,
    jm.job_type_name,
    CAST(NULL AS VARCHAR(20)) COLLATE Thai_CI_AI AS process_order,
    CAST(NULL AS VARCHAR(5)) COLLATE Thai_CI_AI AS movement_type,
    CAST(NULL AS INT) AS from_sloc_id,
    jm.job_from_location_id,
    jm.from_location_id,
    COALESCE(jm.from_location_type, 'MWH') COLLATE Thai_100_CI_AI_KS AS from_location_type,
    CAST(NULL AS NVARCHAR(500)) COLLATE Thai_100_CI_AI_KS AS from_location_name,
    CAST(pk.from_wh_cc_code AS VARCHAR(100)) COLLATE Thai_CI_AI AS from_location_cc_code,
    CAST(pk.from_wh_cc_desc AS NVARCHAR(200)) COLLATE Thai_CI_AI AS from_location_cc_desc,
    ll.lot_no AS from_location_lot_no,
    jm.qty_from_location,
    jm.actual_qty_from_location,
    cp.start_datetime AS from_location_datetime,
    jm.job_to_location_id,
    jm.to_location_id,
    CAST('PRE-ZONE' AS VARCHAR(50)) COLLATE Thai_100_CI_AI_KS AS to_location_type,
    CAST(sz.zone_name AS NVARCHAR(500)) COLLATE Thai_100_CI_AI_KS AS to_location_name,
    CAST(pk.to_pre_zone_cc_code AS VARCHAR(50)) COLLATE Thai_CI_AI AS to_location_cc_code,
    CAST(pk.to_pre_zone_cc_desc AS NVARCHAR(500)) COLLATE Thai_CI_AI AS to_location_cc_desc,
    llt.lot_no AS to_location_lot_no,
    jm.qty_to_location,
    jm.actual_qty_to_location,
    cp.end_datetime AS to_location_datetime,
    jm.is_urgent,
    jm.is_multi_forklift,
    jm.job_status_id,
    jm.job_status_name,
    CAST(pk.item_id AS INT) AS item_id,
    CAST(pk.do_no AS NVARCHAR(100)) AS do_no,
    CAST(pk.code_t AS NVARCHAR(200)) COLLATE Thai_CI_AI AS code_t,
    CAST(pk.grade AS VARCHAR(30)) COLLATE Thai_CI_AI AS grade,
    CAST(pk.lot AS VARCHAR(30)) COLLATE Thai_CI_AI AS lot_no,
    pk.cc_code COLLATE Thai_CI_AI AS pd_cc_code,
    pk.qty,
    CAST(NULL AS DECIMAL(18, 3)) AS confirm_qty,
    'kg' AS qty_unit,
    'kg' AS movement_unit,
    ISNULL(cp.receive_pallet, 0) AS receive_qty,
    ISNULL(cp.complete_pallet, 0) AS complete_qty,
    ISNULL(pk.qty, 0) AS total_qty,
    CAST(NULL AS NVARCHAR(250)) COLLATE Thai_CI_AI AS remark,
    pk.source_id,
    jm.job_start_datetime,
    jm.job_end_datetime,
    jm.create_datetime AS job_create_datetime,
    CAST(pk.shipment_no AS VARCHAR(50)) COLLATE Thai_CI_AI AS shipment_no,
    pk.code_pallet_id,
    CAST(pk.pallet_lot AS VARCHAR(30)) COLLATE Thai_CI_AI AS pallet_lot,
    pk.pallet_qty,
    pk.pallet_weight,
    pk.special_type_package_id
FROM jm_bypass AS jm
INNER JOIN dbo.vPickingForm AS pk
    ON pk.header_id = jm.header_id AND pk.item_id = jm.item_id
LEFT JOIN pallet AS cp
    ON cp.job_main_id = jm.id AND cp.job_header_id = jm.header_id AND cp.job_item_id = jm.item_id
    AND cp.job_type_id = jm.job_type_id AND cp.job_from_location_id = jm.job_from_location_id
    AND (cp.job_to_location_id IS NULL OR cp.job_to_location_id = jm.job_to_location_id)
LEFT OUTER JOIN dbo.tr_lot_location AS llt
    ON llt.job_main_id = jm.id AND llt.job_item_id = jm.item_id AND llt.job_location_type = 'TO'
    AND llt.job_location_id = jm.job_to_location_id AND llt.is_active = 'Y' AND llt.status_flag = 'A'
LEFT OUTER JOIN dbo.tr_lot_location AS ll
    ON ll.job_main_id = COALESCE(jm.ref_id, jm.id) AND ll.job_item_id = COALESCE(jm.ref_item_id, jm.item_id)
    AND ll.job_location_type = 'FROM' AND ll.job_location_id = jm.job_from_location_id
    AND pk.lot IS NULL AND ll.is_active = 'Y' AND ll.status_flag = 'A' AND (llt.lot_no IS NULL OR ll.lot_no = llt.lot_no)
LEFT OUTER JOIN IRPC.dbo.ct_strorage_zone AS sz
    ON sz.ID = jm.to_location_id AND sz.is_active = 'Y' AND sz.status_flag = 'A'
)
GO

-- ===== dbo.pProcessPickingGetPallet =====
-- ---------------------------------------------------------------------
-- pProcessPickingGetPallet: GET like pProcessRequestGetPallet
-- (bag / pallet QR, @pallet_seq, @mode_id, kg over qty -> roll back)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessPickingGetPallet]
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @mode_id            INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    -- ------------------------------------------------
    -- Job / item (picking job_type_id 4 + vPickingForm)
    -- ------------------------------------------------
    DECLARE @job_ok BIT = 0, @item_ok BIT = 0;

    IF EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
        SET @job_ok = 1;

    IF EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
          AND (jm.is_active IS NULL OR jm.is_active = 'Y')
          AND f.item_id = @job_item_id
    )
        SET @item_ok = 1;

    --  JB: create pallet + bag on first scan (pProcessInsertJbPalletBag),
    --  only for an existing job / item, before the QR lookup
    IF @job_ok = 1 AND @item_ok = 1
    BEGIN
        DECLARE @jb_status  VARCHAR(20);
        DECLARE @jb_message VARCHAR(200);

        EXEC dbo.pProcessInsertJbPalletBag
            @qr_code_text  = @qr_code_text,
            @user_id       = @user_id,
            @return_result = 0,
            @status        = @jb_status  OUTPUT,
            @message       = @jb_message OUTPUT;

        IF @jb_status = 'error'
        BEGIN
            SELECT 'error' AS status, @jb_message AS message;
            RETURN;
        END
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    IF @job_ok = 0 OR @item_ok = 0
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    DECLARE @locked_job_id INT, @job_status_id INT;
    DECLARE @loc_qty INT, @loc_actual_before INT, @loc_actual_after INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  A pallet already in another picking job
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet p
            INNER JOIN dbo.tr_job_main jm ON jm.id = p.current_job_id
            WHERE p.id = @pallet_id
              AND p.current_job_id <> @job_main_id
              AND jm.job_type_id = 4
              AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
              AND (jm.is_active IS NULL OR jm.is_active = 'Y')
              AND EXISTS (
                  SELECT 1 FROM dbo.vPickingForm f
                  WHERE f.header_id = jm.interface_job_id AND f.item_id IS NOT NULL
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้อยู่ในงาน Picking อื่นแล้ว' AS message;
            RETURN;
        END

        --  Only at a from-location of this item
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_from_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND (@location_type IS NULL OR from_location_type = @location_type)
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'ตำแหน่งนี้ไม่ใช่ต้นทางของงานนี้' AS message;
            RETURN;
        END

        --  No bag taken twice in this job (Get, Put or store bag)
        --  (bag QR: that bag; mode 1 / pallet QR: every active bag of the pallet)
        IF EXISTS (
            SELECT 1
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.process_id IN (1, 2, 4)
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND (
                    (@bag_id IS NOT NULL AND ISNULL(@mode_id, 0) <> 1 AND ph.bag_id = @bag_id_text)
                 OR ((@bag_id IS NULL OR @mode_id = 1) AND EXISTS (
                        SELECT 1 FROM dbo.tr_bag b
                        WHERE b.id = TRY_CONVERT(BIGINT, ph.bag_id)
                          AND b.pallet_id = @pallet_id
                          AND b.is_active = 'Y'
                          AND b.status_flag = 'A'))
              )
        )
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกรับเข้ามาแล้ว' AS message;
            RETURN;
        END

        --  qty of this item / from-location and what is taken there already
        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_from_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND from_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        IF @loc_qty IS NOT NULL
            SELECT @loc_actual_before = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        UPDATE dbo.tr_job_main
        SET job_status_id = 4,
            start_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @job_main_id
          AND ISNULL(job_status_id, 0) <> 4;

        UPDATE dbo.tr_pallet
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE id = @pallet_id;

        -- ------------------------------------------------
        -- Get rows (one per bag)
        --   mode 1 / pallet QR: every active bag of the pallet
        --   mode 2: store bag -- the scanned bag stays (process 4), the rest of the pallet is taken
        --   other : the scanned bag
        -- ------------------------------------------------
        IF @mode_id = 1 OR @bag_id IS NULL
        BEGIN
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A';
        END
        ELSE IF @mode_id = 2
        BEGIN
            --  only active rows count, so a reset pallet can be scanned again
            IF NOT EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history
                WHERE job_main_id = @job_main_id
                  AND job_item_id = @job_item_id
                  AND bag_id = @bag_id_text
                  AND process_id = 4
                  AND is_active = 'Y'
                  AND status_flag = 'A'
            )
                INSERT INTO dbo.tr_pallet_history (
                    job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                    location_id, location_type, create_user_id, create_datetime,
                    update_user_id, update_datetime
                )
                VALUES (
                    @job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
                    @location_id, @location_type, @user_id, GETDATE(),
                    @user_id, GETDATE()
                );

            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            SELECT
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            FROM dbo.tr_bag b
            WHERE b.pallet_id = @pallet_id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.tr_pallet_history ph
                  WHERE ph.job_main_id = @job_main_id
                    AND ph.job_item_id = @job_item_id
                    AND ph.bag_id = CAST(b.id AS VARCHAR(255))
                    AND ph.process_id IN (1, 4)
                    AND ph.is_active = 'Y'
                    AND ph.status_flag = 'A'
              );
        END
        ELSE
        BEGIN
            INSERT INTO dbo.tr_pallet_history (
                job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
                location_id, location_type, create_user_id, create_datetime,
                update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
                @location_id, @location_type, @user_id, GETDATE(),
                @user_id, GETDATE()
            );
        END

        -- ------------------------------------------------
        -- tr_job_from_location.actual_qty (kg) of this item / location; over qty -> roll back
        -- ------------------------------------------------
        IF @loc_qty IS NOT NULL
        BEGIN
            SELECT @loc_actual_after = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                                       THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                                       ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.job_item_id = @job_item_id
                  AND ph.location_id = @location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

            IF @loc_actual_after > @loc_qty
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'error' AS status,
                    CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                           N', รับแล้ว ', @loc_actual_before,
                           N', ครั้งนี้ ', @loc_actual_after - @loc_actual_before, N')') AS message;
                RETURN;
            END

            UPDATE dbo.tr_job_from_location
            SET actual_qty = @loc_actual_after,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND from_location_id = @location_id
              AND ISNULL(qty, 0) <> 0
              AND is_active = 'Y'
              AND status_flag = 'A'
              AND ISNULL(actual_qty, -1) <> @loc_actual_after;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    --  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
    EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

    SELECT 'success' AS status, N'พาเลทนี้ถูกรับเข้ามาสำเร็จ' AS message, @pallet_seq AS pallet_seq;
END
GO

-- ===== dbo.pProcessPickingPutAway =====
-- ---------------------------------------------------------------------
-- pProcessPickingPutAway: PUT like pProcessRequestPutAway, into the
-- Pre-zone. On completion: Shipping job + iLogistic prepare rows
-- (dbResult1) as before.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessPickingPutAway]
    @job_main_id        INT             = NULL,
    @job_item_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @location_id        INT             = NULL,
    @location_type      VARCHAR(10)     = NULL,
    @pallet_seq         INT             = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL OR @job_item_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    --  Job / item (picking job_type_id 4 + vPickingForm)
    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND (jm.status_flag IS NULL OR jm.status_flag = 'A')
          AND (jm.is_active IS NULL OR jm.is_active = 'Y')
          AND f.item_id = @job_item_id
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงานในระบบ' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_pallet
        WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @bag_id_text VARCHAR(255) = CAST(@bag_id AS VARCHAR(255));
    DECLARE @current_job_status_id INT;
    DECLARE @split_pallet_nos NVARCHAR(MAX) = NULL;
    DECLARE @is_job_complete BIT = 0;
    DECLARE @shipping_message NVARCHAR(200) = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @current_job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        IF @current_job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว' AS message;
            RETURN;
        END

        --  The Pre-zone is picked at the put (no to-location on approve):
        --  add it as this item's to-location the first time
        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_job_to_location
            WHERE job_main_id = @job_main_id
              AND interface_job_item_id = @job_item_id
              AND to_location_id = @location_id
              AND is_active = 'Y'
              AND status_flag = 'A'
        )
            INSERT INTO dbo.tr_job_to_location (
                job_main_id, interface_job_item_id, to_location_id, to_location_type,
                qty, actual_qty, create_user_id, create_datetime, update_user_id, update_datetime
            )
            VALUES (
                @job_main_id, @job_item_id, @location_id, 'PRE-ZONE',
                0, NULL, @user_id, GETDATE(), @user_id, GETDATE()
            );

        -- ------------------------------------------------
        -- Pallets in this put: the scanned pallet + every pallet taken at Get
        -- under the same pallet_seq
        -- ------------------------------------------------
        IF OBJECT_ID('tempdb..#pallet_ids_in_group') IS NOT NULL DROP TABLE #pallet_ids_in_group;

        SELECT DISTINCT pallet_id
        INTO #pallet_ids_in_group
        FROM (
            SELECT @pallet_id AS pallet_id
            UNION
            SELECT ph.pallet_id
            FROM dbo.tr_pallet_history ph
            WHERE @pallet_seq IS NOT NULL
              AND ph.job_main_id = @job_main_id
              AND ph.job_item_id = @job_item_id
              AND ph.process_id = 1
              AND ph.pallet_seq = @pallet_seq
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
        ) src;

        -- ------------------------------------------------
        -- Bags to put away: taken at Get for this job / item, not put yet
        -- ------------------------------------------------
        IF OBJECT_ID('tempdb..#bags_to_put_away') IS NOT NULL DROP TABLE #bags_to_put_away;

        SELECT DISTINCT b.id AS bag_id, b.pallet_id
        INTO #bags_to_put_away
        FROM dbo.tr_bag b
        INNER JOIN #pallet_ids_in_group g ON g.pallet_id = b.pallet_id
        WHERE b.is_active = 'Y'
          AND b.status_flag = 'A'
          AND EXISTS (
              SELECT 1 FROM dbo.tr_pallet_history ph1
              WHERE ph1.job_main_id = @job_main_id
                AND ph1.job_item_id = @job_item_id
                AND ph1.process_id = 1
                AND ph1.bag_id = CAST(b.id AS VARCHAR(255))
                AND ph1.is_active = 'Y'
                AND ph1.status_flag = 'A'
          )
          AND NOT EXISTS (
              SELECT 1 FROM dbo.tr_pallet_history ph2
              WHERE ph2.job_main_id = @job_main_id
                AND ph2.job_item_id = @job_item_id
                AND ph2.process_id = 2
                AND ph2.bag_id = CAST(b.id AS VARCHAR(255))
                AND ph2.is_active = 'Y'
                AND ph2.status_flag = 'A'
          );

        --  No bag put twice in this job (bag QR: that bag; pallet QR: nothing left to put)
        IF (@bag_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = @job_main_id
                  AND ph.process_id = 2
                  AND ph.bag_id = @bag_id_text
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'))
        OR (NOT EXISTS (SELECT 1 FROM #bags_to_put_away) AND EXISTS (
                SELECT 1 FROM dbo.tr_pallet_history ph
                INNER JOIN #pallet_ids_in_group g ON g.pallet_id = ph.pallet_id
                WHERE ph.job_main_id = @job_main_id
                  AND ph.process_id = 2
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'))
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ถูกจัดเก็บตามพื้นที่ที่กำหนดแล้ว' AS message;
            RETURN;
        END

        --  Nothing of this pallet was taken (Get) in this job / item
        IF NOT EXISTS (SELECT 1 FROM #bags_to_put_away)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ยังไม่ได้รับจากต้นทางในงานนี้ กรุณาสแกนรับพาเลทก่อน' AS message;
            RETURN;
        END

        -- ------------------------------------------------
        -- Picking split (as Request split)
        -- An A / J pallet that still has active bags not taken at Get
        -- (store bag / single bag) stays where it is; its taken bags move to
        -- a new pallet of the same type, one per pallet_seq + source pallet:
        --   tr_pallet.ref_id = source pallet id (Reset moves the bags back by it)
        --   tr_pallet.remark = 'PK split: job <job> seq <seq or -> from <pallet_no>'
        --   tr_bag.remark   += the same text
        -- M / S / D pallets move whole (their qty is not per bag).
        -- ------------------------------------------------
        IF OBJECT_ID('tempdb..#partial_pallets') IS NOT NULL DROP TABLE #partial_pallets;

        SELECT g.pallet_id, CAST(NULL AS BIGINT) AS split_pallet_id
        INTO #partial_pallets
        FROM #pallet_ids_in_group g
        INNER JOIN dbo.tr_pallet p ON p.id = g.pallet_id
        WHERE p.pallet_type IN ('A', 'J')
          AND EXISTS (
              SELECT 1 FROM dbo.tr_bag b
              WHERE b.pallet_id = g.pallet_id
                AND b.is_active = 'Y'
                AND b.status_flag = 'A'
                AND NOT EXISTS (
                    SELECT 1 FROM dbo.tr_pallet_history ph1
                    WHERE ph1.job_main_id = @job_main_id
                      AND ph1.job_item_id = @job_item_id
                      AND ph1.process_id = 1
                      AND ph1.bag_id = CAST(b.id AS VARCHAR(255))
                      AND ph1.is_active = 'Y'
                      AND ph1.status_flag = 'A'
                )
          );

        DECLARE @src_pallet_id BIGINT;
        DECLARE @src_pallet_no VARCHAR(50);
        DECLARE @src_pallet_type VARCHAR(1);
        DECLARE @split_pallet_id BIGINT;
        DECLARE @split_pallet_no VARCHAR(50);
        DECLARE @split_ref_id NVARCHAR(100);
        DECLARE @split_remark NVARCHAR(500);
        DECLARE @split_lock_resource NVARCHAR(255);
        DECLARE @split_lock INT;
        DECLARE @moved_bags INT;
        DECLARE @split_log NVARCHAR(MAX);

        DECLARE split_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT pp.pallet_id
            FROM #partial_pallets pp
            WHERE EXISTS (SELECT 1 FROM #bags_to_put_away t WHERE t.pallet_id = pp.pallet_id)
            ORDER BY pp.pallet_id;

        OPEN split_cursor;
        FETCH NEXT FROM split_cursor INTO @src_pallet_id;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @src_pallet_no = pallet_no, @src_pallet_type = pallet_type
            FROM dbo.tr_pallet
            WHERE id = @src_pallet_id;

            SET @split_ref_id = CAST(@src_pallet_id AS NVARCHAR(100));
            SET @split_remark = CONCAT(N'PK split: job ', @job_main_id, N' seq ', ISNULL(CAST(@pallet_seq AS NVARCHAR(20)), N'-'), N' from ', @src_pallet_no);
            SET @split_pallet_id = NULL;

            --  Same seq + source put before (another scan of the same put): add to that pallet
            SELECT TOP (1) @split_pallet_id = id
            FROM dbo.tr_pallet
            WHERE ref_id = @split_ref_id
              AND remark = @split_remark
              AND is_active = 'Y'
              AND status_flag = 'A'
            ORDER BY id;

            IF @split_pallet_id IS NULL
            BEGIN
                --  Same lock as the other creators of this pallet type (pallet_no is unique)
                SET @split_lock_resource = CASE WHEN @src_pallet_type = 'J' THEN N'QTRACK_CreateJbPallet' ELSE N'QTRACK_MatchBagToPallet' END;

                EXEC @split_lock = sp_getapplock @Resource = @split_lock_resource,
                                                 @LockMode = 'Exclusive', @LockOwner = 'Transaction',
                                                 @LockTimeout = 15000;
                IF @split_lock < 0
                    THROW 50001, N'กรุณาแสกนใหม่อีกครั้ง', 1;

                INSERT INTO dbo.tr_pallet (
                    ref_id, remark, pallet_no, pallet_type, pd_group_code, pd_type_code, unit_ratio, unit_pallet,
                    pallet_status_id, is_active, create_user_id, create_datetime,
                    update_user_id, update_datetime, status_flag
                )
                SELECT
                    @split_ref_id, @split_remark, dbo.fGetPalletNo(p.pallet_type), p.pallet_type, p.pd_group_code, p.pd_type_code, p.unit_ratio, p.unit_pallet,
                    1, 'Y', @user_id, GETDATE(),
                    @user_id, GETDATE(), 'A'
                FROM dbo.tr_pallet p
                WHERE p.id = @src_pallet_id;

                SET @split_pallet_id = SCOPE_IDENTITY();
            END

            UPDATE b
            SET pallet_id = @split_pallet_id,
                remark = LEFT(CONCAT(b.remark + ' | ', @split_remark), 255),
                update_user_id = @user_id,
                update_datetime = GETDATE()
            FROM dbo.tr_bag b
            INNER JOIN #bags_to_put_away t ON t.bag_id = b.id
            WHERE t.pallet_id = @src_pallet_id;

            SET @moved_bags = @@ROWCOUNT;

            --  Get rows follow their bags (Get and Put pair by pallet_id + bag_id)
            UPDATE ph
            SET pallet_id = @split_pallet_id,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            FROM dbo.tr_pallet_history ph
            INNER JOIN #bags_to_put_away t ON ph.bag_id = CAST(t.bag_id AS VARCHAR(255))
            WHERE t.pallet_id = @src_pallet_id
              AND ph.job_main_id = @job_main_id
              AND ph.job_item_id = @job_item_id
              AND ph.pallet_id = @src_pallet_id
              AND ph.process_id = 1
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A';

            UPDATE #bags_to_put_away SET pallet_id = @split_pallet_id WHERE pallet_id = @src_pallet_id;
            UPDATE #partial_pallets SET split_pallet_id = @split_pallet_id WHERE pallet_id = @src_pallet_id;

            --  The source pallet stays in the warehouse and leaves this job
            UPDATE dbo.tr_pallet
            SET current_job_id = NULL,
                current_job_item_id = NULL,
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE id = @src_pallet_id
              AND current_job_id = @job_main_id;

            SELECT @split_pallet_no = pallet_no FROM dbo.tr_pallet WHERE id = @split_pallet_id;

            SET @split_pallet_nos = CONCAT(@split_pallet_nos + N',', @split_pallet_no);
            SET @split_log = CONCAT(N'Job ', @job_main_id, N': ', @moved_bags, N' bag(s) *', @src_pallet_no, N'* -> *', @split_pallet_no, N'*');

            EXEC dbo.pInsertTransactionLog
                @topic    = 'Picking',
                @activity = 'Split Pallet',
                @detail   = @split_log,
                @user_id  = @user_id;

            FETCH NEXT FROM split_cursor INTO @src_pallet_id;
        END

        CLOSE split_cursor;
        DEALLOCATE split_cursor;

        --  pallet_status_id by bag count (as pProcessPalletMgmtMoveBag), CONFIRMED / VOID not changed
        UPDATE p
        SET pallet_status_id = CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet p
        CROSS APPLY (
            SELECT COUNT(*) AS cnt
            FROM dbo.tr_bag b
            WHERE b.pallet_id = p.id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
        ) bc
        WHERE (   p.id IN (SELECT pallet_id FROM #partial_pallets WHERE split_pallet_id IS NOT NULL)
               OR p.id IN (SELECT split_pallet_id FROM #partial_pallets WHERE split_pallet_id IS NOT NULL))
          AND ISNULL(p.pallet_status_id, 1) IN (1, 2)
          AND ISNULL(p.pallet_status_id, 1) <> CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END;

        --  Full pallets of the put + the split pallets go to the Pre-zone
        --  (current_job_id = this job, so the Shipping job can take them)
        UPDATE p
        SET current_job_id = @job_main_id,
            current_job_item_id = @job_item_id,
            current_location_id = @location_id,
            current_location_type = @location_type,
            outbound_to_pre_zone_id = @location_id,
            outbound_to_pre_zone_user_id = @user_id,
            outbound_to_pre_zone_datetime = GETDATE(),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet p
        WHERE (    p.id IN (SELECT pallet_id FROM #pallet_ids_in_group)
               AND p.id NOT IN (SELECT pallet_id FROM #partial_pallets))
           OR p.id IN (SELECT split_pallet_id FROM #partial_pallets WHERE split_pallet_id IS NOT NULL);

        INSERT INTO dbo.tr_pallet_history (
            job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
            location_id, location_type, create_user_id, create_datetime,
            update_user_id, update_datetime
        )
        SELECT
            @job_main_id, @job_item_id, 2, @pallet_seq, b.pallet_id, b.bag_id,
            @location_id, @location_type, @user_id, GETDATE(),
            @user_id, GETDATE()
        FROM #bags_to_put_away b;

        -- ------------------------------------------------
        -- tr_job_to_location.actual_qty (kg) of this item / Pre-zone. The
        -- Pre-zone row has no planned qty (0), so there is no over check;
        -- actual_qty is kept anyway -- it becomes the Shipping job's
        -- from-location qty on completion.
        -- ------------------------------------------------
        DECLARE @loc_qty INT, @loc_put_qty INT, @this_qty INT;

        SELECT @loc_qty = SUM(ISNULL(qty, 0))
        FROM dbo.tr_job_to_location
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND to_location_id = @location_id
          AND ISNULL(qty, 0) <> 0
          AND is_active = 'Y'
          AND status_flag = 'A';

        SELECT @loc_put_qty = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                              THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                              ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
        FROM (
            SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
            FROM dbo.tr_pallet_history ph
            WHERE ph.job_main_id = @job_main_id
              AND ph.job_item_id = @job_item_id
              AND ph.location_id = @location_id
              AND ph.process_id = 2
              AND ph.is_active = 'Y'
              AND ph.status_flag = 'A'
              AND ph.bag_id IS NOT NULL
            GROUP BY ph.pallet_id
        ) x
        INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        IF @loc_qty IS NOT NULL AND @loc_put_qty > @loc_qty
        BEGIN
            SELECT @this_qty = ISNULL(SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                               THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                               ELSE y.bag_cnt * ISNULL(p.unit_ratio, 0) END), 0)
            FROM (SELECT pallet_id, COUNT(DISTINCT bag_id) AS bag_cnt FROM #bags_to_put_away GROUP BY pallet_id) y
            INNER JOIN dbo.tr_pallet p ON p.id = y.pallet_id;

            ROLLBACK TRANSACTION;
            SELECT 'error' AS status,
                CONCAT(N'จำนวนเกินที่กำหนด (กำหนด ', @loc_qty,
                       N', ส่งแล้ว ', @loc_put_qty - @this_qty,
                       N', ครั้งนี้ ', @this_qty, N')') AS message;
            RETURN;
        END

        UPDATE dbo.tr_job_to_location
        SET actual_qty = @loc_put_qty,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        WHERE job_main_id = @job_main_id
          AND interface_job_item_id = @job_item_id
          AND to_location_id = @location_id
          AND is_active = 'Y'
          AND status_flag = 'A';

        -- ------------------------------------------------
        -- Job completion: completed kg (Get at the job from-location + Put at
        -- the job to-location, active bag on the same pallet) vs delivery qty
        -- ------------------------------------------------
        DECLARE @job_qty INT, @complete_qty INT;

        SELECT @job_qty = SUM(q.qty)
        FROM (
            SELECT DISTINCT f.item_id, f.qty
            FROM dbo.tr_job_main jm
            INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
            WHERE jm.id = @job_main_id
              AND f.item_id IS NOT NULL
        ) q;

        SELECT @complete_qty = SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                                        ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END)
        FROM (
            SELECT p2.pallet_id, COUNT(DISTINCT p2.bag_id) AS bag_cnt
            FROM dbo.tr_pallet_history p2
            INNER JOIN dbo.tr_job_to_location tl
                ON tl.job_main_id = p2.job_main_id
                AND tl.interface_job_item_id = p2.job_item_id
                AND tl.to_location_id = p2.location_id
                AND tl.is_active = 'Y'
                AND tl.status_flag = 'A'
            INNER JOIN dbo.tr_bag b
                ON b.id = TRY_CONVERT(BIGINT, p2.bag_id)
                AND b.pallet_id = p2.pallet_id
                AND b.is_active = 'Y'
                AND b.status_flag = 'A'
            WHERE p2.job_main_id = @job_main_id
              AND p2.process_id = 2
              AND p2.is_active = 'Y'
              AND p2.status_flag = 'A'
              AND p2.bag_id IS NOT NULL
              AND EXISTS (
                  SELECT 1
                  FROM dbo.tr_pallet_history p1
                  INNER JOIN dbo.tr_job_from_location fl
                      ON fl.job_main_id = p1.job_main_id
                      AND fl.interface_job_item_id = p1.job_item_id
                      AND fl.from_location_id = p1.location_id
                      AND fl.from_location_type = p1.location_type
                      AND fl.is_active = 'Y'
                      AND fl.status_flag = 'A'
                  WHERE p1.job_main_id = @job_main_id
                    AND p1.job_item_id = p2.job_item_id
                    AND p1.pallet_id = p2.pallet_id
                    AND p1.bag_id = p2.bag_id
                    AND p1.process_id = 1
                    AND p1.is_active = 'Y'
                    AND p1.status_flag = 'A'
              )
            GROUP BY p2.pallet_id
        ) x
        INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

        --  tr_job_from_location.actual_qty of the job from its active Get rows
        --  (split moved Get rows to the split pallet; also fixes a stale value)
        UPDATE fl
        SET actual_qty = ISNULL(s.qty, 0),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_job_from_location fl
        OUTER APPLY (
            SELECT SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                            THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                            ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END) AS qty
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = fl.job_main_id
                  AND ph.job_item_id = fl.interface_job_item_id
                  AND ph.location_id = fl.from_location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A'
        ) s
        WHERE fl.job_main_id = @job_main_id
          AND ISNULL(fl.qty, 0) <> 0
          AND fl.is_active = 'Y'
          AND fl.status_flag = 'A'
          AND ISNULL(fl.actual_qty, -1) <> ISNULL(s.qty, 0);

        IF @complete_qty >= @job_qty AND ISNULL(@current_job_status_id, 0) <> 5
        BEGIN
            UPDATE dbo.tr_job_main
            SET job_status_id = 5,
                end_datetime = GETDATE(),
                update_user_id = @user_id,
                update_datetime = GETDATE()
            WHERE id = @job_main_id;

            SET @is_job_complete = 1;

            -- ------------------------------------------------
            -- Shipping job from the Pre-zone (unchanged): only when the
            -- delivery has a shipment
            -- ------------------------------------------------
            DECLARE @pk_has_shipment INT = (
                SELECT SUM(CASE WHEN shipment_no IS NULL THEN 0 ELSE 1 END)
                FROM dbo.vPickingForm
                WHERE id = @job_main_id AND item_id = @job_item_id
            );

            IF @pk_has_shipment IS NULL OR @pk_has_shipment <= 0
                SET @shipping_message = N'ยังไม่ได้สร้างงาน Shipping (ไม่มี Shipment)';
            ELSE
            BEGIN
                DECLARE @pk_header_id INT;

                SELECT @pk_header_id = header_id
                FROM dbo.vPickingForm
                WHERE id = @job_main_id;

                DECLARE @sp_today_seq INT = (
                    SELECT COUNT(*) + 1 FROM dbo.tr_shipping_header
                    WHERE CAST(create_datetime AS DATE) = CAST(GETDATE() AS DATE)
                );

                INSERT INTO dbo.tr_shipping_header (
                    system_no, status_id, from_pre_zone_cc_desc, to_dock_cc_desc
                )
                VALUES (
                    'SP-' + CONVERT(VARCHAR(10), GETDATE(), 112) + RIGHT('000' + CAST(@sp_today_seq AS VARCHAR(3)), 3),
                    1, 'Prepare Zone', 'Dock'
                );

                DECLARE @new_shipping_id INT = SCOPE_IDENTITY();

                INSERT INTO dbo.tr_shipping_detail (delivery_id, header_id)
                SELECT pd.delivery_id, @new_shipping_id
                FROM dbo.tr_picking_detail pd
                WHERE pd.header_id = @pk_header_id
                  AND pd.is_active = 'Y' AND pd.status_flag = 'A'
                  AND NOT EXISTS (
                    SELECT 1 FROM dbo.tr_shipping_detail sd
                    WHERE sd.delivery_id = pd.delivery_id AND sd.is_active = 'Y' AND sd.status_flag = 'A'
                  );

                INSERT INTO dbo.tr_job_main (interface_job_id, job_type_id, job_status_id)
                VALUES (@new_shipping_id, 5, 1);

                DECLARE @shipping_job_main_id INT = SCOPE_IDENTITY();

                IF OBJECT_ID('tempdb..#new_from_locations') IS NOT NULL DROP TABLE #new_from_locations;
                CREATE TABLE #new_from_locations (id INT, item_id INT);

                INSERT INTO dbo.tr_job_from_location (
                    job_main_id, interface_job_item_id, from_location_id, from_location_type,
                    qty, actual_qty, create_user_id, create_datetime, update_user_id, update_datetime
                )
                OUTPUT INSERTED.id, INSERTED.interface_job_item_id INTO #new_from_locations(id, item_id)
                SELECT
                    @shipping_job_main_id, interface_job_item_id, to_location_id, to_location_type,
                    ISNULL(actual_qty, 0), actual_qty,
                    @user_id, GETDATE(), @user_id, GETDATE()
                FROM dbo.tr_job_to_location
                WHERE job_main_id = @job_main_id AND is_active = 'Y' AND status_flag = 'A';

                INSERT INTO dbo.tr_lot_location (
                    job_main_id, job_item_id, job_location_type, job_location_id, lot_no,
                    create_user_id, create_datetime, update_user_id, update_datetime
                )
                SELECT
                    @shipping_job_main_id, nfl.item_id, 'FROM', nfl.id, src.lot_no,
                    @user_id, GETDATE(), @user_id, GETDATE()
                FROM #new_from_locations nfl
                CROSS APPLY (
                    SELECT ll.lot_no
                    FROM dbo.tr_job_from_location fl
                    INNER JOIN dbo.tr_lot_location ll
                        ON ll.job_main_id = @job_main_id
                        AND ll.job_item_id = nfl.item_id
                        AND ll.job_location_type = 'FROM'
                        AND ll.job_location_id = fl.id
                        AND ll.is_active = 'Y'
                        AND ll.status_flag = 'A'
                    WHERE fl.job_main_id = @job_main_id
                        AND fl.interface_job_item_id = nfl.item_id
                        AND fl.is_active = 'Y'
                        AND fl.status_flag = 'A'
                ) src;
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    SELECT 'success' AS status,
           COALESCE(@shipping_message, N'พาเลทนี้ถูกจัดเก็บตามพื้นที่ที่กำหนดแล้ว') AS message,
           @is_job_complete AS is_job_complete, @split_pallet_nos AS split_pallet_no;

    --  iLogistic prepare update (dbResult1, unchanged): only when the job
    --  completed and a Shipping job was created
    IF @is_job_complete = 1 AND @shipping_message IS NULL
        SELECT
            ss.Shipment_id AS shipment_id,
            ss.DO_id AS do_id,
            fp.job_start_datetime,
            fp.job_end_datetime,
            fp.to_location_id,
            fp.to_location_cc_desc,
            fp.code_pallet_id,
            fp.pallet_lot,
            fp.pallet_qty,
            fp.pallet_weight,
            fp.special_type_package_id,
            176 AS user_id
        FROM dbo.fPickingJob(@job_main_id, NULL, NULL) fp
        LEFT JOIN [IRPC].[dbo].[VsearchStatus] ss
            ON ss.Shipment_No = fp.shipment_no COLLATE Thai_CI_AI
            AND ss.Deliver_No = fp.do_no COLLATE Thai_CI_AI;
END
GO

-- ===== dbo.pProcessPickingResetPallet =====
-- ---------------------------------------------------------------------
-- pProcessPickingResetPallet: RESET like pProcessRequestResetPallet
-- (pallet + its 'PK split' pallets + its pallet_seq group). A completed
-- job is still blocked: its Shipping job is already created.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessPickingResetPallet]
    @job_main_id        INT             = NULL,
    @qr_code_text       VARCHAR(100)    = NULL,
    @user_id            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @job_main_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงาน' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลงานในระบบ' AS message;
        RETURN;
    END

    IF @qr_code_text IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูล QR Code' AS message;
        RETURN;
    END

    DECLARE @pallet_id INT, @bag_id INT;

    SELECT @pallet_id = pallet_id, @bag_id = bag_id
    FROM dbo.fQrCodeToPalletBag(@qr_code_text);

    IF @pallet_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM dbo.tr_pallet
           WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
       )
    BEGIN
        SELECT 'error' AS status, N'ไม่พบข้อมูลพาเลทในระบบ' AS message;
        RETURN;
    END

    DECLARE @locked_job_id INT, @job_status_id INT;
    DECLARE @pallets TABLE (pallet_id INT PRIMARY KEY);
    DECLARE @rows TABLE (pallet_id INT, job_item_id INT, process_id INT, location_id INT,
                         location_type VARCHAR(255) COLLATE DATABASE_DEFAULT, bag_cnt INT);
    DECLARE @split TABLE (split_pallet_id INT PRIMARY KEY, source_pallet_id INT,
                          split_remark NVARCHAR(500) COLLATE DATABASE_DEFAULT);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @locked_job_id = id, @job_status_id = job_status_id
        FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @job_main_id;

        --  Completed job already created the Shipping job from its qty: no reset
        IF @job_status_id = 5
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'งานนี้ถูกทำเสร็จแล้ว ไม่สามารถรีเซ็ตพาเลทได้' AS message;
            RETURN;
        END

        -- ------------------------------------------------
        -- Pallets to reset: the scanned pallet
        --   + Picking split pallets made from it in this job
        --     (ref_id = source pallet id, remark 'PK split: job <job> ...')
        --   + every pallet that shares a pallet_seq with them in this job / item
        -- ------------------------------------------------
        INSERT INTO @pallets (pallet_id) VALUES (@pallet_id);

        INSERT INTO @pallets (pallet_id)
        SELECT sp.id
        FROM dbo.tr_pallet sp
        WHERE sp.ref_id = CAST(@pallet_id AS NVARCHAR(100))
          AND sp.remark LIKE CONCAT(N'PK split: job ', @job_main_id, N' %')
          AND sp.id <> @pallet_id
          AND sp.is_active = 'Y'
          AND sp.status_flag = 'A';

        INSERT INTO @pallets (pallet_id)
        SELECT DISTINCT g.pallet_id
        FROM dbo.tr_pallet_history s
        INNER JOIN @pallets x ON x.pallet_id = s.pallet_id
        INNER JOIN dbo.tr_pallet_history g
            ON g.job_main_id = s.job_main_id
            AND g.job_item_id = s.job_item_id
            AND g.pallet_seq = s.pallet_seq
            AND g.is_active = 'Y'
            AND g.status_flag = 'A'
        WHERE s.job_main_id = @job_main_id
          AND s.pallet_seq IS NOT NULL
          AND s.is_active = 'Y'
          AND s.status_flag = 'A'
          AND NOT EXISTS (SELECT 1 FROM @pallets y WHERE y.pallet_id = g.pallet_id);

        --  Active rows of these pallets in this job, before they are deactivated
        INSERT INTO @rows (pallet_id, job_item_id, process_id, location_id, location_type, bag_cnt)
        SELECT ph.pallet_id, ph.job_item_id, ph.process_id, ph.location_id, ph.location_type, COUNT(DISTINCT ph.bag_id)
        FROM dbo.tr_pallet_history ph
        INNER JOIN @pallets g ON g.pallet_id = ph.pallet_id
        WHERE ph.job_main_id = @job_main_id
          AND ph.is_active = 'Y'
          AND ph.status_flag = 'A'
        GROUP BY ph.pallet_id, ph.job_item_id, ph.process_id, ph.location_id, ph.location_type;

        --  The pallet has nothing in this job
        IF NOT EXISTS (SELECT 1 FROM @rows)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'พาเลทนี้ไม่ได้อยู่ในงานนี้' AS message;
            RETURN;
        END

        --  Picking split: bags go back to the source pallet (ref_id),
        --  only while the split pallet is still in this job
        INSERT INTO @split (split_pallet_id, source_pallet_id, split_remark)
        SELECT sp.id, TRY_CONVERT(INT, sp.ref_id), sp.remark
        FROM dbo.tr_pallet sp
        INNER JOIN @pallets g ON g.pallet_id = sp.id
        INNER JOIN dbo.tr_pallet src ON src.id = TRY_CONVERT(INT, sp.ref_id)
        WHERE sp.remark LIKE CONCAT(N'PK split: job ', @job_main_id, N' %')
          AND sp.current_job_id = @job_main_id
          AND sp.is_active = 'Y'
          AND sp.status_flag = 'A';

        UPDATE b
        SET pallet_id = s.source_pallet_id,
            remark = NULLIF(REPLACE(REPLACE(b.remark, CONCAT(' | ', s.split_remark), ''), s.split_remark, ''), ''),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_bag b
        INNER JOIN @split s ON s.split_pallet_id = b.pallet_id;

        --  Deactivate history (whole pallets of the group, pallet or bag QR)
        UPDATE ph
        SET is_active = 'N',
            status_flag = 'D',
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet_history ph
        INNER JOIN @pallets g ON g.pallet_id = ph.pallet_id
        WHERE ph.job_main_id = @job_main_id
          AND ph.is_active = 'Y';

        --  Release the pallets: back to their Get location of this job
        --  (NULL when the pallet has no Get row)
        UPDATE p
        SET current_job_id = NULL,
            current_job_item_id = NULL,
            current_location_id = gl.location_id,
            current_location_type = gl.location_type,
            outbound_to_pre_zone_id = NULL,
            outbound_to_pre_zone_user_id = NULL,
            outbound_to_pre_zone_datetime = NULL,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet p
        INNER JOIN @pallets g ON g.pallet_id = p.id
        OUTER APPLY (
            SELECT TOP (1) r.location_id, r.location_type
            FROM @rows r
            WHERE r.pallet_id = p.id
              AND r.process_id = 1
            ORDER BY r.bag_cnt DESC, r.location_id
        ) gl
        WHERE p.current_job_id = @job_main_id;

        --  Picking split: void the emptied split pallets, count the source pallets again
        --  (as pProcessPalletMgmtMoveBag, CONFIRMED / VOID not changed)
        UPDATE p
        SET current_job_id = NULL,
            current_job_item_id = NULL,
            current_location_id = NULL,
            current_location_type = NULL,
            outbound_to_pre_zone_id = NULL,
            outbound_to_pre_zone_user_id = NULL,
            outbound_to_pre_zone_datetime = NULL,
            pallet_status_id = 4,
            is_active = 'N',
            status_flag = 'D',
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet p
        INNER JOIN @split s ON s.split_pallet_id = p.id;

        UPDATE p
        SET pallet_status_id = CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END,
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_pallet p
        CROSS APPLY (
            SELECT COUNT(*) AS cnt
            FROM dbo.tr_bag b
            WHERE b.pallet_id = p.id
              AND b.is_active = 'Y'
              AND b.status_flag = 'A'
        ) bc
        WHERE p.id IN (SELECT source_pallet_id FROM @split)
          AND ISNULL(p.pallet_status_id, 1) IN (1, 2)
          AND ISNULL(p.pallet_status_id, 1) <> CASE WHEN bc.cnt >= p.unit_pallet THEN 2 ELSE 1 END;

        --  tr_job_to_location.actual_qty (Pre-zone kg) of the to-locations that lost Put rows
        UPDATE tl
        SET actual_qty = ISNULL(s.qty, 0),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_job_to_location tl
        OUTER APPLY (
            SELECT SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                            THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                            ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END) AS qty
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = tl.job_main_id
                  AND ph.job_item_id = tl.interface_job_item_id
                  AND ph.location_id = tl.to_location_id
                  AND ph.process_id = 2
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                  AND ph.bag_id IS NOT NULL
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A'
        ) s
        WHERE tl.job_main_id = @job_main_id
          AND tl.is_active = 'Y'
          AND tl.status_flag = 'A'
          AND EXISTS (
              SELECT 1 FROM @rows r
              WHERE r.process_id = 2
                AND r.job_item_id = tl.interface_job_item_id
                AND r.location_id = tl.to_location_id
          );

        --  tr_job_from_location.actual_qty of the from-locations that lost Get rows
        UPDATE fl
        SET actual_qty = ISNULL(s.qty, 0),
            update_user_id = @user_id,
            update_datetime = GETDATE()
        FROM dbo.tr_job_from_location fl
        OUTER APPLY (
            SELECT SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                            THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                            ELSE x.bag_cnt * ISNULL(p.unit_ratio, 0) END) AS qty
            FROM (
                SELECT ph.pallet_id, COUNT(DISTINCT ph.bag_id) AS bag_cnt
                FROM dbo.tr_pallet_history ph
                WHERE ph.job_main_id = fl.job_main_id
                  AND ph.job_item_id = fl.interface_job_item_id
                  AND ph.location_id = fl.from_location_id
                  AND ph.process_id = 1
                  AND ph.is_active = 'Y'
                  AND ph.status_flag = 'A'
                GROUP BY ph.pallet_id
            ) x
            INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A'
        ) s
        WHERE fl.job_main_id = @job_main_id
          AND ISNULL(fl.qty, 0) <> 0
          AND fl.is_active = 'Y'
          AND fl.status_flag = 'A'
          AND EXISTS (
              SELECT 1 FROM @rows r
              WHERE r.process_id = 1
                AND r.job_item_id = fl.interface_job_item_id
                AND r.location_id = fl.from_location_id
          );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    SELECT 'success' AS status, N'รีเซ็ตพาเลทสำเร็จ' AS message;
END
GO

