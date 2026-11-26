/* =====================================================================
   127_rollback_pProcessInsertTrBag.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   คืน pProcessInsertTrBag กลับเป็นเวอร์ชัน 115_ (UPDLOCK + HOLDLOCK)
   = OBJECT_DEFINITION จาก .75 (RY19-OPS13DBQAS) วันที่ 2026-11-14 , modify_date 2026-11-11 16:34
   ===================================================================== */
GO
-- pProcessInsertTrBag '1301|V1160SUB|L0001|01|109', 3
ALTER PROC [dbo].[pProcessInsertTrBag]
	@qr_text_data			VARCHAR(100)			= NULL,
	@mode_id				INT						= NULL
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;      -- (115_) timeout / error -> ROLLBACK ทันที ไม่มี transaction ค้าง

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
	-- Parse QR code data  (115_ : ตามลำดับแน่นอน แทน STRING_SPLIT)
	--   @s = QR + '|' ปิดท้าย -> field ที่ k อยู่ระหว่าง '|' ตัวที่ k-1 กับตัวที่ k
	--   ไม่มี '|' ตัวที่ k -> field ที่ k = NULL (เหมือน STRING_SPLIT ที่ไม่มีแถวนั้น)
	-- ================================================

	DECLARE @cost_center VARCHAR(20);
	DECLARE @pallet_id   VARCHAR(20);
	DECLARE @bag_no      VARCHAR(20);
    DECLARE @grade       VARCHAR(20);
    DECLARE @lot         VARCHAR(20);

	DECLARE @s VARCHAR(101) = @qr_text_data + '|',
	        @p1 INT, @p2 INT, @p3 INT, @p4 INT, @p5 INT;

	SET @p1 = CHARINDEX('|', @s);
	SET @p2 = CASE WHEN @p1 > 0 THEN CHARINDEX('|', @s, @p1 + 1) ELSE 0 END;
	SET @p3 = CASE WHEN @p2 > 0 THEN CHARINDEX('|', @s, @p2 + 1) ELSE 0 END;
	SET @p4 = CASE WHEN @p3 > 0 THEN CHARINDEX('|', @s, @p3 + 1) ELSE 0 END;
	SET @p5 = CASE WHEN @p4 > 0 THEN CHARINDEX('|', @s, @p4 + 1) ELSE 0 END;

	SET @cost_center = SUBSTRING(@s, 1, @p1 - 1);                                          -- @p1 > 0 เสมอ (มี '|' ปิดท้าย)
	SET @grade       = CASE WHEN @p2 > 0 THEN SUBSTRING(@s, @p1 + 1, @p2 - @p1 - 1) END;
	SET @lot         = CASE WHEN @p3 > 0 THEN SUBSTRING(@s, @p2 + 1, @p3 - @p2 - 1) END;
	SET @bag_no      = CASE WHEN @p4 > 0 THEN SUBSTRING(@s, @p3 + 1, @p4 - @p3 - 1) END;
	SET @pallet_id   = CASE WHEN @p5 > 0 THEN SUBSTRING(@s, @p4 + 1, @p5 - @p4 - 1) END;

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
	-- Check for duplicate QR code data + insert  (115_ : atomic)
	--   UPDLOCK + HOLDLOCK = lock ช่วง key ของ QR นี้ใน IX_tr_bag_qr_text_data จน COMMIT
	--   -> connection อื่นที่ส่ง QR เดียวกันต้องรอ แล้วเห็นแถวนี้ -> Duplicate
	-- ================================================

	BEGIN TRAN;

	IF EXISTS (SELECT 1 FROM dbo.tr_bag WITH (UPDLOCK, HOLDLOCK)
	           WHERE qr_text_data = @qr_text_data AND mode_id <> 3 AND status_flag = 'A')
	BEGIN
		ROLLBACK TRAN;
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

	COMMIT TRAN;

	SELECT 'success' AS status, 'ok' AS message

END
GO
