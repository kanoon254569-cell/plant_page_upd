/* =====================================================================
   pProcessCBGetJobLocationOptions
   ---------------------------------------------------------------------
   Options for WH02 Outbound's "From Location" / "To Location" filters
   (job-wh-outbound-list). Any location type can be a job's from OR to,
   so one list serves both dropdowns.

   Built from the location master tables (not job history), so a new
   location shows up before any job uses it:
     MWH           IRPC.dbo.ct_storage (wms_name)      -> one row per warehouse
                                                          (too many single
                                                          MWH locations)
     BG-PLANT      dbo.ct_bg_plant_location            (bg_plant_desc)
     RQ-PLANT      IRPC_E_TRANSFER.dbo.ct_request_cost_center (cc_desc)
     PRE-ZONE      IRPC.dbo.ct_strorage_zone           (zone_name)
     DOCK          IRPC.dbo.ct_strorage_dock           (dock_name)
     SPC-ZONE      dbo.ct_special_location             (cc_desc)
     REPLACE-ZONE  dbo.ct_replace_location             (cc_desc)
   These are the same tables/columns fXxxJob uses for from/to_location_name.

   Rows:
     location_type  group code
     type_name      group header text (ct_location_type.name)
     location_key   NULL  -> group header row (selects the whole type)
                    value -> wh_code for MWH, location name otherwise
                             (by name: one plant can have several ids,
                             e.g. HD Plant)
     label          option text
   location_type + location_key go to pProcessGetJobList
   @from_location_type/@from_location_key (and @to_...), sql/35.
   GET api/v1/process-cb/job-location
   ===================================================================== */
USE IRPC_QTRACK;
GO

CREATE OR ALTER PROC [dbo].[pProcessCBGetJobLocationOptions]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 'success' AS status,
           'Data retrieved successfully.' AS message;

    IF OBJECT_ID('tempdb..#opt') IS NOT NULL
        DROP TABLE #opt;

    CREATE TABLE #opt (
        location_type NVARCHAR(50)  COLLATE DATABASE_DEFAULT,
        location_key  NVARCHAR(255) COLLATE DATABASE_DEFAULT,
        label         NVARCHAR(500) COLLATE DATABASE_DEFAULT
    );

    --  Same warehouse list as GET process-cb/location-wh?wh=MWH
    --  (pILogistic_ProcessCBGetWh) -- ct_location.wh_code itself holds
    --  stray codes ('A', 'P01', ...) that aren't real warehouses.
    INSERT INTO #opt (location_type, location_key, label)
    SELECT DISTINCT 'MWH', wms_name, wms_name + ' - ' + storage_name
    FROM IRPC.dbo.ct_storage
    WHERE is_active = 'Y' AND status_flag = 'A'
        AND wms_name IS NOT NULL
        AND wms_name NOT IN ('A41', 'A43');

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'BG-PLANT', bg_plant_desc
    FROM dbo.ct_bg_plant_location
    WHERE is_active = 'Y' AND status_flag = 'A' AND bg_plant_desc IS NOT NULL;

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'RQ-PLANT', cc_desc
    FROM IRPC_E_TRANSFER.dbo.ct_request_cost_center
    WHERE is_active = 'Y' AND cc_desc IS NOT NULL;

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'PRE-ZONE', zone_name
    FROM IRPC.dbo.ct_strorage_zone
    WHERE is_active = 'Y' AND status_flag = 'A' AND zone_name IS NOT NULL;

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'DOCK', dock_name
    FROM IRPC.dbo.ct_strorage_dock
    WHERE is_active = 'Y' AND status_flag = 'A' AND dock_name IS NOT NULL;

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'SPC-ZONE', cc_desc
    FROM dbo.ct_special_location
    WHERE is_active = 'Y' AND cc_desc IS NOT NULL;

    INSERT INTO #opt (location_type, location_key)
    SELECT DISTINCT 'REPLACE-ZONE', cc_desc
    FROM dbo.ct_replace_location
    WHERE is_active = 'Y' AND status_flag = 'A' AND cc_desc IS NOT NULL;

    --  Groups: active ct_location_type rows (id order) + REPLACE-ZONE, which
    --  jobs use but ct_location_type doesn't list. Only types that have at
    --  least one location in #opt are shown (drops VEHICLE -- no master table).
    ;WITH grp AS (
        SELECT code COLLATE DATABASE_DEFAULT AS location_type,
               name COLLATE DATABASE_DEFAULT AS type_name,
               id AS sort
        FROM dbo.ct_location_type
        WHERE is_active = 'Y' AND status_flag = 'A'
        UNION ALL
        SELECT 'REPLACE-ZONE', 'Replace Zone', 999
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.ct_location_type
            WHERE code = 'REPLACE-ZONE' AND is_active = 'Y' AND status_flag = 'A'
        )
    )
    SELECT
        g.location_type,
        g.type_name,
        o.location_key,
        COALESCE(o.label, LTRIM(RTRIM(o.location_key)), g.type_name) AS label
    FROM grp g
    OUTER APPLY (
        SELECT CAST(NULL AS NVARCHAR(255)) AS location_key, CAST(NULL AS NVARCHAR(500)) AS label, 0 AS is_item
        UNION ALL
        SELECT location_key, label, 1 FROM #opt WHERE location_type = g.location_type
    ) o
    WHERE EXISTS (SELECT 1 FROM #opt x WHERE x.location_type = g.location_type)
    ORDER BY g.sort, o.is_item, o.location_key;
END
GO

-- EXEC dbo.pProcessCBGetJobLocationOptions;
