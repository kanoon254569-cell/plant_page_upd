-- =============================================================
-- 99_pProcessGetJobList_order_asc.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessGetJobList: list jobs in ascending id order (oldest first)
-- instead of descending.
--
-- Two changes, both on the job id only:
--   1. Paging:       ORDER BY sort_priority, id DESC  -> id ASC
--   2. Final result: ORDER BY pj.id DESC              -> pj.id ASC
-- sort_priority stays first in the paging order. On 10.31.1.75 the final
-- ORDER BY also has ", pj.page_row_no DESC" (row tie-break inside one
-- job); that part is not changed.
--
-- Patched from the live definition with REPLACE (same way as sql/94):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the proc already sorts ascending.
-- Rollback: sql/99_rollback_pProcessGetJobList_order_asc.sql
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessGetJobList';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @p1   NVARCHAR(100) = N'ORDER BY sort_priority, id DESC';
DECLARE @p2   NVARCHAR(100) = N'ORDER BY pj.id DESC';

IF @d LIKE N'%ORDER BY sort_priority, id ASC%' AND @d LIKE N'%ORDER BY pj.id ASC%'
BEGIN
    PRINT 'pProcessGetJobList already sorts ascending (99_) - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @p1, N''))) / DATALENGTH(@p1) <> 1
OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @p2, N''))) / DATALENGTH(@p2) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @p1, N'ORDER BY sort_priority, id ASC');
SET @d = REPLACE(@d, @p2, N'ORDER BY pj.id ASC');
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched (99_: job id order DESC -> ASC).';
GO
