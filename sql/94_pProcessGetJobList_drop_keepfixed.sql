-- =============================================================
-- 94_pProcessGetJobList_drop_keepfixed.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessGetJobList: drop OPTION (KEEPFIXED PLAN) from the 8
-- "INSERT INTO @data_jobs SELECT * FROM dbo.fXxxJob(...)" statements.
--
-- Cause (plan cache on .75, 2026-10-25):
--   The fReceiveJob INSERT ran 130-317 ms / 3.0k-5.5k reads per call
--   (avg 172 ms over 54 calls) with the plan compiled at 22:30. The same
--   statement compiled fresh - same parameters (today, @id NULL),
--   INSERT into a table variable, KEEPFIXED PLAN - runs 7-8 ms /
--   ~2.2k reads. Stats of tr_job_main / tr_job_from_location /
--   tr_job_to_location / tr_lot_location were updated at 22:42, after
--   that compile; KEEPFIXED PLAN blocks the stats-driven recompile, so
--   the stale plan stays until something else throws it out (an ALTER
--   of the TVF, sp_recompile, a restart).
--   The vJobMain statements had the same stale-plan cost (~360 ms
--   each) until they were recompiled at 22:53-22:56 (now 3 / 10 ms).
--
-- Why KEEPFIXED PLAN is no longer needed here: it was added when the
-- union went into a SELECT INTO #temp, which recompiled on every call
-- (~5.8 s compile for the 8 inlined TVFs). The union now goes into the
-- @data_jobs table variable (one INSERT per job type), which does not
-- recompile per call. Without the hint a statement recompiles only when
-- the stats of its tables change.
--
-- Trade-off: after a stats update the first call pays the compile of
-- that one statement (measured 250-470 ms for fReceiveJob with
-- OPTION (RECOMPILE)), instead of every call paying a stale plan until
-- someone recompiles by hand.
--
-- After deploying, check that the INSERTs do NOT recompile on every
-- call: in sys.dm_exec_query_stats for this proc, creation_time of the
-- "INSERT INTO @data_jobs" rows must stay put while execution_count
-- grows (query at the bottom). If they recompile per call, roll back.
--
-- Only change: " OPTION (KEEPFIXED PLAN);" -> ";" on those 8 lines.
-- Nothing else in the proc, its parameters or its result sets changes.
-- SHA-256 of OBJECT_DEFINITION before this patch (NVARCHAR) =
--   88E2528B63D5330EA6338C3C7D29DECF002B62D11F86854C59C8BC021926589A
--
-- Patched from the live definition with REPLACE (same way as sql/93):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the hint is already gone.
-- Rollback: sql/94_rollback_pProcessGetJobList.sql (puts the hint back
-- the same way).
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessGetJobList';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @hint NVARCHAR(50)  = N' OPTION (KEEPFIXED PLAN);';

IF @d NOT LIKE N'%KEEPFIXED PLAN%'
BEGIN
    PRINT 'pProcessGetJobList has no KEEPFIXED PLAN (94_) - skipped.';
    RETURN;
END

DECLARE @tvf TABLE (fn NVARCHAR(100) NOT NULL);
INSERT INTO @tvf (fn) VALUES
    (N'dbo.fTransferSlipJob(@id, @date_from, @date_to)'),
    (N'dbo.fReceiveJob(@id, @date_from, @date_to)'),
    (N'dbo.fTransferWhJob(@id, @date_from, @date_to)'),
    (N'dbo.fRequestJob(@id, @date_from, @date_to)'),
    (N'dbo.fPickingJob(@id, @date_from, @date_to)'),
    (N'dbo.fShippingJob(@id, @date_from, @date_to)'),
    (N'dbo.fSpecialJob(@id, @date_from, @date_to)'),
    (N'dbo.fBrokenBagJob(@id, @date_from, @date_to)');

-- every "<tvf> OPTION (KEEPFIXED PLAN);" exactly once, and no other KEEPFIXED
IF EXISTS (
    SELECT 1 FROM @tvf
    WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, fn + @hint, N''))) / DATALENGTH(fn + @hint) <> 1
)
OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, N'KEEPFIXED', N''))) / DATALENGTH(N'KEEPFIXED') <> 8
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

DECLARE @fn NVARCHAR(100) = (SELECT MIN(fn) FROM @tvf);
WHILE @fn IS NOT NULL
BEGIN
    SET @d  = REPLACE(@d, @fn + @hint, @fn + N';');
    SET @fn = (SELECT MIN(fn) FROM @tvf WHERE fn > @fn);
END

SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched (94_: KEEPFIXED PLAN removed from 8 TVF INSERTs).';
GO

-- =============================================================
-- Check after deploy (read only): run a few times over the next hours.
-- creation_time should stay the same while ex grows; avg_ms of the
-- fReceiveJob row should be in the single-digit / low-tens ms.
-- =============================================================
/*
SELECT qs.execution_count AS ex,
       qs.total_elapsed_time / qs.execution_count / 1000 AS avg_ms,
       qs.last_elapsed_time / 1000 AS last_ms,
       qs.last_logical_reads,
       qs.plan_generation_num AS gen,
       qs.creation_time,
       LEFT(SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 120), 70) AS stmt
FROM sys.dm_exec_procedure_stats ps
JOIN sys.dm_exec_query_stats qs ON qs.plan_handle = ps.plan_handle
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE ps.database_id = DB_ID()
  AND ps.object_id = OBJECT_ID('dbo.pProcessGetJobList')
  AND SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 120) LIKE '%INSERT INTO @data_jobs%'
ORDER BY qs.total_elapsed_time DESC;
*/
