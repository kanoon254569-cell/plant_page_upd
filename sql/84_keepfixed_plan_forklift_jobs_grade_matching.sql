-- =============================================================
-- 84_keepfixed_plan_forklift_jobs_grade_matching.sql  (IRPC_QTRACK)
-- =============================================================
-- Same problem and fix as sql/83 (pProcessGetJobList), for two more
-- procs that inline the large job TVFs:
--
--   pProcessGetForkliftJobs      9 x INSERT INTO @recent_jobs SELECT *
--                                FROM dbo.fXxxJob(...). Compile 0.3-3.2s
--                                each (~11s in total), run < 100ms;
--                                plan_generation_num 11,000+ on
--                                2026-10-22, max call 10s.
--   pServiceGetGradeForMatching  INSERT INTO #src (job grades) -- one
--                                UNION ALL over 8 job TVFs. Compile
--                                2.3s, run ~40ms; plan_generation_num
--                                260, max call 30s.
--
-- tr_bag gets a stats update every few minutes from pallet matching, and
-- each update recompiles these statements. OPTION (KEEPFIXED PLAN) stops
-- recompiles on stats changes; a schema change still recompiles.
-- Only the TVF statements are patched. The #temp-table statements in
-- pProcessGetForkliftJobs are left as they are, so their plans still
-- follow the row counts of each call.
--
-- Patched from the live definition with REPLACE (same way as sql/47 and
-- sql/83): every piece must be found the expected number of times, else
-- that proc is not changed. Idempotent: a proc that already has
-- KEEPFIXED PLAN is skipped. Line breaks follow the live text.
--
-- Rollback: REPLACE ' OPTION (KEEPFIXED PLAN)' with '' in each proc.
-- =============================================================
USE IRPC_QTRACK;
GO

-- -------------------------------------------------------------
-- pProcessGetForkliftJobs
-- -------------------------------------------------------------
DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetForkliftJobs'));

IF @d LIKE N'%KEEPFIXED PLAN%'
BEGIN
    PRINT 'pProcessGetForkliftJobs already has KEEPFIXED PLAN - skipped.';
    RETURN;
END

--  8 TVFs take (id, date, date_to); fInternalTransferJob takes (id, date).
DECLARE @o1 NVARCHAR(400) = N'(NULL, @dateJob, NULL);';
DECLARE @n1 NVARCHAR(400) = N'(NULL, @dateJob, NULL) OPTION (KEEPFIXED PLAN);';
DECLARE @o2 NVARCHAR(400) = N'fInternalTransferJob(NULL, @dateJob);';
DECLARE @n2 NVARCHAR(400) = N'fInternalTransferJob(NULL, @dateJob) OPTION (KEEPFIXED PLAN);';

IF   (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 8
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
BEGIN
    RAISERROR('pProcessGetForkliftJobs: text to patch not found the expected number of times - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetForkliftJobs patched (KEEPFIXED PLAN).';
GO

-- -------------------------------------------------------------
-- pServiceGetGradeForMatching
-- -------------------------------------------------------------
DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pServiceGetGradeForMatching'));

IF @d LIKE N'%KEEPFIXED PLAN%'
BEGIN
    PRINT 'pServiceGetGradeForMatching already has KEEPFIXED PLAN - skipped.';
    RETURN;
END

--  End of the "grades of open inbound jobs" INSERT INTO #src.
DECLARE @o1 NVARCHAR(400) = N'WHERE s.grade = LEFT(REPLACE(x.grade, '' '', ''''), 30) COLLATE DATABASE_DEFAULT);';
DECLARE @n1 NVARCHAR(400) = N'WHERE s.grade = LEFT(REPLACE(x.grade, '' '', ''''), 30) COLLATE DATABASE_DEFAULT)'
    + N' OPTION (KEEPFIXED PLAN);';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pServiceGetGradeForMatching: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pServiceGetGradeForMatching patched (KEEPFIXED PLAN).';
GO
