/* =====================================================================
   pProcessGetInternalTransferJobList -- forklift section
   ---------------------------------------------------------------------
   Base: the version live on IRPC_QTRACK (read back from the DB on
   2026-09-28 -- newer than sql/23, which predates the forklift result
   set), unchanged except for the forklift SELECT below.

   Change: the forklift result (dbResult3) also returns
     section_id    ct_forklift.section_id as stored, e.g. '1,3'
     section_name  same ids as names, e.g. 'Warehouse,Pallet'
                   (1=Warehouse, 2=Loading, 3=Pallet -- same mapping as
                   sql/31 and sql/35)
   so the job-wh-internal-transfer-detail Forklift card can show the
   forklift's section, like job-detail does. JobService's internal
   transfer response builder reads both only when the columns exist.
   ===================================================================== */
USE IRPC_QTRACK;
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetInternalTransferJobList]
    @id             BIGINT        = NULL,
    @system_no      NVARCHAR(50)  = NULL,
    @date_from      VARCHAR(10)   = NULL,
    @date_to        VARCHAR(10)   = NULL,
    @job_status_id  INT           = NULL,
    @page           INT           = 1,
    @page_size      INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start DATETIME = TRY_CONVERT(DATETIME, @date_from);
    DECLARE @end   DATETIME = CASE WHEN TRY_CONVERT(DATETIME, @date_to) IS NULL
                                    THEN NULL
                                    ELSE DATEADD(DAY, 1, TRY_CONVERT(DATETIME, @date_to)) END;

    SELECT
        'success' AS status,
        CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_internal_transfer_header h
            JOIN dbo.tr_job_main jm ON jm.interface_job_id = h.id AND jm.job_type_id = 10 AND jm.status_flag = 'A'
            WHERE h.status_flag = 'A'
              AND (@id IS NULL OR jm.id = @id)
              AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
              AND (@start IS NULL OR h.create_datetime >= @start)
              AND (@end IS NULL OR h.create_datetime < @end)
              AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id)
        ) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    IF OBJECT_ID('tempdb..#job_page') IS NOT NULL DROP TABLE #job_page;

    SELECT jm.id AS id
    INTO #job_page
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.interface_job_id = h.id AND jm.job_type_id = 10 AND jm.status_flag = 'A'
    WHERE h.status_flag = 'A'
      AND (@id IS NULL OR jm.id = @id)
      AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
      AND (@start IS NULL OR h.create_datetime >= @start)
      AND (@end IS NULL OR h.create_datetime < @end)
      AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id)
    ORDER BY h.id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    SELECT
        v.*,
        h.wh_code,
        h.source_remark,
        h.destination_remark,
        jm2.product_cc,
        jm2.product_type,
        dFrom.grade_id AS from_grade_id,
        dFrom.pallet_json AS from_pallet_json,
        dFrom.remark AS from_remark,
        dTo.grade_id AS to_grade_id,
        dTo.pallet_json AS to_pallet_json,
        dTo.remark AS to_remark
    FROM dbo.vInternalTransferJob v
    JOIN dbo.tr_internal_transfer_header h ON h.id = v.header_id
    JOIN dbo.tr_job_main jm2 ON jm2.id = v.id
    INNER JOIN #job_page p ON p.id = v.id
    LEFT JOIN dbo.tr_internal_transfer_detail dFrom ON dFrom.job_location_id = v.job_from_location_id AND dFrom.job_location_type = 'FROM'
    LEFT JOIN dbo.tr_internal_transfer_detail dTo ON dTo.job_location_id = v.job_to_location_id AND dTo.job_location_type = 'TO'
    ORDER BY v.id DESC;

    SELECT
        ja.job_main_id,
        fl.id,
        fl.name,
        fl.wh_code,
        fl.section_id,
        REPLACE(REPLACE(REPLACE(NULLIF(REPLACE(fl.section_id, ' ', ''), ''),
            '1', 'Warehouse'), '2', 'Loading'), '3', 'Pallet') AS section_name,
        ul.id  AS assignee_user_id,
        ul.user_name AS assignee_user_name,
        ul.Thia_name AS assignee_user_thai_name,
        ul.eng_name  AS assignee_user_eng_name,
        (
            SELECT COUNT(DISTINCT ja2.job_main_id)
            FROM dbo.tr_job_assigness ja2
            JOIN dbo.vJobMain vjm
                ON ja2.job_main_id = CASE WHEN vjm.job_type_id IN (4, 7) THEN COALESCE(vjm.ref_id, vjm.id) ELSE vjm.id END
            WHERE ja2.assignee_forklift_id = fl.id
              AND ja2.is_active = 'Y'
              AND ja2.status_flag = 'A'
              AND vjm.job_status_id <> 5
        ) AS job_count
    FROM dbo.tr_job_assigness ja
    JOIN #job_page p ON p.id = ja.job_main_id
    JOIN dbo.ct_forklift fl
        ON fl.id = ja.assignee_forklift_id
        AND fl.is_active = 'Y'
        AND fl.status_flag = 'A'
    LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
        ON ul.id = ja.assignee_user_id
        AND ul.status_flag = 'A'
    WHERE ja.is_active = 'Y'
      AND ja.status_flag = 'A';

    SELECT COUNT(*) AS total_count
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.interface_job_id = h.id AND jm.job_type_id = 10 AND jm.status_flag = 'A'
    WHERE h.status_flag = 'A'
      AND (@id IS NULL OR jm.id = @id)
      AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
      AND (@start IS NULL OR h.create_datetime >= @start)
      AND (@end IS NULL OR h.create_datetime < @end)
      AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id);
END
GO

-- EXEC dbo.pProcessGetInternalTransferJobList @page = 1, @page_size = 5;
