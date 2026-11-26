-- =============================================================
-- 56_pProcessInsertJbPalletBag_no_recreate.sql  (IRPC_QTRACK)
-- =============================================================
-- On top of 42_pProcessInsertJbPalletBag.sql (identical to live as of
-- 2026-10-01). Needs 55_fCheckPalletType_jb_no_recreate.sql first.
--
-- Change (56): a JB pallet / bag that was created before is never created
-- again. Instead of creating, the proc returns @status = 'error' with a
-- clear message (pProcessInboundGetPallet passes it to the scanner):
--   * J pallet for this QR exists but is inactive
--       -> 'JB pallet <no> was created before and is inactive.'
--   * JB bag for this QR exists but is inactive
--       -> 'JB bag was created before and is inactive.'
--   * JB bag is already on a pallet that is not this QR's pallet
--       -> 'JB bag is already on another pallet (<no>).'
-- Before: an inactive J pallet made it create a second pallet with no bag
-- (then the scan failed with 'Pallet not found.'), and an inactive bag made
-- the scan fail with 'Invalid QR code format.'.
--
-- The quick check outside the lock now also lets these cases in, so they
-- get the clear message instead of 'skip' (for the "another pallet" case,
-- 'skip' made the scan go on with the bag's other pallet).
--
-- Everything else is 42 unchanged.
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessInsertJbPalletBag]
	@qr_code_text		VARCHAR(100)	= NULL,
	@user_id			INT				= NULL,
	@return_result		BIT				= 1,
	@status				VARCHAR(20)		= NULL OUTPUT,
	@message			VARCHAR(200)	= NULL OUTPUT,
	@pallet_id			BIGINT			= NULL OUTPUT,
	@bag_id				BIGINT			= NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON;

	SET @status    = 'skip';
	SET @message   = 'not a new JB bag.';
	SET @pallet_id = NULL;
	SET @bag_id    = NULL;

	-- cheap check outside the lock: most scans are not new JB bags
	IF EXISTS (
		SELECT 1 FROM dbo.fCheckPalletType(@qr_code_text)
		WHERE status = 'success' AND pallet_type_code = 'J'
		  AND (is_new_pallet = 'Y' OR is_new_bag = 'Y'
		       OR pallet_exist_active = 'N' OR bag_exist_active = 'N'
		       OR (bag_exist_pallet_id IS NOT NULL
		           AND (pallet_exist_id IS NULL OR bag_exist_pallet_id <> pallet_exist_id)))
	)
	BEGIN
		DECLARE @cost_center         VARCHAR(20);
		DECLARE @grade               VARCHAR(20);
		DECLARE @lot                 VARCHAR(20);
		DECLARE @pallet_running_no   INT;
		DECLARE @bag_no              INT;
		DECLARE @pd_group_code       VARCHAR(20);
		DECLARE @unit_ratio          INT;
		DECLARE @unit_pallet         INT;
		DECLARE @pallet_no           VARCHAR(50);
		DECLARE @is_new_pallet       VARCHAR(1);
		DECLARE @is_new_bag          VARCHAR(1);
		DECLARE @pallet_exist_no     VARCHAR(50);
		DECLARE @pallet_exist_active VARCHAR(1);
		DECLARE @bag_exist_active    VARCHAR(1);
		DECLARE @bag_exist_pallet_id BIGINT;
		DECLARE @lock                INT;

		BEGIN TRY
			BEGIN TRANSACTION;

			EXEC @lock = sp_getapplock @Resource = 'QTRACK_CreateJbPallet',
			                           @LockMode = 'Exclusive', @LockOwner = 'Transaction',
			                           @LockTimeout = 15000;
			IF @lock < 0
			BEGIN
				ROLLBACK TRANSACTION;
				SET @status  = 'error';
				SET @message = 'Busy, please scan again.';
			END
			ELSE
			BEGIN
				-- re-read under the lock
				SELECT @cost_center         = cost_center,
				       @grade               = grade,
				       @lot                 = lot,
				       @pallet_running_no   = pallet_running_no,
				       @bag_no              = bag_no_int,
				       @pd_group_code       = pd_group_code,
				       @unit_ratio          = unit_ratio,
				       @unit_pallet         = unit_pallet,
				       @pallet_id           = pallet_exist_id,
				       @pallet_exist_no     = pallet_exist_no,
				       @bag_id              = bag_exist_id,
				       @is_new_pallet       = is_new_pallet,
				       @is_new_bag          = is_new_bag,
				       @pallet_exist_active = pallet_exist_active,
				       @bag_exist_active    = bag_exist_active,
				       @bag_exist_pallet_id = bag_exist_pallet_id
				FROM   dbo.fCheckPalletType(@qr_code_text)
				WHERE  status = 'success' AND pallet_type_code = 'J';

				-- created before -> never create again, say why
				IF @pallet_exist_active = 'N'
					SET @message = CONCAT('JB pallet ', @pallet_exist_no, ' was created before and is inactive.');
				ELSE IF @bag_exist_active = 'N'
					SET @message = 'JB bag was created before and is inactive.';
				ELSE IF @bag_exist_pallet_id IS NOT NULL
				        AND (@pallet_id IS NULL OR @bag_exist_pallet_id <> @pallet_id)
					SET @message = CONCAT('JB bag is already on another pallet (',
					                      ISNULL((SELECT pallet_no FROM dbo.tr_pallet WHERE id = @bag_exist_pallet_id),
					                             CONCAT('id ', @bag_exist_pallet_id)),
					                      ').');
				ELSE
					SET @message = NULL;

				IF @message IS NOT NULL
				BEGIN
					ROLLBACK TRANSACTION;
					SET @status    = 'error';
					SET @pallet_id = NULL;
					SET @bag_id    = NULL;
				END
				ELSE
				BEGIN
					IF @is_new_pallet = 'Y'
					BEGIN
						SET @pallet_no = dbo.fGetPalletNo('J');

						INSERT INTO dbo.tr_pallet
							( ref_pallet, pallet_no, pallet_type, pd_group_code, unit_ratio, unit_pallet,
							  pallet_status_id, is_active, remark,
							  create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
						VALUES
							( CONCAT(@cost_center, '|', @grade, '|', @lot, '|', @pallet_running_no),
							  @pallet_no, 'J', @pd_group_code, @unit_ratio, @unit_pallet,
							  2, 'Y', CONCAT('Auto create JB: ', @grade, ' / ', @lot, ' #', @pallet_running_no),
							  ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A' );

						SET @pallet_id = SCOPE_IDENTITY();
					END

					IF @is_new_bag = 'Y'
					BEGIN
						INSERT INTO dbo.tr_bag
							( cost_center, pallet_id, pallet_running_no, ton_no, bag_no, grade, lot,
							  qr_text_data, mode_id, bag_status_id,
							  create_user_id, create_datetime, update_user_id, update_datetime )
						VALUES
							( @cost_center, @pallet_id, @pallet_running_no, @pallet_running_no,
							  @bag_no, @grade, @lot,
							  LTRIM(RTRIM(@qr_code_text)), 2, 2,   -- TODO(confirm) mode_id = 2
							  ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE() );

						SET @bag_id = SCOPE_IDENTITY();
					END
					ELSE
					BEGIN
						-- bag printed earlier but never put on a pallet
						UPDATE dbo.tr_bag
						SET    pallet_id       = @pallet_id,
						       bag_no          = @bag_no,
						       ton_no          = @pallet_running_no,
						       bag_status_id   = 2,
						       update_user_id  = ISNULL(@user_id, 0),
						       update_datetime = GETDATE()
						WHERE  id = @bag_id AND pallet_id IS NULL;
					END

					COMMIT TRANSACTION;

					-- another scan may have created both while this one waited for the lock
					IF @is_new_pallet = 'Y' OR @is_new_bag = 'Y'
					BEGIN
						SET @status  = 'success';
						SET @message = CONCAT('JB pallet ',
						                      ISNULL(@pallet_no, (SELECT pallet_no FROM dbo.tr_pallet WHERE id = @pallet_id)),
						                      ' ready.');
					END
					ELSE
						SET @message = 'not a new JB bag.';
				END
			END
		END TRY
		BEGIN CATCH
			IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
			SET @status    = 'error';
			SET @message   = LEFT(ERROR_MESSAGE(), 200);
			SET @pallet_id = NULL;
			SET @bag_id    = NULL;
		END CATCH
	END

	IF @return_result = 1
		SELECT @status AS status, @message AS message, @pallet_id AS pallet_id, @bag_id AS bag_id;
END
GO
