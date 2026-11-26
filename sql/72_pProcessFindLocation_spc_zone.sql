/* =====================================================================
   pProcessFindLocation -- accept the real Special Zone code 'SPC-ZONE'
   ---------------------------------------------------------------------
   Base: live on IRPC_QTRACK as of 2026-10-09 (modify_date 2026-08-27).

   Backs the "Current Location" autocomplete on the Pallet Management
   page. The FE sends ct_location_type.code, and the Special Zone code is
   'SPC-ZONE' (also used by fSpecialJob / pProcessCBGetJobLocationOptions),
   but this proc only matched 'SPECIAL-ZONE', so choosing Special Zone
   fell through to 'Invalid location type provided.' and found nothing.

   Change (72): the Special Zone branch matches 'SPC-ZONE'. 'SPECIAL-ZONE'
   is still accepted so nothing that might send the old value breaks.
   Same as sql/71 for pProcessGetPalletList.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pProcessFindLocation]
	@location_type NVARCHAR(255) = NULL,
	@location_name NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

	SELECT 'success' AS status,
           'Data retrieved successfully.' AS message;

	IF @location_type = 'BG-PLANT'
	BEGIN
		SELECT DISTINCT
			bg.id,
			bg.bg_plant_code AS location_code,
			bg.bg_plant_desc AS location_name
		FROM [dbo].ct_bg_plant_location bg
		WHERE (@location_name IS NULL OR bg.bg_plant_desc LIKE '%' + @location_name + '%')
		  AND bg.is_active = 'Y'
		  AND bg.status_flag = 'A'
	END
	ELSE IF @location_type = 'RQ-PLANT'
	BEGIN
		SELECT DISTINCT
			rqcc.id,
			rqcc.cc_code AS location_code,
			rqcc.cc_desc AS location_name
		FROM IRPC_E_TRANSFER.dbo.ct_request_cost_center rqcc
		WHERE (@location_name IS NULL OR rqcc.cc_desc LIKE '%' + @location_name + '%')
		  AND rqcc.is_active = 'Y'
		  AND rqcc.status_flag = 'A'
	END
	ELSE IF @location_type = 'PRE-ZONE'
	BEGIN
		SELECT DISTINCT
			csz.id,
			NULL AS location_code,
			csz.zone_name AS location_name
		FROM [IRPC].[dbo].[ct_strorage_zone] csz
		WHERE (@location_name IS NULL OR csz.zone_name LIKE '%' + @location_name + '%')
		  AND csz.is_active = 'Y'
		  AND csz.status_flag = 'A'
	END
	ELSE IF @location_type = 'DOCK'
	BEGIN
		SELECT DISTINCT
			sd.id,
			NULL AS location_code,
			sd.dock_name AS location_name
		FROM [IRPC].[dbo].[ct_strorage_dock] sd
		WHERE (@location_name IS NULL OR sd.dock_name LIKE '%' + @location_name + '%')
		  AND sd.is_active = 'Y'
		  AND sd.status_flag = 'A'
	END
	ELSE IF @location_type IN ('SPC-ZONE', 'SPECIAL-ZONE')
	BEGIN
		SELECT DISTINCT
			csl.id,
			csl.cc_code AS location_code,
			csl.cc_desc AS location_name
		FROM dbo.ct_special_location csl
		WHERE (@location_name IS NULL OR csl.cc_desc LIKE '%' + @location_name + '%')
		  AND csl.is_active = 'Y'
		  AND csl.status_flag = 'A'
	END
	ELSE IF @location_type = 'VEHICLE'
	BEGIN
		SELECT DISTINCT
			vm.vechicle_id AS id,
			NULL AS location_code,
			vm.VEHICLE AS location_name
		FROM [IRPC].[dbo].[VVehicleMaster] vm
		WHERE (@location_name IS NULL OR vm.VEHICLE LIKE '%' + @location_name + '%')
		  AND vm.Active = 'Y'
	END
	ELSE
	BEGIN
		SELECT 'error' AS status,
			   'Invalid location type provided.' AS message;
	END

END
GO
