-- =============================================================
-- 132_rollback_pProcessGetJobList_job_main_map_set.sql  (IRPC_QTRACK, 10.31.1.75)
-- =============================================================
-- Undoes sql/132: puts the old job_main_map block back (the new block
-- must be found exactly once), then checks that the body (text from
-- "[dbo].[pProcessGetJobList]" to the end) has the SHA-256 it had before
-- sql/132. Only then the proc is altered.
-- Skipped when the definition does not contain "sql/132".
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @key  NVARCHAR(100) = N'[dbo].[pProcessGetJobList]';
DECLARE @base VARCHAR(64)   = 'D678EDCC0A69CA9B7877F677610BF6787FB3279A50FA4A07B07352C5A3DC86EC';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.pProcessGetJobList'));

IF @d IS NULL OR @d NOT LIKE N'%sql/132%'
BEGIN
    PRINT 'pProcessGetJobList has no sql/132 patch - skipped.';
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

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @r, N''))) / DATALENGTH(@r) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: sql/132 block not found exactly once - not rolled back.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @r, @o);

DECLARE @at INT = CHARINDEX(@key, @d);
DECLARE @hash VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', SUBSTRING(@d, @at, DATALENGTH(@d))), 2);
IF @at = 0 OR @hash <> @base
BEGIN
    RAISERROR('pProcessGetJobList: body after rollback has SHA-256 %s, not the pre-132 body - not rolled back.', 16, 1, @hash);
    RETURN;
END

--  Header keyword -> ALTER (see sql/132).
DECLARE @head NVARCHAR(MAX) = LEFT(@d, @at - 1);
DECLARE @kw INT = CASE WHEN CHARINDEX(N'CREATE', @head) > 0
                       THEN DATALENGTH(@head) / 2 - CHARINDEX(REVERSE(N'CREATE'), REVERSE(@head)) - 4
                       ELSE 0 END;
IF @kw > 0 AND SUBSTRING(@head, @kw, 6) = N'CREATE'
    SET @d = STUFF(@d, @kw, 6, N'ALTER');
ELSE IF CHARINDEX(N'ALTER', @head) = 0
BEGIN
    RAISERROR('pProcessGetJobList: CREATE/ALTER keyword not found before the proc name - not rolled back.', 16, 1);
    RETURN;
END

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList: sql/132 rolled back.';
GO
