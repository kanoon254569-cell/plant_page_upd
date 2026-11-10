-- =============================================================
-- 88_pProcessGetJobList_product_cc_wms_fallback.sql  (IRPC_QTRACK)
-- =============================================================
-- GET api/v1/process/job?topicName=Inbound&statusIds=1&productCcs=...
-- returned nothing, though Pending Inbound jobs exist.
--
-- Cause: the Product CC filter (#filter_product_cc_jobs) matches
-- COALESCE(tr_job_main.product_cc, pd_cc_code). product_cc is set
-- only on Approve, and for Inbound pd_cc_code is no help:
-- fTransferSlipJob returns jm.product_cc again, fReceiveJob returns
-- NULL. So a Pending (1) TS/RC job never had a Product CC to match.
--
-- Change (88): third fallback = from_cc_code_wms of the job's item in
-- IRPC_E_TRANSFER VTransferSlip (TS, type 1) / VReceiveForm (RC,
-- type 2). On IRPC_QTRACK (2026-10-25) every approved TS/RC job's
-- product_cc equals that column, so it's the CC the job is normally
-- approved with. Jobs that already have product_cc are unchanged.
-- Only the filter changes: the TVFs (also used by pProcessGetForkliftJobs,
-- pProcessInboundPutAway, ...) and the returned columns stay as they are.
--
-- Patched from the live definition with REPLACE (same way as sql/83):
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when from_cc_code_wms is already there.
--
-- Rollback: remove the "--  sql/88" comment and the CASE ... END
-- lines and the extra NULLIF/LTRIM/RTRIM around dj.pd_cc_code (back to
-- "dj.pd_cc_code COLLATE DATABASE_DEFAULT").
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%from_cc_code_wms%'
BEGIN
    PRINT 'pProcessGetJobList already has the from_cc_code_wms fallback - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'            dj.pd_cc_code COLLATE DATABASE_DEFAULT' + @nl
    + N'        ))) AS product_cc';
DECLARE @n1 NVARCHAR(MAX) = N'            NULLIF(LTRIM(RTRIM(dj.pd_cc_code COLLATE DATABASE_DEFAULT)), ''''),' + @nl
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

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched (Product CC filter falls back to from_cc_code_wms).';
GO
