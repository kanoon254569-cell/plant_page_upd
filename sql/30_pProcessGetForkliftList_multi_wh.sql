/* =====================================================================
   pProcessGetForkliftList -- รองรับ Forklift หลาย Warehouse
   -----------------------------------------------------------------
   ct_forklift.wh_code เก็บ wms_name ของ ct_storage คั่นด้วย comma
   (เช่น 'M43,M44') ตั้งแต่ 29_pProcessInsertUpdateCtForklift_multi_wh.sql

   - warehouse_code / wms_name : รวมทุก WH ของ forklift คั่นด้วย comma
       warehouse_code = ct_storage.storage_name ของแต่ละรหัส
       wms_name       = ct_storage.wms_name ของแต่ละรหัส
       รหัสที่หาใน ct_storage ไม่เจอ แสดงรหัสดิบแทน (เดิมได้ NULL)
     (ใช้ FOR XML PATH แทน STRING_AGG เผื่อ SQL Server ต่ำกว่า 2017)
   - @wh_codes filter : ได้ forklift ที่มี WH ใดก็ได้ตรงกับที่เลือก
   - ไม่ JOIN ct_storage ที่ query หลักแล้ว -> 1 forklift = 1 แถวเสมอ

   รันหลัง : 29_pProcessInsertUpdateCtForklift_multi_wh.sql
   รันซ้ำได้ (idempotent)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROC [dbo].[pProcessGetForkliftList]
	@id						INT						= NULL,
	@fl_name				NVARCHAR(255)			= NULL,
	@wh_codes				NVARCHAR(MAX)			= NULL,
	@status_id				INT						= NULL,
	@is_active				VARCHAR(1)				= NULL,
	@page					INT						= 1,
	@page_size				INT						= 10
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
