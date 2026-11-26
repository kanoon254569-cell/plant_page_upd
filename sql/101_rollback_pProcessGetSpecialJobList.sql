/* Rollback for sql/101_pProcessGetSpecialJobList_grades.sql -- removes the
   @grades param and its WHERE condition, the carry-over date condition,
   and the @job_status_ids param and its WHERE condition (the exact text
   101 added), leaving
   the rest of the live definition unchanged. Each part is rolled back
   only if it is there. */
GO

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetSpecialJobList'));
DECLARE @lf NCHAR(1) = NCHAR(10);

DECLARE @new_params NVARCHAR(200) =
    N'    @page_size  INT          = 25,' + @lf +
    N'    @grades     NVARCHAR(500) = NULL' + @lf +
    N'AS';
DECLARE @new_where NVARCHAR(1000) =
    @lf +
    N'          AND (NULLIF(LTRIM(RTRIM(@grades)), N'''') IS NULL OR EXISTS' + @lf +
    N'              (SELECT 1 FROM dbo.tr_special_item gi' + @lf +
    N'               WHERE gi.header_id = h.id' + @lf +
    N'                 AND gi.is_active = ''Y''' + @lf +
    N'                 AND gi.status_flag = ''A''' + @lf +
    N'                 AND gi.grade IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@grades, '','')))) ';

DECLARE @new_date NVARCHAR(1000) =
    N'          AND (' + @lf +
    N'                (    (@dateFromVal IS NULL OR h.create_datetime >= @dateFromVal)' + @lf +
    N'                 AND (@dateToVal IS NULL OR h.create_datetime < DATEADD(DAY, 1, @dateToVal)))' + @lf +
    N'             OR (    -- 101b carry-over: unfinished jobs from before @date_from' + @lf +
    N'                     @dateFromVal IS NOT NULL' + @lf +
    N'                 AND h.create_datetime < @dateFromVal' + @lf +
    N'                 AND ISNULL(h.status_id, 0) <> 3)' + @lf +
    N'              )' + @lf;
DECLARE @old_date NVARCHAR(400) =
    N'          AND (@dateFromVal IS NULL OR h.create_datetime >= @dateFromVal)' + @lf +
    N'          AND (@dateToVal IS NULL OR h.create_datetime < DATEADD(DAY, 1, @dateToVal))' + @lf;

DECLARE @new_status_param NVARCHAR(200) = N'    @job_status_ids NVARCHAR(100) = NULL,' + @lf;
DECLARE @new_status_where NVARCHAR(1000) =
    N'          AND (NULLIF(LTRIM(RTRIM(@job_status_ids)), N'''') IS NULL' + @lf +
    N'               OR h.status_id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@job_status_ids, '','')))' + @lf;

DECLARE @has_grades  BIT = CASE WHEN CHARINDEX(@new_params, @d) > 0 AND CHARINDEX(@new_where, @d) > 0 THEN 1 ELSE 0 END;
DECLARE @has_pending BIT = CASE WHEN CHARINDEX(@new_date, @d) > 0 THEN 1 ELSE 0 END;
DECLARE @has_status_ids BIT = CASE WHEN CHARINDEX(@new_status_param, @d) > 0 AND CHARINDEX(@new_status_where, @d) > 0 THEN 1 ELSE 0 END;

IF @has_grades = 0 AND @has_pending = 0 AND @has_status_ids = 0
BEGIN
    RAISERROR('pProcessGetSpecialJobList does not have the sql/101 change -- nothing rolled back.', 16, 1);
    RETURN;
END

IF @has_grades = 1
BEGIN
    SET @d = REPLACE(@d, @new_params, N'    @page_size  INT          = 25' + @lf + N'AS');
    SET @d = REPLACE(@d, @new_where, N'');
END

IF @has_pending = 1
BEGIN
    SET @d = REPLACE(@d, @new_date, @old_date);
END

IF @has_status_ids = 1
BEGIN
    SET @d = REPLACE(@d, @new_status_param, N'');
    SET @d = REPLACE(@d, @new_status_where, N'');
END

--  sql/101 re-created it as CREATE OR ALTER; keep that so this can run.
EXEC sp_executesql @d;
PRINT 'pProcessGetSpecialJobList rolled back (no @grades / carry-over / @job_status_ids).';
GO
