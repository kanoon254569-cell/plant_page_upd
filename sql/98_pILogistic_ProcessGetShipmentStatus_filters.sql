/* =====================================================================
   pILogistic_ProcessGetShipmentStatus -- extra list filters
   ---------------------------------------------------------------------
   Base: sql/54_pILogistic_ProcessGetShipmentStatus_paged.sql.

   Change (98): job-list's shipment modal (GET job/shipment) gets more
   filters. New optional params, NULL/'' = no filter:
   - @status_ids   comma list of current_status_id, e.g. '1,3' (multi-select)
                   (1 Create Shipment / 2 Planning / 3 Estimate Check in)
   - @loading_from Loading_Datetime >= this date
   - @loading_to   Loading_Datetime <  this date + 1 day (whole day)

   All new params have defaults, so the old API call (4 params) still works.
   Rollback: run sql/54_pILogistic_ProcessGetShipmentStatus_paged.sql again.

   Result sets: dbResult (status, message), dbResult1 (rows),
   dbResult2 (total_count).
   ===================================================================== */
GO

CREATE OR ALTER PROCEDURE [dbo].[pILogistic_ProcessGetShipmentStatus]
    @shipment_no  VARCHAR(50) = NULL,
    @delivery_no  VARCHAR(50) = NULL,
    @page         INT         = 1,
    @page_size    INT         = 10,
    @status_ids   VARCHAR(100) = NULL,
    @loading_from DATE        = NULL,
    @loading_to   DATE        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @shipment_no = NULLIF(LTRIM(RTRIM(@shipment_no)), '');
        SET @delivery_no = NULLIF(LTRIM(RTRIM(@delivery_no)), '');
        SET @status_ids  = NULLIF(LTRIM(RTRIM(@status_ids)), '');
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
          AND (@delivery_no IS NULL OR v.Deliver_No LIKE '%' + @delivery_no + '%')
          AND (@status_ids IS NULL OR v.current_status_id IN (
                SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@status_ids, ',')))
          AND (@loading_from IS NULL OR v.Loading_Datetime >= @loading_from)
          AND (@loading_to IS NULL OR v.Loading_Datetime < DATEADD(DAY, 1, @loading_to));

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
