-- =============================================================
-- 66_pProcessLoadingPickingShippingResetPallet_actual_qty.sql  (IRPC_QTRACK)
-- =============================================================
-- On top of the pProcessLoadingResetPallet / pProcessPickingResetPallet /
-- pProcessShippingResetPallet definitions live on IRPC_QTRACK as of
-- 2026-10-02. Same idea as 58 (Inbound).
--
-- Loading / Picking / Shipping Get (process_id 1) and PutAway
-- (process_id 2) insert one history row per scan and each add
-- fGetPalletQty(pallet) to tr_job_from_location / tr_job_to_location
-- .actual_qty. Reset only deactivated the history rows, so after
-- "reset + scan again" the same pallet was counted twice.
-- These jobs have no pallet_seq, so reset stays one pallet.
--
--   1. For every still-active history row of this job + pallet, reset
--      subtracts fGetPalletQty(pallet) from the same location row, with
--      the same conditions the add used (item, location, qty <> 0,
--      active), never below 0.
--   2. Completed job (job_status_id 5):
--        Loading           -> back to in progress (4), end_datetime
--                             cleared. PutAway completes it again.
--        Picking, Shipping -> reset is refused. Their PutAway created the
--                             next job (Shipping / Loading) from this
--                             job's to_location qty when it completed;
--                             reopening would create that job a 2nd time.
--   3. History rows also get status_flag = 'D'.
--   4. All updates run in one transaction.
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessLoadingResetPallet]
	@job_main_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
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
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job main not found.' AS message;
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
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
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		--	Active rows of this pallet in this job, before they are deactivated
		DECLARE @rows TABLE (job_item_id INT, process_id INT, location_id INT, cnt INT);

		INSERT INTO @rows (job_item_id, process_id, location_id, cnt)
		SELECT job_item_id, process_id, location_id, COUNT(*)
		FROM dbo.tr_pallet_history
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y' AND status_flag = 'A'
		GROUP BY job_item_id, process_id, location_id;

		-- ------------------------------------------------
		-- Take back the actual_qty this pallet added
		-- (one fGetPalletQty per Get / Put scan)
		-- ------------------------------------------------
		DECLARE @qty INT = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);

		IF @qty <> 0
		BEGIN
			-- Get (process_id 1) -> tr_job_from_location
			UPDATE fl
			SET actual_qty = CASE WHEN ISNULL(fl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(fl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_from_location fl
			INNER JOIN @rows r
				ON r.job_item_id = fl.interface_job_item_id AND r.location_id = fl.from_location_id
			WHERE r.process_id = 1
			  AND fl.job_main_id = @job_main_id
			  AND ISNULL(fl.qty, 0) <> 0
			  AND fl.is_active = 'Y' AND fl.status_flag = 'A';

			-- Put-away (process_id 2) -> tr_job_to_location
			UPDATE tl
			SET actual_qty = CASE WHEN ISNULL(tl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(tl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_to_location tl
			INNER JOIN @rows r
				ON r.job_item_id = tl.interface_job_item_id AND r.location_id = tl.to_location_id
			WHERE r.process_id = 2
			  AND tl.job_main_id = @job_main_id
			  AND ISNULL(tl.qty, 0) <> 0
			  AND tl.is_active = 'Y' AND tl.status_flag = 'A';
		END

		UPDATE dbo.tr_pallet
		SET current_job_id = NULL,
			current_job_item_id = NULL,
			current_location_id = NULL,
			current_location_type = NULL,
			outbound_to_vehicle_id = NULL,
			outbound_to_vehicle_user_id = NULL,
			outbound_to_vehicle_datetime = NULL,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE current_job_id = @job_main_id AND id = @pallet_id;

		UPDATE dbo.tr_pallet_history
		SET is_active = 'N',
			status_flag = 'D',
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y';

		--	Completed job lost a pallet -> back to in progress
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


CREATE OR ALTER PROC [dbo].[pProcessPickingResetPallet]
	@job_main_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
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
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job main not found.' AS message;
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
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
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;
		RETURN;
	END

	--	Completed job already created the next job from its qty: no reset
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND job_status_id = 5
	)
	BEGIN
		SELECT 'error' AS status, 'Job is already completed. Pallet cannot be reset.' AS message;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		--	Active rows of this pallet in this job, before they are deactivated
		DECLARE @rows TABLE (job_item_id INT, process_id INT, location_id INT, cnt INT);

		INSERT INTO @rows (job_item_id, process_id, location_id, cnt)
		SELECT job_item_id, process_id, location_id, COUNT(*)
		FROM dbo.tr_pallet_history
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y' AND status_flag = 'A'
		GROUP BY job_item_id, process_id, location_id;

		-- ------------------------------------------------
		-- Take back the actual_qty this pallet added
		-- (one fGetPalletQty per Get / Put scan)
		-- ------------------------------------------------
		DECLARE @qty INT = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);

		IF @qty <> 0
		BEGIN
			-- Get (process_id 1) -> tr_job_from_location
			UPDATE fl
			SET actual_qty = CASE WHEN ISNULL(fl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(fl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_from_location fl
			INNER JOIN @rows r
				ON r.job_item_id = fl.interface_job_item_id AND r.location_id = fl.from_location_id
			WHERE r.process_id = 1
			  AND fl.job_main_id = @job_main_id
			  AND ISNULL(fl.qty, 0) <> 0
			  AND fl.is_active = 'Y' AND fl.status_flag = 'A';

			-- Put-away (process_id 2) -> tr_job_to_location
			UPDATE tl
			SET actual_qty = CASE WHEN ISNULL(tl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(tl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_to_location tl
			INNER JOIN @rows r
				ON r.job_item_id = tl.interface_job_item_id AND r.location_id = tl.to_location_id
			WHERE r.process_id = 2
			  AND tl.job_main_id = @job_main_id
			  AND ISNULL(tl.qty, 0) <> 0
			  AND tl.is_active = 'Y' AND tl.status_flag = 'A';
		END

		UPDATE dbo.tr_pallet
		SET current_job_id = NULL,
			current_job_item_id = NULL,
			current_location_id = NULL,
			current_location_type = NULL,
			outbound_to_pre_zone_id = NULL,
			outbound_to_pre_zone_user_id = NULL,
			outbound_to_pre_zone_datetime = NULL,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE current_job_id = @job_main_id AND id = @pallet_id;

		UPDATE dbo.tr_pallet_history
		SET is_active = 'N',
			status_flag = 'D',
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y';

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


CREATE OR ALTER PROC [dbo].[pProcessShippingResetPallet]
	@job_main_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
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
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Job main not found.' AS message;
		RETURN;
	END

	IF @qr_code_text IS NULL
	BEGIN
		SELECT 'error' AS status, 'Invalid @qr_code_text.' AS message
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
		SELECT 1 FROM dbo.tr_pallet
		WHERE id = @pallet_id AND is_active = 'Y' AND status_flag = 'A'
	)
	BEGIN
		SELECT 'error' AS status, 'Pallet not found.' AS message;
		RETURN;
	END

	--	Completed job already created the next job from its qty: no reset
	IF EXISTS (
		SELECT 1 FROM dbo.tr_job_main
		WHERE id = @job_main_id AND job_status_id = 5
	)
	BEGIN
		SELECT 'error' AS status, 'Job is already completed. Pallet cannot be reset.' AS message;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		--	Active rows of this pallet in this job, before they are deactivated
		DECLARE @rows TABLE (job_item_id INT, process_id INT, location_id INT, cnt INT);

		INSERT INTO @rows (job_item_id, process_id, location_id, cnt)
		SELECT job_item_id, process_id, location_id, COUNT(*)
		FROM dbo.tr_pallet_history
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y' AND status_flag = 'A'
		GROUP BY job_item_id, process_id, location_id;

		-- ------------------------------------------------
		-- Take back the actual_qty this pallet added
		-- (one fGetPalletQty per Get / Put scan)
		-- ------------------------------------------------
		DECLARE @qty INT = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);

		IF @qty <> 0
		BEGIN
			-- Get (process_id 1) -> tr_job_from_location
			UPDATE fl
			SET actual_qty = CASE WHEN ISNULL(fl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(fl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_from_location fl
			INNER JOIN @rows r
				ON r.job_item_id = fl.interface_job_item_id AND r.location_id = fl.from_location_id
			WHERE r.process_id = 1
			  AND fl.job_main_id = @job_main_id
			  AND ISNULL(fl.qty, 0) <> 0
			  AND fl.is_active = 'Y' AND fl.status_flag = 'A';

			-- Put-away (process_id 2) -> tr_job_to_location
			UPDATE tl
			SET actual_qty = CASE WHEN ISNULL(tl.actual_qty, 0) - @qty * r.cnt < 0 THEN 0
			                      ELSE ISNULL(tl.actual_qty, 0) - @qty * r.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_to_location tl
			INNER JOIN @rows r
				ON r.job_item_id = tl.interface_job_item_id AND r.location_id = tl.to_location_id
			WHERE r.process_id = 2
			  AND tl.job_main_id = @job_main_id
			  AND ISNULL(tl.qty, 0) <> 0
			  AND tl.is_active = 'Y' AND tl.status_flag = 'A';
		END

		UPDATE dbo.tr_pallet
		SET current_job_id = NULL,
			current_job_item_id = NULL,
			current_location_id = NULL,
			current_location_type = NULL,
			outbound_to_dock_id = NULL,
			outbound_to_dock_user_id = NULL,
			outbound_to_dock_datetime = NULL,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE current_job_id = @job_main_id AND id = @pallet_id;

		UPDATE dbo.tr_pallet_history
		SET is_active = 'N',
			status_flag = 'D',
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
		  AND is_active = 'Y';

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
