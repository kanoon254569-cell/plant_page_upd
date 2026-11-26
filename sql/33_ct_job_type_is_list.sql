/* =====================================================================
   ct_job_type.is_list + pProcessCBGetJobType
   ---------------------------------------------------------------------
   Job List (job-wh-outbound-list) builds its Job Type tabs from
   GET api/v1/process-cb/job-type (pProcessCBGetJobType), which returns
   every active ct_job_type row. Loading (9) and Internal Transfer (10)
   are topic = 'Outbound', so they got tabs -- but pProcessGetJobList has
   no branch for either type, so those tabs were always empty.

   The rows can't be deactivated or filtered out of the SP itself: the
   Forklift PWA's job-accept page reads the same endpoint, and WH03 still
   uses type 10. Instead a per-type flag says whether it belongs on the
   Job List tabs:
     is_list = 'Y'  -> shown as a Job List tab (default)
     is_list = 'N'  -> hidden from Job List tabs only
   pProcessCBGetJobType just returns the extra column; the web frontend
   filters on it (job-list.ts jobTypeOptions). Other callers ignore it.
   Idempotent -- safe to re-run.
   ===================================================================== */
USE IRPC_QTRACK;
GO

IF COL_LENGTH('dbo.ct_job_type', 'is_list') IS NULL
    ALTER TABLE dbo.ct_job_type
        ADD is_list CHAR(1) NOT NULL
            CONSTRAINT DF_ct_job_type_is_list DEFAULT 'Y';
GO

UPDATE dbo.ct_job_type
SET is_list = 'N'
WHERE id IN (9, 10);   -- Loading, Internal Transfer
GO

CREATE OR ALTER PROC [dbo].[pProcessCBGetJobType]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 'success' AS status,
           'Data retrieved successfully.' AS message;

    SELECT
        js.id,
        js.topic,
        js.name,
        js.is_list
    FROM dbo.ct_job_type js
    WHERE js.is_active = 'Y'
      AND js.status_flag = 'A'
END
GO

-- ตรวจสอบ:
-- EXEC dbo.pProcessCBGetJobType;
