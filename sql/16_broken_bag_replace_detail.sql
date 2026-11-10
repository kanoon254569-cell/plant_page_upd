/* ============================================================================
   Broken Bag -- "เปลี่ยนของกับ Warehouse" replace detail (FL PWA)
   ----------------------------------------------------------------------------
   The forklift page (report-broken-bag PWA FL) confirms the physical swap
   from the "เปลี่ยนของกับ Warehouse" modal: it scans / types N bags whose Grade
   and count match the job, then presses Submit -> PATCH
   api/v1/process/broken-bag/{id}/replace (BrokenBagController.
   ConfirmReplaceBrokenBag) -> pProcessConfirmReplaceBrokenBag.

   Each scanned bag becomes ONE row in tr_broken_bag_replace_detail:

       fg            int      -- Finish Good  0 = NG (broken bag removed)
                                              1 = OK (good bag from Warehouse)
       bag_qr_code   nvarchar -- the RAW QR string the forklift scanned or
                                 typed for that bag (kept for traceability;
                                 replaces the old numeric bag_id)
       scan_datetime datetime -- when that bag was scanned on the device

   @replace_items_json is the flattened scan list, fanned out via OPENJSON the
   same way pProcessCreateBrokenBag does with @items_json.

   This REPLACES the earlier grade/lot/qty/reason + 'W'/'S' side shape (that
   column set never existed on tr_broken_bag_replace_detail). BrokenBagController
   still forwards side/grade/lot/qty/reason in the JSON for backward
   compatibility with the CHECKER Replace modal, but this proc only reads the
   columns the table actually has.

   Run against: IRPC_QTRACK
   NOTE: tr_broken_bag_header / tr_broken_bag_status_log column names are assumed
   unchanged from the previous pProcessConfirmReplaceBrokenBag body. The 4
   FL/CK Shipping/Warehouse user-id params are now optional (ISNULL-kept) so the
   FL page -- which has a single signed-in forklift user, not a 4-way Login
   modal -- can call this without them.

   Dependencies: none -- creates dbo.tr_broken_bag_replace_detail itself. Run
   this BEFORE 17_broken_bag_forklift_scan.sql, which requires this table to
   already exist.
   ============================================================================ */

USE [IRPC_QTRACK];
GO

SET XACT_ABORT ON;
GO

/* 1) -------------------------------------------------------------- table -- */
IF OBJECT_ID('dbo.tr_broken_bag_replace_detail', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tr_broken_bag_replace_detail
    (
        id              BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_tr_broken_bag_replace_detail PRIMARY KEY,
        header_id       BIGINT        NOT NULL,
        fg              INT           NULL,   -- 0:NG, 1:OK
        bag_id          BIGINT        NULL,   -- legacy, no longer written
        bag_qr_code     NVARCHAR(255) NULL,   -- raw scanned / typed bag QR
        scan_datetime   DATETIME      NULL,
        create_datetime DATETIME      NULL
    );

    CREATE INDEX IX_tr_broken_bag_replace_detail_header_id
        ON dbo.tr_broken_bag_replace_detail (header_id);

    /* FK is best-effort -- drop this block if the header table name differs. */
    IF OBJECT_ID('dbo.tr_broken_bag_header', 'U') IS NOT NULL
        ALTER TABLE dbo.tr_broken_bag_replace_detail WITH NOCHECK
            ADD CONSTRAINT FK_tr_broken_bag_replace_detail_header
            FOREIGN KEY (header_id) REFERENCES dbo.tr_broken_bag_header (id);
END
GO

/* 1b) ------------------------------------- add bag_qr_code to an old table -- */
IF OBJECT_ID('dbo.tr_broken_bag_replace_detail', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.tr_broken_bag_replace_detail', 'bag_qr_code') IS NULL
    ALTER TABLE dbo.tr_broken_bag_replace_detail ADD bag_qr_code NVARCHAR(255) NULL;
GO

/* 2) ------------------------------------------------------------- proc -- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessConfirmReplaceBrokenBag]
    @id                     BIGINT,
    @fl_warehouse_user_id   INT = NULL,
    @fl_shipping_user_id    INT = NULL,
    @ck_warehouse_user_id   INT = NULL,
    @ck_shipping_user_id    INT = NULL,
    @replace_items_json     NVARCHAR(MAX),
    @user_id                INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* one row per scanned bag -- store the raw QR string, not a numeric id */
        INSERT INTO tr_broken_bag_replace_detail (header_id, fg, bag_qr_code, scan_datetime, create_datetime)
        SELECT @id,
               j.fg,
               j.bag_qr_code,
               ISNULL(j.scan_datetime, GETDATE()),
               GETDATE()
        FROM OPENJSON(@replace_items_json)
        WITH (
            fg            INT           '$.fg',
            bag_qr_code   NVARCHAR(255) '$.bag_qr_code',
            scan_datetime DATETIME      '$.scan_datetime'
        ) j;

        UPDATE tr_broken_bag_header
        SET status_id = 4, status_name = N'เปลี่ยนถุงแตกสำเร็จ',
            warehouse_ready = 1, shipping_ready = 1,
            fl_warehouse_user_id = ISNULL(@fl_warehouse_user_id, fl_warehouse_user_id),
            fl_shipping_user_id  = ISNULL(@fl_shipping_user_id,  fl_shipping_user_id),
            ck_warehouse_user_id = ISNULL(@ck_warehouse_user_id, ck_warehouse_user_id),
            ck_shipping_user_id  = ISNULL(@ck_shipping_user_id,  ck_shipping_user_id),
            update_by = @user_id, update_datetime = GETDATE()
        WHERE id = @id;

        IF @@ROWCOUNT = 0
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'error' AS status, N'Broken bag job not found' AS message;
            RETURN;
        END

        INSERT INTO tr_broken_bag_status_log (header_id, status_id, status_name, status_datetime, create_by)
        VALUES (@id, 4, N'เปลี่ยนถุงแตกสำเร็จ', GETDATE(), @user_id);

        COMMIT TRANSACTION;

        SELECT 'success' AS status, N'Replace confirmed' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO
