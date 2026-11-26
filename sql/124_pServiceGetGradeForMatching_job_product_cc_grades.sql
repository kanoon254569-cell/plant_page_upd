-- =============================================================
-- 124 : pServiceGetGradeForMatching -- grades of not-yet-Approved jobs
-- =============================================================
-- Follow-up to sql/123 (ct_grade_package_ratio.cost_center). The sync job
-- only picked grades of pending bags and of jobs created TODAY, so an older
-- job's grade (eg. IT-RQ-20261067, 1126NK, created 2026-10-07) never got a
-- cost_center and pProcessGetJobList's Product CC filter still fell back
-- to the raw pd_cc_code for it.
--
-- Adds: grades of jobs created in the last 90 days whose
-- tr_job_main.product_cc is still empty (= the jobs whose Product CC
-- filter needs the grade master cost_center). Same TVFs pProcessGetJobList
-- reads. They go through the usual need_refresh rule (no row / no
-- unit_pallet / older than 1 day), so a grade WMS has no cost center for
-- is retried once a day, not every run.
--
-- Patched in place: inserts the block right before the one unique
-- "INSERT INTO #grade (...)" line of the live definition.
-- Rollback: 124_rollback_pServiceGetGradeForMatching_job_product_cc_grades.sql
-- =============================================================

DECLARE @d      NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pServiceGetGradeForMatching'));
DECLARE @anchor NVARCHAR(400) = N'INSERT INTO #grade (grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh)';
DECLARE @block  NVARCHAR(MAX) =
               N'-- sql/124: grades of jobs (last 90 days) not Approved yet (tr_job_main.product_cc'
+ NCHAR(10) + N'        -- empty) -- their Product CC filter uses ct_grade_package_ratio.cost_center.'
+ NCHAR(10) + N'        -- failure here must not block the other grades'
+ NCHAR(10) + N'        BEGIN TRY'
+ NCHAR(10) + N'            DECLARE @cc_from DATE = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));'
+ NCHAR(10) + N'            DECLARE @cc_to   DATE = CAST(GETDATE() AS DATE);'
+ NCHAR(10) + N''
+ NCHAR(10) + N'            INSERT INTO #src (grade, pending_bags)'
+ NCHAR(10) + N'            SELECT DISTINCT LEFT(REPLACE(x.grade, '' '', ''''), 30) COLLATE DATABASE_DEFAULT, 0'
+ NCHAR(10) + N'            FROM ('
+ NCHAR(10) + N'                SELECT id, grade FROM dbo.fTransferSlipJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fReceiveJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fRequestJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fPickingJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fShippingJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fSpecialJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'                UNION ALL SELECT id, grade FROM dbo.fBrokenBagJob(NULL, @cc_from, @cc_to)'
+ NCHAR(10) + N'            ) x'
+ NCHAR(10) + N'            INNER JOIN dbo.tr_job_main jm'
+ NCHAR(10) + N'                ON jm.id = x.id'
+ NCHAR(10) + N'            WHERE NULLIF(LTRIM(RTRIM(jm.product_cc)), '''') IS NULL'
+ NCHAR(10) + N'              AND NULLIF(LTRIM(RTRIM(x.grade)), '''') IS NOT NULL'
+ NCHAR(10) + N'              AND NOT EXISTS (SELECT 1 FROM #src s'
+ NCHAR(10) + N'                              WHERE s.grade = LEFT(REPLACE(x.grade, '' '', ''''), 30) COLLATE DATABASE_DEFAULT) OPTION (KEEPFIXED PLAN);'
+ NCHAR(10) + N'        END TRY'
+ NCHAR(10) + N'        BEGIN CATCH'
+ NCHAR(10) + N'            SET @message = CONCAT(@message, '' (job product cc grades skipped: '', ERROR_MESSAGE(), '')'');'
+ NCHAR(10) + N'        END CATCH'
+ NCHAR(10) + N''
+ NCHAR(10) + N'        ';

IF CHARINDEX(N'sql/124', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @anchor, N''))) / LEN(@anchor) <> 1
        THROW 50003, 'pServiceGetGradeForMatching: anchor line not found exactly once', 1;

    SET @d = REPLACE(@d, @anchor, @block + @anchor);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
