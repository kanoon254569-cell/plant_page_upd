/* Rollback for sql/101_pProcessGetSpecialJobList_grades.sql -- removes the
   @grades param and its WHERE condition again (the exact text 101 added),
   leaving the rest of the live definition unchanged. */
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

IF CHARINDEX(@new_params, @d) = 0 OR CHARINDEX(@new_where, @d) = 0
BEGIN
    RAISERROR('pProcessGetSpecialJobList does not have the sql/101 change -- nothing rolled back.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @new_params, N'    @page_size  INT          = 25' + @lf + N'AS');
SET @d = REPLACE(@d, @new_where, N'');
--  sql/101 re-created it as CREATE OR ALTER; keep that so this can run.
EXEC sp_executesql @d;
PRINT 'pProcessGetSpecialJobList rolled back (no @grades).';
GO
