USE [IRPC_QTRACK]
GO

-- =============================================
-- WH Prod CC options for WH02 Internal Transfer, the same list WMS+ shows on
-- its Transfer WH form ("WH Prod CC : เลือก Prod Cost ที่จะเบิกออกจาก WMS",
-- pProcessFindWmsCodeWithSapCcAndSlocTransferWh): the distinct
-- wms_product_cost_center of ct_transfer_wh_convert_sap_wms for the
-- warehouse (sloc = @wh_code, eg. MWH).
-- Values are returned as stored (WMS+ shows them the same way, eg. 200, 18).
-- pWmsPlus_ProcessCBGetWmsProdCcTransferWh 'MWH'
-- =============================================
CREATE OR ALTER PROC [dbo].[pWmsPlus_ProcessCBGetWmsProdCcTransferWh](@wh_code varchar(20))
AS
BEGIN
	SET NOCOUNT ON;

	SELECT 'Data retrieved successfully.' AS message,
		   'success' AS status;

	select distinct x.wms_product_cost_center as cc_code, x.sap_cost_center as sap_cc_code
	from [IRPC_E_TRANSFER].[dbo].ct_transfer_wh_convert_sap_wms x
	where x.sloc = @wh_code and x.wms_product_cost_center is not null
	order by cc_code
END
GO
