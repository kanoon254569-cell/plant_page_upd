/* =====================================================================
   pProcessGetSpecialJobList -- @grades filter (Map DO Special)
                              + carry-over of unfinished jobs
   ---------------------------------------------------------------------
   Base: the definition live on IRPC_QTRACK (10.31.1.74), last modified
   2026-09-17. The proc is ~24k characters, so instead of a full copy this
   script patches the live definition with exact text replacements and
   re-creates it (CREATE OR ALTER). Each change below is applied on its
   own: one already in the live text is skipped, and the script stops
   without changing anything if the text it needs is not there.
   Rollback: sql/101_rollback_pProcessGetSpecialJobList.sql.

   Change (101): new optional param
   - @grades  comma list of exact grades, e.g. '1126NK,1100ZC'. Keeps only
              Special Jobs (headers) that have an active item with one of
              those grades. NULL/'' = no filter. Applied in the paging step,
              so page / total_count count only matching jobs.
   Used by job-list's Map DO Special filter (GET job/special?grades=...).

   Change (101b): carry-over (no new param)
   - When @date_from is set, jobs created BEFORE @date_from that are not
     Complete yet (status_id <> 3, ct_special_status 3 = Complete) are
     listed too, so an unfinished job carries over to the next day's list
     instead of dropping off it. Jobs inside the date range are listed as
     before. Applies to every caller of this proc (SPC01 list, its Excel
     export, Map DO Special).

   Change (101c): new optional param
   - @job_status_ids  comma list of ct_special_status ids, e.g. '1,2'.
              Keeps only headers whose status_id is in the list -- the
              SPC01 multi-select "สถานะ" filter (GET job/special?
              statusIds=1,2). NULL/'' = no filter. Works alongside the
              old single @job_status and the 101b carry-over.

   Calls without @grades / @job_status_ids work the same as before.
   ===================================================================== */
GO

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetSpecialJobList'));
DECLARE @lf NCHAR(1) = NCHAR(10);

DECLARE @old_params   NVARCHAR(200) = N'    @page_size  INT          = 25' + @lf + N'AS';
DECLARE @old_where    NVARCHAR(400) = N'          AND h.status_flag = ''A''' + @lf + N'        ORDER BY' + @lf + N'            h.create_datetime DESC';
DECLARE @old_date    NVARCHAR(400) =
    N'          AND (@dateFromVal IS NULL OR h.create_datetime >= @dateFromVal)' + @lf +
    N'          AND (@dateToVal IS NULL OR h.create_datetime < DATEADD(DAY, 1, @dateToVal))' + @lf;
DECLARE @old_approve  NVARCHAR(200) = N'    @is_approve VARCHAR(1)   = NULL,' + @lf;
DECLARE @old_status   NVARCHAR(400) = N'          AND (@job_status IS NULL OR h.status_id = @job_status)' + @lf;

DECLARE @need_grades  BIT = CASE WHEN @d LIKE N'%@grades%' THEN 0 ELSE 1 END;
DECLARE @need_pending BIT = CASE WHEN @d LIKE N'%101b carry-over%' THEN 0 ELSE 1 END;
DECLARE @need_status_ids BIT = CASE WHEN @d LIKE N'%@job_status_ids%' THEN 0 ELSE 1 END;

IF @need_grades = 0 AND @need_pending = 0 AND @need_status_ids = 0
BEGIN
    PRINT 'pProcessGetSpecialJobList already has @grades, the carry-over and @job_status_ids -- nothing to do.';
    RETURN;
END

IF (@need_grades = 1 AND (CHARINDEX(@old_params, @d) = 0 OR CHARINDEX(@old_where, @d) = 0))
   OR (@need_pending = 1 AND CHARINDEX(@old_date, @d) = 0)
   OR (@need_status_ids = 1 AND (CHARINDEX(@old_approve, @d) = 0 OR CHARINDEX(@old_status, @d) = 0))
BEGIN
    RAISERROR('pProcessGetSpecialJobList is not the expected base -- not patched.', 16, 1);
    RETURN;
END

--  CREATE ... PROCEDURE -> CREATE OR ALTER PROCEDURE, whatever the spacing
--  between the words (the live header has been both 'CREATE PROCEDURE'
--  and 'CREATE   PROCEDURE'): replace from the last CREATE before the
--  proc name up to the name. Already CREATE OR ALTER if this ran before.
DECLARE @name_pos INT = CHARINDEX(N'[dbo].[pProcessGetSpecialJobList]', @d);
DECLARE @head NVARCHAR(MAX) = LEFT(@d, @name_pos - 1);
DECLARE @create_pos INT = DATALENGTH(@head) / 2 - CHARINDEX(N'ETAERC', REVERSE(@head)) - 4;
IF @name_pos = 0 OR @create_pos < 1
BEGIN
    RAISERROR('pProcessGetSpecialJobList: CREATE PROCEDURE header not found -- not patched.', 16, 1);
    RETURN;
END
SET @d = STUFF(@d, @create_pos, @name_pos - @create_pos, N'CREATE OR ALTER PROCEDURE ');

IF @need_grades = 1
BEGIN
    SET @d = REPLACE(@d, @old_params,
        N'    @page_size  INT          = 25,' + @lf +
        N'    @grades     NVARCHAR(500) = NULL' + @lf +
        N'AS');

    SET @d = REPLACE(@d, @old_where,
        N'          AND h.status_flag = ''A''' + @lf +
        N'          AND (NULLIF(LTRIM(RTRIM(@grades)), N'''') IS NULL OR EXISTS' + @lf +
        N'              (SELECT 1 FROM dbo.tr_special_item gi' + @lf +
        N'               WHERE gi.header_id = h.id' + @lf +
        N'                 AND gi.is_active = ''Y''' + @lf +
        N'                 AND gi.status_flag = ''A''' + @lf +
        N'                 AND gi.grade IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@grades, '','')))) ' + @lf +
        N'        ORDER BY' + @lf +
        N'            h.create_datetime DESC');
END

IF @need_pending = 1
BEGIN
    --  In the date range as before, OR (carry-over) created before
    --  @date_from and not Complete (status_id 3) yet.
    SET @d = REPLACE(@d, @old_date,
        N'          AND (' + @lf +
        N'                (    (@dateFromVal IS NULL OR h.create_datetime >= @dateFromVal)' + @lf +
        N'                 AND (@dateToVal IS NULL OR h.create_datetime < DATEADD(DAY, 1, @dateToVal)))' + @lf +
        N'             OR (    -- 101b carry-over: unfinished jobs from before @date_from' + @lf +
        N'                     @dateFromVal IS NOT NULL' + @lf +
        N'                 AND h.create_datetime < @dateFromVal' + @lf +
        N'                 AND ISNULL(h.status_id, 0) <> 3)' + @lf +
        N'              )' + @lf);
END

IF @need_status_ids = 1
BEGIN
    SET @d = REPLACE(@d, @old_approve,
        @old_approve +
        N'    @job_status_ids NVARCHAR(100) = NULL,' + @lf);

    --  101c: multi-status filter ('1,2'), next to the single @job_status.
    SET @d = REPLACE(@d, @old_status,
        @old_status +
        N'          AND (NULLIF(LTRIM(RTRIM(@job_status_ids)), N'''') IS NULL' + @lf +
        N'               OR h.status_id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@job_status_ids, '','')))' + @lf);
END

EXEC sp_executesql @d;
PRINT 'pProcessGetSpecialJobList patched (@grades / carry-over / @job_status_ids).';
GO
