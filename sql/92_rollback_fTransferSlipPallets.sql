-- =============================================================
-- 92_rollback_fTransferSlipPallets.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 92_fTransferSlipPallets_fast.sql : the definition of
-- dbo.fTransferSlipPallets on IRPC_QTRACK before 92 (2026-10-25),
-- SHA-256 of OBJECT_DEFINITION (NVARCHAR) =
--   D57D515A21BD121635217CDE0CD9DB018B7B24C4F684867BF17E7B9CBE9D8E29
-- Only change from that text: CREATE -> ALTER.
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
ALTER FUNCTION [dbo].[fTransferSlipPallets] (@job_main_id INT)
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
            ts2.item_id,
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
        INNER JOIN IRPC_E_TRANSFER.dbo.VTransferSlip AS ts2
            ON ts2.header_id = jm2.interface_job_id AND jm2.job_type_id = 1
        LEFT JOIN dbo.tr_job_from_location fl2
            ON fl2.job_main_id = jm2.id AND fl2.interface_job_item_id = ts2.item_id
            AND (fl2.is_active IS NULL OR fl2.is_active = 'Y') AND (fl2.status_flag IS NULL OR fl2.status_flag = 'A')
        LEFT JOIN dbo.tr_job_to_location tl2
            ON tl2.job_main_id = jm2.id AND tl2.interface_job_item_id = ts2.item_id
            AND (tl2.is_active IS NULL OR tl2.is_active = 'Y') AND (tl2.status_flag IS NULL OR tl2.status_flag = 'A')
        LEFT JOIN dbo.ct_job_type jt2 ON jt2.id = jm2.job_type_id
        WHERE jm2.id = ph.job_main_id
          AND ts2.item_id = ph.job_item_id
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
)
GO
