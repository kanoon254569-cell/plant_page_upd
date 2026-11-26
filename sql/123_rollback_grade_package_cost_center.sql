-- =============================================================
-- 123 rollback : undo 123_grade_package_cost_center.sql
-- =============================================================

SET XACT_ABORT ON;
GO

-- 3. pProcessGetJobList ---------------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @old NVARCHAR(400) = N'NULLIF(LTRIM(RTRIM(jm.product_cc COLLATE DATABASE_DEFAULT)), ''''),';
DECLARE @new NVARCHAR(1500) = @old
    + NCHAR(10) + N'            --  grade master cost center (sql/123, ct_grade_package_ratio.cost_center),'
    + NCHAR(10) + N'            --  the CC the job card shows before Approve -- ahead of the raw pd_cc_code.'
    + NCHAR(10) + N'            NULLIF(LTRIM(RTRIM((SELECT TOP 1 gpr.cost_center FROM dbo.ct_grade_package_ratio gpr'
    + NCHAR(10) + N'                WHERE gpr.grade = REPLACE(dj.grade COLLATE DATABASE_DEFAULT, '' '', '''')))), ''''),';

IF CHARINDEX(N'gpr.cost_center', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50011, 'pProcessGetJobList: patched block changed since 123 -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO

-- 2. pServiceStampGradePackageRatio (definition before 123) ----
CREATE OR ALTER PROCEDURE dbo.pServiceStampGradePackageRatio
    @grade       VARCHAR(30),
    @unit_ratio  INT         = NULL,
    @unit_pallet INT         = NULL,
    @unit_code   VARCHAR(20) = NULL
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

        MERGE dbo.ct_grade_package_ratio AS t
        USING (SELECT @grade AS grade) AS s
           ON (t.grade = s.grade)
        WHEN MATCHED THEN
            UPDATE SET unit_ratio           = @unit_ratio,
                       unit_pallet          = @unit_pallet,
                       unit_code            = @unit_code,
                       last_update_datetime = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (grade, unit_ratio, unit_pallet, unit_code, last_update_datetime)
            VALUES (@grade, @unit_ratio, @unit_pallet, @unit_code, GETDATE());

        SELECT 'success' AS status, 'stamped' AS message;                  -- dbResult
        SELECT grade, unit_ratio, unit_pallet, unit_code, last_update_datetime
        FROM   dbo.ct_grade_package_ratio
        WHERE  grade = @grade;                                             -- dbResult1
    END TRY
    BEGIN CATCH
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO

-- 1. -----------------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'cost_center') IS NOT NULL
    ALTER TABLE dbo.ct_grade_package_ratio DROP COLUMN cost_center;
GO
