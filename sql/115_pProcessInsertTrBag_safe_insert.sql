/* =====================================================================
   115_pProcessInsertTrBag_safe_insert.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   base = definition บน prod (OBJECT_DEFINITION 2026-11-11 , modify 2026-09-27)
   ผลลัพธ์ที่คืน (1 result set : status , message) และข้อความทุกตัว "เหมือนเดิมทุกตัวอักษร"
   -> C# WmsController.InsertBag (mode 3) และโปรแกรมพิมพ์ QR (Python) ไม่ต้องแก้

   แก้ 3 เรื่อง :
   1) แกะ QR แบบรับประกันลำดับ
      เดิม : STRING_SPLIT + ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
             SQL Server ไม่รับประกันลำดับแถวของ STRING_SPLIT -> field อาจสลับช่องได้
             (เช่น lot ไปลงช่อง grade) แม้ปกติจะออกมาตามลำดับก็ตาม
      ใหม่ : หาตำแหน่ง '|' ด้วย CHARINDEX ทีละตัว ผลเท่า STRING_SPLIT ตามลำดับทุกกรณี
             (field ที่ไม่มี = NULL , field ว่าง = '' , field ที่ 6 ขึ้นไปไม่ใช้)

   2) ตรวจ QR ซ้ำ + INSERT เป็นงานเดียว (atomic)
      เดิม : IF EXISTS แล้วค่อย INSERT -- 2 connection ส่ง QR เดียวกันพร้อมกัน (เช่น client retry
             หลัง timeout ทั้งที่รอบแรกยังค้างอยู่) ผ่านการตรวจทั้งคู่ -> ได้ 2 แถว
      ใหม่ : transaction สั้น ๆ + WITH (UPDLOCK, HOLDLOCK) บน index IX_tr_bag_qr_text_data
             -> คนที่สองรอจนคนแรก COMMIT แล้วเจอว่าซ้ำ ; lock แค่ช่วง key ของ QR นั้น
             ถือ lock แค่ช่วง INSERT 1 แถว (ไม่กี่ ms)
      (unique index ทำไม่ได้ : prod มี QR ซ้ำอยู่แล้ว 72 ค่า -- QR 3 field (cc|grade|lot) 71 ค่า
       12,986 แถว mode 1 และ QR ถุง 5 field 1 ค่า mode 2)

   3) SET NOCOUNT ON + SET XACT_ABORT ON
      client timeout (attention) กลางคัน -> transaction ถูก ROLLBACK ทันที ไม่ค้างถือ lock
      NOCOUNT : ไม่ส่ง "1 row affected" กลับไป (pyodbc / ADO.NET อ่าน result set ได้ตรงขึ้น)

   ไม่เปลี่ยน : เงื่อนไขซ้ำ (mode_id <> 3 AND status_flag = 'A' ของแถวที่มีอยู่) , การตรวจความยาว ,
               คอลัมน์ที่ INSERT , ton_no = pallet_running_no , ข้อความ error ทุกตัว
   retry ฝั่ง client : ได้ 'Duplicate QR code data.' ตอน retry = รอบก่อนบันทึกสำเร็จแล้ว
   ย้อนกลับ : 115_rollback_pProcessInsertTrBag.sql
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

-- ทดสอบ (บน DB ทดสอบ) :
-- EXEC dbo.pProcessInsertTrBag '1301|V1160SUB|L0001|01|109', 3;
