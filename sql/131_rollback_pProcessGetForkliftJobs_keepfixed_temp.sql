-- =============================================================
-- 131_rollback_pProcessGetForkliftJobs_keepfixed_temp.sql  (IRPC_QTRACK, 10.31.1.75)
-- =============================================================
-- Undoes sql/131: runs the same REPLACE pieces in the other direction
-- (each patched piece must be found exactly once), then checks that the
-- body (text from "[dbo].[pProcessGetForkliftJobs]" to the end) has the
-- SHA-256 it had before sql/131. Only then the proc is altered.
-- Skipped when the definition does not contain "sql/131".
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @key  NVARCHAR(100) = N'[dbo].[pProcessGetForkliftJobs]';
DECLARE @base VARCHAR(64)   = 'C90362812B6F52D38D19C34898BF8A7C5379B869CCBB0042AD09BDB9C29AE60E';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.pProcessGetForkliftJobs'));

IF @d IS NULL OR @d NOT LIKE N'%sql/131%'
BEGIN
    PRINT 'pProcessGetForkliftJobs has no sql/131 patch - skipped.';
    RETURN;
END

DECLARE @nl NVARCHAR(2) = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);
DECLARE @kf NVARCHAR(40) = @nl + N'    OPTION (KEEPFIXED PLAN);';

DECLARE @flags NVARCHAR(MAX) =
       @nl + @nl
     + N'    --  sql/131: job types of #forklift_jobs read once (KEEPFIXED PLAN) instead of' + @nl
     + N'    --  9 IF EXISTS (SELECT 1 FROM #forklift_jobs ...) checks, which recompiled' + @nl
     + N'    --  under the proc''s compile lock when the cached temp table''s row count changed.' + @nl
     + N'    DECLARE @has_jt_1  BIT, @has_jt_2  BIT, @has_jt_3  BIT, @has_jt_4  BIT, @has_jt_5  BIT,' + @nl
     + N'            @has_jt_6  BIT, @has_jt_7  BIT, @has_jt_10 BIT, @has_jt_11 BIT;' + @nl
     + @nl
     + N'    SELECT' + @nl
     + N'        @has_jt_1  = MAX(CASE WHEN job_type_id = 1  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_2  = MAX(CASE WHEN job_type_id = 2  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_3  = MAX(CASE WHEN job_type_id = 3  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_4  = MAX(CASE WHEN job_type_id = 4  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_5  = MAX(CASE WHEN job_type_id = 5  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_6  = MAX(CASE WHEN job_type_id = 6  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_7  = MAX(CASE WHEN job_type_id = 7  THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_10 = MAX(CASE WHEN job_type_id = 10 THEN 1 ELSE 0 END),' + @nl
     + N'        @has_jt_11 = MAX(CASE WHEN job_type_id = 11 THEN 1 ELSE 0 END)' + @nl
     + N'    FROM #forklift_jobs' + @kf;

DECLARE @p TABLE (n INT PRIMARY KEY, o NVARCHAR(MAX), r NVARCHAR(MAX));
INSERT INTO @p (n, o, r) VALUES
--  #forklift_jobs: KEEPFIXED + row check without another read
( 1, N'    GROUP BY ja.job_main_id;' + @nl + @nl + N'    IF NOT EXISTS (SELECT 1 FROM #forklift_jobs)',
     N'    GROUP BY ja.job_main_id' + @kf + @nl + @nl + N'    IF @@ROWCOUNT = 0'),
--  job-type flags, read once after the success row
( 2, N'    SELECT ''success'' AS status, ''Data retrieved successfully.'' AS message;',
     N'    SELECT ''success'' AS status, ''Data retrieved successfully.'' AS message;' + @flags),
--  IF ... EXISTS (#forklift_jobs) -> flags
( 3, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 1)',  N' AND @has_jt_1 = 1'),
( 4, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 2)',  N' AND @has_jt_2 = 1'),
( 5, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 11)', N' AND @has_jt_11 = 1'),
( 6, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 3)',  N' AND @has_jt_3 = 1'),
( 7, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 4)',  N' AND @has_jt_4 = 1'),
( 8, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 5)',  N' AND @has_jt_5 = 1'),
( 9, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 7)',  N' AND @has_jt_7 = 1'),
(10, N' AND EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 6)',  N' AND @has_jt_6 = 1'),
(11, N'IF EXISTS (SELECT 1 FROM #forklift_jobs WHERE job_type_id = 10)',   N'IF @has_jt_10 = 1'),
--  KEEPFIXED PLAN on the statements that read #temp tables
(12, N'        ON f.job_main_id = j.id;',                     N'        ON f.job_main_id = j.id' + @kf),                      -- #filter_jobs
(13, N'    GROUP BY header_id, job_type_id, item_id;',        N'    GROUP BY header_id, job_type_id, item_id' + @kf),         -- #item_summary
(14, N'        AND sps.is_active = ''Y'';',                   N'        AND sps.is_active = ''Y''' + @kf),                    -- UPDATE #item_summary
(15, N'    GROUP BY header_id, job_type_id;',                 N'    GROUP BY header_id, job_type_id' + @kf),                  -- #job_summary
(16, N'    FROM pallet_allocation;',                          N'    FROM pallet_allocation' + @kf),                           -- #pallet_cal
(17, N'    ORDER BY dj.id DESC;',                             N'    ORDER BY dj.id DESC' + @kf),                              -- job rows
(18, N'    GROUP BY v.job_main_id, v.job_item_id, COALESCE(v.pallet_seq, v.pallet_id);',
     N'    GROUP BY v.job_main_id, v.job_item_id, COALESCE(v.pallet_seq, v.pallet_id)' + @kf),                                   -- #SpecialPalletStatus
(19, N'    ) AS p;',                                          N'    ) AS p' + @kf),                                           -- #job_pallet_data
(20, N'    GROUP BY p.job_main_id, p.pallet_id, p.bag_id;',   N'    GROUP BY p.job_main_id, p.pallet_id, p.bag_id' + @kf),    -- #pallet_summary
(21, N'    WHERE is_prepare = ''Y'' AND is_received <> ''Y'' AND is_complete <> ''Y'';',
     N'    WHERE is_prepare = ''Y'' AND is_received <> ''Y'' AND is_complete <> ''Y''' + @kf),                                   -- prepare pallets
(22, N'    WHERE is_received = ''Y'' AND is_complete <> ''Y'';',
     N'    WHERE is_received = ''Y'' AND is_complete <> ''Y''' + @kf),                                                           -- receive pallets
(23, N'    WHERE is_complete = ''Y'';',                       N'    WHERE is_complete = ''Y''' + @kf),                        -- complete pallets
(24, N'            AND (ps.is_received = ''Y'' OR ps.is_complete = ''Y'')' + @nl + N'    );',
     N'            AND (ps.is_received = ''Y'' OR ps.is_complete = ''Y'')' + @nl + N'    )' + @kf),                              -- #pallet_manual_summary
(25, N'    SELECT * FROM #pallet_manual_summary;',            N'    SELECT * FROM #pallet_manual_summary' + @kf);             -- manual pallets

--  patched text (r) back to the original text (o)
IF EXISTS (SELECT 1 FROM @p
           WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, r, N''))) / DATALENGTH(r) <> 1)
BEGIN
    DECLARE @bad NVARCHAR(200) = (SELECT STRING_AGG(CAST(n AS VARCHAR(5)), ',') FROM @p
                                  WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, r, N''))) / DATALENGTH(r) <> 1);
    RAISERROR('pProcessGetForkliftJobs: patched piece(s) %s not found exactly once - not rolled back.', 16, 1, @bad);
    RETURN;
END

DECLARE @i INT = (SELECT MAX(n) FROM @p), @o NVARCHAR(MAX), @r NVARCHAR(MAX);
WHILE @i >= 1
BEGIN
    SELECT @o = o, @r = r FROM @p WHERE n = @i;
    SET @d = REPLACE(@d, @r, @o);
    SET @i -= 1;
END

DECLARE @at INT = CHARINDEX(@key, @d);
DECLARE @hash VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', SUBSTRING(@d, @at, DATALENGTH(@d))), 2);
IF @at = 0 OR @hash <> @base
BEGIN
    RAISERROR('pProcessGetForkliftJobs: body after rollback has SHA-256 %s, not the pre-131 body - not rolled back.', 16, 1, @hash);
    RETURN;
END

DECLARE @head NVARCHAR(MAX) = LEFT(@d, @at - 1);
--  Header keyword -> ALTER (see sql/131): last CREATE before the proc
--  name; left as it is if the header already says ALTER.
DECLARE @kw INT = CASE WHEN CHARINDEX(N'CREATE', @head) > 0
                       THEN DATALENGTH(@head) / 2 - CHARINDEX(REVERSE(N'CREATE'), REVERSE(@head)) - 4
                       ELSE 0 END;
IF @kw > 0 AND SUBSTRING(@head, @kw, 6) = N'CREATE'
    SET @d = STUFF(@d, @kw, 6, N'ALTER');
ELSE IF CHARINDEX(N'ALTER', @head) = 0
BEGIN
    RAISERROR('pProcessGetForkliftJobs: CREATE/ALTER keyword not found before the proc name - not rolled back.', 16, 1);
    RETURN;
END

EXEC sp_executesql @d;
PRINT 'pProcessGetForkliftJobs: sql/131 rolled back.';
GO
