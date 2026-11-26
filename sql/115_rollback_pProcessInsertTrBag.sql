/* =====================================================================
   115_rollback_pProcessInsertTrBag.sql  (IRPC_QTRACK)
   คืน pProcessInsertTrBag เป็น definition เดิมบน prod (ก่อน 115_)
   ดึงจาก OBJECT_DEFINITION 2026-11-11 (modify_date 2026-09-27 16:27)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- pProcessInsertTrBag '1301|V1160SUB|L0001|01|109', 3
CREATE OR ALTER PROC [dbo].[pProcessInsertTrBag] 
	@qr_text_data			VARCHAR(100)			= NULL,
	@mode_id				INT						= NULL
AS
BEGIN  
	-- ================================================
	-- Validate input parameters
	-- ================================================

	IF @qr_text_data IS NULL
	BEGIN
		SELECT 'error' AS status, 'QR Code data not found.' AS message
		RETURN
	END

	IF @mode_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'Mode not found.' AS message
		RETURN
	END

	-- ================================================
	-- Parse QR code data
	-- ================================================

	DECLARE @cost_center VARCHAR(20);
	DECLARE @pallet_id   VARCHAR(20);
	DECLARE @bag_no      VARCHAR(20);
    DECLARE @grade       VARCHAR(20);
    DECLARE @lot         VARCHAR(20);

	;WITH cte_qr_code_split AS
	(
		SELECT
			ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS rn,
			value
		FROM STRING_SPLIT(@qr_text_data, '|')
	)
	SELECT
		@cost_center = MAX(CASE WHEN rn = 1 THEN value END),
		@grade		 = MAX(CASE WHEN rn = 2 THEN value END),
		@lot		 = MAX(CASE WHEN rn = 3 THEN value END),
		@bag_no      = MAX(CASE WHEN rn = 4 THEN value END),
		@pallet_id   = MAX(CASE WHEN rn = 5 THEN value END)
	FROM cte_qr_code_split;

	-- ================================================
	-- Validate parsed data
	-- ================================================

	IF LEN(@cost_center) > 4
	BEGIN
		SELECT 'error' AS status, 'Invalid format cost center.' AS message
		RETURN
	END

	IF LEN(@pallet_id) > 3
	BEGIN
		SELECT 'error' AS status, 'Invalid pallet id.' AS message
		RETURN
	END

	IF LEN(@bag_no) > 2
	BEGIN
		SELECT 'error' AS status, 'Invalid bag no.' AS message
		RETURN
	END

	IF LEN(@grade) > 20
	BEGIN
		SELECT 'error' AS status, 'Invalid grade.' AS message
		RETURN
	END

	IF LEN(@lot) > 15
	BEGIN
		SELECT 'error' AS status, 'Invalid lot.' AS message
		RETURN
	END

	-- ================================================
	-- Check for duplicate QR code data
	-- ================================================

	IF EXISTS (SELECT 1 FROM dbo.tr_bag WHERE qr_text_data = @qr_text_data AND mode_id <> 3 AND status_flag = 'A')
	BEGIN
		SELECT 'error' AS status, 'Duplicate QR code data.' AS message
		RETURN
	END

	INSERT INTO dbo.tr_bag 
		(	
			cost_center,
			pallet_running_no,
			ton_no,
			bag_no,
			grade,
			lot,
			qr_text_data, 
			mode_id
		)
	VALUES 
		(
			@cost_center,
			@pallet_id,
			@pallet_id,
			@bag_no,
			@grade,
			@lot,
			@qr_text_data, 
			@mode_id
		)

	SELECT 'success' AS status, 'ok' AS message

END

GO
