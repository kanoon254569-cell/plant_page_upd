-- =============================================================
-- 86_pProcessGetForkliftJobs_cache_temp.sql  (IRPC_QTRACK)
-- =============================================================
-- After sql/84 the job TVF INSERTs keep their plans, but the statements
-- on #temp tables still recompiled on every call (2026-10-22):
--   #forklift_jobs     plan_generation_num 117, compile 0.7s (every call,
--                      also the "No jobs found" ones)
--   #job_pallet_data   plan_generation_num 163, compile 1.8s, run 155ms
--   #pallet_manual_summary                  compile 0.5s
-- A call with jobs took 0.5-1s, mostly compile.
--
-- Cause: every SELECT ... INTO #x was followed by CREATE INDEX ON #x
-- (8 of them, 1 UNIQUE CLUSTERED) or ALTER TABLE #item_summary ADD.
-- DDL after the create stops SQL Server from caching the temp table, so
-- each call makes a new object and every statement on it recompiles.
--
-- Change (86):
--   1. Drop those 9 index statements and the ALTER TABLE; scan_qty is
--      a column of the SELECT INTO instead (CAST(NULL AS INT), same type
--      and place as the ALTER added it). The temp tables hold one
--      forklift's jobs (tens of rows), so the indexes gave nothing.
--      #SpecialPalletStatus stays unique by its GROUP BY.
--   2. OPTION (KEEPFIXED PLAN) on the statements that read #temp tables,
--      so a cached temp table's row count changing does not recompile
--      them either.
-- Result sets are unchanged (same columns, same rows); compared old vs
-- new on real forklift/date pairs before deploy, see sql/README.md.
--
-- Patched from the live definition with REPLACE (same way as sql/47):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when IX_forklift_jobs is gone. @proc lets the
-- same patch run on a copy for the compare.
--
-- Backup of the definition before this patch (SHA-256 checked):
--   ..\scratch_backup_pProcessGetForkliftJobs_20261022.sql
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessGetForkliftJobs';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @nl   NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);
DECLARE @kf   NVARCHAR(40)  = @nl + N'    OPTION (KEEPFIXED PLAN);';

IF @d NOT LIKE N'%IX[_]forklift[_]jobs%'
BEGIN
    PRINT 'pProcessGetForkliftJobs already patched (no IX_forklift_jobs) - skipped.';
    RETURN;
END

DECLARE @p TABLE (n INT PRIMARY KEY, o NVARCHAR(400), r NVARCHAR(400));
INSERT INTO @p (n, o, r) VALUES
--  header note
( 1, N'-- pProcessGetForkliftJobs : #pallet_summary dedupe fix (group by p.bag_id, MAX not SUM).',
     N'-- pProcessGetForkliftJobs : #pallet_summary dedupe fix (group by p.bag_id, MAX not SUM).' + @nl
   + N'-- sql/86 : no index / ALTER on #temp tables after SELECT INTO, so they are cached and the' + @nl
   + N'--          statements on them stop recompiling every call; KEEPFIXED PLAN on those statements.'),
--  index / ALTER statements after SELECT INTO (each with the blank line after it)
( 2, N'    CREATE NONCLUSTERED INDEX IX_forklift_jobs ON #forklift_jobs(job_main_id);' + @nl + @nl, N''),
( 3, N'    CREATE NONCLUSTERED INDEX idx_recent_jobs_id ON #recent_jobs(id);' + @nl + @nl, N''),
( 4, N'    CREATE NONCLUSTERED INDEX idx_filter_jobs ON #filter_jobs(header_id, job_type_id, item_id, job_status_id);' + @nl + @nl, N''),
( 5, N'    CREATE NONCLUSTERED INDEX idx_item_summary ON #item_summary(header_id, job_type_id, item_id);' + @nl + @nl, N''),
( 6, N'    ALTER TABLE #item_summary ADD scan_qty INT NULL;' + @nl + @nl, N''),
( 7, N'    CREATE NONCLUSTERED INDEX idx_job_summary ON #job_summary(header_id, job_type_id);' + @nl + @nl, N''),
( 8, N'    CREATE NONCLUSTERED INDEX idx_pallet_cal ON #pallet_cal(header_id, job_type_id, item_id, job_from_location_id, job_to_location_id, from_location_lot_no, lot_seq);' + @nl + @nl, N''),
( 9, N'    CREATE UNIQUE CLUSTERED INDEX idx_special_pallet_status' + @nl
   + N'        ON #SpecialPalletStatus(job_main_id, job_item_id, pallet_group_key);' + @nl + @nl, N''),
(10, N'    CREATE NONCLUSTERED INDEX idx_job_pallet_data ON #job_pallet_data(job_main_id, job_item_id, pallet_id);' + @nl + @nl, N''),
(11, N'    CREATE NONCLUSTERED INDEX idx_pallet_summary ON #pallet_summary(job_main_id, pallet_id);' + @nl + @nl, N''),
--  scan_qty as a column of the SELECT INTO
(12, N'        MAX(grade) AS grade' + @nl + N'    INTO #item_summary',
     N'        MAX(grade) AS grade,' + @nl + N'        CAST(NULL AS INT) AS scan_qty' + @nl + N'    INTO #item_summary'),
--  KEEPFIXED PLAN on the statements that read #temp tables
(13, N'        AND (@dateJob IS NULL OR CAST(jm.create_datetime AS DATE) = @dateJob);',
     N'        AND (@dateJob IS NULL OR CAST(jm.create_datetime AS DATE) = @dateJob)' + @kf),
(14, N'        ON f.job_main_id = j.id;', N'        ON f.job_main_id = j.id' + @kf),
(15, N'        AND sps.is_active = ''Y'';', N'        AND sps.is_active = ''Y''' + @kf),
(16, N'    FROM pallet_allocation;', N'    FROM pallet_allocation' + @kf),
(17, N'    ORDER BY dj.id DESC;', N'    ORDER BY dj.id DESC' + @kf),
(18, N'    GROUP BY v.job_main_id, v.job_item_id, COALESCE(v.pallet_seq, v.pallet_id);',
     N'    GROUP BY v.job_main_id, v.job_item_id, COALESCE(v.pallet_seq, v.pallet_id)' + @kf),
(19, N'    ) AS p;', N'    ) AS p' + @kf),
(20, N'    GROUP BY p.job_main_id, p.pallet_id, p.bag_id;', N'    GROUP BY p.job_main_id, p.pallet_id, p.bag_id' + @kf),
(21, N'            AND (ps.is_received = ''Y'' OR ps.is_complete = ''Y'')' + @nl + N'    );',
     N'            AND (ps.is_received = ''Y'' OR ps.is_complete = ''Y'')' + @nl + N'    )' + @kf);

IF EXISTS (SELECT 1 FROM @p
           WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, o, N''))) / DATALENGTH(o) <> 1)
BEGIN
    DECLARE @bad NVARCHAR(200) = (SELECT STRING_AGG(CAST(n AS VARCHAR(5)), ',') FROM @p
                                  WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, o, N''))) / DATALENGTH(o) <> 1);
    RAISERROR('pProcessGetForkliftJobs: piece(s) %s not found exactly once - not patched.', 16, 1, @bad);
    RETURN;
END

DECLARE @i INT = 1, @o NVARCHAR(400), @r NVARCHAR(400);
WHILE @i <= (SELECT MAX(n) FROM @p)
BEGIN
    SELECT @o = o, @r = r FROM @p WHERE n = @i;
    SET @d = REPLACE(@d, @o, @r);
    SET @i += 1;
END
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetForkliftJobs patched (cached #temp tables + KEEPFIXED PLAN).';
GO
