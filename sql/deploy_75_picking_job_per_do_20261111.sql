/* =====================================================================
   Deploy to 10.31.1.75 -- one picking job (tr_job_main) per DO
   ---------------------------------------------------------------------
   Problem: pServiceSyncWmsShipment re-used the picking header of any DO
   already synced for the same shipment, so every DO of a shipment landed
   in one tr_picking_header and one tr_job_main (job 2002: DO-3031015452 +
   DO-3031015453). The job list then had to split cards per DO.

   Fix:
   1. pServiceSyncWmsShipment: re-use a picking header only when this same
      DO was synced before. A new DO always gets its own tr_picking_header,
      so its own tr_job_main (job_type_id 4).
   2. pProcessShipmentMapDO: drop the "This shipment is already mapped to a
      different picking job" check. With one job per DO, the DOs of one
      shipment are in different picking jobs by design.

   Shipping follows picking: pProcessPickingPutAway makes a shipping job
   from the picking header, so it now also makes one shipping job per DO
   (no change needed there).

   Base: the current .75 definitions, only the parts above changed.
   Existing multi-DO jobs: deploy_75_split_multi_do_picking_jobs_20261111.sql
   Rollback: rollback_75_picking_job_per_do_20261111.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
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

        --  One picking header (so one picking job) per DO: re-use a header
        --  only when this same DO was synced before. Other DOs of the same
        --  shipment get their own header and job.
        SELECT TOP 1 @pk_primary_id = pd.header_id
        FROM dbo.tr_picking_detail pd
        JOIN dbo.tr_delivery dchk ON dchk.id = pd.delivery_id
        WHERE dchk.do_no = @delivery_no
          AND dchk.is_active = 'Y' AND dchk.status_flag = 'A'
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
                total_pallet = COALESCE(ds.total_pallet, dbo.tr_delivery.total_pallet),
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

CREATE OR ALTER PROC [dbo].[pProcessShipmentMapDO]
	@shipment_no		VARCHAR(50)		= NULL,
	@delivery_no		VARCHAR(50)		= NULL,
	@excel_id			INT				= NULL,
	@user_id			INT				= NULL
AS
BEGIN
    SET NOCOUNT ON;

	IF @shipment_no IS NULL OR @delivery_no IS NULL OR @excel_id IS NULL
	BEGIN
		SELECT 'error' AS status, '@shipment_no, @delivery_no and @excel_id parameters are required.' AS message;
		RETURN;
	END

	BEGIN TRY
		BEGIN TRANSACTION;

		DECLARE @job_main_id INT = (SELECT TOP 1 id FROM dbo.vPickingJob WHERE item_id = @excel_id ORDER BY id);

		IF @job_main_id IS NULL
		BEGIN
			ROLLBACK TRANSACTION;
			SELECT 'error' AS status, 'No picking job found for the given @excel_id.' AS message;
			RETURN;
		END

		DECLARE @picking_header_id INT = (
			SELECT TOP 1 header_id FROM dbo.tr_picking_detail
			WHERE delivery_id = @excel_id AND is_active = 'Y' AND status_flag = 'A'
		);

		DECLARE @shipment_id INT;

		SELECT TOP 1 @shipment_id = id
		FROM dbo.tr_shipment
		WHERE shipment_no = @shipment_no AND is_active = 'Y' AND status_flag = 'A';

		IF @shipment_id IS NULL
		BEGIN
			INSERT INTO dbo.tr_shipment (shipment_no)
			VALUES (@shipment_no);

			SET @shipment_id = SCOPE_IDENTITY();
		END

		--  One picking job per DO: the DOs of one shipment are in different
		--  picking jobs by design, so the old "This shipment is already mapped
		--  to a different picking job" check is gone.

		DECLARE @current_job_status_id INT;

		SELECT @current_job_status_id = job_status_id
		FROM dbo.tr_job_main WITH (UPDLOCK, HOLDLOCK)
		WHERE id = @job_main_id;

		UPDATE dbo.tr_picking_header
		SET update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE id = @picking_header_id;

		UPDATE dbo.tr_delivery
		SET do_no = @delivery_no,
			shipment_id = @shipment_id,
			update_user_id = @user_id,
			update_datetime = GETDATE()
		WHERE id = @excel_id;

		DECLARE @already_shipped INT = (
			SELECT COUNT(*) FROM dbo.tr_shipping_detail
			WHERE delivery_id = @excel_id AND is_active = 'Y' AND status_flag = 'A'
		);

		IF @current_job_status_id = 5 AND ISNULL(@already_shipped, 0) = 0
		BEGIN
			DECLARE @lock_result INT;
			EXEC @lock_result = sp_getapplock
				@Resource = 'tr_shipping_header_seq',
				@LockMode = 'Exclusive',
				@LockOwner = 'Transaction',
				@LockTimeout = 5000;

			IF @lock_result < 0
				RAISERROR('Could not acquire lock for shipping header sequence generation.', 16, 1);

			DECLARE @today_seq INT = (
				SELECT COUNT(*) + 1
				FROM dbo.tr_shipping_header
				WHERE CAST(create_datetime AS DATE) = CAST(GETDATE() AS DATE)
			);

			INSERT INTO dbo.tr_shipping_header (
				system_no,
				status_id,
				from_pre_zone_cc_desc,
				to_dock_cc_desc
			)
			VALUES (
				'SP-' + CONVERT(VARCHAR(10), GETDATE(), 112) + RIGHT('000' + CAST(@today_seq AS VARCHAR(3)), 3),
				1,
				'Prepare Zone',
				'Dock'
			);

			DECLARE @new_shipping_id INT = SCOPE_IDENTITY();

			INSERT INTO dbo.tr_shipping_detail (delivery_id, header_id)
			SELECT pd.delivery_id, @new_shipping_id
			FROM dbo.tr_picking_detail pd
			WHERE pd.header_id = @picking_header_id
			  AND pd.is_active = 'Y' AND pd.status_flag = 'A'
			  AND NOT EXISTS (
				SELECT 1 FROM dbo.tr_shipping_detail sd
				WHERE sd.delivery_id = pd.delivery_id AND sd.is_active = 'Y' AND sd.status_flag = 'A'
			  );

			INSERT INTO dbo.tr_job_main (
				interface_job_id,
				job_type_id,
				job_status_id
			)
			VALUES (
				@new_shipping_id,
				5,
				1
			);

			DECLARE @shipping_job_main_id INT = SCOPE_IDENTITY();

			IF OBJECT_ID('tempdb..#pk_to_location') IS NOT NULL
				DROP TABLE #pk_to_location

			SELECT tl.*
			INTO #pk_to_location
			FROM dbo.tr_job_to_location tl
			WHERE tl.job_main_id = @job_main_id
				AND tl.is_active = 'Y'
				AND tl.status_flag = 'A';

			CREATE NONCLUSTERED INDEX idx_job_to_location ON #pk_to_location(interface_job_item_id, to_location_id);

			IF OBJECT_ID('tempdb..#new_from_locations') IS NOT NULL
				DROP TABLE #new_from_locations
			CREATE TABLE #new_from_locations (id INT);

			INSERT INTO dbo.tr_job_from_location (
				job_main_id,
				interface_job_item_id,
				from_location_id,
				from_location_type,
				qty,
				actual_qty,
				create_user_id,
				create_datetime,
				update_user_id,
				update_datetime
			)
			OUTPUT INSERTED.id INTO #new_from_locations(id)
			SELECT
				@shipping_job_main_id,
				@excel_id,
				to_location_id,
				to_location_type,
				actual_qty AS qty,
				actual_qty,
				@user_id,
				GETDATE(),
				@user_id,
				GETDATE()
			FROM #pk_to_location;

			INSERT INTO dbo.tr_lot_location (
				job_main_id,
				job_item_id,
				job_location_type,
				job_location_id,
				lot_no,
				create_user_id,
				create_datetime,
				update_user_id,
				update_datetime
			)
			SELECT
				@shipping_job_main_id,
				@excel_id,
				'FROM',
				nfl.id,
				src.lot_no,
				@user_id,
				GETDATE(),
				@user_id,
				GETDATE()
			FROM #new_from_locations nfl
			CROSS JOIN (
				SELECT ll.lot_no
				FROM dbo.tr_job_from_location fl
				INNER JOIN dbo.tr_lot_location ll
					ON ll.job_main_id = @job_main_id
					AND ll.job_item_id = @excel_id
					AND ll.job_location_type = 'FROM'
					AND ll.job_location_id = fl.id
					AND ll.is_active = 'Y'
					AND ll.status_flag = 'A'
				WHERE fl.job_main_id = @job_main_id
					AND fl.is_active = 'Y'
					AND fl.status_flag = 'A'
			) src;
		END

		COMMIT TRANSACTION;

		SELECT 'success' AS status, 'Shipment mapped successfully.' AS message;
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
		SELECT 'error' AS status, ERROR_MESSAGE() AS message;
	END CATCH
END
GO
