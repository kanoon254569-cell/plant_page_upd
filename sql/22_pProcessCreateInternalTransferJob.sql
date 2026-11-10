/* =====================================================================
   pProcessCreateInternalTransferJob
   -----------------------------------------------------------------
   Backs POST api/v1/process/job/internal-transfer (JobController.cs
   CreateInternalTransferJob), called when the user clicks
   "สร้างรายการย้ายสินค้า" on job-wh-internal-transfer-list (WH02 Internal
   Transfer). Creates ONE job across three tables in a single transaction:

     1. dbo.tr_job_main   -- shared cross-job-type header row (already exists
                             live). job_type_id = 10 (ct_job_type: category
                             'Outbound', code 'IT', name 'Internal Transfer')
                             and job_status_id = 1 (ct_job_status: 'Pending' --
                             the initial state before WH approval/execution,
                             matching this page's "Drafted" filter option).
                             interface_job_id = tr_internal_transfer_header.id
                             (per user direction -- no external interface system
                             assigns this for WH02, so it points at this job's
                             own header row instead). product_cc = cost center
                             ของฝั่งต้นทาง (first non-null ccCode among the
                             selected source locations -- destination's cc_code
                             is never collected in this flow, see requireExistingStock
                             on select-internal-transfer-location.ts). is_urgent/
                             is_multi_forklift are plain passthrough columns
                             (job-wh-internal-transfer-detail.html's URGENT
                             checkbox / 1 Step-2 Step toggle, same UI job-detail
                             already has for WH01) -- default 'N' when the
                             caller omits them.
     0. dbo.tr_job_assigness (pre-existing live table, shared across job
        types) -- 1 row per forklift assigned in the Forklift card, keyed off
        this new job's @job_main_id. Written last (after @job_main_id exists)
        even though the table itself has no other dependency here.
     2. dbo.tr_internal_transfer_header (NEW, created below if missing) --
        1 row per job: system_no ('IT'+yyyyMMdd+running 4-digit seq),
        source/destination remark (job-wh-internal-transfer-list.html's two
        separate remark boxes), total_qty, qty_unit.
     3. dbo.tr_internal_transfer_detail (NEW, created below if missing) --
        1 row per selected location on EITHER side (direction = 'SOURCE' |
        'DESTINATION'), carrying grade/lot/qty/remark plus a JSON snapshot of
        the specific pallets picked when "เลือกเป็นรายพาเลท" mode was used
        (select-internal-transfer-location.ts locationForm.selectedPallets) --
        snapshotted as-is rather than normalized into another table, since
        nothing downstream consumes per-pallet rows yet.

   Design of tables 2/3 follows the tr_special_header/tr_special_detail
   PATTERN (1 header row per job + N detail rows) per user's explicit
   direction, not their exact columns -- Special Job's columns are specific
   to that very different workflow (pre-zone staging, checker approval,
   pallet/bag counts) and don't fit a location-to-location transfer.

   Out of scope (not asked for): wiring this job into the unified WH01 Job
   List (pProcessGetJobList's 6-way view UNION) or dbo.tr_job_to_location --
   job-wh-internal-transfer-list's own list/search endpoint doesn't exist yet
   either (see job-wh-internal-transfer-list.ts search()), so there is
   nothing in-repo to wire this into today.
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.tr_internal_transfer_header', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tr_internal_transfer_header](
        [id]                  [bigint] IDENTITY(1,1) NOT NULL,
        [job_main_id]         [bigint] NOT NULL,
        [system_no]           [nvarchar](50) NOT NULL,
        [wh_code]             [varchar](10) NULL,
        [source_remark]       [nvarchar](500) NULL,
        [destination_remark]  [nvarchar](500) NULL,
        [qty_unit]            [varchar](10) NULL,
        [total_qty]           [decimal](18, 3) NULL,
        [is_active]           [varchar](1) NOT NULL,
        [create_user_id]      [int] NOT NULL,
        [create_datetime]     [datetime] NOT NULL,
        [update_user_id]      [int] NOT NULL,
        [update_datetime]     [datetime] NOT NULL,
        [status_flag]         [varchar](1) NOT NULL,
     CONSTRAINT [PK_tr_internal_transfer_header] PRIMARY KEY CLUSTERED
    (
        [id] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
    ) ON [PRIMARY]

    CREATE NONCLUSTERED INDEX [IX_tr_internal_transfer_header_job_main_id]
        ON [dbo].[tr_internal_transfer_header]([job_main_id]);
END
GO

IF OBJECT_ID('dbo.tr_internal_transfer_detail', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tr_internal_transfer_detail](
        [id]                [bigint] IDENTITY(1,1) NOT NULL,
        [header_id]         [bigint] NOT NULL,
        [direction]         [varchar](11) NOT NULL,   -- 'SOURCE' | 'DESTINATION'
        [location_id]       [int] NOT NULL,
        [location_type]     [varchar](10) NOT NULL,
        [location_name]     [varchar](50) NULL,        -- snapshot of locationForm.locationName, for list display without a master-location join
        [grade]             [varchar](50) NULL,
        [grade_id]          [int] NULL,                -- fpdgradeid from the WMS stock/grade lookup (select-internal-transfer-location.ts locationForm.gradeId), alongside the [grade] code snapshot above
        [lot_no]            [varchar](50) NULL,
        [qty]               [decimal](18, 3) NOT NULL,
        [remark]            [nvarchar](500) NULL,
        [pallet_json]       [nvarchar](max) NULL,     -- snapshot of selectedPallets when pallet-mode was used
        [is_active]         [varchar](1) NOT NULL,
        [create_user_id]    [int] NOT NULL,
        [create_datetime]   [datetime] NOT NULL,
        [update_user_id]    [int] NOT NULL,
        [update_datetime]   [datetime] NOT NULL,
        [status_flag]       [varchar](1) NOT NULL,
     CONSTRAINT [PK_tr_internal_transfer_detail] PRIMARY KEY CLUSTERED
    (
        [id] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
    ) ON [PRIMARY]

    CREATE NONCLUSTERED INDEX [IX_tr_internal_transfer_detail_header_id]
        ON [dbo].[tr_internal_transfer_detail]([header_id]);
END
GO

-- Idempotent add-column for a table that may already exist live from an
-- earlier deploy of this file (before location_name existed) -- the
-- CREATE TABLE block above only fires on a brand-new deploy.
IF COL_LENGTH('dbo.tr_internal_transfer_detail', 'location_name') IS NULL
BEGIN
    ALTER TABLE dbo.tr_internal_transfer_detail ADD [location_name] [varchar](50) NULL;
END
GO

-- Same idempotent add for grade_id (added after location_name).
IF COL_LENGTH('dbo.tr_internal_transfer_detail', 'grade_id') IS NULL
BEGIN
    ALTER TABLE dbo.tr_internal_transfer_detail ADD [grade_id] [int] NULL;
END
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessCreateInternalTransferJob]
    @wh_code                     VARCHAR(10)     = 'MWH',
    @qty_unit                    VARCHAR(10)     = NULL,
    @source_remark                NVARCHAR(500)   = NULL,
    @destination_remark           NVARCHAR(500)   = NULL,
    @source_locations_json        NVARCHAR(MAX),
    @destination_locations_json   NVARCHAR(MAX),
    @is_urgent                   VARCHAR(1)      = 'N',
    @is_multi_forklift           VARCHAR(1)      = 'N',
    @forklifts_json               NVARCHAR(MAX)   = NULL,
    @user_id                     INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @job_main_id  BIGINT;
    DECLARE @header_id    BIGINT;
    DECLARE @system_no    NVARCHAR(50);
    DECLARE @source_total DECIMAL(18, 3);
    DECLARE @dest_total   DECIMAL(18, 3);
    DECLARE @product_cc   VARCHAR(10);

    -- =============================================================
    -- Validate before opening a transaction -- mirrors the client-side
    -- checks in job-wh-internal-transfer-list.ts isFormValid, kept here
    -- too since this SP could be called by something other than that page.
    -- =============================================================

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

    -- product_cc = cost center ต้นทาง (source side only) -- takes the first
    -- non-null ccCode among the selected source locations, same as how a
    -- single source stock pick is expected to share one cost center.
    SELECT TOP 1 @product_cc = j.ccCode
    FROM OPENJSON(@source_locations_json) WITH (ccCode VARCHAR(10) '$.ccCode') j
    WHERE j.ccCode IS NOT NULL;

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

    BEGIN TRY
        BEGIN TRAN;

        -- 1) tr_job_main -- job_type_id=10 ('IT'/Internal Transfer),
        --    job_status_id=1 ('Pending', i.e. this page's "Drafted" state).
        INSERT INTO dbo.tr_job_main
            (interface_job_id, job_type_id, job_status_id, is_urgent, is_multi_forklift,
             start_datetime, end_datetime, product_cc, is_active,
             create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
        VALUES
            (0, 10, 1, ISNULL(@is_urgent, 'N'), ISNULL(@is_multi_forklift, 'N'),
             NULL, NULL, @product_cc, 'Y',
             ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A');

        SET @job_main_id = SCOPE_IDENTITY();

        -- 2) system_no: 'IT' + yyyyMMdd + running 4-digit seq for that day.
        --    sp_getapplock with @LockOwner='Transaction' auto-releases at
        --    COMMIT/ROLLBACK -- serializes concurrent creates so two requests
        --    in the same millisecond can't compute the same next seq (same
        --    concern fGetPalletNo/pallet_matching_service already guards for).
        DECLARE @lock_result INT;
        EXEC @lock_result = sp_getapplock
            @Resource = 'tr_internal_transfer_header_system_no',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 5000;

        IF @lock_result < 0
            THROW 50001, N'ไม่สามารถขอ lock สำหรับสร้างเลขที่เอกสารได้ กรุณาลองใหม่อีกครั้ง', 1;

        DECLARE @today VARCHAR(8) = FORMAT(GETDATE(), 'yyyyMMdd');
        DECLARE @seq   INT;

        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(system_no, 4) AS INT)), 0) + 1
        FROM dbo.tr_internal_transfer_header
        WHERE system_no LIKE 'IT' + @today + '%';

        SET @system_no = 'IT' + @today + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        -- 3) tr_internal_transfer_header -- 1 row per job.
        INSERT INTO dbo.tr_internal_transfer_header
            (job_main_id, system_no, wh_code, source_remark, destination_remark, qty_unit, total_qty,
             is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
        VALUES
            (@job_main_id, @system_no, @wh_code, @source_remark, @destination_remark, @qty_unit, @source_total,
             'Y', ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A');

        SET @header_id = SCOPE_IDENTITY();

        -- interface_job_id = tr_internal_transfer_header.id (per user direction --
        -- changed from self-referencing tr_job_main.id: WH02's "interface" id is
        -- this job's own header row, not tr_job_main's row).
        UPDATE dbo.tr_job_main
        SET    interface_job_id = @header_id
        WHERE  id = @job_main_id;

        -- 4) tr_internal_transfer_detail -- 1 row per selected location, both sides.
        --    location_name is a display-only snapshot (locationForm.locationName)
        --    so the list page can show a route without joining master location data.
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

        -- 5) dbo.tr_job_assigness -- 1 row per assigned forklift, same table
        --    WH01's own approve/forklift-assignment flow uses (pProcessGetJobList
        --    .optimized.sql's #forklift temp table reads it filtered on
        --    is_active='Y' AND status_flag='A', see JobController.cs's
        --    CreatePickingJob/ApproveJob for the equivalent write pattern
        --    with pProcessCreatePickingJob's @forklifts_json). assigner_user_id
        --    is whoever created this job (@user_id) -- there's no separate
        --    "assigned by" actor in this flow.
        IF @forklifts_json IS NOT NULL
        BEGIN
            INSERT INTO dbo.tr_job_assigness
                (job_main_id, assigner_user_id, assignee_forklift_id, is_active,
                 create_user_id, create_datetime, update_user_id, update_datetime, status_flag)
            SELECT
                @job_main_id, ISNULL(@user_id, 0), f.id, 'Y',
                ISNULL(@user_id, 0), GETDATE(), ISNULL(@user_id, 0), GETDATE(), 'A'
            FROM OPENJSON(@forklifts_json) WITH (id INT '$.id') f
            WHERE f.id IS NOT NULL;
        END

        -- 6) Audit log via the shared helper from 20_tr_transaction_log.sql
        --    (already deployed) -- swallows its own exceptions, never fails this COMMIT.
        --    @detail built into a local variable first, then passed positionally --
        --    a Thai N'...' literal built inline inside CONCAT(...) as a named
        --    @detail = ... argument broke SSMS/sqlcmd's parser on this specific
        --    phrase (Msg 102 "Incorrect syntax near ...") even though the file's
        --    own bytes were valid UTF-8; declaring it as a plain variable first
        --    sidesteps whatever parsing edge case that was.
        DECLARE @topic NVARCHAR(50) = 'Internal Transfer';
        DECLARE @activity NVARCHAR(50) = 'Create Internal Transfer Job';
        DECLARE @detail NVARCHAR(MAX) = CONCAT(N'สร้างรายการย้ายสินค้าภายในคลัง เลขที่ ', @system_no,
                              N' จำนวน ', CAST(@source_total AS VARCHAR(20)), N' ', ISNULL(@qty_unit, N''),
                              N' โดย User ID: ', ISNULL(@user_id, 0));
        EXEC dbo.pInsertTransactionLog @topic, @activity, @detail, @user_id;

        COMMIT TRAN;

        SELECT 'success' AS status, N'สร้างรายการย้ายสินค้าสำเร็จ' AS message,
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
-- EXEC dbo.pProcessCreateInternalTransferJob
--      @wh_code = 'MWH', @qty_unit = 'kg',
--      @source_remark = N'หมายเหตุต้นทาง', @destination_remark = N'หมายเหตุปลายทาง',
--      @source_locations_json = N'[{"locationId":101,"locationType":"MWH","locationName":"W43A0101","ccCode":"1312","grade":"1126NK","gradeId":4510,"lot":"0260805036","qty":500,"remark":null,"pallets":null}]',
--      @destination_locations_json = N'[{"locationId":205,"locationType":"MWH","locationName":"W43B0205","grade":"1126NK","gradeId":4510,"lot":"0260805036","qty":500,"remark":null,"pallets":null}]',
--      @is_urgent = 'N', @is_multi_forklift = 'N',
--      @forklifts_json = N'[{"id":12}]',
--      @user_id = 101;
