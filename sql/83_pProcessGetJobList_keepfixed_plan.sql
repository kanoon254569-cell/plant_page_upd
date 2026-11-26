-- =============================================================
-- 83_pProcessGetJobList_keepfixed_plan.sql  (IRPC_QTRACK)
-- =============================================================
-- GET api/v1/process/job took 15-25s at times, ~1.5s otherwise.
--
-- Cause: compile time, not run time. Each
--   INSERT INTO @data_jobs SELECT * FROM dbo.fXxxJob(...)
-- inlines a large job TVF and takes 0.5-3.8s to compile (~10-13s in
-- total), while running them all takes ~1s. tr_bag (~1.08M rows) gets
-- a stats update every few minutes from pallet matching, and each
-- update recompiles all of these statements (plan_generation_num was
-- 130+ on 2026-10-22).
--
-- Change (83):
--   1. OPTION (KEEPFIXED PLAN) on every INSERT INTO @data_jobs, so a
--      stats update no longer recompiles them. A schema change still
--      recompiles as usual.
--   2. Skip the TVFs whose topic can't match @topic_name. The topic of
--      every row comes from ct_job_type: TS (1) / RC (2) = 'Inbound',
--      all others (incl. TW 11) = 'Outbound'. @want_inbound /
--      @want_outbound use the same LIKE test as the #filter_jobs WHERE,
--      so the result is unchanged; topicName=Inbound now runs 2 TVFs,
--      not 7.
--
-- Patched from the live definition with REPLACE (same way as sql/47):
-- every piece must be found the expected number of times, else nothing
-- is changed. Idempotent: skipped when KEEPFIXED PLAN is already there.
--
-- Rollback: run the same REPLACEs the other way round (remove
-- ' OPTION (KEEPFIXED PLAN)', the @want_* DECLAREs and the
-- '@want_inbound = 1 AND ' / '@want_outbound = 1 AND ' guards).
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%KEEPFIXED PLAN%'
BEGIN
    PRINT 'pProcessGetJobList already has KEEPFIXED PLAN - skipped.';
    RETURN;
END

--  1. KEEPFIXED PLAN on the 8 TVF INSERTs
DECLARE @o1 NVARCHAR(400) = N'(@id, @date_from, @date_to);';
DECLARE @n1 NVARCHAR(400) = N'(@id, @date_from, @date_to) OPTION (KEEPFIXED PLAN);';

--  2. Topic flags, declared next to the permission flags
DECLARE @o2 NVARCHAR(400) = N'DECLARE @outbound_breakage_replacement NVARCHAR(10) = ''N'';';
DECLARE @n2 NVARCHAR(800) = @o2 + @nl
    + @nl
    + N'    --  Topic of each TVF (ct_job_type): TS/RC = Inbound, rest = Outbound.' + @nl
    + N'    --  Same LIKE as the #filter_jobs WHERE, so skipped TVFs had no rows' + @nl
    + N'    --  that would have passed it (sql/83).' + @nl
    + N'    DECLARE @want_inbound  BIT = CASE WHEN @topic_name IS NULL OR ''Inbound''  LIKE ''%'' + @topic_name + ''%'' THEN 1 ELSE 0 END;' + @nl
    + N'    DECLARE @want_outbound BIT = CASE WHEN @topic_name IS NULL OR ''Outbound'' LIKE ''%'' + @topic_name + ''%'' THEN 1 ELSE 0 END;';

--  3. Topic guards on each TVF's IF
DECLARE @o3 NVARCHAR(400) = N'IF (@inbound_transfer_slip = ''Y'') AND ';
DECLARE @n3 NVARCHAR(400) = @o3 + N'@want_inbound = 1 AND ';
DECLARE @o4 NVARCHAR(400) = N'IF (@inbound_receive = ''Y'') AND (@has_type';
DECLARE @n4 NVARCHAR(400) = N'IF (@inbound_receive = ''Y'') AND @want_inbound = 1 AND (@has_type';
DECLARE @o5 NVARCHAR(400) = N'IF (@inbound_receive = ''Y'') AND (@id IS NOT NULL)';
DECLARE @n5 NVARCHAR(400) = N'IF (@inbound_receive = ''Y'') AND @want_outbound = 1 AND (@id IS NOT NULL)';
DECLARE @o6 NVARCHAR(400) = N'IF (@outbound_request = ''Y'') AND ';
DECLARE @n6 NVARCHAR(400) = @o6 + N'@want_outbound = 1 AND ';
DECLARE @o7 NVARCHAR(400) = N'IF (@outbound_picking = ''Y'') AND ';
DECLARE @n7 NVARCHAR(400) = @o7 + N'@want_outbound = 1 AND ';
DECLARE @o8 NVARCHAR(400) = N'IF (@outbound_shipping = ''Y'') AND ';
DECLARE @n8 NVARCHAR(400) = @o8 + N'@want_outbound = 1 AND ';
DECLARE @o9 NVARCHAR(400) = N'IF (@outbound_special_package = ''Y'') AND ';
DECLARE @n9 NVARCHAR(400) = @o9 + N'@want_outbound = 1 AND ';
DECLARE @o10 NVARCHAR(400) = N'IF (@outbound_breakage_replacement = ''Y'') AND ';
DECLARE @n10 NVARCHAR(400) = @o10 + N'@want_outbound = 1 AND ';

--  DATALENGTH, not LEN: LEN drops the trailing space of @o3/@o6..@o10.
IF   (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 8
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o3, N''))) / DATALENGTH(@o3) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o4, N''))) / DATALENGTH(@o4) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o5, N''))) / DATALENGTH(@o5) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o6, N''))) / DATALENGTH(@o6) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o7, N''))) / DATALENGTH(@o7) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o8, N''))) / DATALENGTH(@o8) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o9, N''))) / DATALENGTH(@o9) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o10, N''))) / DATALENGTH(@o10) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found the expected number of times - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = REPLACE(@d, @o4, @n4);
SET @d = REPLACE(@d, @o5, @n5);
SET @d = REPLACE(@d, @o6, @n6);
SET @d = REPLACE(@d, @o7, @n7);
SET @d = REPLACE(@d, @o8, @n8);
SET @d = REPLACE(@d, @o9, @n9);
SET @d = REPLACE(@d, @o10, @n10);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched (KEEPFIXED PLAN + topic guards).';
GO
