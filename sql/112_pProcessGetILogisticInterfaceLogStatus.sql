/* =====================================================================
   dbo.pProcessGetILogisticInterfaceLogStatus
   -----------------------------------------------------------------
   Batch lookup (1 call per job-list page) of every iLogistic interface
   log row of the given jobs, newest first per job -- same shape as
   dbo.pProcessGetWmsPlusInterfaceLogStatus, plus ref_no.

   API: GET api/v1/process/job/ilogistic-log?jobMainIds=101,102
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROC [dbo].[pProcessGetILogisticInterfaceLogStatus]
    @job_main_ids NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH ids AS (
        SELECT TRY_CAST(TRIM(value) AS INT) AS job_main_id
        FROM STRING_SPLIT(@job_main_ids, ',')
        WHERE TRY_CAST(TRIM(value) AS INT) IS NOT NULL
    )
    SELECT
        l.job_main_id,
        l.ref_no,
        l.mode,
        l.method,
        l.route,
        l.param,
        l.status_code,
        l.is_success,
        l.message,
        l.create_datetime
    FROM dbo.tr_ilogistic_interface_log l
    WHERE l.job_main_id IN (SELECT job_main_id FROM ids)
      AND l.status_flag = 'A'
    ORDER BY l.job_main_id, l.create_datetime DESC, l.id DESC;
END
GO
