/* =====================================================================
   pProcessGetDoFromExcel -- Map DO Shipment filters
   ---------------------------------------------------------------------
   Base: the definition live on IRPC_QTRACK (10.31.1.74) as of 2026-10-29
   (the "td.do_no IS NULL" version). Rollback:
   sql/99_rollback_pProcessGetDoFromExcel.sql.

   Change (99): job-list's Map DO Shipment tab filters the Excel DDO list
   on the server. New optional params, NULL/'' = no filter:
   - @search       contains match on ddo / lot / agent / go_down /
                   shipping_instruction
   - @grades       comma list of exact grades, e.g. '1100ZC,BC3NSW'
   - @loading_from loading_date >= this date
   - @loading_to   loading_date <  this date + 1 day (whole day)

   The "last 7 days from the newest loading_date" window still applies
   when no loading date filter is given; a loading date filter replaces it,
   so older DDO can be found by date.

   @ddo / @grade are kept unchanged, so the old API call still works.
   Result sets: dbResult (status, message), dbResult1 (rows),
   dbResult2 (total_count).
   ===================================================================== */
GO

CREATE OR ALTER PROC [dbo].[pProcessGetDoFromExcel]
	@ddo					VARCHAR(20)				= NULL,
	@grade					VARCHAR(20)				= NULL,
	@search					NVARCHAR(100)			= NULL,
	@grades					VARCHAR(500)			= NULL,
	@loading_from			DATE					= NULL,
	@loading_to				DATE					= NULL
AS
BEGIN
	SET @search = NULLIF(LTRIM(RTRIM(@search)), '');
	SET @grades = NULLIF(LTRIM(RTRIM(@grades)), '');

	IF OBJECT_ID('tempdb..#data_do') IS NOT NULL
		DROP TABLE #data_do

	SELECT
		td.item_id AS id,
		td.ddo,
		td.loading_date,
		td.po_status,
		td.cc_code,
		td.wh_code,
		td.seq,
		td.grade,
		td.lot,
		td.qty,
		td.code_t,
		td.qty_bag,
		td.pk_unit,
		td.total_pallet,
		td.truck_l,
		td.on_pallet,
		td.go_down,
		td.agent,
		td.owner,
		td.truck,
		td.shipping_instruction
	INTO #data_do
	FROM dbo.vPickingForm td
	INNER JOIN
	(
		SELECT DISTINCT tj.id, tj.header_id, tj.job_status_id
		FROM dbo.vJobMain tj
	) tj
		ON td.id = tj.id
		AND td.header_id = tj.header_id
	WHERE (@ddo IS NULL OR td.ddo LIKE '%' + @ddo + '%')
		AND (@grade IS NULL OR td.grade LIKE '%' + @grade + '%')
		AND (@search IS NULL
			OR td.ddo LIKE '%' + @search + '%'
			OR td.lot LIKE '%' + @search + '%'
			OR td.agent LIKE '%' + @search + '%'
			OR td.go_down LIKE '%' + @search + '%'
			OR td.shipping_instruction LIKE '%' + @search + '%')
		AND (@grades IS NULL OR td.grade IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@grades, ',')))
		AND (@loading_from IS NULL OR td.loading_date >= @loading_from)
		AND (@loading_to IS NULL OR td.loading_date < DATEADD(DAY, 1, @loading_to))
		AND (@loading_from IS NOT NULL OR @loading_to IS NOT NULL
			OR td.loading_date >= DATEADD(DAY, -7, (SELECT MAX(loading_date) FROM dbo.vPickingForm)))
		AND td.source_id = 2
		AND tj.job_status_id = 5
		AND td.ref_id IS NULL
		AND td.ref_header_id IS NULL
		AND td.ref_item_id IS NULL
		AND td.do_no IS NULL

	SELECT CASE WHEN COUNT(*) > 0 THEN 'success' ELSE 'success' END AS status,
		   CASE WHEN COUNT(*) > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message
	FROM #data_do

	SELECT
		id,
		ddo,
		loading_date,
		po_status,
		cc_code,
		wh_code,
		seq,
		grade,
		lot,
		qty,
		code_t,
		qty_bag,
		pk_unit,
		total_pallet,
		truck_l,
		on_pallet,
		go_down,
		agent,
		owner,
		truck,
		shipping_instruction
	FROM #data_do

	SELECT COUNT(*) AS total_count
	FROM #data_do
END
GO
