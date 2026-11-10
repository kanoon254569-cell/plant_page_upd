-- =============================================================
-- 95_rollback_inbound_get_put.sql  (IRPC_QTRACK)
-- =============================================================
-- Rollback of 95_inbound_get_put_drop_vJobMain.sql: puts the dbo.vJobMain
-- statements back in pProcessInboundGetPallet / pProcessInboundPutAway
-- with the reverse REPLACE. Every piece must be found exactly once, else
-- nothing is changed. Skipped when the 95_ marker is not in the proc.
-- Afterwards the text is checked against the definition before 95:
--   pProcessInboundGetPallet  64549E7D4DB7AA37F8090C31C2B5AC6053B37CABAC48812C7E5F207B36AFF8CD
--   pProcessInboundPutAway    3BE91D5FEEEE78C88FBBAF25133F71E65A5B240989ECA9F30929B8152E5DAE98
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
DECLARE @o1 NVARCHAR(MAX) = REPLACE(N'	--  95: the job/item check runs on the base tables for the inbound job
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
DECLARE @n1 NVARCHAR(MAX) = REPLACE(N'	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT ''error'' AS status, N''ไม่พบข้อมูลของงานในระบบ'' AS message;
		RETURN;
	END
', NCHAR(13) + @lf, @lf);
DECLARE @o2 NVARCHAR(MAX) = REPLACE(N'	--  95: the job passed the vJobMain-equivalent check above, so its
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
DECLARE @n2 NVARCHAR(MAX) = REPLACE(N'	SELECT @job_type_id = job_type_id FROM dbo.vJobMain WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id AND p.is_active = ''Y'' AND p.status_flag = ''A'';
', NCHAR(13) + @lf, @lf);

IF @d IS NULL
BEGIN
    RAISERROR('pProcessInboundGetPallet: not found in this database (run it in IRPC_QTRACK) - not changed.', 16, 1);
    RETURN;
END

IF @d NOT LIKE N'%--  95:%'
BEGIN
    PRINT 'pProcessInboundGetPallet has no 95_ patch - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
   OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
BEGIN
    RAISERROR('pProcessInboundGetPallet: text to roll back not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessInboundGetPallet rolled back (95_).';
IF CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(@proc))), 2) <> '64549E7D4DB7AA37F8090C31C2B5AC6053B37CABAC48812C7E5F207B36AFF8CD'
    PRINT 'NOTE: pProcessInboundGetPallet text differs from the pre-95 definition (changed elsewhere since 95?).';
GO

DECLARE @proc SYSNAME       = N'dbo.pProcessInboundPutAway';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @lf   NCHAR(1)      = NCHAR(10);
DECLARE @o1 NVARCHAR(MAX) = REPLACE(N'	--  95: the job/item check runs on the base tables for the inbound job
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
DECLARE @n1 NVARCHAR(MAX) = REPLACE(N'	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
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

IF @d NOT LIKE N'%--  95:%'
BEGIN
    PRINT 'pProcessInboundPutAway has no 95_ patch - skipped.';
    RETURN;
END

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pProcessInboundPutAway: text to roll back not found exactly once - not changed.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessInboundPutAway rolled back (95_).';
IF CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', OBJECT_DEFINITION(OBJECT_ID(@proc))), 2) <> '3BE91D5FEEEE78C88FBBAF25133F71E65A5B240989ECA9F30929B8152E5DAE98'
    PRINT 'NOTE: pProcessInboundPutAway text differs from the pre-95 definition (changed elsewhere since 95?).';
GO
