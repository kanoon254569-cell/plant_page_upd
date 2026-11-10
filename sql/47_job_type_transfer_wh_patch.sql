-- =============================================================
-- 47_job_type_transfer_wh_patch.sql  (IRPC_QTRACK)
-- =============================================================
-- Wires job type 11 'TW' (Transfer WH, sql/46) into every object that
-- already handles RC (2), next to the RC line:
--
--   vJobMain                    LEFT JOIN VTransferWhForm tw (type 11),
--                               tw.item_id / tw.from_plant_cc_code in COALESCE
--   fManualPallets              @job_type = 11 branch (VTransferWhForm)
--   pProcessApproveJob          to-location required for 11 too
--   pProcessInboundPutAway      fTransferWhPallets / vTransferWhJob in the
--                               job-complete check
--   pServiceGetGradeForMatching grades of open TW jobs
--   pProcessGetJobList          fTransferWhJob (gated by inbound_receive)
--   pProcessGetForkliftJobs     fTransferWhJob (gated by inbound_receive),
--                               fTransferWhPallets, scan_qty for 11
--
-- Permission: VRolePermission has no column for TW, so TW jobs follow the
-- role's inbound_receive flag.
--
-- Not changed: pWmsPlus_InboundApprove / pWmsPlus_InboundGetPutAway. They
-- only have TS/RC branches and TW falls to the "no WMS+ interface" branch
-- (Approve) or returns nothing (GetPutAway). Add TW branches there only
-- after the backend knows what to send WMS+ for a TW job.
--
-- Each object is patched from its live definition with REPLACE (the same
-- way as sql/44): every piece must be found exactly once, else that object
-- is not changed. Idempotent: an object that already mentions TW is
-- skipped. Line breaks follow the live text (CRLF or LF).
--
-- Needs 46_job_type_transfer_wh.sql deployed first.
-- =============================================================
USE IRPC_QTRACK;
GO

-- -------------------------------------------------------------
-- vJobMain
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.vJobMain'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%VTransferWhForm%'
BEGIN
    PRINT 'vJobMain already has TW - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'LEFT JOIN IRPC_E_TRANSFER.dbo.VRequestForm AS rq ON jm.job_type_id = 3 AND rq.header_id = jm.interface_job_id';
DECLARE @n1 NVARCHAR(400) = @o1 + @nl
    + N'LEFT JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm AS tw ON jm.job_type_id = 11 AND tw.header_id = jm.interface_job_id';
DECLARE @o2 NVARCHAR(400) = N'COALESCE(ts.item_id, rc.item_id, rq.item_id,';
DECLARE @n2 NVARCHAR(400) = N'COALESCE(ts.item_id, rc.item_id, rq.item_id, tw.item_id,';
DECLARE @o3 NVARCHAR(400) = N'COALESCE(ts.from_plant_cc_code, rc.from_plant_cc_code, rq.from_plant_cc_code,';
DECLARE @n3 NVARCHAR(400) = N'COALESCE(ts.from_plant_cc_code, rc.from_plant_cc_code, rq.from_plant_cc_code, tw.from_plant_cc_code,';

IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o3, N''))) / LEN(@o3) <> 1
BEGIN
    RAISERROR('vJobMain: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'vJobMain patched: TW (11).';
GO

-- -------------------------------------------------------------
-- fManualPallets
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.fManualPallets'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%VTransferWhForm%'
BEGIN
    PRINT 'fManualPallets already has TW - skipped.';
    RETURN;
END

-- total_pallet is not read by the function's output, and VTransferWhForm has no such column
DECLARE @o1 NVARCHAR(400) = N'WHERE @job_type = 1 AND item_id = @item_id';
DECLARE @n1 NVARCHAR(MAX) = @o1 + @nl + @nl
    + N'        UNION ALL' + @nl + @nl
    + N'        SELECT item_id, grade COLLATE Thai_CI_AI AS grade, lot_no COLLATE Thai_CI_AI AS lot, qty, CAST(NULL AS INT) AS total_pallet' + @nl
    + N'        FROM IRPC_E_TRANSFER.dbo.VTransferWhForm' + @nl
    + N'        WHERE @job_type = 11 AND item_id = @item_id';

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('fManualPallets: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'fManualPallets patched: TW (11).';
GO

-- -------------------------------------------------------------
-- pProcessApproveJob
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessApproveJob'));

DECLARE @o1 NVARCHAR(400) = N'@job_type_id IN (1, 2, 3, 5)';
DECLARE @n1 NVARCHAR(400) = N'@job_type_id IN (1, 2, 3, 5, 11)';

IF @d LIKE N'%@job_type_id IN (1, 2, 3, 5, 11)%'
BEGIN
    PRINT 'pProcessApproveJob already has TW - skipped.';
    RETURN;
END

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('pProcessApproveJob: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessApproveJob patched: TW (11).';
GO

-- -------------------------------------------------------------
-- pProcessInboundPutAway
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessInboundPutAway'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);
DECLARE @t3 NCHAR(3)      = REPLICATE(NCHAR(9), 3);

IF @d LIKE N'%TransferWh%'
BEGIN
    PRINT 'pProcessInboundPutAway already has TW - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'SELECT * FROM dbo.fReceivePallets(@job_main_id)';
DECLARE @n1 NVARCHAR(400) = @o1 + @nl
    + @t3 + N'UNION ALL' + @nl
    + @t3 + N'SELECT * FROM dbo.fTransferWhPallets(@job_main_id)';
DECLARE @o2 NVARCHAR(400) = N'SELECT DISTINCT id, item_id, total_qty FROM [dbo].[vReceiveJob] WHERE id = @job_main_id';
DECLARE @n2 NVARCHAR(400) = @o2 + @nl
    + @t3 + N'UNION ALL' + @nl
    + @t3 + N'SELECT DISTINCT id, item_id, total_qty FROM [dbo].[vTransferWhJob] WHERE id = @job_main_id';

IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway patched: TW (11).';
GO

-- -------------------------------------------------------------
-- pServiceGetGradeForMatching
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pServiceGetGradeForMatching'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%fTransferWhJob%'
BEGIN
    PRINT 'pServiceGetGradeForMatching already has TW - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'SELECT grade, job_status_id FROM dbo.fReceiveJob(NULL, NULL)';
DECLARE @n1 NVARCHAR(400) = @o1 + @nl
    + N'                UNION ALL' + @nl
    + N'                SELECT grade, job_status_id FROM dbo.fTransferWhJob(NULL, NULL)';

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('pServiceGetGradeForMatching: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pServiceGetGradeForMatching patched: TW (11).';
GO

-- -------------------------------------------------------------
-- pProcessGetJobList
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%fTransferWhJob%'
BEGIN
    PRINT 'pProcessGetJobList already has TW - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'SELECT * FROM dbo.fReceiveJob(@id, @date) WHERE (@inbound_receive = ''Y'') AND (@type_id IS NULL OR @type_id = 2)';
DECLARE @n1 NVARCHAR(400) = @o1 + @nl
    + N'        UNION ALL' + @nl
    + N'        SELECT * FROM dbo.fTransferWhJob(@id, @date) WHERE (@inbound_receive = ''Y'') AND (@type_id IS NULL OR @type_id = 11)';

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched: TW (11).';
GO

-- -------------------------------------------------------------
-- pProcessGetForkliftJobs
-- -------------------------------------------------------------
DECLARE @d  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetForkliftJobs'));
DECLARE @nl NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%TransferWh%'
BEGIN
    PRINT 'pProcessGetForkliftJobs already has TW - skipped.';
    RETURN;
END

-- 1) jobs
DECLARE @o1 NVARCHAR(400) =
      N'        SELECT * FROM dbo.fReceiveJob(NULL, @dateJob) v' + @nl
    + N'        WHERE @inbound_receive = ''Y''';
DECLARE @n1 NVARCHAR(MAX) = @o1 + @nl
    + N'        UNION ALL' + @nl
    + N'        SELECT * FROM dbo.fTransferWhJob(NULL, @dateJob) v' + @nl
    + N'        WHERE @inbound_receive = ''Y''';

-- 2) pallets (same column list as the fReceivePallets block)
DECLARE @o2 NVARCHAR(400) = N'        CROSS APPLY dbo.fReceivePallets(fj.id) v';
DECLARE @n2 NVARCHAR(MAX) = @o2 + @nl
    + N'        UNION ALL' + @nl
    + N'        SELECT' + @nl
    + N'            v.job_main_id,' + @nl
    + N'            v.job_item_id,' + @nl
    + N'            v.pallet_id,' + @nl
    + N'            NULL AS bag_id,' + @nl
    + N'            NULL AS pallet_seq,' + @nl
    + N'            v.unit_pallet,' + @nl
    + N'            v.unit_ratio,' + @nl
    + N'            v.grade,' + @nl
    + N'            v.lot,' + @nl
    + N'            v.bag_count,' + @nl
    + N'            v.qty,' + @nl
    + N'            v.is_prepare,' + @nl
    + N'            v.is_received,' + @nl
    + N'            v.is_complete' + @nl
    + N'        FROM (SELECT DISTINCT id FROM #filter_jobs) fj' + @nl
    + N'        CROSS APPLY dbo.fTransferWhPallets(fj.id) v';

-- 3) scan_qty (pallet scan setting) for inbound pallet types
DECLARE @o3 NVARCHAR(400) = N'CASE WHEN ism.job_type_id IN (1, 2) THEN sps.scan_qty ELSE 1 END';
DECLARE @n3 NVARCHAR(400) = N'CASE WHEN ism.job_type_id IN (1, 2, 11) THEN sps.scan_qty ELSE 1 END';

IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
  OR (LEN(@d) - LEN(REPLACE(@d, @o3, N''))) / LEN(@o3) <> 1
BEGIN
    RAISERROR('pProcessGetForkliftJobs: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetForkliftJobs patched: TW (11).';
GO
