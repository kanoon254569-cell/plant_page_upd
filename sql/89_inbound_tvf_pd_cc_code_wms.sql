-- =============================================================
-- 89_inbound_tvf_pd_cc_code_wms.sql  (IRPC_QTRACK)
-- =============================================================
-- sql/88 made the Product CC filter of pProcessGetJobList look up
-- from_cc_code_wms with one correlated subquery per job row, against
-- IRPC_E_TRANSFER VTransferSlip / VReceiveForm. Those views are
-- already joined inside the Inbound job TVFs, so the lookup belongs
-- there, at no extra cost.
--
-- Change (89):
--   1. fTransferSlipJob: pd_cc_code = product_cc (set on Approve), else
--      the item's from_cc_code_wms (was: product_cc only).
--   2. fReceiveJob: pd_cc_code = the item's from_cc_code_wms (was: NULL).
--   3. pProcessGetJobList: sql/88's CASE ... END subqueries removed; the
--      filter is COALESCE(product_cc, pd_cc_code) again, with pd_cc_code
--      now filled by 1/2. NULLIF on pd_cc_code from sql/88 stays.
--
-- Other users of the TVFs' pd_cc_code: the API's JobService
-- (GET process/job) uses it as the cost center when it picks a WMS
-- grade master; an RC job / Pending TS job now passes its WMS CC there
-- instead of an empty one. pProcessGetForkliftJobs only carries the
-- column. pProcessInboundPutAway, pServiceGetGradeForMatching,
-- vReceiveJob, vTransferSlipJob don't read it.
--
-- Patched from the live definitions with REPLACE (same way as sql/83):
-- each piece must be found exactly once, else that object is not
-- changed. Idempotent: each object is skipped when already patched.
--
-- Rollback:
--   fTransferSlipJob: pd_cc_code back to
--     "jm.product_cc COLLATE Thai_CI_AI AS pd_cc_code,"
--   fReceiveJob: pd_cc_code back to
--     "CAST(NULL AS VARCHAR(50)) COLLATE Thai_CI_AI AS pd_cc_code,"
--   pProcessGetJobList: re-run sql/88.
-- =============================================================
USE IRPC_QTRACK;
GO

--  1. fTransferSlipJob
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.fTransferSlipJob'));

IF @d LIKE N'%from_cc_code_wms%'
BEGIN
    PRINT 'fTransferSlipJob already has the from_cc_code_wms fallback - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'    jm.product_cc COLLATE Thai_CI_AI AS pd_cc_code,';
DECLARE @n1 NVARCHAR(400) = N'    COALESCE(NULLIF(TRIM(jm.product_cc COLLATE Thai_CI_AI), ''''), ts.from_cc_code_wms COLLATE Thai_CI_AI) AS pd_cc_code,';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('fTransferSlipJob: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'fTransferSlipJob patched (pd_cc_code falls back to from_cc_code_wms).';
GO

--  2. fReceiveJob
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.fReceiveJob'));

IF @d LIKE N'%from_cc_code_wms%'
BEGIN
    PRINT 'fReceiveJob already has the from_cc_code_wms pd_cc_code - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'    CAST(NULL AS VARCHAR(50)) COLLATE Thai_CI_AI AS pd_cc_code,';
DECLARE @n1 NVARCHAR(400) = N'    CAST(rf.from_cc_code_wms AS VARCHAR(50)) COLLATE Thai_CI_AI AS pd_cc_code,';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('fReceiveJob: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'fReceiveJob patched (pd_cc_code = from_cc_code_wms).';
GO

--  3. pProcessGetJobList: drop sql/88's subqueries
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d NOT LIKE N'%from_cc_code_wms%'
BEGIN
    PRINT 'pProcessGetJobList has no sql/88 subqueries - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(MAX) = N'            NULLIF(LTRIM(RTRIM(dj.pd_cc_code COLLATE DATABASE_DEFAULT)), ''''),' + @nl
    + N'            --  sql/88: Pending TS/RC jobs have no product_cc yet -- use the' + @nl
    + N'            --  item''s WMS CC, which approved jobs always carry as product_cc.' + @nl
    + N'            CASE dj.job_type_id' + @nl
    + N'                WHEN 1 THEN (SELECT TOP 1 ts.from_cc_code_wms COLLATE DATABASE_DEFAULT' + @nl
    + N'                             FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts' + @nl
    + N'                             WHERE ts.header_id = dj.header_id AND ts.item_id = dj.item_id)' + @nl
    + N'                WHEN 2 THEN (SELECT TOP 1 rc.from_cc_code_wms COLLATE DATABASE_DEFAULT' + @nl
    + N'                             FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc' + @nl
    + N'                             WHERE rc.header_id = dj.header_id AND rc.item_id = dj.item_id)' + @nl
    + N'            END' + @nl
    + N'        ))) AS product_cc';
DECLARE @n1 NVARCHAR(MAX) = N'            --  pd_cc_code: Inbound TVFs fall back to the item''s WMS CC (sql/89).' + @nl
    + N'            NULLIF(LTRIM(RTRIM(dj.pd_cc_code COLLATE DATABASE_DEFAULT)), '''')' + @nl
    + N'        ))) AS product_cc';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched (sql/88 subqueries removed).';
GO
