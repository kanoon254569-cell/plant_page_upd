/* =====================================================================
   dbo.pILogistic_ProcessCBGetShipmentStatus
   -----------------------------------------------------------------
   STATUS filter options of the shipment list (job-list "รายการงานขาย"):
   active iLogistic shipment statuses from [IRPC].[dbo].[ct_status] --
   the same table VsearchStatus.current_status_id / current_status come
   from. Replaces the 3 statuses hardcoded in job-list.ts.

   API: GET api/v1/process/job/shipment/statuses
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pILogistic_ProcessCBGetShipmentStatus]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT 'success' AS status, 'OK' AS message;

        SELECT s.ID AS id, s.name
        FROM [IRPC].[dbo].[ct_status] s
        WHERE s.status_flag = 'A'
          AND s.is_active = 'Y'
        ORDER BY s.ID;
    END TRY
    BEGIN CATCH
        SELECT
            'error' AS status,
            N'Error: ' + ERROR_MESSAGE() AS message;
    END CATCH
END
GO
