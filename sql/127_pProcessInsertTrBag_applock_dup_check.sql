/* =====================================================================
   127_pProcessInsertTrBag_applock_dup_check.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   base     = 115_ ที่ใช้งานอยู่ (OBJECT_DEFINITION บน .75 2026-11-14 , modify_date 2026-11-11 16:34)
   rollback = 127_rollback_pProcessInsertTrBag.sql

   ปัญหา : 115_ ตรวจ QR ซ้ำด้วย WITH (UPDLOCK, HOLDLOCK) -> serializable range lock บน
           IX_tr_bag_qr_text_data (key = qr_text_data, mode_id, bag_status_id) ซึ่งต้องล็อก key "ถัดไป"
           ของ QR ใหม่ด้วย ; ถ้าแถวนั้นถูก transaction อื่นแก้อยู่ (เช่น pServiceMatchBagToPallet
           UPDATE bag_status_id ของถุงใน lot เดียวกัน) INSERT ของเครื่องพิมพ์ต้องรอจนอีกฝั่ง COMMIT
           -> โปรแกรมพิมพ์ timeout (~1 s) แล้วทิ้งถุง

   แก้ : กันซ้ำด้วย sp_getapplock ต่อ QR (LockOwner = Transaction) แทน range lock
         - QR เดียวกันส่งมาพร้อมกัน -> ต่อคิวที่ app lock -> คนที่สองเห็นแถวของคนแรก -> Duplicate (เหมือน 115_)
         - QR ต่างกัน -> ไม่รอกันเลย และไม่ไปล็อก key ของถุงอื่น
         - lock ปล่อยเองตอน COMMIT / ROLLBACK (XACT_ABORT ON : timeout กลางคัน -> ROLLBACK -> ปล่อย)

   ไม่เปลี่ยน : การแกะ QR / ตรวจความยาว / เงื่อนไขซ้ำ (mode_id <> 3 AND status_flag = 'A') /
               คอลัมน์ที่ INSERT / ข้อความทุกตัวเดิม
   เพิ่ม     : ข้อความใหม่ 1 ตัว 'QR code data is being saved by another request. Please retry.'
               เฉพาะกรณีรอ app lock ของ QR เดียวกันเกิน 10 วินาที (ไม่ควรเกิด : คนถือ lock ใช้แค่ไม่กี่ ms)
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
	-- Check for duplicate QR code data + insert  (127_ : atomic ด้วย app lock ต่อ QR)
	--   เดิม (115_) : WITH (UPDLOCK, HOLDLOCK) บน IX_tr_bag_qr_text_data = range lock ไปถึง key ถัดไป
	--                 ถ้า key ถัดไปถูก matching แก้อยู่ (bag_status_id / pallet_id เป็น key / include
	--                 ของ index นี้) INSERT ต้องรอจน matching COMMIT -> client timeout -> ถุงหาย
	--   ใหม่ : sp_getapplock ชื่อ = QR -> คนที่ส่ง QR เดียวกันพร้อมกันต้องต่อคิวกันเอง (ไม่กี่ ms)
	--          ส่วนการตรวจซ้ำเป็นการอ่านธรรมดา ไม่ถือ lock ข้าม key ของถุงอื่นอีก
	--   ชื่อ lock ใช้ UPPER + RTRIM : applock เทียบชื่อแบบ binary แต่ "=" ในตาราง (Thai_CI_AI)
	--   ไม่สนตัวพิมพ์ใหญ่/เล็กและช่องว่างท้าย -> QR ที่ตารางถือว่าซ้ำกันต้องได้ lock ตัวเดียวกัน
	-- ================================================

	DECLARE @lk INT;
	DECLARE @lock_name NVARCHAR(255) = N'QTRACK_TrBagQr|' + UPPER(RTRIM(@qr_text_data));

	BEGIN TRAN;

	EXEC @lk = sp_getapplock @Resource    = @lock_name,
	                         @LockMode    = 'Exclusive',
	                         @LockOwner   = 'Transaction',
	                         @LockTimeout = 10000;
	IF @lk < 0
	BEGIN
		-- มีอีก connection กำลังบันทึก QR เดียวกันค้างเกิน 10 วินาที (ไม่ควรเกิด) -> ให้ client retry
		ROLLBACK TRAN;
		SELECT 'error' AS status, 'QR code data is being saved by another request. Please retry.' AS message
		RETURN
	END

	IF EXISTS (SELECT 1 FROM dbo.tr_bag
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
