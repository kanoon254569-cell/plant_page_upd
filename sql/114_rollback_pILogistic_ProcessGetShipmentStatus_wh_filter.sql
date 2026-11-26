/* Rollback: 114_pILogistic_ProcessGetShipmentStatus_wh_filter.sql
   Restores pILogistic_ProcessGetShipmentStatus without @wh_ids (the CC Code
   filter version) and drops pILogistic_ProcessCBGetShipmentStorage. */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.pILogistic_ProcessCBGetShipmentStorage', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].[pILogistic_ProcessCBGetShipmentStorage];
GO

CREATE OR ALTER PROCEDURE [dbo].[pILogistic_ProcessGetShipmentStatus]
    @shipment_no  VARCHAR(50) = NULL,
    @delivery_no  VARCHAR(50) = NULL,
    @page         INT         = 1,
    @page_size    INT         = 10,
    @status_ids   VARCHAR(100) = NULL,
    @loading_from DATE        = NULL,
    @loading_to   DATE        = NULL,
    @plant_codes  VARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @shipment_no = NULLIF(LTRIM(RTRIM(@shipment_no)), '');
        SET @delivery_no = NULLIF(LTRIM(RTRIM(@delivery_no)), '');
        SET @status_ids  = NULLIF(LTRIM(RTRIM(@status_ids)), '');
        SET @plant_codes = NULLIF(LTRIM(RTRIM(@plant_codes)), '');
        SET @page        = CASE WHEN ISNULL(@page, 0) <= 0 THEN 1 ELSE @page END;
        SET @page_size   = CASE WHEN ISNULL(@page_size, 0) <= 0 THEN 10 ELSE @page_size END;

        IF OBJECT_ID('tempdb..#shipment') IS NOT NULL
            DROP TABLE #shipment;

        SELECT
            s.Shipment_No,
            d.Deliver_No,
            s.ID AS Shipment_id,
            d.ID AS DO_id,
            g.mat_no AS grade,
            l.Lot_no AS lot_no,
            g.Do_qty AS do_qty,
            g.Do_saleunit AS do_unit,
            st.storage_name,
            sw.storage_name AS shipment_storage_name,
            p.code AS plant_code,
            p.Name AS plant_name,
            d.pallet_qty,
            d.delivery_remarks,
            d.delivery_note,
            s.current_status_id,
            cs.name AS current_status,
            s.Loading_Datetime,
            s.Truck_Checkin_Datetime,
            s.Weight_In_Datetime,
            s.Weight_Out_Datetime
        INTO #shipment
        FROM [IRPC].[dbo].[tr_Shipment] s
        INNER JOIN [IRPC].[dbo].[tr_Deliver] d ON d.Shipment_id = s.ID
        LEFT JOIN [IRPC].[dbo].[tr_Grade] g ON g.Deliver_id = d.ID
        LEFT JOIN [IRPC].[dbo].[tr_Lotno] l ON l.grade_id = g.ID
        LEFT JOIN [IRPC].[dbo].[ct_status] cs ON cs.ID = s.current_status_id
        LEFT JOIN [IRPC].[dbo].[ct_storage] st ON st.ID = d.storage_id
        LEFT JOIN [IRPC].[dbo].[ct_storage] sw ON sw.ID = s.Ware_House_id
        LEFT JOIN [IRPC].[dbo].[ct_plant] p ON p.ID = g.plant_id
        WHERE s.status_flag = 'A'
          AND ISNULL(d.status_flag, 'A') = 'A'
          AND ISNULL(g.status_flag, 'A') = 'A'
          AND ISNULL(l.status_flag, 'A') = 'A'
          AND s.Product_preparing_Datetime IS NULL
          AND (@shipment_no IS NULL OR s.Shipment_No LIKE '%' + @shipment_no + '%')
          AND (@delivery_no IS NULL OR d.Deliver_No LIKE '%' + @delivery_no + '%')
          AND (@status_ids IS NULL OR s.current_status_id IN (
                SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@status_ids, ',')))
          AND (@loading_from IS NULL OR s.Loading_Datetime >= @loading_from)
          AND (@loading_to IS NULL OR s.Loading_Datetime < DATEADD(DAY, 1, @loading_to))
          AND (@plant_codes IS NULL OR p.code IN (
                SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@plant_codes, ',')))
        OPTION (RECOMPILE);

        SELECT 'success' AS status, 'OK' AS message;

        SELECT *
        FROM #shipment
        ORDER BY Loading_Datetime DESC, Shipment_No DESC, Deliver_No
        OFFSET (@page - 1) * @page_size ROWS
        FETCH NEXT @page_size ROWS ONLY;

        SELECT COUNT(*) AS total_count
        FROM #shipment;
    END TRY
    BEGIN CATCH
        SELECT
            'error' AS status,
            N'Error: ' + ERROR_MESSAGE() AS message;
    END CATCH
END
GO
