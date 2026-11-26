-- =============================================================
-- 132_pProcessGetJobList_job_main_map_set.sql  (IRPC_QTRACK, 10.31.1.75)
-- =============================================================
-- Problem (2026-11-15, 10.31.1.75):
--   GET api/v1/process/job (job list page) is slow: pProcessGetJobList
--   avg 2.0s, max 24.9s, 415k logical reads per call. One statement is
--   most of it, the forklift queue count (SELECT ... INTO #queue_job
--   FROM job_main_map): avg 1.5s, max 10.2s, CPU 1.1s, 401k reads
--   (max 1.46M) per call.
--
-- Cause:
--   job_main_map checked each assignment of @queue_assignment (~2-5k
--   rows: every active assignment of the forklifts on the page) with
--   "EXISTS (SELECT 1 FROM dbo.vJobMain vjm WHERE vjm.id = jm.id)".
--   @queue_assignment is a table variable, estimated at 1 row, so the
--   plan does that lookup as a nested loop: the job form views inside
--   vJobMain (VTransferSlip, VReceiveForm, vPickingForm, ...) are read
--   again for every job.
--
-- Change (132):
--   job_main_map reads vJobMain once, as a set, for every non-Complete
--   job (~600 rows on 2026-11-15), maps each row to the id the
--   assignments use, and @queue_assignment is joined at the end.
--     id -> COALESCE(ref_id, id)  for Picking(4) / Special(7)
--     id -> id                    for every other type (also NULL type)
--   This is the same set as before. Old branch 1 = vJobMain ids of
--   non-Complete, non-4/7 jobs that are in @queue_assignment
--   (job_status_id and job_type_id of vJobMain come straight from
--   tr_job_main). Old branch 2 = the 4/7 mapping, unchanged. The
--   @queue_assignment filter of branch 1 is applied by the final join.
--
-- Checked on 10.31.1.75 (2026-11-15), read-only, with a real
-- @queue_assignment (4,891 rows, forklifts of today's inbound jobs):
--     old job_main_map   2,956 - 6,712 ms
--     new job_main_map     188 -   690 ms
--   Same rows (forklift_id, job_count): EXCEPT both ways is empty.
--
-- Patched from the live definition with REPLACE (same way as sql/131).
-- The body (text from "[dbo].[pProcessGetJobList]" to the end) must
-- have the SHA-256 checked on 2026-11-15, and the old block must be
-- found exactly once. Otherwise nothing is changed. Idempotent: skipped
-- when the definition already contains "sql/132".
--
-- Rollback: 132_rollback_pProcessGetJobList_job_main_map_set.sql
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @key  NVARCHAR(100) = N'[dbo].[pProcessGetJobList]';
DECLARE @base VARCHAR(64)   = 'D678EDCC0A69CA9B7877F677610BF6787FB3279A50FA4A07B07352C5A3DC86EC';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.pProcessGetJobList'));

IF @d IS NULL
BEGIN
    RAISERROR('dbo.pProcessGetJobList not found - not patched.', 16, 1);
    RETURN;
END

IF @d LIKE N'%sql/132%'
BEGIN
    PRINT 'pProcessGetJobList already patched by sql/132 - skipped.';
    RETURN;
END

DECLARE @at INT = CHARINDEX(@key, @d);
DECLARE @hash VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', SUBSTRING(@d, @at, DATALENGTH(@d))), 2);
IF @at = 0 OR @hash <> @base
BEGIN
    RAISERROR('pProcessGetJobList body changed since 2026-11-15 (SHA-256 %s) - not patched. Review the live definition first.', 16, 1, @hash);
    RETURN;
END

DECLARE @nl NVARCHAR(2) = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

DECLARE @o NVARCHAR(MAX) =
      N'    --  A vJobMain row maps to its own id unless it is a Picking(4)/' + @nl
    + N'    --  Special(7) job (then COALESCE(ref_id, id)), so any other row can' + @nl
    + N'    --  only match an assignment through its own id: look those up by id' + @nl
    + N'    --  instead of running every non-Complete job through the view.' + @nl
    + N'    ;WITH job_main_map AS' + @nl
    + N'    (' + @nl
    + N'        --  tr_job_main filters first; vJobMain (heavy: joins every job' + @nl
    + N'        --  form view) only checks the jobs left, so its rules still apply' + @nl
    + N'        --  (sql/pProcessGetJobList_perf_job_main_map_10.31.1.75.sql).' + @nl
    + N'        SELECT jm.id AS job_main_id' + @nl
    + N'        FROM dbo.tr_job_main jm' + @nl
    + N'        WHERE jm.id IN (SELECT job_main_id FROM @queue_assignment)' + @nl
    + N'            AND jm.job_status_id <> 5' + @nl
    + N'            AND (jm.job_type_id NOT IN (4, 7) OR jm.job_type_id IS NULL)' + @nl
    + N'            AND EXISTS (SELECT 1 FROM dbo.vJobMain vjm WHERE vjm.id = jm.id)' + @nl
    + N'        UNION' + @nl
    + N'        SELECT COALESCE(vjm.ref_id, vjm.id)' + @nl
    + N'        FROM dbo.vJobMain vjm' + @nl
    + N'        WHERE vjm.job_status_id <> 5' + @nl
    + N'            AND vjm.job_type_id IN (4, 7)' + @nl
    + N'    )' + @nl;

DECLARE @r NVARCHAR(MAX) =
      N'    --  sql/132: every non-Complete job goes through vJobMain once, as a' + @nl
    + N'    --  set, and @queue_assignment is joined at the end. A row maps to its' + @nl
    + N'    --  own id unless it is a Picking(4)/Special(7) job (then' + @nl
    + N'    --  COALESCE(ref_id, id)). The old per-id "EXISTS vJobMain WHERE id ="' + @nl
    + N'    --  check ran as a nested loop (@queue_assignment is estimated at 1' + @nl
    + N'    --  row) and read the job form views once per job: 1.5s avg, 10s max' + @nl
    + N'    --  per call on 10.31.1.75 (2026-11-15). Same rows as before.' + @nl
    + N'    ;WITH job_main_map AS' + @nl
    + N'    (' + @nl
    + N'        SELECT CASE WHEN vjm.job_type_id IN (4, 7) THEN COALESCE(vjm.ref_id, vjm.id) ELSE vjm.id END AS job_main_id' + @nl
    + N'        FROM dbo.vJobMain vjm' + @nl
    + N'        WHERE vjm.job_status_id <> 5' + @nl
    + N'        GROUP BY CASE WHEN vjm.job_type_id IN (4, 7) THEN COALESCE(vjm.ref_id, vjm.id) ELSE vjm.id END' + @nl
    + N'    )' + @nl;

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o, N''))) / DATALENGTH(@o) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: job_main_map block not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o, @r);

--  Header keyword -> ALTER: the last CREATE before the proc name (the live
--  text has "CREATE   PROC"). If the header already says ALTER, it is left
--  as it is.
SET @at = CHARINDEX(@key, @d);
DECLARE @head NVARCHAR(MAX) = LEFT(@d, @at - 1);
DECLARE @kw INT = CASE WHEN CHARINDEX(N'CREATE', @head) > 0
                       THEN DATALENGTH(@head) / 2 - CHARINDEX(REVERSE(N'CREATE'), REVERSE(@head)) - 4
                       ELSE 0 END;
IF @kw > 0 AND SUBSTRING(@head, @kw, 6) = N'CREATE'
    SET @d = STUFF(@d, @kw, 6, N'ALTER');
ELSE IF CHARINDEX(N'ALTER', @head) = 0
BEGIN
    RAISERROR('pProcessGetJobList: CREATE/ALTER keyword not found before the proc name - not patched.', 16, 1);
    RETURN;
END

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched by sql/132 (job_main_map reads vJobMain once as a set).';
GO
