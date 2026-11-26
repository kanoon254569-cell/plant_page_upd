USE [IRPC_QTRACK]
GO

-- =============================================
-- WH Prod CC options for one job, the same as WMS+'s "WH Prod CC" select:
--
--   TS -> distinct wms_product_cost_center of the document's SAP plant + sloc
--         (VTransferSlip + ct_convert_sap_wms, pProcessFindWmsCodeWithSapCcAndSloc)
--   RC -> same from VReceiveForm + ct_receive_convert_sap_wms
--   RQ -> same from VRequestForm + ct_request_convert_sap_wms (status_flag = 'A',
--         pProcessFindWmsCodeWithSapCcAndSlocRequest)
--
-- Any other job type returns no rows; the web then keeps its full list.
-- pWmsPlus_ProcessCBGetWmsProdCcByJob 723
-- =============================================
CREATE OR ALTER PROC [dbo].[pWmsPlus_ProcessCBGetWmsProdCcByJob](@job_main_id int)
AS
BEGIN
	SET NOCOUNT ON;

	SELECT 'Data retrieved successfully.' AS message,
		   'success' AS status;

	declare @job_type varchar(5) = null, @header_id int = null
	select top 1 @job_type = cj.short_name, @header_id = t.interface_job_id
	from dbo.tr_job_main t
	join dbo.ct_job_type cj on cj.id = t.job_type_id
	where t.id = @job_main_id

	declare @sap_cc varchar(100) = null, @sloc varchar(100) = null

	if @job_type = 'TS'
		select top 1 @sap_cc = v.from_plant_cc_code, @sloc = v.from_sloc
		from [IRPC_E_TRANSFER].[dbo].VTransferSlip v where v.header_id = @header_id
	else if @job_type = 'RC'
		select top 1 @sap_cc = v.from_plant_cc_code, @sloc = v.from_sloc
		from [IRPC_E_TRANSFER].[dbo].VReceiveForm v where v.header_id = @header_id
	else if @job_type = 'RQ'
		select top 1 @sap_cc = v.from_plant_cc_code, @sloc = v.from_sloc
		from [IRPC_E_TRANSFER].[dbo].VRequestForm v where v.header_id = @header_id

	if @job_type = 'TS'
		select distinct x.wms_product_cost_center as cc_code, x.sap_cost_center as sap_cc_code
		from [IRPC_E_TRANSFER].[dbo].ct_convert_sap_wms x
		where x.sap_cost_center = @sap_cc and x.sloc = @sloc and x.wms_product_cost_center is not null
		order by cc_code
	else if @job_type = 'RC'
		select distinct x.wms_product_cost_center as cc_code, x.sap_cost_center as sap_cc_code
		from [IRPC_E_TRANSFER].[dbo].ct_receive_convert_sap_wms x
		where x.sap_cost_center = @sap_cc and x.sloc = @sloc and x.wms_product_cost_center is not null
		order by cc_code
	else if @job_type = 'RQ'
		select distinct x.wms_product_cost_center as cc_code, x.sap_cost_center as sap_cc_code
		from [IRPC_E_TRANSFER].[dbo].ct_request_convert_sap_wms x
		where x.sap_cost_center = @sap_cc and x.sloc = @sloc and x.wms_product_cost_center is not null
			and x.status_flag = 'A'
		order by cc_code
	else
		select cast(null as varchar(100)) as cc_code, cast(null as varchar(100)) as sap_cc_code
		where 1 = 0
END
GO
