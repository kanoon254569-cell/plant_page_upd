-- =============================================================
-- 99_rollback_pProcessGetJobList_order_asc.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of sql/99_pProcessGetJobList_order_asc.sql: job id order
-- back to descending (newest first).
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessGetJobList';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @p1   NVARCHAR(100) = N'ORDER BY sort_priority, id ASC';
DECLARE @p2   NVARCHAR(100) = N'ORDER BY pj.id ASC';

IF @d LIKE N'%ORDER BY sort_priority, id DESC%' AND @d LIKE N'%ORDER BY pj.id DESC%'
BEGIN
    PRINT 'pProcessGetJobList already sorts descending (99_ rollback) - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @p1, N''))) / DATALENGTH(@p1) <> 1
OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @p2, N''))) / DATALENGTH(@p2) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to roll back not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @p1, N'ORDER BY sort_priority, id DESC');
SET @d = REPLACE(@d, @p2, N'ORDER BY pj.id DESC');
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList rolled back (99_: job id order ASC -> DESC).';
GO
