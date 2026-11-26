-- =============================================================
-- 41_pProcessInboundGetPallet_jb.sql  (IRPC_QTRACK)
-- =============================================================
-- pProcessInboundGetPallet + auto-create of JB pallet/bag on first scan.
--
-- Before: the proc resolves the QR with dbo.fQrCodeToPalletBag, which only
-- finds a bag that is already in tr_bag with a pallet, or a pallet_no. A JB
-- bag QR ('1311|1105RC/750|7260804272|01|436|750|JB1') has neither when it
-- is scanned the first time, so the proc returned 'Invalid QR code format.'
--
-- Now: after the job checks, the proc calls dbo.pProcessInsertJbPalletBag
-- (42_pProcessInsertJbPalletBag.sql). For a JB QR seen the first time it
-- creates the J pallet + bag (see 42 for the rules). Then the original flow
-- runs unchanged (fQrCodeToPalletBag now finds the bag and its pallet).
--
-- Normal bag QRs ('A') are NOT created: their pallets are built by
-- pServiceMatchBagToPallet, so the original behavior is kept.
--
-- The job checks were moved before the QR lookup so a JB pallet is never
-- created for a job that does not exist.
--
-- Deploy order: 40 -> 42 -> 41.
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessInboundGetPallet]
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

	-- job checks moved before the QR lookup so a JB pallet is never created
	-- for a job that does not exist
	IF NOT EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job not found.' AS message;
		RETURN;
	END

	IF NOT EXISTS (
		SELECT 1 FROM dbo.vJobMain
		WHERE id = @job_main_id AND item_id = @job_item_id
	)
	BEGIN
		SELECT 'error' AS status, 'Job item not found.' AS message;
		RETURN;
	END

	-- ================================================
	-- JB : create pallet + bag on first scan (42)
	-- ================================================
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

	-- ================================================
	-- Original flow
	-- ================================================
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
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;
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
