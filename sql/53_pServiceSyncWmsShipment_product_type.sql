/* =====================================================================
   pServiceSyncWmsShipment -- store product type (on top of live)
   ---------------------------------------------------------------------
   Base: the definition live on IRPC_QTRACK as of 2026-10-01.

   Change (53): new optional @product_type (default NULL -- existing
   callers unchanged), from WMS tshipmentsub.PDTYPECODE via
   GET api/v1/wms/QtrackShipmentSub ("pdtypecode"). Written to
   tr_delivery.code_t on insert; on update it only overwrites code_t
   when a value is sent.
   Why: Picking jobs read pd_type from vPickingForm.code_t =
   tr_delivery.code_t, which no sync ever filled (job 688: NULL).
   ServiceController.SyncShipment passes @product_type, so this must be
   deployed before that API build.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pServiceSyncWmsShipment]
    @shipment_no         VARCHAR(50)         = NULL,
    @delivery_no         VARCHAR(50)         = NULL,
    @delivery_date       VARCHAR(50)         = NULL,
    @grade               VARCHAR(50)         = NULL,
    @lot                 VARCHAR(50)         = NULL,
    @qty                 INT                 = NULL,
    @unit                VARCHAR(50)         = NULL,
    @cc_code             VARCHAR(50)         = NULL,
    @wh_code             VARCHAR(50)         = NULL,
    @total_pallet        INT                 = NULL,
    @remark              VARCHAR(50)         = NULL,
    @product_type        VARCHAR(50)         = NULL   -- WMS tshipmentsub.PDTYPECODE (eg. 'FG') -> tr_delivery.code_t
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pk_primary_id INT;
    DECLARE @shipment_id INT;
    DECLARE @status VARCHAR(20) = 'success';
    DECLARE @message NVARCHAR(200) = 'Sync completed successfully.';

    IF @shipment_no IS NULL OR @delivery_no IS NULL
    BEGIN
        SELECT 'error' AS status, '@shipment_no and @delivery_no are required' AS message,
               CAST(NULL AS INT) AS picking_header_id, CAST(NULL AS INT) AS delivery_id, CAST(NULL AS INT) AS job_main_id;
        RETURN;
    END

    IF OBJECT_ID('tempdb..#data_shipment') IS NOT NULL
        DROP TABLE #data_shipment;

    SELECT TOP 1
        COALESCE(vs.Shipment_No, @shipment_no) AS shipment_no,
        COALESCE(vs.Deliver_No, @delivery_no) AS do_no,
        @delivery_date AS delivery_date,
        @cc_code AS cc_code,
        @wh_code AS wh_code,
        COALESCE(vs.mat_no, @grade) AS grade,
        COALESCE(vs.Lot_no, @lot) AS lot,
        @qty AS qty,
        COALESCE(vs.Do_saleunit, @unit) AS pk_unit,
        vs.Truck_Load AS truck_l,
        vs.Customer_name AS agent,
        vs.vehicle_group_desc AS truck,
        CEILING(@total_pallet) AS total_pallet,
        @remark AS shipping_instruction,
        NULLIF(LTRIM(RTRIM(@product_type)), '') AS code_t
    INTO #data_shipment
    FROM [IRPC].[dbo].VsearchStatus vs
    WHERE vs.Shipment_No = @shipment_no
        AND vs.Deliver_No = @delivery_no
    ORDER BY vs.Shipment_No;

    IF NOT EXISTS (SELECT 1 FROM #data_shipment)
    BEGIN
        SELECT 'error' AS status, 'No active shipment found for the specified criteria.' AS message,
               CAST(NULL AS INT) AS picking_header_id, CAST(NULL AS INT) AS delivery_id, CAST(NULL AS INT) AS job_main_id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT TOP 1 @shipment_id = id
        FROM dbo.tr_shipment
        WHERE shipment_no = @shipment_no AND is_active = 'Y' AND status_flag = 'A';

        IF @shipment_id IS NULL
        BEGIN
            INSERT INTO dbo.tr_shipment (shipment_no)
            VALUES (@shipment_no);

            SET @shipment_id = SCOPE_IDENTITY();
        END

        -- Find an existing picking header for this shipment via any delivery
        -- already linked to it (tr_picking_header no longer stores
        -- shipment_no directly -- see tr_shipment/tr_delivery.shipment_id).
        SELECT TOP 1 @pk_primary_id = pd.header_id
        FROM dbo.tr_picking_detail pd
        JOIN dbo.tr_delivery dchk ON dchk.id = pd.delivery_id
        WHERE dchk.shipment_id = @shipment_id
          AND pd.is_active = 'Y' AND pd.status_flag = 'A'
        ORDER BY pd.header_id DESC;

        IF @pk_primary_id IS NULL
        BEGIN
            DECLARE @pk_today_seq INT = (
                SELECT COUNT(*) + 1
                FROM dbo.tr_picking_header
                WHERE CAST(create_datetime AS DATE) = CAST(GETDATE() AS DATE)
            );

            INSERT INTO dbo.tr_picking_header (
                system_no,
                status_id,
                from_wh_id,
                from_wh_cc_code,
                from_wh_cc_desc,
                to_pre_zone_id,
                to_pre_zone_cc_code,
                to_pre_zone_cc_desc
            )
            VALUES (
                'PK-' + CONVERT(VARCHAR(10), GETDATE(), 112) + RIGHT('000' + CAST(@pk_today_seq AS VARCHAR(3)), 3),
                1,
                NULL,
                4510,
                'Manual WH',
                NULL,
                NULL,
                'Prepare Zone'
            );

            SET @pk_primary_id = SCOPE_IDENTITY();

            SET @status = 'success';
            SET @message = 'Picking header inserted successfully.';
        END
        ELSE
        BEGIN
            UPDATE dbo.tr_picking_header
            SET update_user_id = 1,
                update_datetime = GETDATE()
            WHERE id = @pk_primary_id;

            SET @status = 'success';
            SET @message = 'Picking header already exists. Updated successfully.';
        END

        IF NOT EXISTS (
            SELECT 1
            FROM dbo.tr_delivery td
            WHERE td.do_no = @delivery_no
                AND td.is_active = 'Y'
                AND td.status_flag = 'A'
        )
        BEGIN
            INSERT INTO dbo.tr_delivery (
                shipment_id,
                do_no,
                delivery_date,
                cc_code,
                wh_code,
                grade,
                lot,
                qty,
                pk_unit,
                truck_l,
                agent,
                truck,
                total_pallet,
                shipping_instruction,
                code_t,
                source_id
            )
            SELECT
                @shipment_id AS shipment_id,
                ds.do_no,
                ds.delivery_date,
                ds.cc_code,
                ds.wh_code,
                ds.grade,
                ds.lot,
                ds.qty,
                ds.pk_unit,
                ds.truck_l,
                ds.agent,
                ds.truck,
                ds.total_pallet,
                ds.shipping_instruction,
                ds.code_t,
                1 AS source_id
            FROM #data_shipment ds;

            SET @status = 'success';
            SET @message = 'Shipment inserted successfully.';
        END
        ELSE
        BEGIN
            UPDATE dbo.tr_delivery
            SET delivery_date = ds.delivery_date,
                cc_code = ds.cc_code,
                wh_code = ds.wh_code,
                grade = ds.grade,
                lot = ds.lot,
                qty = ds.qty,
                pk_unit = ds.pk_unit,
                truck_l = ds.truck_l,
                agent = ds.agent,
                truck = ds.truck,
                total_pallet = ds.total_pallet,
                shipping_instruction = ds.shipping_instruction,
                -- keep an existing code_t when WMS sends none
                code_t = COALESCE(ds.code_t, dbo.tr_delivery.code_t),
                shipment_id = @shipment_id,
                update_user_id = 1,
                update_datetime = GETDATE()
            FROM #data_shipment ds
            WHERE dbo.tr_delivery.do_no = @delivery_no
                AND dbo.tr_delivery.is_active = 'Y'
                AND dbo.tr_delivery.status_flag = 'A';

            SET @status = 'success';
            SET @message = 'Shipment already exists. Updated successfully.';
        END

        DECLARE @delivery_id INT = (
            SELECT TOP 1 id FROM dbo.tr_delivery
            WHERE do_no = @delivery_no AND is_active = 'Y' AND status_flag = 'A'
            ORDER BY id DESC
        );

        IF @delivery_id IS NOT NULL AND @pk_primary_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.tr_picking_detail
            WHERE delivery_id = @delivery_id AND is_active = 'Y' AND status_flag = 'A'
        )
        BEGIN
            INSERT INTO dbo.tr_picking_detail (delivery_id, header_id)
            VALUES (@delivery_id, @pk_primary_id);
        END

        IF NOT EXISTS (
            SELECT 1
            FROM dbo.tr_job_main tj
            WHERE tj.interface_job_id = @pk_primary_id
                AND tj.job_type_id = 4
                AND tj.is_active = 'Y'
                AND tj.status_flag = 'A'
        )
        BEGIN
            INSERT INTO dbo.tr_job_main (
                interface_job_id,
                job_type_id,
                job_status_id,
                is_active,
                create_user_id,
                create_datetime
            )
            VALUES (
                @pk_primary_id,
                4,
                1,
                'Y',
                1,
                GETDATE()
            );

            SET @status = 'success';
            SET @message = 'Job main record inserted successfully.';
        END
        ELSE
        BEGIN
            UPDATE dbo.tr_job_main
            SET update_user_id = 1,
                update_datetime = GETDATE()
            WHERE interface_job_id = @pk_primary_id
                AND job_type_id = 4
                AND is_active = 'Y'
                AND status_flag = 'A';

            SET @status = 'warning';
            SET @message = 'Job main record already exists. Updated successfully.';
        END

        COMMIT TRANSACTION;

        DECLARE @job_main_id INT = (
            SELECT TOP 1 id FROM dbo.tr_job_main
            WHERE interface_job_id = @pk_primary_id AND job_type_id = 4 AND is_active = 'Y' AND status_flag = 'A'
            ORDER BY id DESC
        );

        SELECT @status AS status, @message AS message,
               @pk_primary_id AS picking_header_id, @delivery_id AS delivery_id, @job_main_id AS job_main_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message,
               CAST(NULL AS INT) AS picking_header_id, CAST(NULL AS INT) AS delivery_id, CAST(NULL AS INT) AS job_main_id;
    END CATCH

    IF OBJECT_ID('tempdb..#data_shipment') IS NOT NULL
        DROP TABLE #data_shipment;
END
GO
