/* =====================================================================
   Forklift หลาย Warehouse -- ct_forklift.wh_code เก็บแบบคั่นด้วย comma
   -----------------------------------------------------------------
   หน้า forklift-management (Add / Edit modal) ให้เลือกได้หลาย WH แล้ว
   ส่ง whCode = 'M43,M44,...' มาที่ PUT/POST api/v1/master/forklift

   1) ขยาย ct_forklift.wh_code เป็น 500 ตัวอักษร (คง type varchar/nvarchar
      และ NULL/NOT NULL เดิมไว้) -- ถ้ามี index/constraint บนคอลัมน์นี้
      ALTER COLUMN จะ error ต้อง drop แล้วสร้างใหม่เอง
   2) pProcessInsertUpdateCtForklift
      - @wh_code / @oldwh_code ขยายเป็น 500
      - ตัดช่องว่างออก ('M43, M44' -> 'M43,M44') และ '' ถือเป็น NULL
        (NULL = ไม่แตะค่าเดิม ตามพฤติกรรมเดิมของ ISNULL(@wh_code,[wh_code]))

   รันซ้ำได้ (idempotent)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1) ขยายคอลัมน์ ct_forklift.wh_code
DECLARE @col_type SYSNAME, @col_len INT, @col_nullable BIT, @sql NVARCHAR(MAX);

SELECT  @col_type     = t.name,
        @col_len      = CASE WHEN t.name IN ('nvarchar', 'nchar') THEN c.max_length / 2 ELSE c.max_length END,
        @col_nullable = c.is_nullable
FROM    sys.columns c
JOIN    sys.types   t ON t.user_type_id = c.user_type_id
WHERE   c.object_id = OBJECT_ID('dbo.ct_forklift')
AND     c.name      = 'wh_code';

IF @col_type IS NULL
    RAISERROR('dbo.ct_forklift.wh_code not found.', 16, 1);
ELSE IF @col_len <> -1 AND @col_len < 500
BEGIN
    SET @sql = N'ALTER TABLE dbo.ct_forklift ALTER COLUMN wh_code '
             + CASE WHEN @col_type IN ('nvarchar', 'nchar') THEN N'NVARCHAR(500)' ELSE N'VARCHAR(500)' END
             + CASE WHEN @col_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END;
    EXEC sp_executesql @sql;
END
GO

-- 2) Stored procedure
-- pProcessInsertUpdateCtForklift 4, 'TLWL-04(A)', 'M43,M44', '0', 1, 'Y', '', 'U'
ALTER   PROC [dbo].[pProcessInsertUpdateCtForklift]
	@id				INT				= NULL,
	@name			VARCHAR(100)	= NULL,
	@wh_code		VARCHAR(500)	= NULL,		-- หลาย WH คั่นด้วย comma เช่น 'M43,M44'
	@user_id		VARCHAR(50)		= NULL,
	@fl_status_id	INT				= NULL,
	@is_active		VARCHAR(1)		= NULL,
	@remark			VARCHAR(MAX)	= NULL,
	@flag			VARCHAR(1)		= NULL
AS
BEGIN
	DECLARE @topic	VARCHAR(10)		= 'Forklift';
	SET NOCOUNT ON;

	-- normalize รายการ WH: ตัดช่องว่าง, '' -> NULL (ไม่แตะค่าเดิม)
	SET @wh_code = NULLIF(REPLACE(LTRIM(RTRIM(@wh_code)), ' ', ''), '');

        if @flag = 'C'
		begin
			INSERT INTO [dbo].[ct_forklift]
				(
					[name],
					[wh_code],
					[create_user_id]

				)
			VALUES
				(
					@name,
					@wh_code,
					@user_id
				)
			DECLARE @create_id  INT;
			SET @create_id = SCOPE_IDENTITY() ;
			SELECT 'success' AS status, 'ok' AS message
		end
		else if @flag = 'U'
        begin
			DECLARE
				@oldname NVARCHAR(100),
				@oldwh_code NVARCHAR(500),
				@oldfl_status_id INT,
				@oldis_active VARCHAR(1),
				@oldremark VARCHAR(MAX);
			SELECT
				@oldname = [name],
				@oldwh_code = [wh_code],
				@oldfl_status_id = [forklift_status_id],
				@oldis_active = [is_active],
				@oldremark = [remark]
			FROM [dbo].[ct_forklift]
			WHERE id=@id;
			UPDATE [dbo].[ct_forklift]
			SET	[name] = ISNULL(@name, [name]),
				[wh_code] = ISNULL(@wh_code, [wh_code]),
				[forklift_status_id] = ISNULL(@fl_status_id, [forklift_status_id]),
				[is_active] = ISNULL(@is_active, [is_active]),
				[remark] = @remark,
				[update_user_id] = @user_id,
				[update_datetime] = getdate()
			WHERE id=@id;
			SELECT 'success' AS status, 'ok' AS message
		end
		else if @flag = 'D'
        begin
			DECLARE @deletename NVARCHAR(100) = (SELECT [name] FROM [dbo].[ct_forklift] WHERE id = @id);

            UPDATE [dbo].[ct_forklift]
            SET status_flag = 'D',
                [update_user_id] = @user_id,
				[update_datetime] = getdate()
            WHERE ID = @id;

            SELECT N'ลบ Forlift สำเร็จ' as message, 'success' as status;
        end
        else
        begin
            raiserror('Forlift not found.: C, U, D.', 16, 1);
        end
		begin

		-- ======================================================================
		-- Insert log to tr_transaction_log
		-- (detail is built here as a ready-to-display Thai sentence -
		--  pProcessGetTransactionLog just returns it as-is)
		-- ======================================================================

		DECLARE	@activity VARCHAR(10)	= '';
		DECLARE @detail	NVARCHAR(MAX)	= '';
		DECLARE @display_name NVARCHAR(100);
		DECLARE @sentence NVARCHAR(MAX) = '';
		DECLARE @clause NVARCHAR(MAX);
		DECLARE @skip_log BIT = 0;

			if	@flag = 'C'
			begin
				SET	@activity += 'Create'
				SET @sentence = N'โฟร์คลิฟท์ ' + ISNULL(@name, N'') + N':สร้างเข้าระบบ'
				SET @detail   = N'ID: ' + CAST(@create_id AS VARCHAR(max)) + N' | ' + @sentence
			end
			if	@flag = 'U'
			begin
				SET @activity += 'Update'
				SET @display_name = ISNULL(@name, @oldname);

				-- แต่ละ field ที่เปลี่ยนจริง ใส่เป็น "{label} *เก่า* → *ใหม่*" แล้วคั่นด้วย ", "
				-- ค่าเก่า/ค่าใหม่ยังห่อด้วย *...* (single-asterisk marker) ให้ front-end split เอง
				-- แล้ว render เป็นตัวหนา - ไม่ใช่ HTML tag ตรงๆ เพื่อกัน stored XSS จาก remark ที่เป็น free text
				-- UPDATE ใช้ ISNULL(@param,[column]) กับ name/wh_code/fl_status_id/is_active - @param เป็น
				-- NULL แปลว่า "ไม่แตะ" ไม่ใช่ "เปลี่ยนเป็นค่าว่าง" จึงเช็ค IS NOT NULL ก่อนทุกครั้ง
				if @name IS NOT NULL AND ISNULL(@oldname, '') <> @name
				begin
					SET @clause = N'ชื่อ *' + ISNULL(@oldname, N'ค่าว่าง') + N'* → *' + @name + N'*'
					SET @sentence += CASE WHEN @sentence = '' THEN '' ELSE N', ' END + @clause
				end

				if @wh_code IS NOT NULL AND ISNULL(@oldwh_code, '') <> @wh_code
				begin
					SET @clause = N'คลัง *' + ISNULL(@oldwh_code, N'ค่าว่าง') + N'* → *' + @wh_code + N'*'
					SET @sentence += CASE WHEN @sentence = '' THEN '' ELSE N', ' END + @clause
				end

				if @fl_status_id IS NOT NULL AND ISNULL(@oldfl_status_id, -1) <> @fl_status_id
				begin
					SET @clause = N'สถานะรถ *'
						+ ISNULL((SELECT [name] FROM dbo.ct_forklift_status WHERE id = @oldfl_status_id), N'ค่าว่าง')
						+ N'* → *'
						+ ISNULL((SELECT [name] FROM dbo.ct_forklift_status WHERE id = @fl_status_id), N'ค่าว่าง')
						+ N'*'
					SET @sentence += CASE WHEN @sentence = '' THEN '' ELSE N', ' END + @clause
				end

				if @is_active IS NOT NULL AND ISNULL(@oldis_active, '') <> @is_active
				begin
					SET @clause = N'การใช้งาน *'
						+ CASE @oldis_active WHEN 'Y' THEN N'เปิดใช้งาน' WHEN 'N' THEN N'ปิดใช้งาน' ELSE N'ค่าว่าง' END
						+ N'* → *'
						+ CASE @is_active WHEN 'Y' THEN N'เปิดใช้งาน' WHEN 'N' THEN N'ปิดใช้งาน' ELSE N'ค่าว่าง' END
						+ N'*'
					SET @sentence += CASE WHEN @sentence = '' THEN '' ELSE N', ' END + @clause
				end

				if ISNULL(NULLIF(@oldremark, ''), '') <> ISNULL(NULLIF(@remark, ''), '')
				begin
					SET @clause = N'หมายเหตุ *' + ISNULL(NULLIF(@oldremark, ''), N'ค่าว่าง') + N'* → *' + ISNULL(NULLIF(@remark, ''), N'ค่าว่าง') + N'*'
					SET @sentence += CASE WHEN @sentence = '' THEN '' ELSE N', ' END + @clause
				end

				IF @sentence = ''
					SET @skip_log = 1;  -- ไม่มีข้อมูลเปลี่ยนแปลง - ไม่ต้อง insert log เลย
				ELSE
				BEGIN
					SET @sentence = N'โฟร์คลิฟท์ ' + ISNULL(@display_name, N'') + N':' + @sentence
					SET @detail = N'ID: ' + CAST(@id AS VARCHAR(max)) + N' | ' + @sentence
				END
			end
			if	@flag = 'D'
			begin
				SET @activity += 'Delete'
				SET @sentence = N'โฟร์คลิฟท์ ' + ISNULL(@deletename, N'') + N':ลบออกจากระบบ'
				SET @detail   = N'ID: ' + CAST(@id AS VARCHAR(max)) + N' | ' + @sentence
			end
			SET NOCOUNT ON;

			IF @skip_log = 0
			BEGIN
				-- tr_transaction_log.detail is nvarchar(255) - a plain
				-- INSERT longer than that errors out ("String or binary
				-- data would be truncated") and would abort the whole
				-- log insert. Truncate defensively so a long remark
				-- (or a long multi-warehouse list) never breaks logging.
				SET @detail = LEFT(@detail, 255);

				INSERT INTO [dbo].[tr_transaction_log](
					topic,
					activity,
					detail,
					create_user_id,
					create_datetime,
					update_user_id,
					update_datetime
					)
				VALUES(
					@topic,
					@activity,
					@detail,
					@user_id,
					getdate(),
					@user_id,
					getdate()
					);
			END
		end

END
GO
