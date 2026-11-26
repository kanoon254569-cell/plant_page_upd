-- =============================================================
-- 94_rollback_pProcessGetJobList.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 94_pProcessGetJobList_drop_keepfixed.sql : puts
-- " OPTION (KEEPFIXED PLAN);" back on the 8
-- "INSERT INTO @data_jobs SELECT * FROM dbo.fXxxJob(...)" statements.
--
-- Patched from the live definition with REPLACE, the reverse of 94:
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the hint is already there.
-- After this rollback the definition is the one before 94, SHA-256 of
-- OBJECT_DEFINITION (NVARCHAR) =
--   88E2528B63D5330EA6338C3C7D29DECF002B62D11F86854C59C8BC021926589A
-- (checked at the end; a mismatch only prints a warning, since 94 and
-- this rollback both leave the rest of the proc as it is).
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessGetJobList';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @hint NVARCHAR(50)  = N' OPTION (KEEPFIXED PLAN);';

IF @d LIKE N'%KEEPFIXED PLAN%'
BEGIN
    PRINT 'pProcessGetJobList already has KEEPFIXED PLAN (94_ rollback) - skipped.';
    RETURN;
END

DECLARE @tvf TABLE (fn NVARCHAR(100) NOT NULL);
INSERT INTO @tvf (fn) VALUES
    (N'dbo.fTransferSlipJob(@id, @date_from, @date_to)'),
    (N'dbo.fReceiveJob(@id, @date_from, @date_to)'),
    (N'dbo.fTransferWhJob(@id, @date_from, @date_to)'),
    (N'dbo.fRequestJob(@id, @date_from, @date_to)'),
    (N'dbo.fPickingJob(@id, @date_from, @date_to)'),
    (N'dbo.fShippingJob(@id, @date_from, @date_to)'),
    (N'dbo.fSpecialJob(@id, @date_from, @date_to)'),
    (N'dbo.fBrokenBagJob(@id, @date_from, @date_to)');

-- every "<tvf>;" exactly once
IF EXISTS (
    SELECT 1 FROM @tvf
    WHERE (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, fn + N';', N''))) / DATALENGTH(fn + N';') <> 1
)
BEGIN
    RAISERROR('pProcessGetJobList: text to roll back not found exactly once - not changed.', 16, 1);
    RETURN;
END

DECLARE @fn NVARCHAR(100) = (SELECT MIN(fn) FROM @tvf);
WHILE @fn IS NOT NULL
BEGIN
    SET @d  = REPLACE(@d, @fn + N';', @fn + @hint);
    SET @fn = (SELECT MIN(fn) FROM @tvf WHERE fn > @fn);
END

SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList rolled back (94_: KEEPFIXED PLAN restored on 8 TVF INSERTs).';

IF CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(@proc))), 2)
   <> '88E2528B63D5330EA6338C3C7D29DECF002B62D11F86854C59C8BC021926589A'
    PRINT 'WARNING: definition differs from the one before 94 (proc was changed elsewhere since).';
GO
