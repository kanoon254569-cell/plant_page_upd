/* =====================================================================
   pProcessGetInternalTransferJobList
   -----------------------------------------------------------------
   Backs GET api/v1/process/job/internal-transfer (JobController.cs
   GetInternalTransferJobList), which job-wh-internal-transfer-list.ts
   calls to populate its own job list -- the page never called a real
   endpoint before this (search() was a no-op stub).

   Not part of the unified WH01 Job List (pProcessGetJobList's 6-way view
   UNION) -- same reasoning Special Job already follows: it has its own
   dedicated list SP (pProcessGetSpecialJobList) rather than being wired
   into that view, since WH02 Internal Transfer isn't one of the 6 job
   types that view unions today.

   One row per job (dbo.tr_internal_transfer_header joined to
   dbo.tr_job_main for job_status_id) -- source/destination
   dbo.tr_internal_transfer_detail rows are aggregated into a single
   display string + count per side via STRING_AGG, so the list doesn't
   need a second round-trip per job to show a route summary.

   status mapping (job_status_id -> 'draft'/'planned'/'completed', matching
   the page's existing status filter options) is PROVISIONAL: every job
   created by pProcessCreateInternalTransferJob currently starts and stays
   at job_status_id = 1 (ct_job_status: 'Pending') forever, since no
   approve/execute workflow exists yet for WH02. 1 -> 'draft' and
   5 -> 'completed' follow the same job_status_id=5-means-complete
   convention pProcessGetJobList.optimized.sql already hardcodes elsewhere
   in this project; everything else falls into 'planned' as a placeholder
   until a real WH02 workflow defines what those in-between states mean.
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetInternalTransferJobList]
    @system_no      NVARCHAR(50)  = NULL,
    @date_from      VARCHAR(10)   = NULL,   -- 'yyyy-MM-dd'
    @date_to        VARCHAR(10)   = NULL,   -- 'yyyy-MM-dd'
    @job_status_id  INT           = NULL,
    @wh_from        VARCHAR(10)   = NULL,   -- source location_type (tr_internal_transfer_detail.direction='SOURCE')
    @wh_to          VARCHAR(10)   = NULL,   -- destination location_type (direction='DESTINATION')
    @page           INT           = 1,
    @page_size      INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Half-open date range [@start, @end) -- sargable, avoids wrapping
    -- create_datetime in a function (same fix already applied to
    -- 01_sp_PalletAdjustment_GetOverview.sql's @PrintDate filter).
    DECLARE @start DATETIME = TRY_CONVERT(DATETIME, @date_from);
    DECLARE @end   DATETIME = CASE WHEN TRY_CONVERT(DATETIME, @date_to) IS NULL
                                    THEN NULL
                                    ELSE DATEADD(DAY, 1, TRY_CONVERT(DATETIME, @date_to)) END;

    -- =============================================================
    -- Return status and message based on data retrieval result.
    -- status stays 'success' even with zero matching jobs (only "message"
    -- differs) -- an empty filter result is not an error condition, same
    -- convention as pProcessGetPalletList/pProcessGetPalletListByLocation.
    -- =============================================================

    SELECT
        'success' AS status,
        CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_internal_transfer_header h
            JOIN dbo.tr_job_main jm ON jm.id = h.job_main_id AND jm.status_flag = 'A'
            WHERE h.status_flag = 'A'
              AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
              AND (@start IS NULL OR h.create_datetime >= @start)
              AND (@end IS NULL OR h.create_datetime < @end)
              AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id)
              AND (@wh_from IS NULL OR EXISTS (
                  SELECT 1 FROM dbo.tr_internal_transfer_detail d
                  WHERE d.header_id = h.id AND d.direction = 'SOURCE' AND d.status_flag = 'A'
                    AND d.location_type = @wh_from
              ))
              AND (@wh_to IS NULL OR EXISTS (
                  SELECT 1 FROM dbo.tr_internal_transfer_detail d
                  WHERE d.header_id = h.id AND d.direction = 'DESTINATION' AND d.status_flag = 'A'
                    AND d.location_type = @wh_to
              ))
        ) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    -- =============================================================
    -- Paginated job list, one row per job, newest first.
    -- =============================================================

    ;WITH src AS (
        SELECT
            header_id,
            STRING_AGG(
                CONCAT(ISNULL(location_name, CAST(location_id AS VARCHAR(20))),
                       ' (', ISNULL(grade, ''), '/', ISNULL(lot_no, ''), ' ', CAST(qty AS VARCHAR(20)), ')'),
                ', '
            ) AS summary,
            COUNT(*) AS cnt
        FROM dbo.tr_internal_transfer_detail
        WHERE direction = 'SOURCE' AND status_flag = 'A'
        GROUP BY header_id
    ),
    dest AS (
        SELECT
            header_id,
            STRING_AGG(
                CONCAT(ISNULL(location_name, CAST(location_id AS VARCHAR(20))),
                       ' (', ISNULL(grade, ''), '/', ISNULL(lot_no, ''), ' ', CAST(qty AS VARCHAR(20)), ')'),
                ', '
            ) AS summary,
            COUNT(*) AS cnt
        FROM dbo.tr_internal_transfer_detail
        WHERE direction = 'DESTINATION' AND status_flag = 'A'
        GROUP BY header_id
    )
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
        h.total_qty,
        h.qty_unit,
        ISNULL(src.summary, '')  AS source_summary,
        ISNULL(src.cnt, 0)       AS source_count,
        ISNULL(dest.summary, '') AS destination_summary,
        ISNULL(dest.cnt, 0)      AS destination_count,
        h.create_datetime,
        h.create_user_id
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.id = h.job_main_id AND jm.status_flag = 'A'
    LEFT JOIN src  ON src.header_id = h.id
    LEFT JOIN dest ON dest.header_id = h.id
    WHERE h.status_flag = 'A'
      AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
      AND (@start IS NULL OR h.create_datetime >= @start)
      AND (@end IS NULL OR h.create_datetime < @end)
      AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id)
      AND (@wh_from IS NULL OR EXISTS (
          SELECT 1 FROM dbo.tr_internal_transfer_detail d
          WHERE d.header_id = h.id AND d.direction = 'SOURCE' AND d.status_flag = 'A'
            AND d.location_type = @wh_from
      ))
      AND (@wh_to IS NULL OR EXISTS (
          SELECT 1 FROM dbo.tr_internal_transfer_detail d
          WHERE d.header_id = h.id AND d.direction = 'DESTINATION' AND d.status_flag = 'A'
            AND d.location_type = @wh_to
      ))
    ORDER BY h.id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    -- =============================================================
    -- total_count must match the grain of the list above (1 row per job).
    -- =============================================================

    SELECT COUNT(*) AS total_count
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.id = h.job_main_id AND jm.status_flag = 'A'
    WHERE h.status_flag = 'A'
      AND (@system_no IS NULL OR h.system_no LIKE @system_no + '%')
      AND (@start IS NULL OR h.create_datetime >= @start)
      AND (@end IS NULL OR h.create_datetime < @end)
      AND (@job_status_id IS NULL OR jm.job_status_id = @job_status_id)
      AND (@wh_from IS NULL OR EXISTS (
          SELECT 1 FROM dbo.tr_internal_transfer_detail d
          WHERE d.header_id = h.id AND d.direction = 'SOURCE' AND d.status_flag = 'A'
            AND d.location_type = @wh_from
      ))
      AND (@wh_to IS NULL OR EXISTS (
          SELECT 1 FROM dbo.tr_internal_transfer_detail d
          WHERE d.header_id = h.id AND d.direction = 'DESTINATION' AND d.status_flag = 'A'
            AND d.location_type = @wh_to
      ));
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessGetInternalTransferJobList @system_no = N'IT', @page = 1, @page_size = 25;
-- EXEC dbo.pProcessGetInternalTransferJobList @wh_from = 'MWH', @wh_to = 'MWH', @page = 1, @page_size = 25;
