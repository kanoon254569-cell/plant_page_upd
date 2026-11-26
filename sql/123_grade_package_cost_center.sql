-- =============================================================
-- 123 : ct_grade_package_ratio.cost_center (grade master Product CC)
-- =============================================================
-- Problem: the job list's Product CC filter (pProcessGetJobList,
-- @product_ccs) matched COALESCE(tr_job_main.product_cc, item pd_cc_code).
-- Before Approve, product_cc is NULL and pd_cc_code is the raw WMS "from"
-- CC (eg. 0005), while the API shows the WMS grade master's cost_center
-- (eg. 1600). So a job shown as "CC 1600" was not found by 1600.
--
-- Fix: the Hangfire job sync-grade-package-ratio (PalletMatchingService.
-- RefreshRatioAsync) also reads the WMS grade master and passes the
-- grade's cost_center to pServiceStampGradePackageRatio, which keeps it
-- in ct_grade_package_ratio.cost_center. pProcessGetJobList's Product CC
-- filter uses it before pd_cc_code.
--
--   1. ct_grade_package_ratio.cost_center          (new column)
--   2. pServiceStampGradePackageRatio @cost_center (new param)
--   3. pProcessGetJobList                          (patched in place:
--      REPLACE on one unique line, keeps the rest of the live definition)
--
-- Rollback: 123_rollback_grade_package_cost_center.sql
-- =============================================================

SET XACT_ABORT ON;
GO

-- 1. ----------------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'cost_center') IS NULL
    ALTER TABLE dbo.ct_grade_package_ratio ADD cost_center VARCHAR(50) NULL;
GO

-- 2. ----------------------------------------------------------
--  @cost_center NULL (grade master call failed / no exact grade) keeps
--  the value already stamped, so a WMS hiccup doesn't wipe it.
CREATE OR ALTER PROCEDURE dbo.pServiceStampGradePackageRatio
    @grade       VARCHAR(30),
    @unit_ratio  INT         = NULL,
    @unit_pallet INT         = NULL,
    @unit_code   VARCHAR(20) = NULL,
    @cost_center VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @grade IS NULL OR LTRIM(RTRIM(@grade)) = ''
        BEGIN
            SELECT 'error' AS status, 'grade is required' AS message;
            RETURN;
        END

        -- เก็บ grade แบบตัด space ออกทั้งหมด เช่น '1100NK SUB' -> '1100NKSUB'
        SET @grade = REPLACE(@grade, ' ', '');
        SET @cost_center = NULLIF(LTRIM(RTRIM(@cost_center)), '');

        MERGE dbo.ct_grade_package_ratio AS t
        USING (SELECT @grade AS grade) AS s
           ON (t.grade = s.grade)
        WHEN MATCHED THEN
            UPDATE SET unit_ratio           = @unit_ratio,
                       unit_pallet          = @unit_pallet,
                       unit_code            = @unit_code,
                       cost_center          = COALESCE(@cost_center, t.cost_center),
                       last_update_datetime = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (grade, unit_ratio, unit_pallet, unit_code, cost_center, last_update_datetime)
            VALUES (@grade, @unit_ratio, @unit_pallet, @unit_code, @cost_center, GETDATE());

        SELECT 'success' AS status, 'stamped' AS message;                  -- dbResult
        SELECT grade, unit_ratio, unit_pallet, unit_code, cost_center, last_update_datetime
        FROM   dbo.ct_grade_package_ratio
        WHERE  grade = @grade;                                             -- dbResult1
    END TRY
    BEGIN CATCH
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO

-- 3. ----------------------------------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @old NVARCHAR(400) = N'NULLIF(LTRIM(RTRIM(jm.product_cc COLLATE DATABASE_DEFAULT)), ''''),';
DECLARE @new NVARCHAR(1500) = @old
    + NCHAR(10) + N'            --  grade master cost center (sql/123, ct_grade_package_ratio.cost_center),'
    + NCHAR(10) + N'            --  the CC the job card shows before Approve -- ahead of the raw pd_cc_code.'
    + NCHAR(10) + N'            NULLIF(LTRIM(RTRIM((SELECT TOP 1 gpr.cost_center FROM dbo.ct_grade_package_ratio gpr'
    + NCHAR(10) + N'                WHERE gpr.grade = REPLACE(dj.grade COLLATE DATABASE_DEFAULT, '' '', '''')))), ''''),';

IF CHARINDEX(N'gpr.cost_center', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50002, 'pProcessGetJobList: anchor line not found exactly once', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
