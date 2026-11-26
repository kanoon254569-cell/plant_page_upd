-- =============================================================
-- 45_jb_grade_from_wms_unit_code.sql  (IRPC_QTRACK)
-- =============================================================
-- One source of truth for "is this grade JB": WMS master package data,
-- stored in ct_grade_package_ratio.unit_code (pk_unit_code = 'JB').
-- Replaces the is_jb flag from 43 (which was only set after the first JB
-- scan) and the WMS call the API made on every forklift job list load.
--
-- Flow after this script:
--   PalletMatchingService.RefreshRatiosAsync (C#, existing)
--     -> pServiceGetGradeForMatching  : grades needing refresh (1)
--     -> WMS QtrackMasterGradePackage : { pkUnitCode, unitRatio, unitPallet }
--     -> pServiceStampGradePackageRatio -> ct_grade_package_ratio.unit_code
--   pProcessGetForkliftJobs (per item, 44): 'M' manual item
--     -> 'J' unit_code = 'JB' (2) -> 'A'; scan_qty from sys_pallet_scan_setting
--   API JobService passes items[].scan_qty through unchanged.
--
-- 1. pServiceGetGradeForMatching also returns grades of open inbound jobs
--    (Transfer Slip / Receive, job_status_id <> 5), so a JB grade is stamped
--    before the forklift sees the job -- not only grades with pending bags
--    (JB bags never pend: they get a pallet on insert). Job-only grades come
--    back with pending_bags = 0; pServiceRunPalletMatching has its own grade
--    cursor over tr_bag, so matching itself is unchanged. If reading the job
--    functions fails, bag grades are still returned.
-- 2. pProcessGetForkliftJobs: 'J' when unit_code = 'JB' (was is_jb = 'Y').
-- 3. Drop ct_grade_package_ratio.is_jb -- guarded: stops if any object
--    still references it (deploy the updated 42 first).
--
-- Gap: a job created between two refresh runs shows scan_qty from 'A' until
-- the next run stamps its grade.
--
-- Deploy order: 42 (no is_jb) -> 45.
--
-- NOTE (2026-10-10): pServiceGetGradeForMatching below is OUTDATED -- the live
-- version (8 job functions, today's jobs only) is in 11_pServiceGetGradeForMatching.sql.
-- Re-running this file overwrites it.
-- =============================================================

-- 1) pServiceGetGradeForMatching -------------------------------
CREATE OR ALTER PROCEDURE dbo.pServiceGetGradeForMatching
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = 'ok';

    CREATE TABLE #grade
    (
        grade        VARCHAR(30) NULL,
        pending_bags INT         NULL,
        unit_ratio   INT         NULL,
        unit_pallet  INT         NULL,
        unit_code    VARCHAR(20) NULL,
        need_refresh BIT         NULL
    );

    CREATE TABLE #src (grade VARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, pending_bags INT NOT NULL);

    BEGIN TRY
        -- grades with bags waiting for a pallet (unchanged)
        INSERT INTO #src (grade, pending_bags)
        SELECT b.grade, COUNT(*)
        FROM   dbo.tr_bag b
        WHERE  b.bag_status_id = 1
          AND  b.pallet_id IS NULL
          AND  b.is_active   = 'Y'
          AND  b.status_flag = 'A'
          AND  b.grade IS NOT NULL
        GROUP BY b.grade;

        -- grades of open inbound jobs (new) -- failure here must not block the bag grades
        BEGIN TRY
            INSERT INTO #src (grade, pending_bags)
            SELECT DISTINCT LEFT(LTRIM(RTRIM(x.grade)), 30) COLLATE DATABASE_DEFAULT, 0
            FROM (
                SELECT grade, job_status_id FROM dbo.fTransferSlipJob(NULL, NULL)
                UNION ALL
                SELECT grade, job_status_id FROM dbo.fReceiveJob(NULL, NULL)
            ) x
            WHERE x.grade IS NOT NULL
              AND LTRIM(RTRIM(x.grade)) <> ''
              AND ISNULL(x.job_status_id, 0) <> 5
              AND NOT EXISTS (SELECT 1 FROM #src s
                              WHERE s.grade = LEFT(LTRIM(RTRIM(x.grade)), 30) COLLATE DATABASE_DEFAULT);
        END TRY
        BEGIN CATCH
            SET @message = CONCAT('ok (job grades skipped: ', ERROR_MESSAGE(), ')');
        END CATCH

        INSERT INTO #grade (grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh)
        SELECT  s.grade,
                s.pending_bags,
                r.unit_ratio,
                r.unit_pallet,
                r.unit_code,
                CAST(CASE WHEN r.grade IS NULL
                           OR r.unit_pallet IS NULL
                           OR r.last_update_datetime < DATEADD(DAY, -1, GETDATE())
                          THEN 1 ELSE 0 END AS BIT)
        FROM    #src s
        LEFT JOIN dbo.ct_grade_package_ratio r ON r.grade = s.grade;
    END TRY
    BEGIN CATCH
        SET @status  = 'error';
        SET @message = ERROR_MESSAGE();
    END CATCH

    SELECT @status AS status, @message AS message;                         -- dbResult
    SELECT grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh
    FROM   #grade
    ORDER BY grade;                                                        -- dbResult1
END
GO

-- 2) pProcessGetForkliftJobs: J from unit_code -----------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetForkliftJobs'));
DECLARE @old NVARCHAR(200) = N'AND gpr.is_jb = ''Y''';
DECLARE @new NVARCHAR(200) = N'AND UPPER(LTRIM(RTRIM(gpr.unit_code))) = ''JB''';

IF @d LIKE N'%UPPER(LTRIM(RTRIM(gpr.unit_code))) = ''JB''%'
    PRINT 'pProcessGetForkliftJobs already uses unit_code - skipped.';
ELSE IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
    RAISERROR('pProcessGetForkliftJobs: is_jb condition not found exactly once - not patched.', 16, 1);
ELSE
BEGIN
    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE PROC'), N'ALTER PROC');
    EXEC sp_executesql @d;
    PRINT 'pProcessGetForkliftJobs patched: J from unit_code.';
END
GO

-- 3) drop is_jb ------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'is_jb') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.sql_modules WHERE definition LIKE N'%is_jb%')
        RAISERROR('ct_grade_package_ratio.is_jb is still referenced - deploy the updated 42 first.', 16, 1);
    ELSE
    BEGIN
        IF OBJECT_ID('dbo.DF_ct_grade_package_ratio_is_jb', 'D') IS NOT NULL
            ALTER TABLE dbo.ct_grade_package_ratio DROP CONSTRAINT DF_ct_grade_package_ratio_is_jb;
        ALTER TABLE dbo.ct_grade_package_ratio DROP COLUMN is_jb;
        PRINT 'ct_grade_package_ratio.is_jb dropped.';
    END
END
GO
