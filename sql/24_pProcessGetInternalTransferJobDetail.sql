/* =====================================================================
   pProcessGetInternalTransferJobDetail
   -----------------------------------------------------------------
   Backs GET api/v1/process/job/internal-transfer/{jobId} (JobController.cs
   GetInternalTransferJobDetail) -- loads ONE job's header plus every
   selected location on both sides, so job-wh-internal-transfer-list.ts's
   Edit action can pre-fill the exact same create-form/pickers used to
   create it (openEditModal / buildLocationFormGroup).

   Returns 4 result sets: dbResult (status/message), dbResult1 (1 header
   row, 0 rows if not found/inactive), dbResult2 (every active detail row,
   both directions together -- distinguished by the `direction` column;
   the controller splits it into sourceLocations/destinationLocations),
   dbResult3 (every actively-assigned forklift, same dbo.tr_job_assigness /
   dbo.ct_forklift join pProcessGetJobList.optimized.sql's own #forklift
   build uses, minus that query's page-wide job_count aggregation -- this is
   a single job, so job_count here is a per-forklift correlated subquery
   instead of a GROUP BY over many jobs at once).
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetInternalTransferJobDetail]
    @job_main_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        'success' AS status,
        CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_internal_transfer_header h
            WHERE h.job_main_id = @job_main_id AND h.status_flag = 'A'
        ) THEN 'Data retrieved successfully.' ELSE 'Internal transfer job not found.' END AS message;

    SELECT
        jm.id AS job_main_id,
        h.id  AS header_id,
        h.system_no,
        jm.job_status_id,
        CASE jm.job_status_id
            WHEN 1 THEN 'draft'
            WHEN 5 THEN 'completed'
            ELSE 'planned'
        END AS status,
        h.wh_code,
        h.source_remark,
        h.destination_remark,
        h.qty_unit,
        h.total_qty,
        jm.is_urgent,
        jm.is_multi_forklift
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.id = h.job_main_id AND jm.status_flag = 'A'
    WHERE h.job_main_id = @job_main_id AND h.status_flag = 'A';

    SELECT
        d.direction,
        d.location_id,
        d.location_type,
        d.location_name,
        d.grade,
        d.grade_id,
        d.lot_no,
        d.qty,
        d.remark,
        d.pallet_json
    FROM dbo.tr_internal_transfer_detail d
    JOIN dbo.tr_internal_transfer_header h ON h.id = d.header_id
    WHERE h.job_main_id = @job_main_id AND h.status_flag = 'A' AND d.status_flag = 'A'
    ORDER BY d.direction, d.id;

    SELECT
        fl.id,
        fl.name,
        fl.wh_code,
        ul.id  AS current_user_id,
        ul.user_name AS current_user_name,
        ul.Thia_name AS current_user_thai_name,
        ul.eng_name  AS current_user_eng_name,
        (
            SELECT COUNT(DISTINCT ja2.job_main_id)
            FROM dbo.tr_job_assigness ja2
            WHERE ja2.assignee_forklift_id = fl.id
              AND ja2.is_active = 'Y'
              AND ja2.status_flag = 'A'
        ) AS job_count
    FROM dbo.tr_job_assigness ja
    JOIN dbo.ct_forklift fl
        ON fl.id = ja.assignee_forklift_id
        AND fl.is_active = 'Y'
        AND fl.status_flag = 'A'
    LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
        ON ul.id = fl.current_user_id
        AND ul.status_flag = 'A'
    WHERE ja.job_main_id = @job_main_id
      AND ja.is_active = 'Y'
      AND ja.status_flag = 'A';
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessGetInternalTransferJobDetail @job_main_id = 123;
