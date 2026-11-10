/* =====================================================================
   pProcessGetPalletList -- paginate first, then enrich only the page
   ---------------------------------------------------------------------
   Base: live on IRPC_QTRACK as of 2026-10-08.

   Backs GET api/v1/process/pallet (Pallet Management page). The old body
   took ~2.5 s for an unfiltered page of 25 (15k pallets / 145k bags):
   it joined all 7 location tables (3 of them cross-database), grouped
   every pallet and only then applied OFFSET/FETCH, and it repeated the
   bag/pallet joins for the status row and for total_count.

   Change (70): same parameters, same result sets, same columns.
     1. #rows   = the list grain (pallet x running no x grade x lot) with
                  every filter applied, built from tr_pallet + tr_bag only.
     2. #page   = one page of #rows (ORDER BY pallet id, as before).
     3. Location names, bag_count, qty and is_full_pallet are computed
        for the page rows only. fGetPalletQty is inlined as a set-based
        count (same rule: M/S pallet = unit_ratio * unit_pallet, else
        active bag count * unit_ratio).
     4. Status row and total_count read #rows instead of re-joining.
   @pallet_no stays an exact match: the old body already filtered bags on
   pallet_no = @pallet_no, so its later LIKE never widened the result.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pProcessGetPalletList]
	@id						INT						= NULL,
	@pallet_id				INT						= NULL,
	@pallet_no				NVARCHAR(100)			= NULL,
	@grade					NVARCHAR(255)			= NULL,
	@lot					NVARCHAR(255)			= NULL,
	@location_type			NVARCHAR(255)			= NULL,
	@location_id			INT						= NULL,
	@pallet_type_id			INT						= NULL,
	@pallet_location_id 	INT						= NULL,
	@qr_code				VARCHAR(100)			= NULL,
	@page					INT						= 1,
	@page_size				INT						= 20
AS
BEGIN
	SET NOCOUNT ON

	-- =============================================================
	-- Resolve @qr_code (scanned QR text) to a pallet id via
	-- fQrCodeToPalletBag -- matches tr_bag.qr_text_data first, then
	-- falls back to tr_pallet.pallet_no. @id still wins if a caller
	-- passes both.
	-- =============================================================

	DECLARE @qr_resolved_id INT = NULL

	IF @qr_code IS NOT NULL
	BEGIN
		SELECT @qr_resolved_id = pallet_id FROM dbo.fQrCodeToPalletBag(@qr_code)
	END

	DECLARE @find_id INT = COALESCE(@id, @qr_resolved_id)

	-- =============================================================
	-- 1. All list rows that match the filters (cheap columns only).
	-- =============================================================

	IF OBJECT_ID('tempdb..#rows') IS NOT NULL
		DROP TABLE #rows

	SELECT DISTINCT
		tp.id AS pallet_id,
		b.pallet_running_no AS pallet_running,
		b.grade AS grade,
		b.lot AS lot
	INTO #rows
	FROM dbo.tr_pallet tp
	INNER JOIN dbo.tr_bag b
		ON b.pallet_id = tp.id
		AND b.is_active = 'Y'
		AND b.status_flag = 'A'
	WHERE tp.is_active = 'Y'
		AND tp.status_flag = 'A'
		AND (@find_id IS NULL OR tp.id = @find_id)
		AND (@pallet_no IS NULL OR tp.pallet_no = @pallet_no)
		AND (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
		AND (@location_id IS NULL OR tp.current_location_id = @location_id)
		AND (@grade IS NULL OR b.grade LIKE '%' + @grade + '%')
		AND (@lot IS NULL OR b.lot LIKE '%' + @lot + '%')
		AND (@pallet_id IS NULL OR b.pallet_running_no = @pallet_id)
	OPTION (RECOMPILE)

	-- =============================================================
	-- Return status and message based on data retrieval result.
	-- =============================================================

	SELECT 'success' AS status,
		   CASE WHEN EXISTS (SELECT 1 FROM #rows) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- =============================================================
	-- 2. One page of rows.
	-- =============================================================

	IF OBJECT_ID('tempdb..#page') IS NOT NULL
		DROP TABLE #page

	SELECT pallet_id, pallet_running, grade, lot
	INTO #page
	FROM #rows
	ORDER BY pallet_id, pallet_running, grade, lot
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY

	-- =============================================================
	-- 3a. bag_count per pallet -- same grain as before: distinct
	--     (running no, bag no, grade, lot) among the bags that match
	--     the grade/lot/running filters.
	-- =============================================================

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

	-- =============================================================
	-- 3b. All active bags per pallet (what fGetPalletQty counts).
	-- =============================================================

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

	-- =============================================================
	-- 3c. Paginated pallet list.
	-- =============================================================

	SELECT
		tp.id AS id,
		pg.pallet_running AS pallet_id,
		tp.pallet_no AS pallet_no,
		pg.grade AS grade,
		pg.lot AS lot,
		tp.pd_type_code AS pallet_type,
		tp.current_location_id AS current_location_id,
		COALESCE(clt.name, 'Bagging Area') AS location_type,
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
		AND tp.current_location_type = 'SPECIAL-ZONE'
	LEFT JOIN [IRPC].[dbo].[VVehicleMaster] vm
		ON vm.vechicle_id = tp.current_location_id
		AND tp.current_location_type = 'VEHICLE'
	GROUP BY tp.id, pg.pallet_running, tp.pallet_no, pg.grade, pg.lot, tp.pd_type_code, tp.pallet_type, tp.current_location_id, tp.current_location_type, tp.unit_pallet, tp.unit_ratio, bc.bag_count, qbc.bag_count, tp.create_datetime, clt.name
	ORDER BY tp.id, pg.pallet_running, pg.grade, pg.lot

	-- =============================================================
	-- total_count -- 1 row per pallet (distinct tp.id), same as before.
	-- =============================================================

	SELECT
		COUNT(DISTINCT pallet_id) AS total_count
	FROM #rows
END
GO
