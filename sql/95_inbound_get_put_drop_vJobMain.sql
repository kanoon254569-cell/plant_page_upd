-- =============================================================
-- 95_inbound_get_put_drop_vJobMain.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessInboundGetPallet / pProcessInboundPutAway: stop using
-- dbo.vJobMain for the TS (1) / RC (2) jobs.
--
-- Cause (measured on .75, 2026-10-26, job 75 / item 134610):
--   Running is fast (vJobMain check 0-3 ms, fGetPalletQty 2 ms), but a
--   statement on vJobMain costs 0.9-1.9 s to COMPILE (~0.9 s CPU; the
--   very first one 8.9 s): the view expands into 10 form views, 4 of them
--   in IRPC_E_TRANSFER. GetPallet has 3 such statements, PutAway 1.
--   The plan cache keeps these procs only for a few hours (PLE ~40 s,
--   10 procs of this DB cached; neither proc was in cache when checked),
--   so the first scan after an idle spell paid ~3-5 s (Get) and
--   ~1.5-2.5 s (Put).
--
-- Change (job types 1 and 2 only; every other type runs the old vJobMain
-- statement through sp_executesql, so it is compiled only when used):
--   1. both procs: "job + item exists in vJobMain" -> the same test on
--      tr_job_main + ct_job_type + ct_job_status + VTransferSlip (TS) /
--      VReceiveForm (RC). Compile measured ~50 ms instead of ~1 s.
--   2. GetPallet: @job_type_id from tr_job_main (the job passed check 1,
--      so its vJobMain job_type_id is tr_job_main.job_type_id).
--   3. GetPallet: the pallet's current job type. It only changes the
--      result when it equals this job's type, so for TS / RC it is read
--      from tr_job_main with the vJobMain filters (flags + the job has an
--      item) and only when it is the same type.
--   Messages, result sets, writes and their order are unchanged.
--
-- Same results: sql/95_compare_inbound_vJobMain.sql (read only) compares
-- old and new for every job / item / pallet.
--
-- SHA-256 of OBJECT_DEFINITION before 95 (NVARCHAR):
--   pProcessInboundGetPallet  64549E7D4DB7AA37F8090C31C2B5AC6053B37CABAC48812C7E5F207B36AFF8CD
--   pProcessInboundPutAway    3BE91D5FEEEE78C88FBBAF25133F71E65A5B240989ECA9F30929B8152E5DAE98
--
-- Patched from the live definition with REPLACE (same way as sql/93):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the 95_ marker is already in the proc.
-- Rollback: sql/95_rollback_inbound_get_put.sql (reverse REPLACE).
-- =============================================================
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessInboundGetPallet';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @lf   NCHAR(1)      = NCHAR(10);
DECLARE @o1 NVARCHAR(MAX) = REPLACE(N'	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT ''error'' AS status, N''ไม่พบข้อมูลของงานในระบบ'' AS message;
		RETURN;
	END
', NCHAR(13) + @lf, @lf);
DECLARE @n1 NVARCHAR(MAX) = REPLACE(N'	--  95: the job/item check runs on the base tables for the inbound job
	--  types (1 = TS, 2 = RC) instead of dbo.vJobMain: compiling a vJobMain
	--  statement costs ~1 s CPU, and this proc''s plan is often evicted.
	--  Same rows as vJobMain: job, job type and job status flags, and the
	--  item is in the job''s form view. Other job types keep the vJobMain
	--  check through sp_executesql, so it is compiled only when used.
	DECLARE @job_item_ok BIT = 0;

	IF EXISTS (SELECT 1 FROM dbo.tr_job_main WHERE id = @job_main_id AND job_type_id IN (1, 2))
	BEGIN
		IF EXISTS (
			SELECT 1
			FROM dbo.tr_job_main jm
			LEFT JOIN dbo.ct_job_type jt ON jt.id = jm.job_type_id
			LEFT JOIN dbo.ct_job_status js ON js.id = jm.job_status_id
			WHERE jm.id = @job_main_id
			  AND (jm.status_flag IS NULL OR jm.status_flag = ''A'') AND (jm.is_active IS NULL OR jm.is_active = ''Y'')
			  AND (jt.is_active IS NULL OR jt.is_active = ''Y'') AND (js.is_active IS NULL OR js.is_active = ''Y'')
			  AND (jt.status_flag IS NULL OR jt.status_flag = ''A'') AND (js.status_flag IS NULL OR js.status_flag = ''A'')
			  AND (   (jm.job_type_id = 1 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts
			                                       WHERE ts.header_id = jm.interface_job_id AND ts.item_id = @job_item_id))
			       OR (jm.job_type_id = 2 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc
			                                       WHERE rc.header_id = jm.interface_job_id AND rc.item_id = @job_item_id)))
		)
			SET @job_item_ok = 1;
	END
	ELSE
		EXEC sp_executesql
			N''IF EXISTS (SELECT 1 FROM dbo.vJobMain WHERE id = @job_main_id AND item_id = @job_item_id) SET @job_item_ok = 1;'',
			N''@job_main_id INT, @job_item_id INT, @job_item_ok BIT OUTPUT'',
			@job_main_id, @job_item_id, @job_item_ok OUTPUT;

	IF @job_item_ok = 0
	BEGIN
		SELECT ''error'' AS status, N''ไม่พบข้อมูลของงานในระบบ'' AS message;
		RETURN;
	END
', NCHAR(13) + @lf, @lf);
DECLARE @o2 NVARCHAR(MAX) = REPLACE(N'	SELECT @job_type_id = job_type_id FROM dbo.vJobMain WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id AND p.is_active = ''Y'' AND p.status_flag = ''A'';
', NCHAR(13) + @lf, @lf);
DECLARE @n2 NVARCHAR(MAX) = REPLACE(N'	--  95: the job passed the vJobMain-equivalent check above, so its
	--  vJobMain job_type_id is tr_job_main.job_type_id.
	SELECT @job_type_id = job_type_id FROM dbo.tr_job_main WHERE id = @job_main_id;

	--  95: the pallet''s current job counts only when it is in vJobMain (job,
	--  type and status flags, and the job has at least one item). It only
	--  matters when it has the same type as this job, so for TS / RC the
	--  check is made on the base tables; other types use vJobMain as before
	--  through sp_executesql.
	IF @job_type_id IN (1, 2)
	BEGIN
		SELECT @current_job_type_id = jm.job_type_id
		FROM dbo.tr_pallet p
		INNER JOIN dbo.tr_job_main jm ON jm.id = p.current_job_id
		LEFT JOIN dbo.ct_job_type jt ON jt.id = jm.job_type_id
		LEFT JOIN dbo.ct_job_status js ON js.id = jm.job_status_id
		WHERE p.id = @pallet_id AND p.is_active = ''Y'' AND p.status_flag = ''A''
		  AND jm.job_type_id = @job_type_id
		  AND (jm.status_flag IS NULL OR jm.status_flag = ''A'') AND (jm.is_active IS NULL OR jm.is_active = ''Y'')
		  AND (jt.is_active IS NULL OR jt.is_active = ''Y'') AND (js.is_active IS NULL OR js.is_active = ''Y'')
		  AND (jt.status_flag IS NULL OR jt.status_flag = ''A'') AND (js.status_flag IS NULL OR js.status_flag = ''A'')
		  AND (   (jm.job_type_id = 1 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts
		                                       WHERE ts.header_id = jm.interface_job_id AND ts.item_id IS NOT NULL))
		       OR (jm.job_type_id = 2 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc
		                                       WHERE rc.header_id = jm.interface_job_id AND rc.item_id IS NOT NULL)));
	END
	ELSE
		EXEC sp_executesql
			N''SELECT @current_job_type_id = jm.job_type_id
			  FROM dbo.tr_pallet p
			  INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
			  WHERE p.id = @pallet_id AND p.is_active = ''''Y'''' AND p.status_flag = ''''A'''';'',
			N''@pallet_id INT, @current_job_type_id INT OUTPUT'',
			@pallet_id, @current_job_type_id OUTPUT;
', NCHAR(13) + @lf, @lf);

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundGetPallet: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF @d LIKE N'%--  95:%'
BEGIN
    PRINT 'pProcessInboundGetPallet is already patched (95_) - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
   OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
BEGIN
    RAISERROR('pProcessInboundGetPallet: text to patch not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessInboundGetPallet patched (95_: vJobMain replaced).';
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessInboundPutAway';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @lf   NCHAR(1)      = NCHAR(10);
DECLARE @o1 NVARCHAR(MAX) = REPLACE(N'	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT ''error'' AS status, N''ไม่พบข้อมูลของงานในระบบ'' AS message;;
		RETURN;
	END
', NCHAR(13) + @lf, @lf);
DECLARE @n1 NVARCHAR(MAX) = REPLACE(N'	--  95: the job/item check runs on the base tables for the inbound job
	--  types (1 = TS, 2 = RC) instead of dbo.vJobMain: compiling a vJobMain
	--  statement costs ~1 s CPU, and this proc''s plan is often evicted.
	--  Same rows as vJobMain: job, job type and job status flags, and the
	--  item is in the job''s form view. Other job types keep the vJobMain
	--  check through sp_executesql, so it is compiled only when used.
	DECLARE @job_item_ok BIT = 0;

	IF EXISTS (SELECT 1 FROM dbo.tr_job_main WHERE id = @job_main_id AND job_type_id IN (1, 2))
	BEGIN
		IF EXISTS (
			SELECT 1
			FROM dbo.tr_job_main jm
			LEFT JOIN dbo.ct_job_type jt ON jt.id = jm.job_type_id
			LEFT JOIN dbo.ct_job_status js ON js.id = jm.job_status_id
			WHERE jm.id = @job_main_id
			  AND (jm.status_flag IS NULL OR jm.status_flag = ''A'') AND (jm.is_active IS NULL OR jm.is_active = ''Y'')
			  AND (jt.is_active IS NULL OR jt.is_active = ''Y'') AND (js.is_active IS NULL OR js.is_active = ''Y'')
			  AND (jt.status_flag IS NULL OR jt.status_flag = ''A'') AND (js.status_flag IS NULL OR js.status_flag = ''A'')
			  AND (   (jm.job_type_id = 1 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts
			                                       WHERE ts.header_id = jm.interface_job_id AND ts.item_id = @job_item_id))
			       OR (jm.job_type_id = 2 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc
			                                       WHERE rc.header_id = jm.interface_job_id AND rc.item_id = @job_item_id)))
		)
			SET @job_item_ok = 1;
	END
	ELSE
		EXEC sp_executesql
			N''IF EXISTS (SELECT 1 FROM dbo.vJobMain WHERE id = @job_main_id AND item_id = @job_item_id) SET @job_item_ok = 1;'',
			N''@job_main_id INT, @job_item_id INT, @job_item_ok BIT OUTPUT'',
			@job_main_id, @job_item_id, @job_item_ok OUTPUT;

	IF @job_item_ok = 0
	BEGIN
		SELECT ''error'' AS status, N''ไม่พบข้อมูลของงานในระบบ'' AS message;;
		RETURN;
	END
', NCHAR(13) + @lf, @lf);

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundPutAway: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF @d LIKE N'%--  95:%'
BEGIN
    PRINT 'pProcessInboundPutAway is already patched (95_) - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: text to patch not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway patched (95_: vJobMain replaced).';
GO
