/* =====================================================================
   pProcessGetSpecialJobList -- @grades filter (Map DO Special)
   ---------------------------------------------------------------------
   Base: the definition live on IRPC_QTRACK (10.31.1.74), last modified
   2026-09-17. The proc is ~24k characters, so instead of a full copy this
   script patches the live definition with two exact text replacements and
   re-creates it (CREATE OR ALTER). It stops without changing anything if
   the live text is not the expected base (or is already patched).
   Rollback: sql/101_rollback_pProcessGetSpecialJobList.sql.

   Change (101): new optional param
   - @grades  comma list of exact grades, e.g. '1126NK,1100ZC'. Keeps only
              Special Jobs (headers) that have an active item with one of
              those grades. NULL/'' = no filter. Applied in the paging step,
              so page / total_count count only matching jobs.
   Used by job-list's Map DO Special filter (GET job/special?grades=...).
   The old call (no @grades) works the same as before.
   ===================================================================== */
GO

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetSpecialJobList'));
DECLARE @lf NCHAR(1) = NCHAR(10);

DECLARE @old_create NVARCHAR(200) = N'CREATE   PROCEDURE [dbo].[pProcessGetSpecialJobList]';
DECLARE @old_params NVARCHAR(200) = N'    @page_size  INT          = 25' + @lf + N'AS';
DECLARE @old_where  NVARCHAR(400) = N'          AND h.status_flag = ''A''' + @lf + N'        ORDER BY' + @lf + N'            h.create_datetime DESC';

IF @d LIKE N'%@grades%'
BEGIN
    PRINT 'pProcessGetSpecialJobList already has @grades -- nothing to do.';
    RETURN;
END

IF CHARINDEX(@old_create, @d) = 0 OR CHARINDEX(@old_params, @d) = 0 OR CHARINDEX(@old_where, @d) = 0
BEGIN
    RAISERROR('pProcessGetSpecialJobList is not the expected base -- not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @old_create, N'CREATE OR ALTER PROCEDURE [dbo].[pProcessGetSpecialJobList]');

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

EXEC sp_executesql @d;
PRINT 'pProcessGetSpecialJobList patched with @grades.';
GO
