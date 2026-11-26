-- =============================================================
-- 129 : pProcessUpdateInternalTransferJob -- advance order locked once approved
-- =============================================================
-- WH03 counterpart of sql/128 (pProcessApproveJob, used by WH01/02/04).
-- pProcessCreateInternalTransferJob saves the job straight to WH Approved
-- (2); before this, every later edit could still flip is_advance_order back
-- to 'N'. Now a WH Approved job saved with 'Y' keeps 'Y'.
-- job-wh-internal-transfer-detail disables the chip the same way.
--
-- Patched in place on one unique block of the live definition.
-- Rollback: 129_rollback_pProcessUpdateInternalTransferJob_lock_advance_order.sql
-- =============================================================

DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessUpdateInternalTransferJob'));
DECLARE @old NVARCHAR(400) = N'is_advance_order = CASE WHEN @job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                        --  sql/129: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                        AND NOT (@job_status_id = 2 AND ISNULL(is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/129', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50129, 'pProcessUpdateInternalTransferJob: anchor not found exactly once -- nothing changed', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO
