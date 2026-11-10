/* =====================================================================
   pILogistic_ProcessGetShipmentStatus -- iLogistic is the primary source
   ---------------------------------------------------------------------
   Base: the definition live on IRPC_QTRACK as of 2026-10-01 16:19
   (@pairs_json + "v.Product_preparing_Datetime IS NULL").

   Change (54): GET job/shipment now lists shipments from
   [IRPC].[dbo].[VsearchStatus] first and only then looks up WMS Plus
   data for the rows on the page (JobController.GetJobShipment). Before,
   the list came from WMS (status P, paged by WMS) and was then filtered
   by VsearchStatus, so pages came back short/empty and total_count was
   WMS's count, not the count of shipments actually shown.

   - @pairs_json replaced by @shipment_no / @delivery_no (contains match,
     NULL/'' = no filter) + @page / @page_size.
   - Keeps "Product_preparing_Datetime IS NULL" (not yet in preparing).
   - Newest loading date first.
   - Returns Shipment_id / DO_id (iLogistic internal ids) and the DO's
     own grade / lot / qty / unit / storage, so a row is still usable
     when WMS has no matching record.

   Result sets: dbResult (status, message), dbResult1 (rows),
   dbResult2 (total_count).
   ===================================================================== */
GO

CREATE OR ALTER PROCEDURE [dbo].[pILogistic_ProcessGetShipmentStatus]
    @shipment_no VARCHAR(50) = NULL,
    @delivery_no VARCHAR(50) = NULL,
    @page        INT         = 1,
    @page_size   INT         = 10
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @shipment_no = NULLIF(LTRIM(RTRIM(@shipment_no)), '');
        SET @delivery_no = NULLIF(LTRIM(RTRIM(@delivery_no)), '');
        SET @page        = CASE WHEN ISNULL(@page, 0) <= 0 THEN 1 ELSE @page END;
        SET @page_size   = CASE WHEN ISNULL(@page_size, 0) <= 0 THEN 10 ELSE @page_size END;

        IF OBJECT_ID('tempdb..#shipment') IS NOT NULL
            DROP TABLE #shipment;

        SELECT
            v.Shipment_No,
            v.Deliver_No,
            v.Shipment_id,
            v.DO_id,
            v.mat_no AS grade,
            v.Lot_no AS lot_no,
            v.Do_qty AS do_qty,
            v.Do_saleunit AS do_unit,
            v.storage_name,
            v.current_status_id,
            v.current_status,
            v.Loading_Datetime,
            v.Truck_Checkin_Datetime,
            v.Weight_In_Datetime,
            v.Weight_Out_Datetime
        INTO #shipment
        FROM [IRPC].[dbo].[VsearchStatus] v
        WHERE v.Product_preparing_Datetime IS NULL
          AND (@shipment_no IS NULL OR v.Shipment_No LIKE '%' + @shipment_no + '%')
          AND (@delivery_no IS NULL OR v.Deliver_No LIKE '%' + @delivery_no + '%');

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
END;
GO
