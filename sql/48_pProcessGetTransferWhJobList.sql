-- =============================================================
-- 48_pProcessGetTransferWhJobList.sql  (IRPC_QTRACK)
-- =============================================================
-- WH04 Transfer Warehouse has its own list page and its own API, the same
-- way WH03 Internal Transfer does (pProcessGetInternalTransferJobList /
-- GET job/internal-transfer):
--
--   page     job-wh-transfer-list
--   API      GET api/v1/process/job/transfer-wh  (JobController.GetTransferWhJobList)
--   SP       dbo.pProcessGetTransferWhJobList   (this file)
--
-- 1) dbo.pProcessGetTransferWhJobList -- one row per TW job (type 11), built
--    from dbo.fTransferWhJob (sql/46). Result sets:
--      dbResult   status / message
--      dbResult1  job rows for the page
--      dbResult2  total_count
--    Rows are per job: the first item (lowest item_id) gives grade / lot /
--    qty, item_count says how many more. Pallet counts are summed per item
--    (fTransferWhJob repeats them on every from/to location row).
--
-- 2) pProcessGetJobList -- the fTransferWhJob branch now runs only for a
--    single job (@id set, used by job-detail). WH01 / WH02 list calls no
--    longer return TW jobs, whatever ct_job_type.topic of type 11 is.
--
-- Idempotent. Needs 46 / 47 deployed first.
-- =============================================================
USE IRPC_QTRACK;
GO

CREATE OR ALTER PROC dbo.pProcessGetTransferWhJobList
    @id             INT             = NULL,
    @system_no      NVARCHAR(255)   = NULL,
    @date           DATE            = NULL,
    @job_status_id  INT             = NULL,
    @page           INT             = 1,
    @page_size      INT             = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;

    IF OBJECT_ID('tempdb..#rows') IS NOT NULL
        DROP TABLE #rows;

    SELECT *
    INTO #rows
    FROM dbo.fTransferWhJob(@id, @date) j
    WHERE (@system_no IS NULL OR j.system_no LIKE '%' + @system_no + '%')
      AND (@job_status_id IS NULL OR j.job_status_id = @job_status_id);

    -- one row per item: pallet counts are repeated on every location row
    IF OBJECT_ID('tempdb..#items') IS NOT NULL
        DROP TABLE #items;

    SELECT
        r.id,
        r.item_id,
        MAX(r.grade) AS grade,
        MAX(r.lot_no) AS lot_no,
        MAX(COALESCE(r.confirm_qty, r.qty)) AS qty,
        MAX(r.total_qty) AS total_pallet,
        SUM(r.receive_qty) AS receive_pallet,
        SUM(r.complete_qty) AS complete_pallet
    INTO #items
    FROM (
        SELECT DISTINCT id, item_id, grade, lot_no, confirm_qty, qty,
               job_to_location_id, total_qty, receive_qty, complete_qty
        FROM #rows
    ) r
    GROUP BY r.id, r.item_id;

    IF OBJECT_ID('tempdb..#jobs') IS NOT NULL
        DROP TABLE #jobs;

    SELECT
        r.id,
        MAX(r.header_id) AS header_id,
        MAX(r.system_no) AS system_no,
        MAX(r.wms_no) AS wms_no,
        MAX(r.job_type_id) AS job_type_id,
        MAX(r.job_type_short_name) AS job_type_short_name,
        MAX(r.job_type_name) AS job_type_name,
        MAX(r.job_status_id) AS job_status_id,
        MAX(r.job_status_name) AS job_status_name,
        MAX(r.is_urgent) AS is_urgent,
        MAX(r.movement_type) AS movement_type,
        MAX(r.from_location_cc_code) AS from_cc_code,
        MAX(r.from_location_cc_desc) AS from_cc_desc,
        MAX(r.to_location_type) AS to_location_type,
        MAX(r.to_location_cc_code) AS to_cc_code,
        MAX(r.to_location_cc_desc) AS to_cc_desc,
        MAX(r.qty_unit) AS qty_unit,
        MAX(r.movement_unit) AS movement_unit,
        MAX(r.job_start_datetime) AS job_start_datetime,
        MAX(r.job_end_datetime) AS job_end_datetime,
        MAX(r.job_create_datetime) AS job_create_datetime
    INTO #jobs
    FROM #rows r
    GROUP BY r.id;

    SELECT
        CASE WHEN EXISTS (SELECT 1 FROM #jobs) THEN 'success' ELSE 'success' END AS status,
        CASE WHEN EXISTS (SELECT 1 FROM #jobs) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    SELECT
        j.id,
        j.header_id,
        j.system_no,
        j.wms_no,
        j.job_type_id,
        j.job_type_short_name,
        j.job_type_name,
        j.job_status_id,
        j.job_status_name,
        j.is_urgent,
        j.movement_type,
        fi.grade,
        fi.lot_no,
        fi.qty,
        j.qty_unit,
        it.item_count,
        it.total_qty,
        it.total_pallet,
        it.receive_pallet,
        it.complete_pallet,
        j.movement_unit,
        j.from_cc_code,
        j.from_cc_desc,
        j.to_location_type,
        j.to_cc_code,
        j.to_cc_desc,
        tw.wh_code,
        tw.area_code,
        tw.level_code,
        tw.location_code,
        jm.product_cc,
        j.job_start_datetime,
        j.job_end_datetime,
        j.job_create_datetime
    FROM #jobs j
    CROSS APPLY (
        SELECT
            COUNT(*) AS item_count,
            SUM(i.qty) AS total_qty,
            SUM(ISNULL(i.total_pallet, 0)) AS total_pallet,
            SUM(ISNULL(i.receive_pallet, 0)) AS receive_pallet,
            SUM(ISNULL(i.complete_pallet, 0)) AS complete_pallet
        FROM #items i
        WHERE i.id = j.id
    ) it
    OUTER APPLY (
        SELECT TOP (1) i.item_id, i.grade, i.lot_no, i.qty
        FROM #items i
        WHERE i.id = j.id
        ORDER BY i.item_id
    ) fi
    LEFT JOIN IRPC_E_TRANSFER.dbo.VTransferWhForm tw
        ON tw.item_id = fi.item_id
    LEFT JOIN dbo.tr_job_main jm
        ON jm.id = j.id
    ORDER BY
        CASE WHEN j.is_urgent = 'Y' AND j.job_status_id <> 5 THEN 0 ELSE 1 END,
        j.id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    SELECT COUNT(*) AS total_count FROM #jobs;
END
GO

-- -------------------------------------------------------------
-- pProcessGetJobList: TW only for a single job (job-detail)
-- -------------------------------------------------------------
DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));

DECLARE @o1 NVARCHAR(400) = N'SELECT * FROM dbo.fTransferWhJob(@id, @date) WHERE (@inbound_receive = ''Y'') AND (@type_id IS NULL OR @type_id = 11)';
DECLARE @n1 NVARCHAR(400) = N'SELECT * FROM dbo.fTransferWhJob(@id, @date) WHERE (@inbound_receive = ''Y'') AND (@id IS NOT NULL)';

IF @d LIKE N'%fTransferWhJob(@id, @date) WHERE (@inbound_receive = ''Y'') AND (@id IS NOT NULL)%'
BEGIN
    PRINT 'pProcessGetJobList already returns TW for @id only - skipped.';
    RETURN;
END

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('pProcessGetJobList: text to patch not found exactly once - not patched (run 47 first).', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pProcessGetJobList patched: TW returned for @id (job-detail) only.';
GO
