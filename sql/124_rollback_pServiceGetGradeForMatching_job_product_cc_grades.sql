-- =============================================================
-- 124 rollback : remove the sql/124 block from pServiceGetGradeForMatching
-- =============================================================
-- Cuts from the "-- sql/124:" comment up to (not including) the
-- "INSERT INTO #grade (...)" line it was inserted before.
-- =============================================================

DECLARE @d      NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pServiceGetGradeForMatching'));
DECLARE @anchor NVARCHAR(400) = N'INSERT INTO #grade (grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh)';
DECLARE @start  INT = CHARINDEX(N'-- sql/124:', @d);

IF @start > 0
BEGIN
    DECLARE @end INT = CHARINDEX(@anchor, @d, @start);
    IF @end = 0
        THROW 50013, 'pServiceGetGradeForMatching: anchor after sql/124 block not found -- restore by hand', 1;

    SET @d = STUFF(@d, @start, @end - @start, N'');
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
