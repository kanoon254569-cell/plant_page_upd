/* Rollback for sql/100_pProcessCreatePickingJob_return_job_id.sql -- the
   definition live on IRPC_QTRACK (10.31.1.74) as of 2026-10-29, unchanged. */
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessCreatePickingJob]
    @shipment_no         VARCHAR(50)   = NULL,
    @delivery_no         VARCHAR(50)   = NULL,
    @grade               VARCHAR(50)   = NULL,
    @lot                 VARCHAR(50)   = NULL,
    @qty                 DECIMAL(18,3) = NULL,
    @cc_code             VARCHAR(50)   = NULL,
    @wh_code             VARCHAR(50)   = NULL,
    @total_pallet        INT           = NULL,
    @remark              VARCHAR(50)   = NULL,
    @from_locations_json NVARCHAR(MAX) = NULL,
    @to_locations_json   NVARCHAR(MAX) = NULL,
    @forklifts_json      NVARCHAR(MAX) = NULL,
    @user_id             INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @shipment_no IS NULL OR @delivery_no IS NULL
    BEGIN
        SELECT 'error' AS status, '@shipment_no and @delivery_no are required' AS message;
        RETURN;
    END

    BEGIN TRY
        DECLARE @effective_user_id INT = ISNULL(@user_id, 0);

        DECLARE @SyncResult TABLE
        (
            status VARCHAR(20),
            message NVARCHAR(200),
            picking_header_id INT,
            delivery_id INT,
            job_main_id INT
        );

        INSERT INTO @SyncResult (status, message, picking_header_id, delivery_id, job_main_id)
        EXEC dbo.pServiceSyncWmsShipment
            @shipment_no = @shipment_no,
            @delivery_no = @delivery_no,
            @grade = @grade,
            @lot = @lot,
            @qty = @qty,
            @cc_code = @cc_code,
            @wh_code = @wh_code,
            @total_pallet = @total_pallet,
            @remark = @remark;

        DECLARE @sync_status VARCHAR(20), @sync_message NVARCHAR(200), @job_main_id INT, @delivery_id INT;

        SELECT TOP 1
            @sync_status = status,
            @sync_message = message,
            @job_main_id = job_main_id,
            @delivery_id = delivery_id
        FROM @SyncResult;

        IF @sync_status NOT IN ('success', 'warning')
        BEGIN
            SELECT @sync_status AS status, @sync_message AS message;
            RETURN;
        END

        IF @job_main_id IS NULL OR @delivery_id IS NULL
        BEGIN
            SELECT 'error' AS status, N'Shipment synced but the resulting job could not be located.' AS message;
            RETURN;
        END

        BEGIN TRANSACTION;

        IF @from_locations_json IS NOT NULL AND LTRIM(RTRIM(@from_locations_json)) <> N'' AND ISJSON(@from_locations_json) = 1
        BEGIN
            MERGE dbo.tr_job_from_location AS target
            USING
            (
                SELECT
                    locationId AS from_location_id,
                    locationType AS from_location_type,
                    qty
                FROM OPENJSON(@from_locations_json) WITH
                (
                    locationId   INT,
                    locationType VARCHAR(50),
                    qty          DECIMAL(18,2)
                )
                WHERE locationId > 0
                  AND NULLIF(LTRIM(RTRIM(locationType)), '') IS NOT NULL
            ) AS source
                ON target.job_main_id = @job_main_id
               AND target.interface_job_item_id = @delivery_id
               AND target.from_location_id = source.from_location_id
               AND target.is_active = 'Y'
               AND target.status_flag = 'A'

            WHEN MATCHED THEN
                UPDATE SET
                    target.from_location_type = source.from_location_type,
                    target.qty = source.qty,
                    target.update_user_id = @effective_user_id,
                    target.update_datetime = GETDATE()

            WHEN NOT MATCHED BY TARGET THEN
                INSERT (job_main_id, interface_job_item_id, from_location_id, from_location_type, qty, create_user_id, update_user_id)
                VALUES (@job_main_id, @delivery_id, source.from_location_id, source.from_location_type, source.qty, @effective_user_id, @effective_user_id);
        END

        IF @to_locations_json IS NOT NULL AND LTRIM(RTRIM(@to_locations_json)) <> N'' AND ISJSON(@to_locations_json) = 1
        BEGIN
            MERGE dbo.tr_job_to_location AS target
            USING
            (
                SELECT
                    locationId AS to_location_id,
                    locationType AS to_location_type,
                    qty
                FROM OPENJSON(@to_locations_json) WITH
                (
                    locationId   INT,
                    locationType VARCHAR(50),
                    qty          DECIMAL(18,2)
                )
                WHERE locationId > 0
                  AND NULLIF(LTRIM(RTRIM(locationType)), '') IS NOT NULL
            ) AS source
                ON target.job_main_id = @job_main_id
               AND target.interface_job_item_id = @delivery_id
               AND target.to_location_id = source.to_location_id
               AND target.is_active = 'Y'
               AND target.status_flag = 'A'

            WHEN MATCHED THEN
                UPDATE SET
                    target.to_location_type = source.to_location_type,
                    target.qty = source.qty,
                    target.update_user_id = @effective_user_id,
                    target.update_datetime = GETDATE()

            WHEN NOT MATCHED BY TARGET THEN
                INSERT (job_main_id, interface_job_item_id, to_location_id, to_location_type, qty, create_user_id, update_user_id)
                VALUES (@job_main_id, @delivery_id, source.to_location_id, source.to_location_type, source.qty, @effective_user_id, @effective_user_id);
        END

        IF @forklifts_json IS NOT NULL AND LTRIM(RTRIM(@forklifts_json)) <> N'' AND ISJSON(@forklifts_json) = 1
        BEGIN
            MERGE dbo.tr_job_assigness AS target
            USING
            (
                SELECT id AS forklift_id
                FROM OPENJSON(@forklifts_json) WITH (id INT)
                WHERE id > 0
            ) AS source
                ON target.assignee_forklift_id = source.forklift_id
               AND target.job_main_id = @job_main_id
               AND target.is_active = 'Y'
               AND target.status_flag = 'A'

            WHEN NOT MATCHED BY TARGET THEN
                INSERT (job_main_id, assigner_user_id, assignee_forklift_id, assignee_user_id, create_user_id, update_user_id)
                VALUES (
                    @job_main_id,
                    @effective_user_id,
                    source.forklift_id,
                    (SELECT fl.current_user_id FROM dbo.ct_forklift fl WHERE fl.id = source.forklift_id),
                    @effective_user_id,
                    @effective_user_id
                );
        END

        COMMIT TRANSACTION;

        SELECT 'success' AS status, N'Picking job created successfully.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END;
GO
