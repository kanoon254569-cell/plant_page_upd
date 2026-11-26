-- =============================================================
-- 130 rollback : Pre-zone to-location INSERT back to qty 0
-- =============================================================
-- Backfilled qty on existing rows is NOT reverted (no record of which
-- rows were 0 before); set them back by hand if needed:
--   UPDATE tl SET qty = 0 FROM dbo.tr_job_to_location tl
--   INNER JOIN dbo.tr_job_main jm ON jm.id = tl.job_main_id AND jm.job_type_id = 4
--   WHERE tl.to_location_type = 'PRE-ZONE';
-- =============================================================

DECLARE @d     NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @start INT = CHARINDEX(N'--  sql/130:', @d);

IF @start > 0
BEGIN
    --  From the sql/130 comment line up to (not including) the "NULL, @user_id" line.
    DECLARE @lineStart INT = @start;
    WHILE @lineStart > 1 AND SUBSTRING(@d, @lineStart - 1, 1) <> NCHAR(10) SET @lineStart -= 1;

    DECLARE @end INT = CHARINDEX(N'NULL, @user_id, GETDATE(), @user_id, GETDATE()', @d, @start);
    IF @end = 0
        THROW 50131, 'pProcessPickingPutAway: sql/130 block end not found -- restore by hand', 1;

    SET @d = STUFF(@d, @lineStart, @end - @lineStart, N'                0, ');
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
