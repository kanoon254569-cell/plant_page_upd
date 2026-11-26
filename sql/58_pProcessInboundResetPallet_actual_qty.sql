-- =============================================================
-- 58_pProcessInboundResetPallet_actual_qty.sql  (IRPC_QTRACK)
-- =============================================================
-- On top of the pProcessInboundResetPallet definition live on IRPC_QTRACK
-- as of 2026-10-01.
--
-- Change (58): reset now takes back the actual_qty the pallet added.
--   pProcessInboundGetPallet (process_id 1) adds fGetPalletQty(pallet) to
--   tr_job_from_location.actual_qty, and pProcessInboundPutAway
--   (process_id 2) adds it to tr_job_to_location.actual_qty. Reset only
--   deactivated the history rows, so after "reset + scan again" the same
--   pallet was counted twice (eg. a JB pallet: 750 + 750).
--
--   For every still-active history row of this job + pallet, reset now
--   subtracts fGetPalletQty(pallet) from the same location row, with the
--   same conditions the add used (item, location, qty <> 0, active), never
--   below 0. Then it deactivates the history as before.
--
--   The pallet / history / qty updates now run in one transaction.
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessInboundResetPallet]
	@job_main_id		INT				= NULL,
	@qr_code_text		VARCHAR(100)	= NULL,
	@user_id			INT				= NULL
AS
BEGIN
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
		SELECT 'error' AS status, 'Pallet not found.' AS message;;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		-- ------------------------------------------------
		-- Take back the actual_qty this pallet added
		-- ------------------------------------------------
		DECLARE @qty INT = ISNULL(dbo.fGetPalletQty(@pallet_id), 0);

		IF @qty <> 0
		BEGIN
			-- Get (process_id 1) -> tr_job_from_location
			UPDATE fl
			SET actual_qty = CASE WHEN ISNULL(fl.actual_qty, 0) - @qty * h.cnt < 0 THEN 0
			                      ELSE ISNULL(fl.actual_qty, 0) - @qty * h.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_from_location fl
			INNER JOIN (
				SELECT job_item_id, location_id, COUNT(*) AS cnt
				FROM dbo.tr_pallet_history
				WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
				  AND process_id = 1 AND ISNULL(is_active, 'Y') = 'Y'
				GROUP BY job_item_id, location_id
			) h ON h.job_item_id = fl.interface_job_item_id AND h.location_id = fl.from_location_id
			WHERE fl.job_main_id = @job_main_id
			  AND ISNULL(fl.qty, 0) <> 0
			  AND fl.is_active = 'Y' AND fl.status_flag = 'A';

			-- Put-away (process_id 2) -> tr_job_to_location
			UPDATE tl
			SET actual_qty = CASE WHEN ISNULL(tl.actual_qty, 0) - @qty * h.cnt < 0 THEN 0
			                      ELSE ISNULL(tl.actual_qty, 0) - @qty * h.cnt END,
				update_user_id = @user_id, update_datetime = GETDATE()
			FROM dbo.tr_job_to_location tl
			INNER JOIN (
				SELECT job_item_id, location_id, COUNT(*) AS cnt
				FROM dbo.tr_pallet_history
				WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id
				  AND process_id = 2 AND ISNULL(is_active, 'Y') = 'Y'
				GROUP BY job_item_id, location_id
			) h ON h.job_item_id = tl.interface_job_item_id AND h.location_id = tl.to_location_id
			WHERE tl.job_main_id = @job_main_id
			  AND ISNULL(tl.qty, 0) <> 0
			  AND tl.is_active = 'Y' AND tl.status_flag = 'A';
		END

		UPDATE dbo.tr_pallet
		SET current_job_id = NULL,
			current_job_item_id = NULL,
			current_location_id = NULL,
			current_location_type = NULL,
			inbound_to_wh_id = NULL,
			inbound_to_wh_user_id = NULL,
			inbound_to_wh_datetime = NULL,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE current_job_id = @job_main_id AND id = @pallet_id;

		UPDATE dbo.tr_pallet_history
		SET is_active = 'N',
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE job_main_id = @job_main_id AND pallet_id = @pallet_id;

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
