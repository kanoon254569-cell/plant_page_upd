-- 129 rollback : remove the sql/129 lock from pProcessUpdateInternalTransferJob
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessUpdateInternalTransferJob'));
DECLARE @old NVARCHAR(400) = N'is_advance_order = CASE WHEN @job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                        --  sql/129: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                        AND NOT (@job_status_id = 2 AND ISNULL(is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/129', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50130, 'pProcessUpdateInternalTransferJob: sql/129 block changed -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
