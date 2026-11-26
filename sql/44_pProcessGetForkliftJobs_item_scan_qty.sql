-- =============================================================
-- 44_pProcessGetForkliftJobs_item_scan_qty.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessGetForkliftJobs: scan_qty is decided once per item instead of
-- once per job/location row.
--
-- Before: the final SELECT joined sys_pallet_scan_setting for every
--         #filter_jobs row (one row per from/to location and lot).
-- Now:    #item_summary (header_id, job_type_id, item_id) gets grade and
--         scan_qty; the final SELECT reads ism.scan_qty. The column keeps
--         its name and position in the result, so the backend is unchanged.
--
-- scan_qty rule (same as 43):
--   job_type_id not in (1, 2)                        -> 1
--   item is a manual pallet item (tr_pallet_manual_item) -> 'M' row
--   grade is JB (ct_grade_package_ratio.is_jb = 'Y')    -> 'J' row
--   otherwise                                           -> 'A' row
--
-- The proc is ~23k characters, so this script patches the live definition
-- with REPLACE (each piece must be found exactly once, else nothing is
-- changed). Idempotent: skipped if #item_summary already has scan_qty.
--
-- Needs 43_ct_grade_package_ratio_is_jb.sql deployed first.
-- =============================================================

DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetForkliftJobs'));
DECLARE @lf NCHAR(1)      = NCHAR(10);

IF @d LIKE N'%ALTER TABLE #item_summary ADD scan_qty%'
BEGIN
    PRINT 'pProcessGetForkliftJobs already has item-level scan_qty - skipped.';
    RETURN;
END

-- 1) carry grade into #item_summary
DECLARE @o1 NVARCHAR(400) =
      N'            ISNULL(total_qty,0) AS total_qty' + @lf
    + N'        FROM #filter_jobs' + @lf
    + N'    ) dedup';
DECLARE @n1 NVARCHAR(400) =
      N'            ISNULL(total_qty,0) AS total_qty,' + @lf
    + N'            grade' + @lf
    + N'        FROM #filter_jobs' + @lf
    + N'    ) dedup';

DECLARE @o2 NVARCHAR(400) =
      N'        MAX(total_qty) AS item_total_qty' + @lf
    + N'    INTO #item_summary';
DECLARE @n2 NVARCHAR(400) =
      N'        MAX(total_qty) AS item_total_qty,' + @lf
    + N'        MAX(grade) AS grade' + @lf
    + N'    INTO #item_summary';

-- 2) scan_qty per item, right after the #item_summary index
DECLARE @o3 NVARCHAR(400) =
      N'    CREATE NONCLUSTERED INDEX idx_item_summary ON #item_summary(header_id, job_type_id, item_id);' + @lf;
DECLARE @n3 NVARCHAR(MAX) = @o3 + @lf
    + N'    ALTER TABLE #item_summary ADD scan_qty INT NULL;' + @lf + @lf
    + N'    UPDATE ism' + @lf
    + N'    SET scan_qty = CASE WHEN ism.job_type_id IN (1, 2) THEN sps.scan_qty ELSE 1 END' + @lf
    + N'    FROM #item_summary ism' + @lf
    + N'    LEFT JOIN dbo.sys_pallet_scan_setting sps' + @lf
    + N'        ON sps.pallet_type = CASE' + @lf
    + N'            WHEN EXISTS (' + @lf
    + N'                SELECT 1 FROM dbo.tr_pallet_manual_item pmi' + @lf
    + N'                WHERE pmi.job_type_id = ism.job_type_id' + @lf
    + N'                    AND pmi.wms_plus_item_id = ism.item_id' + @lf
    + N'                    AND pmi.is_active = ''Y''' + @lf
    + N'                    AND pmi.status_flag = ''A''' + @lf
    + N'            ) THEN ''M''' + @lf
    + N'            WHEN EXISTS (' + @lf
    + N'                SELECT 1 FROM dbo.ct_grade_package_ratio gpr' + @lf
    + N'                WHERE gpr.grade = ism.grade COLLATE DATABASE_DEFAULT' + @lf
    + N'                    AND gpr.is_jb = ''Y''' + @lf
    + N'            ) THEN ''J''' + @lf
    + N'            ELSE ''A''' + @lf
    + N'        END' + @lf
    + N'        AND sps.is_active = ''Y'';' + @lf;

-- 3) final SELECT reads the item value
DECLARE @o4 NVARCHAR(400) =
      N'        CASE WHEN dj.job_type_id IN (1, 2) THEN sps.scan_qty ELSE 1 END scan_qty,';
DECLARE @n4 NVARCHAR(400) =
      N'        ism.scan_qty,';

-- 4) drop the per-row sys_pallet_scan_setting join from the final SELECT
DECLARE @j_start INT = CHARINDEX(N'    LEFT JOIN dbo.sys_pallet_scan_setting sps' + @lf + N'        ON sps.pallet_type = CASE', @d);
DECLARE @j_end_marker NVARCHAR(100) = N'        AND sps.is_active = ''Y''' + @lf;
DECLARE @j_end INT = CASE WHEN @j_start > 0 THEN CHARINDEX(@j_end_marker, @d, @j_start) END;

IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o3, N''))) / LEN(@o3) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o4, N''))) / LEN(@o4) <> 1
  OR ISNULL(@j_start, 0) = 0 OR ISNULL(@j_end, 0) = 0
BEGIN
    RAISERROR('pProcessGetForkliftJobs: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

-- remove the join first (positions are from the unpatched text)
SET @d = STUFF(@d, @j_start, @j_end + LEN(@j_end_marker) - @j_start, N'');

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = REPLACE(@d, @o4, @n4);
SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');

EXEC sp_executesql @d;
PRINT 'pProcessGetForkliftJobs patched: item-level scan_qty.';
GO
