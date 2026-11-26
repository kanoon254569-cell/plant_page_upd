-- =============================================================
-- 133 : pProcessGetPickingPrepareUpdate -- ISNULL pallet fields + @user_id
-- =============================================================
-- Job 2782 (DO-3140393827): vPickingForm has no pallet info for the DO, so
-- dbResult1 returned NULL code_pallet_id / pallet_qty / pallet_weight /
-- special_type_package_id and iLogistic ProcessWarehousePrepareUpdate
-- rejected the send with 400 "Error converting value {null} to type
-- 'System.Int32'". pProcessPickingPutAway's dbResult1 already ISNULLs
-- these to 0 / '-'; this matches it.
--
-- Also adds @user_id (optional, default NULL): the API now passes the user
-- who pressed send; NULL keeps the old fixed 176.
--
-- Rollback: 133_rollback_pProcessGetPickingPrepareUpdate_isnull_user.sql
-- =============================================================

CREATE OR ALTER PROCEDURE dbo.pProcessGetPickingPrepareUpdate
    @job_main_id INT,
    @user_id INT = NULL
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
        ISNULL(fp.code_pallet_id, 0) AS code_pallet_id,
        ISNULL(fp.pallet_lot, '-') AS pallet_lot,
        ISNULL(fp.pallet_qty, 0) AS pallet_qty,
        ISNULL(fp.pallet_weight, 0) AS pallet_weight,
        ISNULL(fp.special_type_package_id, 0) AS special_type_package_id,
        ISNULL(@user_id, 176) AS user_id
    FROM dbo.fPickingJob(@job_main_id, NULL, NULL) fp
    INNER JOIN [IRPC].[dbo].[VsearchStatus] ss
        ON ss.Shipment_No = fp.shipment_no COLLATE Thai_CI_AI
        AND ss.Deliver_No = fp.do_no COLLATE Thai_CI_AI;                   -- dbResult1
END
GO
