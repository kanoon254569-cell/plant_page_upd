-- =============================================================
-- 42_pProcessInsertJbPalletBag.sql  (IRPC_QTRACK)
-- =============================================================
-- Creates the tr_pallet + tr_bag rows for a JB bag QR on its first scan.
-- Split out of pProcessInboundGetPallet (41) so other scan procs can reuse it.
--
-- Uses dbo.fCheckPalletType (40_fCheckPalletType.sql):
--   * is_new_pallet = 'Y' -> INSERT tr_pallet
--       pallet_no   = dbo.fGetPalletNo('J')   ('PLJyymmdd####')
--       pallet_type = 'J', ref_pallet = cost_center|grade|lot|pallet_running_no
--       unit_ratio  = qty on the QR, unit_pallet = 1
--       pallet_status_id = 2 (COMPLETED: 1 bag = full pallet)
--   * is_new_bag = 'Y'    -> INSERT tr_bag on that pallet
--                            (bag_status_id = 2 MATCHED, mode_id = 2)
--   * bag already in tr_bag without a pallet -> link it to the pallet
--   * ct_grade_package_ratio is NOT touched here: whether a grade is JB comes
--     from WMS master (pk_unit_code -> unit_code = 'JB'), see 45.
--
-- @status OUTPUT:
--   'success' -> pallet and/or bag created or linked
--   'skip'    -> nothing to do: not a JB QR, QR invalid for fCheckPalletType
--                (e.g. a pallet_no), or pallet and bag already exist
--   'error'   -> create failed, @message has the reason
--
-- Result set: one row (status, message, pallet_id, bag_id) only when
-- @return_result = 1 (default). Callers inside another proc pass 0 so no
-- extra result set reaches the backend, and read the OUTPUT params.
--
-- Runs in its own transaction under an app lock, because fGetPalletNo
-- counts rows in tr_pallet and two scans at the same time could get the
-- same pallet_no. fCheckPalletType is re-read inside the lock.
--
-- TODO(confirm): mode_id = 2 for JB bags. It must not be NULL or 3, or the
-- duplicate check in pProcessInsertTrBag / fCheckPalletType (mode_id <> 3)
-- would not see the bag.
--
-- Usage:
--   EXEC dbo.pProcessInsertJbPalletBag
--        @qr_code_text = '1311|1105RC/750|7260804272|01|436|750|JB1', @user_id = 1;
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
		  AND (is_new_pallet = 'Y' OR is_new_bag = 'Y')
	)
	BEGIN
		DECLARE @cost_center       VARCHAR(20);
		DECLARE @grade             VARCHAR(20);
		DECLARE @lot               VARCHAR(20);
		DECLARE @pallet_running_no INT;
		DECLARE @bag_no            INT;
		DECLARE @pd_group_code     VARCHAR(20);
		DECLARE @unit_ratio        INT;
		DECLARE @unit_pallet       INT;
		DECLARE @pallet_no         VARCHAR(50);
		DECLARE @is_new_pallet     VARCHAR(1);
		DECLARE @is_new_bag        VARCHAR(1);
		DECLARE @lock              INT;

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
				SELECT @cost_center       = cost_center,
				       @grade             = grade,
				       @lot               = lot,
				       @pallet_running_no = pallet_running_no,
				       @bag_no            = bag_no_int,
				       @pd_group_code     = pd_group_code,
				       @unit_ratio        = unit_ratio,
				       @unit_pallet       = unit_pallet,
				       @pallet_id         = pallet_exist_id,
				       @bag_id            = bag_exist_id,
				       @is_new_pallet     = is_new_pallet,
				       @is_new_bag        = is_new_bag
				FROM   dbo.fCheckPalletType(@qr_code_text)
				WHERE  status = 'success' AND pallet_type_code = 'J';

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
