-- =============================================================
-- 64_pProcessSpecialResetPallet_fixes.sql  (IRPC_QTRACK)
-- =============================================================
-- On top of the pProcessSpecialResetPallet / pProcessSpecialGetPallet
-- definitions live on IRPC_QTRACK as of 2026-10-02.
-- Same fixes as 63 (Request), adjusted to the Special Get / PutAway math.
--
-- pProcessSpecialResetPallet
--   1. Reset is the whole pallet group: the QR (pallet or bag) finds the
--      pallet, its active rows in this job give the pallet_seq, and every
--      pallet with an active row of the same job / item / pallet_seq is
--      reset too (same group PutAway puts away together). pallet_seq NULL
--      -> only the scanned pallet.
--   2. Takes back tr_job_from_location.actual_qty that Get added for the
--      reset pallets (same conditions as the add: item, location, qty <> 0,
--      active), never below 0. Special Get adds bag count * unit_ratio in
--      every mode, so reset takes back bag count * unit_ratio of the
--      active process_id 1 rows.
--   3. Recalculates tr_job_to_location.actual_qty for every (item,
--      location) the reset pallets were put away to, with the PutAway
--      formula: SUM(unit_ratio) of every distinct active bag of the item
--      (any process_id).
--   4. If the job was completed (job_status_id 5) and an active row is
--      reset, the job goes back to in progress (4) and end_datetime is
--      cleared. PutAway completes it again.
--   5. All updates run in one transaction.
--
-- pProcessSpecialGetPallet
--   6. mode 2 (store bag): the "already taken" checks for process_id 4
--      and process_id 1 / 4 now only look at active rows. Before, after a
--      reset the old inactive rows made every bag look taken, so a
--      re-scan inserted nothing and added 0 qty.
--      No other change in this proc.
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessSpecialResetPallet]
	@qr_code_text		VARCHAR(100)	= NULL,
	@job_main_id		INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
	SET NOCOUNT ON;

	IF @job_main_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Job main ID is required.' AS message;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1
		FROM dbo.tr_job_main
		WHERE id = @job_main_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job main not found.' AS message;
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_bag.' AS message
		RETURN;
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
		SELECT 1
		FROM dbo.tr_pallet
		WHERE id = @pallet_id
		  AND is_active = 'Y'
		  AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		--	Pallets to reset: the scanned pallet + every pallet that shares a
		--	pallet_seq with it in this job / item (active rows only).
		--	Same group PutAway uses. pallet_seq NULL -> only the scanned pallet.
		DECLARE @pallets TABLE (pallet_id INT PRIMARY KEY);

		INSERT INTO @pallets (pallet_id)
		SELECT @pallet_id

		UNION

		SELECT g.pallet_id
		FROM dbo.tr_pallet_history s
		INNER JOIN dbo.tr_pallet_history g
			ON g.job_main_id = s.job_main_id
			AND g.job_item_id = s.job_item_id
			AND g.pallet_seq = s.pallet_seq
			AND g.is_active = 'Y' AND g.status_flag = 'A'
		WHERE s.job_main_id = @job_main_id
		  AND s.pallet_id = @pallet_id
		  AND s.pallet_seq IS NOT NULL
		  AND s.is_active = 'Y' AND s.status_flag = 'A';

		--	Active rows of these pallets in this job, before they are deactivated
		DECLARE @rows TABLE (pallet_id INT, job_item_id INT, process_id INT, location_id INT, bag_cnt INT);

		INSERT INTO @rows (pallet_id, job_item_id, process_id, location_id, bag_cnt)
		SELECT ph.pallet_id, ph.job_item_id, ph.process_id, ph.location_id, COUNT(DISTINCT ph.bag_id)
		FROM dbo.tr_pallet_history ph
		INNER JOIN @pallets g ON g.pallet_id = ph.pallet_id
		WHERE ph.job_main_id = @job_main_id
		  AND ph.is_active = 'Y' AND ph.status_flag = 'A'
		GROUP BY ph.pallet_id, ph.job_item_id, ph.process_id, ph.location_id;

		-- ------------------------------------------------
		-- Get (process_id 1) -> take back tr_job_from_location.actual_qty
		-- Special Get adds bag count * unit_ratio
		-- ------------------------------------------------
		UPDATE fl
		SET actual_qty = CASE WHEN ISNULL(fl.actual_qty, 0) - r.qty < 0 THEN 0
		                      ELSE ISNULL(fl.actual_qty, 0) - r.qty END,
			update_user_id = @user_id, update_datetime = GETDATE()
		FROM dbo.tr_job_from_location fl
		INNER JOIN (
			SELECT x.job_item_id, x.location_id,
				SUM(x.bag_cnt * ISNULL(p.unit_ratio, 0)) AS qty
			FROM @rows x
			INNER JOIN dbo.tr_pallet p ON p.id = x.pallet_id
			WHERE x.process_id = 1
			GROUP BY x.job_item_id, x.location_id
		) r ON r.job_item_id = fl.interface_job_item_id AND r.location_id = fl.from_location_id
		WHERE fl.job_main_id = @job_main_id
		  AND ISNULL(fl.qty, 0) <> 0
		  AND fl.is_active = 'Y' AND fl.status_flag = 'A'
		  AND r.qty <> 0;

		-- ------------------------------------------------
		-- Deactivate history (whole pallets of the group, pallet or bag QR)
		-- ------------------------------------------------
		UPDATE ph
		SET is_active = 'N',
			status_flag = 'D',
			update_user_id = @user_id,
			update_datetime = GETDATE()
		FROM dbo.tr_pallet_history ph
		INNER JOIN @pallets g ON g.pallet_id = ph.pallet_id
		WHERE ph.job_main_id = @job_main_id
		  AND ph.is_active = 'Y';

		-- ------------------------------------------------
		-- Put-away (process_id 2) -> recalc tr_job_to_location.actual_qty
		-- same formula as pProcessSpecialPutAway (@scanned_qty)
		-- ------------------------------------------------
		UPDATE tl
		SET actual_qty = ISNULL(s.scanned_qty, 0),
			update_user_id = @user_id, update_datetime = GETDATE()
		FROM dbo.tr_job_to_location tl
		INNER JOIN (
			SELECT DISTINCT job_item_id, location_id
			FROM @rows
			WHERE process_id = 2
		) r ON r.job_item_id = tl.interface_job_item_id AND r.location_id = tl.to_location_id
		OUTER APPLY (
			SELECT SUM(p.unit_ratio) AS scanned_qty
			FROM (
				SELECT DISTINCT ph.bag_id, ph.pallet_id
				FROM dbo.tr_pallet_history ph
				WHERE ph.job_main_id = @job_main_id
				  AND ph.job_item_id = r.job_item_id
				  AND ph.is_active = 'Y'
				  AND ph.status_flag = 'A'
				  AND ph.bag_id IS NOT NULL
			) scanned
			INNER JOIN dbo.tr_pallet p
				ON p.id = scanned.pallet_id
				AND p.is_active = 'Y'
				AND p.status_flag = 'A'
		) s
		WHERE tl.job_main_id = @job_main_id
		  AND ISNULL(tl.qty, 0) <> 0
		  AND tl.is_active = 'Y' AND tl.status_flag = 'A';

		-- ------------------------------------------------
		-- Release the pallets
		-- ------------------------------------------------
		UPDATE p
		SET current_job_id = NULL,
			current_job_item_id = NULL,
			current_location_id = NULL,
			current_location_type = NULL,
			outbound_to_special_location_id = NULL,
			outbound_to_special_user_id = NULL,
			outbound_to_special_datetime = NULL,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		FROM dbo.tr_pallet p
		INNER JOIN @pallets g ON g.pallet_id = p.id
		WHERE p.current_job_id = @job_main_id;

		-- ------------------------------------------------
		-- Completed job lost a pallet -> back to in progress
		-- ------------------------------------------------
		IF EXISTS (SELECT 1 FROM @rows)
		BEGIN
			UPDATE dbo.tr_job_main
			SET job_status_id = 4,
				end_datetime = NULL,
				update_user_id = @user_id,
				update_datetime = GETDATE()
			WHERE id = @job_main_id AND job_status_id = 5;
		END

		COMMIT TRANSACTION;
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
		SELECT 'error' AS status, ERROR_MESSAGE() AS message;
		RETURN;
	END CATCH

	SELECT 'success' AS status, 'Pallet reseted successfully.' AS message;
END
GO


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
		--	only active rows count, so a reset pallet can be scanned again
		IF NOT EXISTS (
			SELECT 1 FROM dbo.tr_pallet_history
			WHERE job_main_id = @job_main_id
			  AND job_item_id = @job_item_id
			  AND bag_id = @bag_id
			  AND process_id = 4
			  AND is_active = 'Y'
			  AND status_flag = 'A'
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
				AND ph.is_active = 'Y'
				AND ph.status_flag = 'A'
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
