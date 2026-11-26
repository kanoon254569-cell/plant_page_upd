/* ============================================================================
   Broken Bag -- Forklift scan (report-broken-bag PWA FL, "เปลี่ยนของกับ
   Warehouse" modal Submit)
   ----------------------------------------------------------------------------
   New endpoint  PATCH api/v1/process/broken-bag/{id}/forklift-scan-broken-bag
                 -> BrokenBagController.ForkliftScanBrokenBag
                 -> pProcessForkliftScanBrokenBag

   Records every bag the forklift scanned / typed in the modal:
     * one row per bag into tr_broken_bag_replace_detail
         fg            0 = NG / 1 = OK
         bag_qr_code   the raw scanned / typed QR string
         bag_id        resolved from tr_bag.qr_text_data (LEFT JOIN -> NULL
                       when the QR is not a known bag)
         scan_datetime device scan time (falls back to GETDATE())
         create_user_id / create_datetime  audit
     * header: shipping_ready = 1, fl_shipping_user_id = @user_id
     * status log: status_id 3 "สแกนถุงแตกสำเร็จ"

   Lighter than pProcessConfirmReplaceBrokenBag (the CHECKER Replace flow):
   no 4-way FL/CK login, header status_id is left as-is.

   @replace_items_json item shape (flattened by BrokenBagController):
       [{ "fg": 0, "bag_qr_code": "...", "scan_datetime": "2026-08-30T19:03:00" }]

   Run against: IRPC_QTRACK

   Dependencies: 16_broken_bag_replace_detail.sql (requires
   dbo.tr_broken_bag_replace_detail to already exist -- this script only adds
   a column to it, it does not create the table).
   ============================================================================ */

USE [IRPC_QTRACK];
GO

SET XACT_ABORT ON;
GO

/* 1) ----------------------------- audit column on the detail table -- */
IF OBJECT_ID('dbo.tr_broken_bag_replace_detail', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.tr_broken_bag_replace_detail', 'create_user_id') IS NULL
    ALTER TABLE dbo.tr_broken_bag_replace_detail ADD create_user_id INT NULL;
GO

/* 2) ------------------------------------------------------------ proc -- */
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessForkliftScanBrokenBag]
    @id                     BIGINT,
    @replace_items_json     NVARCHAR(MAX),
    @user_id                INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* one row per scanned bag -- read only the columns the table has */
        INSERT INTO tr_broken_bag_replace_detail (header_id, fg, bag_qr_code, bag_id, scan_datetime, create_user_id, create_datetime)
        SELECT @id,
               j.fg,
               j.bag_qr_code,
               b.id,
               ISNULL(j.scan_datetime, GETDATE()),
               @user_id,
               GETDATE()
        FROM OPENJSON(@replace_items_json)
        WITH (
            fg            INT          '$.fg',
            bag_qr_code   VARCHAR(100) '$.bag_qr_code',
            scan_datetime DATETIME     '$.scan_datetime'
        ) j
        LEFT JOIN tr_bag b
            ON b.qr_text_data = j.bag_qr_code;

        UPDATE tr_broken_bag_header
        SET shipping_ready = 1,
            fl_shipping_user_id = @user_id,
            update_by = @user_id,
            update_datetime = GETDATE()
        WHERE id = @id;

        IF @@ROWCOUNT = 0
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'Broken bag job not found' AS message;
            RETURN;
        END

        INSERT INTO tr_broken_bag_status_log (header_id, status_id, status_name, status_datetime, create_by)
        VALUES (@id, 3, N'สแกนถุงแตกสำเร็จ', GETDATE(), @user_id);

        COMMIT TRANSACTION;

        SELECT 'success' AS status, N'Broken Bag Confirmed' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO
