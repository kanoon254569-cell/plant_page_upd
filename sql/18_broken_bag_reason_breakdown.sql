/* ============================================================================
   Broken Bag -- "สาเหตุการเปลี่ยนถุงแตก" breakdown (multi-reason + จำนวนถุง)
   ----------------------------------------------------------------------------
   Feature: the Inspect modal (broken-bag-list PWA CHECKER) now lets the checker
   press "+" to add MANY สาเหตุ rows, each with its own bag quantity, instead of
   a single Remark dropdown.

   This script is ADDITIVE only -- it does NOT alter pProcessApproveBrokenBag or
   pProcessGetBrokenBagList. BrokenBagController orchestrates the two new procs:
     * POST-approve  -> pProcessSaveBrokenBagReasons  (persist the breakdown)
     * GET list      -> pProcessGetBrokenBagReasons   (read it back as
                        dbResultReasons, folded into the list response)
   Both calls are wrapped in try/catch on the API side, so deploy order does not
   matter -- the list keeps working before this runs, the breakdown just shows
   up once it is applied.

   Run against: IRPC_QTRACK
   NOTE: confirm the broken-bag table names used below (assumed
   dbo.tr_broken_bag_header and dbo.tr_broken_bag_detail, per
   BrokenBagController / BrokenBagService comments). The detail table is only
   used to re-check "reason qty total = reported qty total" in
   pProcessSaveBrokenBagReasons -- drop that block if the name differs.

   Dependencies: none -- creates dbo.tr_broken_bag_reason itself; independent
   of the other broken-bag files in this folder (16-17, 19).
   ============================================================================ */

SET XACT_ABORT ON;
GO

/* 1) ---------------------------------------------------------------- table -- */
IF OBJECT_ID('dbo.tr_broken_bag_reason', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tr_broken_bag_reason
    (
        id              BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_tr_broken_bag_reason PRIMARY KEY,
        header_id       BIGINT         NOT NULL,
        reason          NVARCHAR(255)  NOT NULL,
        qty             DECIMAL(18,2)  NOT NULL CONSTRAINT DF_tr_broken_bag_reason_qty DEFAULT (0),
        create_by       INT            NULL,
        create_datetime DATETIME       NOT NULL CONSTRAINT DF_tr_broken_bag_reason_created DEFAULT (GETDATE()),
        update_by       INT            NULL,
        update_datetime DATETIME       NULL
    );

    CREATE INDEX IX_tr_broken_bag_reason_header_id
        ON dbo.tr_broken_bag_reason (header_id);

    /* FK is best-effort -- drop this block if the header table differs. */
    IF OBJECT_ID('dbo.tr_broken_bag_header', 'U') IS NOT NULL
        ALTER TABLE dbo.tr_broken_bag_reason WITH NOCHECK
            ADD CONSTRAINT FK_tr_broken_bag_reason_header
            FOREIGN KEY (header_id) REFERENCES dbo.tr_broken_bag_header (id);
END
GO

/* 2) ------------------------------------------- save (called after approve) -- */
CREATE OR ALTER PROCEDURE dbo.pProcessSaveBrokenBagReasons
    @header_id    BIGINT,
    @reasons_json NVARCHAR(MAX),
    @user_id      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @reasons TABLE (reason NVARCHAR(255) NOT NULL, qty DECIMAL(18,2) NOT NULL);

        INSERT INTO @reasons (reason, qty)
        SELECT LTRIM(RTRIM(j.reason)), ISNULL(j.qty, 0)
        FROM OPENJSON(@reasons_json)
             WITH (
                 reason NVARCHAR(255) '$.reason',
                 qty    DECIMAL(18,2) '$.qty'
             ) AS j
        WHERE NULLIF(LTRIM(RTRIM(j.reason)), '') IS NOT NULL
          AND ISNULL(j.qty, 0) > 0;

        /* Safety net for the frontend's own rule: the จำนวนถุงรวมของสาเหตุ
           must equal the reported damage-bag total for this header. */
        DECLARE @reason_total DECIMAL(18,2) = (SELECT ISNULL(SUM(qty), 0) FROM @reasons);
        DECLARE @reported_total DECIMAL(18,2) =
            (SELECT ISNULL(SUM(qty), 0) FROM dbo.tr_broken_bag_detail WHERE header_id = @header_id);

        IF @reported_total > 0 AND @reason_total <> @reported_total
        BEGIN
            SELECT 'error' AS [status],
                   N'จำนวนถุงรวมของสาเหตุ (' + CONVERT(NVARCHAR(20), @reason_total)
                       + N') ไม่เท่ากับจำนวนที่แจ้ง (' + CONVERT(NVARCHAR(20), @reported_total) + N')' AS [message];
            RETURN;
        END

        BEGIN TRAN;

        /* one approve = one authoritative set of reasons: replace, don't append */
        DELETE FROM dbo.tr_broken_bag_reason
        WHERE  header_id = @header_id;

        INSERT INTO dbo.tr_broken_bag_reason (header_id, reason, qty, create_by, create_datetime)
        SELECT @header_id, reason, qty, @user_id, GETDATE()
        FROM   @reasons;

        COMMIT TRAN;

        SELECT 'success' AS [status],
               'Broken bag reasons saved' AS [message];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SELECT 'error' AS [status],
               ERROR_MESSAGE() AS [message];
    END CATCH
END
GO

/* 3) -------------------------------------------- read back (list response) -- */
CREATE OR ALTER PROCEDURE dbo.pProcessGetBrokenBagReasons
    @wh_code NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.header_id,
           r.reason,
           r.qty
    FROM   dbo.tr_broken_bag_reason  AS r
    INNER JOIN dbo.tr_broken_bag_header AS h
            ON h.id = r.header_id
    WHERE  (@wh_code IS NULL OR h.wh_code = @wh_code)
    ORDER BY r.header_id, r.id;
END
GO
