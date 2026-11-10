/* =====================================================================
   pProcessGetBagList -- running pallet no / ton no
   ---------------------------------------------------------------------
   Base: live on IRPC_QTRACK as of 2026-10-09.

   Backs GET api/v1/process/bag (Bag List on the Pallet Information page).

   Change (73): same parameters, same result sets; the bag list
   (dbResult1) gets extra columns, existing columns are unchanged.
     - pallet_running_no, ton_no      (tr_bag)
   The list is ordered by bag_no (bags without a bag_no last), then id,
   so it reads in the bag's position on the pallet instead of insert order.
   The mode_id <> 2 filter is kept as is.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pProcessGetBagList]
	@pallet_id				INT						= NULL,
	@page					INT						= 1,
	@page_size				INT						= 10
AS
BEGIN
	SET NOCOUNT ON

	-- =============================================================
	-- Retrieve bag list based on pallet number with pagination.
	-- =============================================================

	IF OBJECT_ID('tempdb..#data_bags') IS NOT NULL
		DROP TABLE #data_bags

	SELECT
		trb.id,
		trb.cost_center,
		tp.pallet_no,
		trb.bag_no,
		trb.pallet_running_no,
		trb.ton_no,
		trb.grade,
		trb.lot,
		trb.qr_text_data,
		tp.unit_ratio,
		trb.create_datetime
	INTO #data_bags
	FROM dbo.tr_bag trb
	LEFT JOIN dbo.tr_pallet tp
		ON tp.id = trb.pallet_id
		AND tp.is_active = 'Y'
		AND tp.status_flag = 'A'
	WHERE (@pallet_id IS NULL OR tp.id = @pallet_id)
		AND trb.mode_id <> 2
		AND trb.is_active = 'Y'
		AND trb.status_flag = 'A'

	-- =============================================================
	-- Return status and message based on data retrieval result.
	-- =============================================================

	SELECT 'success' AS status,
		   CASE WHEN EXISTS (SELECT 1 FROM #data_bags) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- =============================================================
	-- Return paginated bag list and total count.
	-- =============================================================

	SELECT
		id,
		cost_center,
		pallet_no,
		bag_no,
		pallet_running_no,
		ton_no,
		grade,
		lot,
		qr_text_data,
		unit_ratio,
		create_datetime
	FROM #data_bags
	ORDER BY CASE WHEN bag_no IS NULL THEN 1 ELSE 0 END, bag_no, id
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY

	SELECT
		COUNT(*) AS total_count
	FROM #data_bags
END
GO
