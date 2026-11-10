/* =====================================================================
   ct_forklift.section_id -- Section ของ Forklift (เลือกได้หลายค่า)
   -----------------------------------------------------------------
   section_id varchar(100) เก็บ id คั่นด้วย comma เช่น '1,3'
       1 = Warehouse
       2 = Loading
       3 = Pallet
   (คอลัมน์ section_id ถูกเพิ่มใน ct_forklift ด้วยมือแล้ว)

   - pProcessInsertUpdateCtForklift : เพิ่ม @section_id (C / U) + log การเปลี่ยน section
                                      + บันทึก @is_active, @remark ตอนสร้าง (C) ด้วย
   - pProcessGetForkliftList        : คืนคอลัมน์ section_id + filter @section_ids

   รันหลัง : 29_pProcessInsertUpdateCtForklift_multi_wh.sql,
             30_pProcessGetForkliftList_multi_wh.sql
             (ไฟล์นี้ ALTER ทั้ง 2 SP ทับด้วยเวอร์ชันที่มี section_id)
   รันซ้ำได้ (idempotent)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1) pProcessInsertUpdateCtForklift
-- pProcessInsertUpdateCtForklift 4, 'TLWL-04(A)', 'M43,M44', '0', 1, 'Y', '', 'U', '1,3'
ALTER   PROC [dbo].[pProcessInsertUpdateCtForklift]
	@id				INT				= NULL,
	@name			VARCHAR(100)	= NULL,
	@wh_code		VARCHAR(500)	= NULL,		-- หลาย WH คั่นด้วย comma เช่น 'M43,M44'
	@user_id		VARCHAR(50)		= NULL,
	@fl_status_id	INT				= NULL,
	@is_active		VARCHAR(1)		= NULL,
	@remark			VARCHAR(MAX)	= NULL,
	@flag			VARCHAR(1)		= NULL,
	@section_id		VARCHAR(100)	= NULL		-- หลาย section id คั่นด้วย comma: 1=Warehouse, 2=Loading, 3=Pallet
AS
BEGIN
	DECLARE @topic	VARCHAR(10)		= 'Forklift';
	SET NOCOUNT ON;

	-- normalize รายการ WH: ตัดช่องว่าง, '' -> NULL (ไม่แตะค่าเดิม)
	SET @wh_code = NULLIF(REPLACE(LTRIM(RTRIM(@wh_code)), ' ', ''), '');
	-- normalize รายการ section id แบบเดียวกัน
	SET @section_id = NULLIF(REPLACE(LTRIM(RTRIM(@section_id)), ' ', ''), '');

        if @flag = 'C'
		begin
			INSERT INTO [dbo].[ct_forklift]
				(
					[name],
					[wh_code],
					[section_id],
					[is_active],
					[remark],
					[create_user_id]

				)
			VALUES
				(
					@name,
					@wh_code,
					@section_id,
					ISNULL(NULLIF(@is_active, ''), 'Y'),	-- ไม่ส่งมา = เปิดใช้งาน
					NULLIF(@remark, ''),
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
				@oldsection_id VARCHAR(100),
				@oldfl_status_id INT,
				@oldis_active VARCHAR(1),
				@oldremark VARCHAR(MAX);
			SELECT
				@oldname = [name],
				@oldwh_code = [wh_code],
				@oldsection_id = [section_id],
				@oldfl_status_id = [forklift_status_id],
				@oldis_active = [is_active],
				@oldremark = [remark]
			FROM [dbo].[ct_forklift]
			WHERE id=@id;
			UPDATE [dbo].[ct_forklift]
			SET	[name] = ISNULL(@name, [name]),
				[wh_code] = ISNULL(@wh_code, [wh_code]),
				[section_id] = ISNULL(@section_id, [section_id]),
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
				-- UPDATE ใช้ ISNULL(@param,[column]) กับ name/wh_code/section_id/fl_status_id/is_active - @param เป็น
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

				-- section id (1/2/3) -> ชื่อ ก่อนใส่ log เช่น '1,3' -> 'Warehouse,Pallet'
				if @section_id IS NOT NULL AND ISNULL(@oldsection_id, '') <> @section_id
				begin
					SET @clause = N'Section *'
						+ ISNULL(REPLACE(REPLACE(REPLACE(NULLIF(@oldsection_id, ''), '1', 'Warehouse'), '2', 'Loading'), '3', 'Pallet'), N'ค่าว่าง')
						+ N'* → *'
						+ REPLACE(REPLACE(REPLACE(@section_id, '1', 'Warehouse'), '2', 'Loading'), '3', 'Pallet')
						+ N'*'
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

-- 2) pProcessGetForkliftList
ALTER PROC [dbo].[pProcessGetForkliftList]
	@id						INT						= NULL,
	@fl_name				NVARCHAR(255)			= NULL,
	@wh_codes				NVARCHAR(MAX)			= NULL,
	@status_id				INT						= NULL,
	@is_active				VARCHAR(1)				= NULL,
	@page					INT						= 1,
	@page_size				INT						= 10,
	@section_ids			VARCHAR(100)			= NULL		-- filter section id คั่นด้วย comma เช่น '1,3'
AS
BEGIN
	-- =============================================================
	-- Get forklift data with pagination
	-- =============================================================

	SELECT
		fl.id,
		fl.name AS forklift_name,
		wh.warehouse_code,
		wh.wms_name,
		fl.section_id AS section_id,
		fs.name AS forklift_status,
		fl.current_user_id AS current_user_id,
		ul.user_name AS current_user_name,
		ul.Thia_name AS current_user_thai_name,
		fl.last_used_user_id AS last_used_user_id,
		ul.user_name AS last_used_user_name,
		ul.Thia_name AS last_used_user_thai_name,
		fl.update_datetime AS lasted_used_datetime,
		fl.update_datetime AS updated_datetime,
		fl.is_active AS status_active,
		fl.remark AS remark
	INTO #forklift
	FROM dbo.ct_forklift fl
	-- รวมทุก WH ของ forklift (wh_code คั่นด้วย comma) เป็น 1 แถว
	OUTER APPLY (
		SELECT
			warehouse_code = STUFF((
				SELECT ',' + ISNULL(cs.storage_name COLLATE DATABASE_DEFAULT, LTRIM(RTRIM(s.value)))
				FROM STRING_SPLIT(fl.wh_code, ',') s
				OUTER APPLY (
					SELECT TOP 1 c.storage_name, c.wms_name
					FROM [IRPC].[dbo].[ct_storage] c
					WHERE c.wms_name = LTRIM(RTRIM(s.value)) COLLATE Thai_100_CI_AI_KS
						AND c.is_active = 'Y'
						AND c.status_flag = 'A'
				) cs
				WHERE LTRIM(RTRIM(s.value)) <> ''
				FOR XML PATH(''), TYPE
			).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
			wms_name = STUFF((
				SELECT ',' + ISNULL(cs.wms_name COLLATE DATABASE_DEFAULT, LTRIM(RTRIM(s.value)))
				FROM STRING_SPLIT(fl.wh_code, ',') s
				OUTER APPLY (
					SELECT TOP 1 c.wms_name
					FROM [IRPC].[dbo].[ct_storage] c
					WHERE c.wms_name = LTRIM(RTRIM(s.value)) COLLATE Thai_100_CI_AI_KS
						AND c.is_active = 'Y'
						AND c.status_flag = 'A'
				) cs
				WHERE LTRIM(RTRIM(s.value)) <> ''
				FOR XML PATH(''), TYPE
			).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
	) wh
	LEFT JOIN dbo.ct_forklift_status fs
		ON fl.forklift_status_id = fs.id
		AND fs.is_active = 'Y'
		AND fs.status_flag = 'A'
	LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
		ON fl.current_user_id = ul.ID
		AND ul.status_flag = 'A'
	WHERE (@id IS NULL OR fl.id = @id)
		AND (@fl_name IS NULL OR fl.name LIKE '%' + @fl_name + '%')
		AND (
			@wh_codes IS NULL
			OR LTRIM(RTRIM(@wh_codes)) = ''
			-- forklift มี WH ใดก็ได้ตรงกับที่เลือกใน filter
			OR EXISTS (
				SELECT 1
				FROM STRING_SPLIT(fl.wh_code, ',') s
				JOIN STRING_SPLIT(@wh_codes, ',') f
					ON LTRIM(RTRIM(s.value)) COLLATE Thai_100_CI_AI_KS = LTRIM(RTRIM(f.value)) COLLATE Thai_100_CI_AI_KS
				WHERE LTRIM(RTRIM(s.value)) <> ''
			)
		)
		AND (
			@section_ids IS NULL
			OR LTRIM(RTRIM(@section_ids)) = ''
			-- forklift มี section ใดก็ได้ตรงกับที่เลือกใน filter
			OR EXISTS (
				SELECT 1
				FROM STRING_SPLIT(fl.section_id, ',') s
				JOIN STRING_SPLIT(@section_ids, ',') f
					ON LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(f.value))
				WHERE LTRIM(RTRIM(s.value)) <> ''
			)
		)
		AND (@is_active IS NULL OR @is_active = fl.is_active)
		AND fl.status_flag = 'A'

	SELECT CASE WHEN COUNT(*) > 0 THEN 'success' ELSE 'success' END AS status,
		   CASE WHEN COUNT(*) > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message
	FROM #forklift

	SELECT
		id,
		forklift_name,
		warehouse_code,
		wms_name,
		section_id,
		forklift_status,
		current_user_id,
		current_user_name,
		current_user_thai_name,
		last_used_user_id,
		last_used_user_name,
		last_used_user_thai_name,
		lasted_used_datetime,
		updated_datetime,
		status_active,
		remark
	FROM #forklift
	ORDER BY id
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY

	SELECT
		COUNT(*) AS total_count
	FROM #forklift
END
GO
