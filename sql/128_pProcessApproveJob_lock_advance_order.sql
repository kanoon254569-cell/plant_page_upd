-- =============================================================
-- 128 : pProcessApproveJob -- advance order locked once approved with it
-- =============================================================
-- tr_job_main.is_advance_order could be changed on every approve while
-- the job was Pending (1) or WH Approved (2), so a job approved as an
-- advance order could be saved back to 'N' later. Now, once the job is
-- WH Approved (2) with is_advance_order = 'Y', later approves keep 'Y'.
-- (Pending -> approve with 'Y' still works; a job approved with 'N' can
-- still be switched on while it is WH Approved.) job-detail disables the
-- chip the same way (canSetAdvanceOrder).
--
-- Patched in place on one unique block of the live definition.
-- Rollback: 128_rollback_pProcessApproveJob_lock_advance_order.sql
-- =============================================================

DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessApproveJob'));
DECLARE @old NVARCHAR(400) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')'
    + NCHAR(10) + N'                                    --  sql/128: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                    AND NOT (jm.job_status_id = 2 AND ISNULL(jm.is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/128', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50128, 'pProcessApproveJob: anchor not found exactly once -- nothing changed', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
