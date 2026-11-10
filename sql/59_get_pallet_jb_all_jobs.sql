-- =============================================================
-- 59_get_pallet_jb_all_jobs.sql  (IRPC_QTRACK)
-- =============================================================
-- JB pallet + bag auto-create on first scan, for the Get of every job type.
--
-- Before: only pProcessInboundGetPallet (41) and pProcessPickingGetPallet
-- called dbo.pProcessInsertJbPalletBag (42 / 56). Scanning a JB bag that was
-- never scanned before in any other job's Get failed with
-- 'Invalid QR code format.' (no tr_bag / tr_pallet for it yet).
--
-- Now the same call is added to the Get of:
--   pProcessRequestGetPallet          (request/get-pallet)
--   pProcessInternalTransferGetPallet (internal-transfer/get-pallet)
--   pProcessShippingGetPallet         (shipping/get-pallet)
--   pProcessLoadingGetPallet          (loading/get-pallet)
--   pProcessSpecialGetPallet          (special/get-pallet)
--   pProcessBrokenBagGetPallet        (broken-bag get-pallet)
--
-- Inserted right after the parameter checks, before the QR lookup
-- (fQrCodeToPalletBag). It runs only when the job and job item exist, so a
-- JB pallet is never created for a job that does not exist (same rule as
-- inbound 41). An 'error' from pProcessInsertJbPalletBag (busy, JB pallet /
-- bag created before but inactive, bag on another pallet) is returned as
-- the scan result. Normal (A) bags and pallet_no QRs: 'skip', original flow.
--
-- Everything else in each proc is the live definition of 2026-10-01,
-- unchanged. Needs 55 + 56.
-- =============================================================
GO
-- -------------------------------------------------------------
-- pProcessRequestGetPallet
-- -------------------------------------------------------------
-- ---------------------------------------------
-- pProcessRequestGetPallet
-- ---------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessRequestGetPallet]
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@pallet_seq			INT				= NULL,
	@mode_id			INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	DECLARE @job_type_id INT;
	DECLARE @current_job_type_id INT;
	DECLARE @current_job_id INT;

	SELECT @job_type_id = job_type_id FROM dbo.vJobMain WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id, @current_job_id = p.current_job_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

	--	Same-job-type guard; scanning more bags of a pallet already in THIS job is allowed
	IF @job_item_id IS NOT NULL
	   AND @current_job_type_id IS NOT NULL
	   AND @job_type_id = @current_job_type_id
	   AND @current_job_id <> @job_main_id
	BEGIN
		SELECT 'error' AS status, 'Pallet is already assigned to a job with the same job type.' AS message;
		RETURN;
	END;

	--	Legacy caller (single qrCode, no mode): one scan = the whole pallet, as before (pallet or bag QR)
	IF @mode_id IS NULL
		SET @mode_id = 1;

	--	Already scanned in this job (Get or Put, still active): reset first to scan again
	IF @mode_id = 1 AND EXISTS (
		SELECT 1 FROM dbo.tr_pallet_history
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND process_id IN (1, 2) AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet is already scanned in this job.' AS message;
		RETURN;
	END

	IF @mode_id NOT IN (1, 2) AND EXISTS (
		SELECT 1 FROM dbo.tr_pallet_history
		WHERE job_main_id = @job_main_id AND bag_id = @bag_id
		  AND process_id IN (1, 2) AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Bag is already scanned in this job.' AS message;
		RETURN;
	END

	DECLARE @unit_ratio INT;

	SELECT @unit_ratio = p.unit_ratio
	FROM dbo.tr_pallet p
	WHERE p.id = @pallet_id
	  AND p.is_active = 'Y'
	  AND p.status_flag = 'A';

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_job_main WHERE job_status_id = 4 AND id = @job_main_id
	)
	BEGIN
		UPDATE dbo.tr_job_main
		SET job_status_id = 4, start_datetime = GETDATE(),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE id = @job_main_id;
	END

	UPDATE dbo.tr_pallet
	SET current_job_id = @job_main_id,
		current_job_item_id = @job_item_id,
		current_location_id = @location_id,
		current_location_type = @location_type,
		update_user_id = @user_id,
		update_datetime = GETDATE()
	WHERE id = @pallet_id;

	DECLARE @add_qty INT;

	IF @mode_id = 1
	BEGIN
		--	Full pallet: one Get row per bag
		INSERT INTO dbo.tr_pallet_history (
			job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
			location_id, location_type, create_user_id, create_datetime,
			update_user_id, update_datetime
		)
		SELECT
			@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
			@location_id, @location_type, @user_id, GETDATE(),
			@user_id, GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A';

		SET @add_qty = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);
	END
	ELSE IF @mode_id = 2
	BEGIN
		--	Store bag: the scanned bag stays (process 4), the rest of the pallet is taken
		IF NOT EXISTS (
			SELECT 1 FROM dbo.tr_pallet_history
			WHERE job_main_id = @job_main_id
			  AND job_item_id = @job_item_id
			  AND bag_id = @bag_id
			  AND process_id = 4
		)
		BEGIN
			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			VALUES (
				@job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			);
		END

		DECLARE @newly_processed TABLE (bag_id INT);

		INSERT INTO dbo.tr_pallet_history (
			job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
			location_id, location_type, create_user_id, create_datetime,
			update_user_id, update_datetime
		)
		OUTPUT INSERTED.bag_id INTO @newly_processed(bag_id)
		SELECT
			@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
			@location_id, @location_type, @user_id, GETDATE(),
			@user_id, GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A'
		  AND NOT EXISTS (
			  SELECT 1 FROM dbo.tr_pallet_history ph
			  WHERE ph.job_main_id = @job_main_id
				AND ph.job_item_id = @job_item_id
				AND ph.bag_id = b.id
				AND ph.process_id IN (1, 4)
		  );

		DECLARE @newly_processed_count INT = (SELECT COUNT(*) FROM @newly_processed);

		SET @add_qty = ISNULL(@newly_processed_count, 0) * ISNULL(@unit_ratio, 0);
	END
	ELSE
	BEGIN
		--	Single bag
		INSERT INTO dbo.tr_pallet_history (
			job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
			location_id, location_type, create_user_id, create_datetime,
			update_user_id, update_datetime
		)
		VALUES (
			@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
			@location_id, @location_type, @user_id, GETDATE(),
			@user_id, GETDATE()
		);

		SET @add_qty = ISNULL(@unit_ratio, 0);
	END

	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_from_location
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id
		  AND from_location_id = @location_id AND ISNULL(qty, 0) <> 0
		  AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		UPDATE dbo.tr_job_from_location
		SET actual_qty = ISNULL(actual_qty, 0) + ISNULL(@add_qty, 0),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id AND from_location_id = @location_id
	END

	--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message, @pallet_seq AS pallet_seq;
END
GO

-- -------------------------------------------------------------
-- pProcessInternalTransferGetPallet
-- -------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessInternalTransferGetPallet]
	@qr_code_text		VARCHAR(100)	= NULL,
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@pallet_seq			INT				= NULL,
	@mode_id			INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	DECLARE @unit_ratio INT;

	SELECT @unit_ratio = p.unit_ratio
	FROM dbo.tr_pallet p
	WHERE p.id = @pallet_id
	  AND p.is_active = 'Y'
	  AND p.status_flag = 'A';

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE id = @job_main_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.vJobMain
		WHERE id = @job_main_id
		  AND item_id = @job_item_id

	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_pallet
		WHERE id = @pallet_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE job_status_id = 4 AND id = @job_main_id
	)
	BEGIN
		UPDATE dbo.tr_job_main
		SET job_status_id = 4,
			start_datetime = GETDATE(),
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE id = @job_main_id;
	END

	UPDATE dbo.tr_pallet
	SET current_job_id = @job_main_id,
		current_job_item_id = @job_item_id,
		current_location_id = @location_id,
		current_location_type = @location_type,
		update_user_id = @user_id,
		update_datetime = GETDATE()
	WHERE id = @pallet_id;

	DECLARE @add_qty INT;

	IF @mode_id = 1
	BEGIN
		INSERT INTO dbo.tr_pallet_history (
			job_main_id,
			job_item_id,
			process_id,
			pallet_seq,
			pallet_id,
			bag_id,
			location_id,
			location_type,
			create_user_id,
			create_datetime,
			update_user_id,
			update_datetime
		)
		SELECT
			@job_main_id,
			@job_item_id,
			1,
			@pallet_seq,
			@pallet_id,
			b.id,
			@location_id,
			@location_type,
			@user_id,
			GETDATE(),
			@user_id,
			GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A';

		SET @add_qty = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);
	END
	ELSE IF @mode_id = 2
	BEGIN
		IF NOT EXISTS (
			SELECT 1 FROM dbo.tr_pallet_history
			WHERE job_main_id = @job_main_id
			  AND job_item_id = @job_item_id
			  AND bag_id = @bag_id
			  AND process_id = 4
		)
		BEGIN
			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			VALUES (
				@job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			);
		END

		DECLARE @newly_processed TABLE (bag_id INT);

		INSERT INTO dbo.tr_pallet_history (
			job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
			location_id, location_type, create_user_id, create_datetime,
			update_user_id, update_datetime
		)
		OUTPUT INSERTED.bag_id INTO @newly_processed(bag_id)
		SELECT
			@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
			@location_id, @location_type, @user_id, GETDATE(),
			@user_id, GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A'
		  AND NOT EXISTS (
			  SELECT 1 FROM dbo.tr_pallet_history ph
			  WHERE ph.job_main_id = @job_main_id
				AND ph.job_item_id = @job_item_id
				AND ph.bag_id = b.id
				AND ph.process_id IN (1, 4)
		  );

		DECLARE @newly_processed_count INT = (SELECT COUNT(*) FROM @newly_processed);

		SET @add_qty = ISNULL(@newly_processed_count, 0) * ISNULL(@unit_ratio, 0);
	END
	ELSE
	BEGIN
		INSERT INTO dbo.tr_pallet_history (
			job_main_id,
			job_item_id,
			process_id,
			pallet_seq,
			pallet_id,
			bag_id,
			location_id,
			location_type,
			create_user_id,
			create_datetime,
			update_user_id,
			update_datetime
		)
		VALUES (
			@job_main_id,
			@job_item_id,
			1,
			@pallet_seq,
			@pallet_id,
			@bag_id,
			@location_id,
			@location_type,
			@user_id,
			GETDATE(),
			@user_id,
			GETDATE()
		);

		SET @add_qty = ISNULL(@unit_ratio, 0);
	END

	IF EXISTS (
		SELECT 1
		FROM dbo.tr_job_from_location
		WHERE job_main_id = @job_main_id
		  AND interface_job_item_id = @job_item_id
		  AND from_location_id = @location_id
		  AND ISNULL(qty, 0) <> 0
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		UPDATE dbo.tr_job_from_location
		SET actual_qty = ISNULL(actual_qty, 0) + ISNULL(@add_qty, 0),
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id
			AND interface_job_item_id = @job_item_id
			AND from_location_id = @location_id
	END

	--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message, @pallet_seq AS pallet_seq;
END
GO

-- -------------------------------------------------------------
-- pProcessShippingGetPallet
-- -------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessShippingGetPallet]
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	DECLARE @job_type_id INT;
	DECLARE @current_job_type_id INT;

	SELECT @job_type_id = job_type_id FROM dbo.vJobMain WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

	IF @job_item_id IS NOT NULL
	   AND @current_job_type_id IS NOT NULL
	   AND @job_type_id = @current_job_type_id
	BEGIN
		SELECT 'error' AS status, 'Pallet is already assigned to a job with the same job type.' AS message;
		RETURN;
	END;

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain WHERE job_status_id = 4 AND id = @job_main_id
	)
	BEGIN
		UPDATE dbo.tr_job_main
		SET job_status_id = 4, start_datetime = GETDATE(),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE id = @job_main_id;
	END

	UPDATE dbo.tr_pallet
	SET current_job_id = @job_main_id,
		current_job_item_id = @job_item_id,
		current_location_id = @location_id,
		current_location_type = @location_type,
		update_user_id = @user_id,
		update_datetime = GETDATE()
	WHERE id = @pallet_id;

	INSERT INTO dbo.tr_pallet_history (
		job_main_id, job_item_id, process_id, pallet_id, bag_id,
		location_id, location_type, create_user_id, create_datetime,
		update_user_id, update_datetime
	)
	VALUES (
		@job_main_id, @job_item_id, 1, @pallet_id, @bag_id,
		@location_id, @location_type, @user_id, GETDATE(),
		@user_id, GETDATE()
	);

	DECLARE @qty INT = dbo.fGetPalletQty(@pallet_id)

	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_from_location
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id
		  AND from_location_id = @location_id AND ISNULL(qty, 0) <> 0
		  AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		UPDATE dbo.tr_job_from_location
		SET actual_qty = ISNULL(actual_qty, 0) + (@qty),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id AND from_location_id = @location_id
	END

	--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message;
END
GO

-- -------------------------------------------------------------
-- pProcessLoadingGetPallet
-- -------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessLoadingGetPallet]
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	DECLARE @job_type_id INT;
	DECLARE @current_job_type_id INT;

	SELECT @job_type_id = job_type_id FROM dbo.vJobMain WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id AND p.is_active = 'Y' AND p.status_flag = 'A';

	IF @job_item_id IS NOT NULL
	   AND @current_job_type_id IS NOT NULL
	   AND @job_type_id = @current_job_type_id
	BEGIN
		SELECT 'error' AS status, 'Pallet is already assigned to a job with the same job type.' AS message;
		RETURN;
	END;

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain WHERE job_status_id = 4 AND id = @job_main_id
	)
	BEGIN
		UPDATE dbo.tr_job_main
		SET job_status_id = 4, start_datetime = GETDATE(),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE id = @job_main_id;
	END

	UPDATE dbo.tr_pallet
	SET current_job_id = @job_main_id,
		current_job_item_id = @job_item_id,
		current_location_id = @location_id,
		current_location_type = @location_type,
		update_user_id = @user_id,
		update_datetime = GETDATE()
	WHERE id = @pallet_id;

	INSERT INTO dbo.tr_pallet_history (
		job_main_id, job_item_id, process_id, pallet_id, bag_id,
		location_id, location_type, create_user_id, create_datetime,
		update_user_id, update_datetime
	)
	VALUES (
		@job_main_id, @job_item_id, 1, @pallet_id, @bag_id,
		@location_id, @location_type, @user_id, GETDATE(),
		@user_id, GETDATE()
	);

	DECLARE @qty INT = dbo.fGetPalletQty(@pallet_id)

	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_from_location
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id
		  AND from_location_id = @location_id AND ISNULL(qty, 0) <> 0
		  AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		UPDATE dbo.tr_job_from_location
		SET actual_qty = ISNULL(actual_qty, 0) + (@qty),
			update_user_id = @user_id, update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND interface_job_item_id = @job_item_id AND from_location_id = @location_id
	END

	--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message;
END
GO

-- -------------------------------------------------------------
-- pProcessSpecialGetPallet
-- -------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessSpecialGetPallet]
	@qr_code_text		VARCHAR(100)	= NULL,
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@pallet_seq			INT				= NULL,
	@mode_id			INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	DECLARE @unit_ratio INT;

	SELECT @unit_ratio = p.unit_ratio
	FROM dbo.tr_pallet p
	WHERE p.id = @pallet_id
	  AND p.is_active = 'Y'
	  AND p.status_flag = 'A';

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE id = @job_main_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.vJobMain
		WHERE id = @job_main_id
		  AND item_id = @job_item_id

	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_pallet
		WHERE id = @pallet_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	DECLARE @job_type_id INT;
	DECLARE @current_job_type_id INT;

	SELECT @job_type_id = job_type_id
	FROM dbo.vJobMain
	WHERE id = @job_main_id;

	SELECT @current_job_type_id = jm.job_type_id
	FROM dbo.tr_pallet p
	INNER JOIN dbo.vJobMain jm
		ON jm.id = p.current_job_id
	WHERE p.id = @pallet_id
	  AND p.is_active = 'Y'
	  AND p.status_flag = 'A';

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE job_status_id = 4 AND id = @job_main_id
	)
	BEGIN
		UPDATE dbo.tr_job_main
		SET job_status_id = 4,
			start_datetime = GETDATE(),
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE id = @job_main_id;
	END

	UPDATE dbo.tr_pallet
	SET current_job_id = @job_main_id,
		current_job_item_id = @job_item_id,
		current_location_id = @location_id,
		current_location_type = @location_type,
		update_user_id = @user_id,
		update_datetime = GETDATE()
	WHERE id = @pallet_id;

	DECLARE @add_qty INT;

	IF @mode_id = 1
	BEGIN
		INSERT INTO dbo.tr_pallet_history (
			job_main_id,
			job_item_id,
			process_id,
			pallet_seq,
			pallet_id,
			bag_id,
			location_id,
			location_type,
			create_user_id,
			create_datetime,
			update_user_id,
			update_datetime
		)
		SELECT
			@job_main_id,
			@job_item_id,
			1,
			@pallet_seq,
			@pallet_id,
			b.id,
			@location_id,
			@location_type,
			@user_id,
			GETDATE(),
			@user_id,
			GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A';

		DECLARE @full_bag_count INT = (
			SELECT COUNT(*)
			FROM dbo.tr_bag
			WHERE pallet_id = @pallet_id
			  AND is_active = 'Y'
			  AND status_flag = 'A'
		);

		SET @add_qty = ISNULL(@full_bag_count, 0) * ISNULL(@unit_ratio, 0);
	END
	ELSE IF @mode_id = 2
	BEGIN
		IF NOT EXISTS (
			SELECT 1 FROM dbo.tr_pallet_history
			WHERE job_main_id = @job_main_id
			  AND job_item_id = @job_item_id
			  AND bag_id = @bag_id
			  AND process_id = 4
		)
		BEGIN
			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			VALUES (
				@job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			);
		END

		DECLARE @newly_processed TABLE (bag_id INT);

		INSERT INTO dbo.tr_pallet_history (
			job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
			location_id, location_type, create_user_id, create_datetime,
			update_user_id, update_datetime
		)
		OUTPUT INSERTED.bag_id INTO @newly_processed(bag_id)
		SELECT
			@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
			@location_id, @location_type, @user_id, GETDATE(),
			@user_id, GETDATE()
		FROM dbo.tr_bag b
		WHERE b.pallet_id = @pallet_id
		  AND b.is_active = 'Y'
		  AND b.status_flag = 'A'
		  AND NOT EXISTS (
			  SELECT 1 FROM dbo.tr_pallet_history ph
			  WHERE ph.job_main_id = @job_main_id
				AND ph.job_item_id = @job_item_id
				AND ph.bag_id = b.id
				AND ph.process_id IN (1, 4)
		  );

		DECLARE @newly_processed_count INT = (SELECT COUNT(*) FROM @newly_processed);

		SET @add_qty = ISNULL(@newly_processed_count, 0) * ISNULL(@unit_ratio, 0);
	END
	ELSE
	BEGIN
		INSERT INTO dbo.tr_pallet_history (
			job_main_id,
			job_item_id,
			process_id,
			pallet_seq,
			pallet_id,
			bag_id,
			location_id,
			location_type,
			create_user_id,
			create_datetime,
			update_user_id,
			update_datetime
		)
		VALUES (
			@job_main_id,
			@job_item_id,
			1,
			@pallet_seq,
			@pallet_id,
			@bag_id,
			@location_id,
			@location_type,
			@user_id,
			GETDATE(),
			@user_id,
			GETDATE()
		);

		SET @add_qty = ISNULL(@unit_ratio, 0);
	END

	IF EXISTS (
		SELECT 1
		FROM dbo.tr_job_from_location
		WHERE job_main_id = @job_main_id
		  AND interface_job_item_id = @job_item_id
		  AND from_location_id = @location_id
		  AND ISNULL(qty, 0) <> 0
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		UPDATE dbo.tr_job_from_location
		SET actual_qty = ISNULL(actual_qty, 0) + ISNULL(@add_qty, 0),
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id
			AND interface_job_item_id = @job_item_id
			AND from_location_id = @location_id
	END

	--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message, @pallet_seq AS pallet_seq;
END
GO

-- -------------------------------------------------------------
-- pProcessBrokenBagGetPallet
-- -------------------------------------------------------------
CREATE OR ALTER PROC [dbo].[pProcessBrokenBagGetPallet]
	@qr_code_text		VARCHAR(100)	= NULL,
	@job_main_id		INT				= NULL,
	@job_item_id		INT				= NULL,
	@location_id		INT				= NULL,
	@location_type		VARCHAR(10)		= NULL,
	@pallet_seq			INT				= NULL,
	@mode_id			INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_main_id.' AS message
		RETURN;
	END

	IF @job_item_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @job_item_id.' AS message
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (pProcessInsertJbPalletBag, 56)
	-- only for an existing job / item, before the QR lookup below
	-- ================================================
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	AND EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		DECLARE @jb_status  VARCHAR(20);
		DECLARE @jb_message VARCHAR(200);

		EXEC dbo.pProcessInsertJbPalletBag
			@qr_code_text  = @qr_code_text,
			@user_id       = @user_id,
			@return_result = 0,
			@status        = @jb_status  OUTPUT,
			@message       = @jb_message OUTPUT;

		IF @jb_status = 'error'
		BEGIN
			SELECT 'error' AS status, @jb_message AS message;
			RETURN;
		END
	END

	DECLARE @pallet_id INT;
	DECLARE @bag_id INT;

	SELECT @pallet_id = pallet_id, @bag_id = bag_id
	FROM dbo.fQrCodeToPalletBag(@qr_code_text);

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid QR code format.' AS message;
		RETURN;
	END

	DECLARE @unit_ratio INT;

	SELECT @unit_ratio = p.unit_ratio
	FROM dbo.tr_pallet p
	WHERE p.id = @pallet_id
	  AND p.is_active = 'Y'
	  AND p.status_flag = 'A';

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE id = @job_main_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.vJobMain
		WHERE id = @job_main_id
		  AND item_id = @job_item_id
	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_pallet
		WHERE id = @pallet_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		DECLARE @current_job_status_id INT;

		SELECT @current_job_status_id = job_status_id
		FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
		WHERE id = @job_main_id;

		IF ISNULL(@current_job_status_id, 0) <> 4
		BEGIN
			UPDATE dbo.tr_job_main
			SET job_status_id = 4,
				start_datetime = GETDATE(),
				update_user_id = @user_id,
				update_datetime = GETDATE()
			WHERE id = @job_main_id;
		END

		UPDATE dbo.tr_pallet
		SET current_job_id = @job_main_id,
			current_job_item_id = @job_item_id,
			current_location_id = @location_id,
			current_location_type = @location_type,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE id = @pallet_id;

		DECLARE @add_qty INT;

		IF @mode_id = 1
		BEGIN
			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			SELECT
				@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
				@location_id, @location_type, @user_id, GETDATE(), @user_id, GETDATE()
			FROM dbo.tr_bag b
			WHERE b.pallet_id = @pallet_id
			  AND b.is_active = 'Y'
			  AND b.status_flag = 'A';

			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			SELECT
				@job_main_id, @job_item_id, 2, @pallet_seq, @pallet_id, b.id,
				@location_id, @location_type, @user_id, GETDATE(), @user_id, GETDATE()
			FROM dbo.tr_bag b
			WHERE b.pallet_id = @pallet_id
			  AND b.is_active = 'Y'
			  AND b.status_flag = 'A';

			DECLARE @full_bag_count INT = (
				SELECT COUNT(*)
				FROM dbo.tr_bag
				WHERE pallet_id = @pallet_id
				  AND is_active = 'Y'
				  AND status_flag = 'A'
			);

			SET @add_qty = ISNULL(@full_bag_count, 0) * ISNULL(@unit_ratio, 0);
		END
		ELSE IF @mode_id = 2
		BEGIN
			IF NOT EXISTS (
				SELECT 1 FROM dbo.tr_pallet_history
				WHERE job_main_id = @job_main_id
				  AND job_item_id = @job_item_id
				  AND bag_id = @bag_id
				  AND process_id = 4
			)
			BEGIN
				INSERT INTO dbo.tr_pallet_history (
					job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
					location_id, location_type, create_user_id, create_datetime,
					update_user_id, update_datetime
				)
				VALUES (
					@job_main_id, @job_item_id, 4, @pallet_seq, @pallet_id, @bag_id,
					@location_id, @location_type, @user_id, GETDATE(),
					@user_id, GETDATE()
				);
			END

			DECLARE @newly_processed TABLE (bag_id INT);

			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			OUTPUT INSERTED.bag_id INTO @newly_processed(bag_id)
			SELECT
				@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, b.id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			FROM dbo.tr_bag b
			WHERE b.pallet_id = @pallet_id
			  AND b.is_active = 'Y'
			  AND b.status_flag = 'A'
			  AND NOT EXISTS (
				  SELECT 1 FROM dbo.tr_pallet_history ph
				  WHERE ph.job_main_id = @job_main_id
					AND ph.job_item_id = @job_item_id
					AND ph.bag_id = b.id
					AND ph.process_id IN (1, 4)
			  );

			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			SELECT
				@job_main_id, @job_item_id, 2, @pallet_seq, @pallet_id, np.bag_id,
				@location_id, @location_type, @user_id, GETDATE(), @user_id, GETDATE()
			FROM @newly_processed np;

			DECLARE @newly_processed_count INT = (SELECT COUNT(*) FROM @newly_processed);

			SET @add_qty = ISNULL(@newly_processed_count, 0) * ISNULL(@unit_ratio, 0);
		END
		ELSE
		BEGIN
			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			VALUES (
				@job_main_id, @job_item_id, 1, @pallet_seq, @pallet_id, @bag_id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			);

			INSERT INTO dbo.tr_pallet_history (
				job_main_id, job_item_id, process_id, pallet_seq, pallet_id, bag_id,
				location_id, location_type, create_user_id, create_datetime,
				update_user_id, update_datetime
			)
			VALUES (
				@job_main_id, @job_item_id, 2, @pallet_seq, @pallet_id, @bag_id,
				@location_id, @location_type, @user_id, GETDATE(),
				@user_id, GETDATE()
			);

			SET @add_qty = ISNULL(@unit_ratio, 0);
		END

		IF EXISTS (
			SELECT 1
			FROM dbo.tr_job_from_location
			WHERE job_main_id = @job_main_id
			  AND interface_job_item_id = @job_item_id
			  AND from_location_id = @location_id
			  AND ISNULL(qty, 0) <> 0
			  AND is_active = 'Y'
			  AND status_flag = 'A'
		)
		BEGIN
			UPDATE dbo.tr_job_from_location
			SET actual_qty = ISNULL(actual_qty, 0) + ISNULL(@add_qty, 0),
				update_user_id = @user_id,
				update_datetime = GETDATE()
			WHERE job_main_id = @job_main_id
				AND interface_job_item_id = @job_item_id
				AND from_location_id = @location_id
		END

		DECLARE @total_qty DECIMAL(18, 3) = (
			SELECT SUM(t.qty)
			FROM (SELECT DISTINCT header_id, item_id, qty FROM dbo.vBrokenBagJob WHERE id = @job_main_id) t
		);

		DECLARE @complete_qty DECIMAL(18, 3) = (
			SELECT SUM(CASE WHEN is_complete = 'Y' THEN qty ELSE 0 END)
			FROM dbo.fBrokenBagBags(@job_main_id)
		);

		DECLARE @is_job_complete BIT = 0;

		IF ISNULL(@total_qty, 0) > 0 AND ISNULL(@complete_qty, 0) >= @total_qty AND ISNULL(@current_job_status_id, 0) <> 5
		BEGIN
			UPDATE dbo.tr_job_main
			SET job_status_id = 5,
				end_datetime = GETDATE(),
				update_user_id = @user_id,
				update_datetime = GETDATE()
			WHERE id = @job_main_id;

			SET @is_job_complete = 1;

			DECLARE @header_id INT;
			DECLARE @shipping_ready BIT;

			SELECT @header_id = header_id
			FROM dbo.vBrokenBagJob
			WHERE id = @job_main_id;

			IF @header_id IS NOT NULL
			BEGIN
				UPDATE dbo.tr_broken_bag_header
				SET warehouse_ready = 1,
					update_by = @user_id,
					update_datetime = GETDATE()
				WHERE id = @header_id;

				SELECT @shipping_ready = shipping_ready
				FROM dbo.tr_broken_bag_header
				WHERE id = @header_id;

				IF ISNULL(@shipping_ready, 0) = 1
				   AND NOT EXISTS (
					   SELECT 1 FROM dbo.tr_broken_bag_status_log
					   WHERE header_id = @header_id AND status_id = 3
				   )
				BEGIN
					UPDATE dbo.tr_broken_bag_header
					SET status_id = 3,
						status_name = N'ตรวจสอบถุง',
						update_by = @user_id,
						update_datetime = GETDATE()
					WHERE id = @header_id;

					INSERT INTO dbo.tr_broken_bag_status_log (header_id, status_id, status_name, status_datetime, create_by)
					VALUES (@header_id, 3, N'ตรวจสอบถุง', GETDATE(), @user_id);
				END
			END
		END

		COMMIT TRANSACTION;

		--  First Get of the job: fill tr_job_assigness.assignee_user_id if still empty
	EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;

	SELECT 'success' AS status, 'Pallet updated successfully.' AS message, @pallet_seq AS pallet_seq, @is_job_complete AS is_job_complete;
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
		SELECT 'error' AS status, ERROR_MESSAGE() AS message;
	END CATCH
END
GO

