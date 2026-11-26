-- =============================================================
-- 43_ct_grade_package_ratio_is_jb.sql  (IRPC_QTRACK)
-- =============================================================
-- JB (jumbo bag) grades get their own scan setting on the forklift job list.
--
-- 1. ct_grade_package_ratio.is_jb  VARCHAR(1) NOT NULL DEFAULT 'N'
--      'Y' = JB grade (e.g. '1105RC/750'). Set by
--      dbo.pProcessCreateJbPalletBag (42) on the first JB scan of a grade.
--
-- 2. dbo.pProcessGetForkliftJobs: the sys_pallet_scan_setting join picks
--      'M' -> item is a manual pallet item (tr_pallet_manual_item)  (unchanged)
--      'J' -> grade is in ct_grade_package_ratio with is_jb = 'Y'   (new)
--      'A' -> everything else                                       (unchanged)
--    sys_pallet_scan_setting already has the 'J' row (Jumbo pallet, scan_qty 1).
--
--    The proc is ~23k characters, so step 2 patches the live definition
--    with REPLACE instead of repeating the whole proc here. The patch is
--    idempotent: it does nothing if the proc already reads is_jb, and it
--    fails loudly if the text to replace is not found exactly once.
--
-- Limitation: a JB grade shows as 'A' (scan_qty 3) on the job list until
-- its first bag has been scanned once (that scan registers the grade).
-- Pre-register a grade by hand if needed:
--   INSERT dbo.ct_grade_package_ratio (grade, unit_ratio, unit_pallet, is_jb)
--   VALUES ('1105RC/750', 750, 1, 'Y');
--
-- pServiceStampGradePackageRatio (WMS+ refresh) does not touch is_jb, and
-- it only runs for grades with pending bags; JB bags always have a pallet.
--
-- Deploy order: 40 -> 43 -> 42 -> 41.
-- =============================================================

-- 1) column ---------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'is_jb') IS NULL
BEGIN
    ALTER TABLE dbo.ct_grade_package_ratio
        ADD is_jb VARCHAR(1) NOT NULL
            CONSTRAINT DF_ct_grade_package_ratio_is_jb DEFAULT ('N');
END
GO

-- 2) pProcessGetForkliftJobs ----------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetForkliftJobs'));
DECLARE @lf  NCHAR(1)      = NCHAR(10);
DECLARE @old NVARCHAR(400) =
      N'            ) THEN ''M''' + @lf
    + N'            ELSE ''A''';
DECLARE @new NVARCHAR(800) =
      N'            ) THEN ''M''' + @lf
    + N'            WHEN EXISTS (' + @lf
    + N'                SELECT 1 FROM dbo.ct_grade_package_ratio gpr' + @lf
    + N'                WHERE gpr.grade = dj.grade COLLATE DATABASE_DEFAULT' + @lf  -- #filter_jobs uses tempdb collation
    + N'                    AND gpr.is_jb = ''Y''' + @lf
    + N'            ) THEN ''J''' + @lf
    + N'            ELSE ''A''';

IF @d LIKE N'%gpr.is_jb%'
BEGIN
    PRINT 'pProcessGetForkliftJobs already reads is_jb - skipped.';
END
ELSE IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
BEGIN
    RAISERROR('pProcessGetForkliftJobs: scan-setting CASE not found exactly once - not patched.', 16, 1);
END
ELSE
BEGIN
    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');
    EXEC sp_executesql @d;
    PRINT 'pProcessGetForkliftJobs patched.';
END
GO
