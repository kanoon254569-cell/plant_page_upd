/* Rollback for sql/99_pProcessGetDoFromExcel_filters.sql -- the definition
   live on IRPC_QTRACK (10.31.1.74) as of 2026-10-29, copied unchanged. */
GO

-- pProcessGetDoFromExcel: previously excluded already-mapped excel rows via
-- `td.ref_id IS NULL` (the old map-shipment-do design set ref_id on the
-- separate "do" row, not on the excel row itself, so this check happened
-- to also work as a side effect). The new map-shipment-do design
-- (pProcessShipmentMapDO) stamps shipment_no/do_no directly onto the
-- SAME excel job instead of ever touching ref_id -- so ref_id stays NULL
-- forever now, and this filter no longer excludes mapped rows. Replaced
-- with `td.do_no IS NULL` (do_no is exactly what map-shipment-do sets),
-- which is what "not yet mapped" now actually means. Nothing else changed.
CREATE OR ALTER PROC [dbo].[pProcessGetDoFromExcel]
	@ddo					VARCHAR(20)				= NULL,
	@grade					VARCHAR(20)				= NULL
AS
BEGIN
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
		AND td.loading_date >= DATEADD(DAY, -7, (SELECT MAX(loading_date) FROM dbo.vPickingForm))
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
