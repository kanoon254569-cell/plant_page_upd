-- 128 rollback : remove the sql/128 lock from pProcessApproveJob
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessApproveJob'));
DECLARE @old NVARCHAR(400) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                    --  sql/128: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                    AND NOT (jm.job_status_id = 2 AND ISNULL(jm.is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/128', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50129, 'pProcessApproveJob: sql/128 block changed -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
