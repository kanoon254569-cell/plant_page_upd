/* =====================================================================
   pProcessUpdateInternalTransferJob
   -----------------------------------------------------------------
   Backs PUT api/v1/process/job/internal-transfer/{jobId} (JobController.cs
   UpdateInternalTransferJob) -- job-wh-internal-transfer-list.ts's Edit
   action reuses the exact same create-form/pickers (openEditModal), so
   this SP mirrors pProcessCreateInternalTransferJob's validation and
   @*_locations_json shape almost exactly; the only real differences are:

     - No new tr_job_main row -- updates the existing one (product_cc only;
       job_type_id/job_status_id/interface_job_id are left alone).
     - tr_internal_transfer_header is UPDATEd in place (same id, same
       system_no) instead of INSERTed.
     - tr_internal_transfer_detail rows are replaced wholesale (DELETE +
       re-INSERT) rather than only ever inserted -- safe here because
       nothing downstream references a detail row's id yet (WH02 has no
       execution/approval workflow that would have picked one up), unlike
       e.g. tr_pallet rows in pallet_matching_service.sql which get
       re-pointed, never replaced.
     - Guarded to job_status_id = 1 ('Pending'/"Drafted") only -- once
       something advances a job past that (no such workflow exists for
       WH02 yet, but this guard is here for when one does), the create-form
       no longer applies to it.
     - dbo.tr_job_assigness (forklift assignment) rows are replaced SOFTLY
       (old rows marked is_active='N', not DELETEd) rather than wholesale
       DELETE + re-INSERT like tr_internal_transfer_detail -- see the inline
       comment at that block.
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessUpdateInternalTransferJob]
    @job_main_id                  BIGINT,
    @wh_code                      VARCHAR(10)     = 'MWH',
    @qty_unit                     VARCHAR(10)     = NULL,
    @source_remark                NVARCHAR(500)   = NULL,
    @destination_remark           NVARCHAR(500)   = NULL,
    @source_locations_json        NVARCHAR(MAX),
    @destination_locations_json   NVARCHAR(MAX),
    @is_urgent                    VARCHAR(1)      = NULL,
    @is_multi_forklift            VARCHAR(1)      = NULL,
    @forklifts_json                NVARCHAR(MAX)   = NULL,
    @user_id                      INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @header_id     BIGINT;
    DECLARE @system_no     NVARCHAR(50);
    DECLARE @job_status_id INT;
    DECLARE @source_total  DECIMAL(18, 3);
    DECLARE @dest_total    DECIMAL(18, 3);
    DECLARE @product_cc    VARCHAR(10);

    SELECT @header_id = h.id, @system_no = h.system_no, @job_status_id = jm.job_status_id
    FROM dbo.tr_internal_transfer_header h
    JOIN dbo.tr_job_main jm ON jm.id = h.job_main_id AND jm.status_flag = 'A'
    WHERE h.job_main_id = @job_main_id AND h.status_flag = 'A';

    IF @header_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบรายการย้ายสินค้านี้' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    IF @job_status_id <> 1
    BEGIN
        SELECT 'error' AS status, N'แก้ไขได้เฉพาะรายการที่ยังเป็นสถานะ Drafted เท่านั้น' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM OPENJSON(@source_locations_json))
    BEGIN
        SELECT 'error' AS status, N'กรุณาเลือกตำแหน่งต้นทางอย่างน้อย 1 รายการ' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM OPENJSON(@destination_locations_json))
    BEGIN
        SELECT 'error' AS status, N'กรุณาเลือกตำแหน่งปลายทางอย่างน้อย 1 รายการ' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    SELECT @source_total = SUM(qty) FROM OPENJSON(@source_locations_json) WITH (qty DECIMAL(18, 3) '$.qty');
    SELECT @dest_total   = SUM(qty) FROM OPENJSON(@destination_locations_json) WITH (qty DECIMAL(18, 3) '$.qty');

    IF ISNULL(@source_total, 0) <= 0 OR ISNULL(@dest_total, 0) <= 0
    BEGIN
        SELECT 'error' AS status, N'จำนวนที่เลือกต้องมากกว่า 0' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    IF @source_total <> @dest_total
    BEGIN
        SELECT 'error' AS status, N'จำนวนรวมต้นทางและปลายทางต้องเท่ากัน' AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
        RETURN;
    END

    -- product_cc = cost center ต้นทาง (source side only), same rule as create.
    SELECT TOP 1 @product_cc = j.ccCode
    FROM OPENJSON(@source_locations_json) WITH (ccCode VARCHAR(10) '$.ccCode') j
    WHERE j.ccCode IS NOT NULL;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE dbo.tr_internal_transfer_header
        SET    wh_code = @wh_code,
               source_remark = @source_remark,
               destination_remark = @destination_remark,
               qty_unit = @qty_unit,
               total_qty = @source_total,
               update_user_id = ISNULL(@user_id, 0),
               update_datetime = GETDATE()
        WHERE  id = @header_id;

        -- COALESCE, not overwrite: tr_internal_transfer_detail doesn't persist
        -- ccCode (only tr_job_main.product_cc does), so a location that was
        -- pre-filled by Edit and never re-picked through the Stock Inquiry
        -- filter carries no ccCode at all -- overwriting unconditionally would
        -- NULL out product_cc on any edit that doesn't touch the picker.
        UPDATE dbo.tr_job_main
        SET    product_cc = COALESCE(@product_cc, product_cc),
               is_urgent = COALESCE(@is_urgent, is_urgent),
               is_multi_forklift = COALESCE(@is_multi_forklift, is_multi_forklift),
               update_user_id = ISNULL(@user_id, 0),
               update_datetime = GETDATE()
        WHERE  id = @job_main_id;

        DELETE FROM dbo.tr_internal_transfer_detail WHERE header_id = @header_id;

        INSERT INTO dbo.tr_internal_transfer_detail
            (header_id, direction, location_id, location_type, location_name, grade, grade_id, lot_no, qty, remark, pallet_json,
             is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
        SELECT
            @header_id, 'SOURCE', j.locationId, ISNULL(j.locationType, @wh_code), j.locationName, j.grade, j.gradeId, j.lot, j.qty, j.remark, j.pallets_json,
            'Y', ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A'
        FROM OPENJSON(@source_locations_json)
        WITH (
            locationId      INT             '$.locationId',
            locationType    VARCHAR(10)     '$.locationType',
            locationName    VARCHAR(50)     '$.locationName',
            grade           VARCHAR(50)     '$.grade',
            gradeId         INT             '$.gradeId',
            lot             VARCHAR(50)     '$.lot',
            qty             DECIMAL(18, 3)  '$.qty',
            remark          NVARCHAR(500)   '$.remark',
            pallets_json    NVARCHAR(MAX)   '$.pallets' AS JSON
        ) j;

        INSERT INTO dbo.tr_internal_transfer_detail
            (header_id, direction, location_id, location_type, location_name, grade, grade_id, lot_no, qty, remark, pallet_json,
             is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
        SELECT
            @header_id, 'DESTINATION', j.locationId, ISNULL(j.locationType, @wh_code), j.locationName, j.grade, j.gradeId, j.lot, j.qty, j.remark, j.pallets_json,
            'Y', ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A'
        FROM OPENJSON(@destination_locations_json)
        WITH (
            locationId      INT             '$.locationId',
            locationType    VARCHAR(10)     '$.locationType',
            locationName    VARCHAR(50)     '$.locationName',
            grade           VARCHAR(50)     '$.grade',
            gradeId         INT             '$.gradeId',
            lot             VARCHAR(50)     '$.lot',
            qty             DECIMAL(18, 3)  '$.qty',
            remark          NVARCHAR(500)   '$.remark',
            pallets_json    NVARCHAR(MAX)   '$.pallets' AS JSON
        ) j;

        -- dbo.tr_job_assigness -- replaced wholesale like tr_internal_transfer_detail
        -- above, but soft (is_active='N' on the old rows, not DELETEd): this table is
        -- shared across job types and its own read side (pProcessGetJobList
        -- .optimized.sql's #forklift, pProcessGetForkliftJobs.optimized.sql) already
        -- filters on is_active='Y' AND status_flag='A', so deactivating old
        -- assignments is enough to drop them from those views without touching rows
        -- another job type's history might still expect to find.
        IF @forklifts_json IS NOT NULL
        BEGIN
            UPDATE dbo.tr_job_assigness
            SET    is_active = 'N',
                   update_user_id = ISNULL(@user_id, 0),
                   update_datetime = GETDATE()
            WHERE  job_main_id = @job_main_id AND is_active = 'Y' AND status_flag = 'A';

            INSERT INTO dbo.tr_job_assigness
                (job_main_id, assigner_user_id, assignee_forklift_id, is_active,
                 create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
            SELECT
                @job_main_id, ISNULL(@user_id, 0), f.id, 'Y',
                ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A'
            FROM OPENJSON(@forklifts_json) WITH (id INT '$.id') f
            WHERE f.id IS NOT NULL;
        END

        DECLARE @topic NVARCHAR(50) = 'Internal Transfer';
        DECLARE @activity NVARCHAR(50) = 'Update Internal Transfer Job';
        DECLARE @detail NVARCHAR(MAX) = CONCAT(N'แก้ไขรายการย้ายสินค้าภายในคลัง เลขที่ ', @system_no,
                              N' จำนวน ', CAST(@source_total AS VARCHAR(20)), N' ', ISNULL(@qty_unit, N''),
                              N' โดย User ID: ', ISNULL(@user_id, 0));
        EXEC dbo.pInsertTransactionLog @topic, @activity, @detail, @user_id;

        COMMIT TRAN;

        SELECT 'success' AS status, N'แก้ไขรายการย้ายสินค้าสำเร็จ' AS message,
               @job_main_id AS job_main_id, @system_no AS system_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;

        SELECT 'error' AS status, ERROR_MESSAGE() AS message,
               CAST(NULL AS BIGINT) AS job_main_id, CAST(NULL AS NVARCHAR(50)) AS system_no;
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessUpdateInternalTransferJob
--      @job_main_id = 123, @wh_code = 'MWH', @qty_unit = 'kg',
--      @source_remark = N'หมายเหตุต้นทาง (แก้ไข)', @destination_remark = N'หมายเหตุปลายทาง (แก้ไข)',
--      @source_locations_json = N'[{"locationId":101,"locationType":"MWH","locationName":"W43A0101","ccCode":"1312","grade":"1126NK","gradeId":4510,"lot":"0260805036","qty":500,"remark":null,"pallets":null}]',
--      @destination_locations_json = N'[{"locationId":205,"locationType":"MWH","locationName":"W43B0205","grade":"1126NK","gradeId":4510,"lot":"0260805036","qty":500,"remark":null,"pallets":null}]',
--      @is_urgent = 'Y', @is_multi_forklift = 'N',
--      @forklifts_json = N'[{"id":12}]',
--      @user_id = 101;
