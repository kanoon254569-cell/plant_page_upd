/* =====================================================================
   105_rollback_pProcessGetPalletList.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   ย้อน 105_ กลับเป็น definition บน prod ก่อนรัน (OBJECT_DEFINITION 2026-11-01)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================================
-- pProcessGetPalletList: also return ton_no
-- =============================================================
-- Boardman Pallet Management shows a Ton No. column. The real Ton No.
-- is tr_bag.ton_no; it is not the same as pallet_running_no (returned
-- as pallet_id) for 29,824 active bags on 10.31.1.74 (2026-10-28).
-- ton_no = MIN(tr_bag.ton_no) over the pallet's active bags. Only 4
-- pallets had more than one ton_no (2026-10-28).
--
-- Only step 3c (#ton) and the ton_no output column are new; the rest
-- is the same as sql/pProcessGetPalletList_use_vPalletBagGroup.sql.
--
-- Rollback: run sql/backup_20261028_pProcessGetPalletList.sql
-- =============================================================

CREATE OR ALTER PROC [dbo].[pProcessGetPalletList]
	@id INT = NULL,
	@pallet_id INT = NULL,
	@pallet_no NVARCHAR(100) = NULL,
	@grade NVARCHAR(255) = NULL,
	@lot NVARCHAR(255) = NULL,
	@location_type NVARCHAR(255) = NULL,
	@location_id INT = NULL,
	@pallet_type_id INT = NULL,
	@pallet_location_id INT = NULL,
	@qr_code VARCHAR(100) = NULL,
	@page INT = 1,
	@page_size INT = 20
AS
BEGIN
	SET NOCOUNT ON

	-- Resolve @qr_code (scanned QR text) to a pallet id via fQrCodeToPalletBag
	-- (tr_bag.qr_text_data first, then tr_pallet.pallet_no). @id still wins.
	DECLARE @qr_resolved_id INT = NULL

	IF @qr_code IS NOT NULL
	BEGIN
		SELECT @qr_resolved_id = pallet_id FROM dbo.fQrCodeToPalletBag(@qr_code)
	END

	DECLARE @find_id INT = COALESCE(@id, @qr_resolved_id)

	-- 1. total_count -- one row per (pallet, grade, lot) that matches the
	--    filters. A pallet can hold bags with several pallet_running_no
	--    values; they are one row (see
	--    sql/pProcessGetPalletList_one_row_per_pallet.sql).
	DECLARE @total_count INT

	SELECT @total_count = COUNT(*)
	FROM (
		SELECT 1 AS x
		FROM dbo.tr_pallet tp
		INNER JOIN dbo.vPalletBagGroup v WITH (NOEXPAND)
			ON v.pallet_id = tp.id
		WHERE tp.is_active = 'Y'
			AND tp.status_flag = 'A'
			AND (@find_id IS NULL OR tp.id = @find_id)
			AND (@pallet_no IS NULL OR tp.pallet_no = @pallet_no)
			AND (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
			AND (@location_id IS NULL OR tp.current_location_id = @location_id)
			AND (@grade IS NULL OR v.grade LIKE '%' + @grade + '%')
			AND (@lot IS NULL OR v.lot LIKE '%' + @lot + '%')
			AND (@pallet_id IS NULL OR v.pallet_running_no = @pallet_id)
		GROUP BY v.pallet_id, v.grade, v.lot
	) c
	OPTION (RECOMPILE, MERGE JOIN, ORDER GROUP)

	SELECT 'success' AS status,
		   CASE WHEN @total_count > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- 2. One page of rows, in the view's clustered index order.
	IF OBJECT_ID('tempdb..#page') IS NOT NULL
		DROP TABLE #page

	SELECT
		v.pallet_id AS pallet_id,
		MIN(v.pallet_running_no) AS pallet_running,
		v.grade AS grade,
		v.lot AS lot
	INTO #page
	FROM dbo.tr_pallet tp
	INNER JOIN dbo.vPalletBagGroup v WITH (NOEXPAND)
		ON v.pallet_id = tp.id
	WHERE tp.is_active = 'Y'
		AND tp.status_flag = 'A'
		AND (@find_id IS NULL OR tp.id = @find_id)
		AND (@pallet_no IS NULL OR tp.pallet_no = @pallet_no)
		AND (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
		AND (@location_id IS NULL OR tp.current_location_id = @location_id)
		AND (@grade IS NULL OR v.grade LIKE '%' + @grade + '%')
		AND (@lot IS NULL OR v.lot LIKE '%' + @lot + '%')
		AND (@pallet_id IS NULL OR v.pallet_running_no = @pallet_id)
	GROUP BY v.pallet_id, v.grade, v.lot
	ORDER BY v.pallet_id, v.grade, v.lot
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY
	OPTION (RECOMPILE)

	-- 3a. bag_count per pallet -- distinct (running no, bag no, grade, lot)
	--     among the bags that match the grade/lot/running filters.
	IF OBJECT_ID('tempdb..#bag_count') IS NOT NULL
		DROP TABLE #bag_count

	SELECT
		d.pallet_id,
		COUNT(*) AS bag_count
	INTO #bag_count
	FROM (
		SELECT DISTINCT b.pallet_id, b.pallet_running_no, b.bag_no, b.grade, b.lot
		FROM dbo.tr_bag b
		WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
			AND b.is_active = 'Y'
			AND b.status_flag = 'A'
			AND (@grade IS NULL OR b.grade LIKE '%' + @grade + '%')
			AND (@lot IS NULL OR b.lot LIKE '%' + @lot + '%')
			AND (@pallet_id IS NULL OR b.pallet_running_no = @pallet_id)
	) d
	GROUP BY d.pallet_id

	-- 3b. All active bags per pallet (what fGetPalletQty counts).
	IF OBJECT_ID('tempdb..#qty_bag_count') IS NOT NULL
		DROP TABLE #qty_bag_count

	SELECT
		b.pallet_id,
		COUNT(*) AS bag_count
	INTO #qty_bag_count
	FROM dbo.tr_bag b
	WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
		AND b.is_active = 'Y'
		AND b.status_flag = 'A'
	GROUP BY b.pallet_id

	-- 3c. Ton No. per pallet -- MIN(tr_bag.ton_no) over active bags.
	IF OBJECT_ID('tempdb..#ton') IS NOT NULL
		DROP TABLE #ton

	SELECT
		b.pallet_id,
		MIN(b.ton_no) AS ton_no
	INTO #ton
	FROM dbo.tr_bag b
	WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
		AND b.is_active = 'Y'
		AND b.status_flag = 'A'
	GROUP BY b.pallet_id

	-- 3d. Paginated pallet list.
	SELECT
		tp.id AS id,
		pg.pallet_running AS pallet_id,
		tp.pallet_no AS pallet_no,
		t.ton_no AS ton_no,
		pg.grade AS grade,
		pg.lot AS lot,
		tp.pd_type_code AS pallet_type,
		tp.current_location_id AS current_location_id,
		COALESCE(clt.name, 'Bagging Area') AS location_type,
		tp.current_location_type AS location_type_code,
		COALESCE(
			MAX(cpl.bg_plant_desc COLLATE DATABASE_DEFAULT),
			MAX(rqcc.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(csz.zone_name COLLATE DATABASE_DEFAULT),
			MAX(csl.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(sd.dock_name COLLATE DATABASE_DEFAULT),
			MAX(vm.VEHICLE COLLATE DATABASE_DEFAULT),
			IIF(tp.current_location_id IS NULL, 'Bagging Area', NULL)
		) AS current_location,
		tp.unit_pallet,
		tp.unit_ratio,
		CASE
			WHEN tp.pallet_type IN ('M', 'S') THEN ISNULL(tp.unit_ratio, 0) * ISNULL(tp.unit_pallet, 0)
			ELSE ISNULL(qbc.bag_count, 0) * ISNULL(tp.unit_ratio, 0)
		END AS qty,
		CASE WHEN tp.pallet_type IN ('M', 'S') THEN 'Y' WHEN bc.bag_count >= tp.unit_pallet THEN 'Y' ELSE 'N' END AS is_full_pallet,
		tp.create_datetime AS create_datetime
	FROM #page pg
	INNER JOIN dbo.tr_pallet tp
		ON tp.id = pg.pallet_id
	LEFT JOIN #bag_count bc
		ON bc.pallet_id = pg.pallet_id
	LEFT JOIN #qty_bag_count qbc
		ON qbc.pallet_id = pg.pallet_id
	LEFT JOIN #ton t
		ON t.pallet_id = pg.pallet_id
	LEFT JOIN dbo.ct_location_type clt
		ON clt.code = tp.current_location_type
		AND clt.is_active = 'Y'
		AND clt.status_flag = 'A'
	LEFT JOIN dbo.ct_bg_plant_location cpl
		ON cpl.id = tp.current_location_id
		AND cpl.is_active = 'Y'
		AND cpl.status_flag = 'A'
		AND tp.current_location_type = 'BG-PLANT'
	LEFT JOIN IRPC_E_TRANSFER.dbo.ct_request_cost_center rqcc
		ON rqcc.id = tp.current_location_id
		AND rqcc.is_active = 'Y'
		AND rqcc.status_flag = 'A'
		AND tp.current_location_type = 'RQ-PLANT'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_dock] sd
		ON sd.id = tp.current_location_id
		AND sd.is_active = 'Y'
		AND sd.status_flag = 'A'
		AND tp.current_location_type = 'DOCK'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_zone] csz
		ON csz.id = tp.current_location_id
		AND csz.is_active = 'Y'
		AND csz.status_flag = 'A'
		AND tp.current_location_type = 'PRE-ZONE'
	LEFT JOIN dbo.ct_special_location csl
		ON csl.id = tp.current_location_id
		AND csl.is_active = 'Y'
		AND csl.status_flag = 'A'
		AND tp.current_location_type = 'SPC-ZONE'
	LEFT JOIN [IRPC].[dbo].[VVehicleMaster] vm
		ON vm.vechicle_id = tp.current_location_id
		AND tp.current_location_type = 'VEHICLE'
	GROUP BY tp.id, pg.pallet_running, tp.pallet_no, pg.grade, pg.lot, tp.pd_type_code, tp.pallet_type, tp.current_location_id, tp.current_location_type, tp.unit_pallet, tp.unit_ratio, bc.bag_count, qbc.bag_count, tp.create_datetime, clt.name, t.ton_no
	ORDER BY tp.id, pg.grade, pg.lot

	-- total_count -- same rows paging walks over (1 per pallet+grade+lot).
	SELECT @total_count AS total_count
END
GO
