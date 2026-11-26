-- =============================================================
-- 133 rollback : pProcessGetPickingPrepareUpdate back to sql/126
-- =============================================================

CREATE OR ALTER PROCEDURE dbo.pProcessGetPickingPrepareUpdate
    @job_main_id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.tr_job_main WHERE id = @job_main_id AND job_type_id = 4 AND job_status_id = 5)
    BEGIN
        SELECT 'not_applicable' AS status, 'Not a completed Picking job' AS message;
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.tr_ilogistic_interface_log
        WHERE job_main_id = @job_main_id
          AND mode = 'Do Preparing'
          AND is_success = 'Y'
          AND ISNULL(status_flag, 'A') = 'A'
    )
    BEGIN
        SELECT 'not_applicable' AS status, 'DO Preparing already sent' AS message;
        RETURN;
    END

    SELECT 'success' AS status, 'OK' AS message;                           -- dbResult

    SELECT TOP 1
        ss.Shipment_id AS shipment_id,
        ss.DO_id AS do_id,
        fp.job_start_datetime,
        fp.job_end_datetime,
        fp.to_location_id,
        fp.code_pallet_id,
        fp.pallet_lot,
        fp.pallet_qty,
        fp.pallet_weight,
        fp.special_type_package_id,
        176 AS user_id                                                     -- same as pProcessPickingPutAway
    FROM dbo.fPickingJob(@job_main_id, NULL, NULL) fp
    INNER JOIN [IRPC].[dbo].[VsearchStatus] ss
        ON ss.Shipment_No = fp.shipment_no COLLATE Thai_CI_AI
        AND ss.Deliver_No = fp.do_no COLLATE Thai_CI_AI;                   -- dbResult1
END
GO
