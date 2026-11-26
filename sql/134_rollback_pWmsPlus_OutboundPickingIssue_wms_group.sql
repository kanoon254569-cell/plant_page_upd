-- =============================================================
-- Backup of dbo.pWmsPlus_OutboundPickingIssue on 10.31.1.75
-- (taken 2026-11-18, before sql/134). Not present on 10.31.1.74.
-- Run this script to roll back sql/134.
-- =============================================================
USE IRPC_QTRACK;
GO
CREATE OR ALTER PROCEDURE [dbo].[pWmsPlus_OutboundPickingIssue] (@job_main_id INT)
AS
BEGIN
    SET NOCOUNT ON;

    IF @job_main_id IS NULL
    BEGIN
        SELECT 'error' AS status, 'Invalid @job_main_id.' AS message;
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND job_type_id = 4
          AND is_active = 'Y' AND status_flag = 'A'
    )
    BEGIN
        SELECT 'error' AS status, 'Picking job not found.' AS message;
        RETURN;
    END

    DECLARE @delivery_no VARCHAR(50), @shipment_no VARCHAR(50), @grade VARCHAR(50),
            @form_loading_date DATETIME, @prod_cc VARCHAR(50);

    SELECT TOP 1
        @delivery_no = f.do_no,
        @shipment_no = f.shipment_no,
        @grade = f.grade,
        @form_loading_date = TRY_CONVERT(DATETIME, f.loading_date),
        @prod_cc = COALESCE(NULLIF(LTRIM(RTRIM(jm.product_cc)), ''), f.cc_code)
    FROM dbo.tr_job_main jm
    INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
    WHERE jm.id = @job_main_id;

    DECLARE @loading_date DATETIME = (
        SELECT TOP 1 ss.Loading_Datetime
        FROM [IRPC].[dbo].[VsearchStatus] ss
        WHERE ss.Deliver_No = @delivery_no COLLATE Thai_CI_AI
          AND (@shipment_no IS NULL OR ss.Shipment_No = @shipment_no COLLATE Thai_CI_AI)
          AND ss.Loading_Datetime IS NOT NULL
    );
    SET @loading_date = COALESCE(@loading_date, @form_loading_date, CAST(CAST(GETDATE() AS DATE) AS DATETIME));

    ;WITH from_loc AS (
        SELECT fl.id, fl.job_main_id, fl.interface_job_item_id, fl.from_location_id, fl.from_location_type,
               ISNULL(fl.actual_qty, fl.qty) AS location_qty,
               (SELECT MAX(ll.lot_no) FROM dbo.tr_lot_location ll
                WHERE ll.job_main_id = fl.job_main_id AND ll.job_item_id = fl.interface_job_item_id
                  AND ll.job_location_type = 'FROM' AND ll.job_location_id = fl.id
                  AND ll.is_active = 'Y' AND ll.status_flag = 'A') AS location_lot
        FROM dbo.tr_job_from_location fl
        WHERE fl.job_main_id = @job_main_id
          AND fl.from_location_type IN ('MWH', 'A41', 'A43')
          AND fl.is_active = 'Y' AND fl.status_flag = 'A'
    ),
    pallet_get AS (
        --  One row per pallet taken from a location: its lot and bag count.
        SELECT fl.from_location_id, fl.from_location_type, ph.pallet_id,
               COALESCE(MAX(b.lot), MAX(fl.location_lot)) AS lot,
               COUNT(DISTINCT ph.bag_id) AS bag_cnt
        FROM from_loc fl
        INNER JOIN dbo.tr_pallet_history ph
            ON ph.job_main_id = fl.job_main_id
           AND ph.job_item_id = fl.interface_job_item_id
           AND ph.location_id = fl.from_location_id
           AND ph.process_id = 1
           AND ph.is_active = 'Y' AND ph.status_flag = 'A'
        LEFT JOIN dbo.tr_bag b ON b.id = TRY_CONVERT(BIGINT, ph.bag_id)
        GROUP BY fl.from_location_id, fl.from_location_type, ph.pallet_id
    ),
    lot_qty AS (
        SELECT g.from_location_id, g.from_location_type, g.lot,
               SUM(CASE WHEN p.pallet_type IN ('M', 'S')
                        THEN ISNULL(p.unit_ratio, 0) * ISNULL(p.unit_pallet, 0)
                        ELSE g.bag_cnt * ISNULL(p.unit_ratio, 0) END) AS qty
        FROM pallet_get g
        INNER JOIN dbo.tr_pallet p ON p.id = g.pallet_id
        GROUP BY g.from_location_id, g.from_location_type, g.lot
        UNION ALL
        --  Location with no Get rows: its own qty + lot.
        SELECT fl.from_location_id, fl.from_location_type, fl.location_lot, fl.location_qty
        FROM from_loc fl
        WHERE NOT EXISTS (
            SELECT 1 FROM pallet_get g
            WHERE g.from_location_id = fl.from_location_id AND g.from_location_type = fl.from_location_type
        )
    )
    SELECT
        CONVERT(VARCHAR(19), @loading_date, 126) AS loadingDate,
        @delivery_no AS deliveryNo,
        @prod_cc AS prodCc,
        @grade AS gradeCode,
        ISNULL(q.lot, '') AS lotNo,
        q.from_location_id AS wms_location_id,
        q.from_location_type AS wms_location_type,
        CAST(ROUND(q.qty, 0) AS INT) AS qty
    FROM lot_qty q
    WHERE ISNULL(q.qty, 0) > 0
    ORDER BY q.from_location_id, q.lot;
END
GO
