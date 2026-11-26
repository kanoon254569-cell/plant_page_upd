/* =====================================================================
   Deploy to 10.31.1.75 -- split existing multi-DO picking jobs
   ---------------------------------------------------------------------
   Run after deploy_75_picking_job_per_do_20261111.sql.

   Before that deploy, all DOs of one shipment went into one picking job.
   On 11/11/2026 the .75 DB has 3 such jobs, all status 2 (approved, not
   started, no pallet moved):
     job 2002 (header 3): DO-3031015452 + DO-3031015453
     job 2003 (header 4): DO-3031015240 + DO-3031015469
     job 2004 (header 5): DO-3031015471 + DO-3031015473

   For each active picking job (job_type_id 4) with more than one DO and
   job_status_id IN (1, 2), the first DO (lowest tr_picking_detail.id)
   stays on the old job. Each other DO gets:
     - a new tr_picking_header (copy of the old header, new PK- system_no)
     - its tr_picking_detail row moved to the new header
     - a new tr_job_main (copy of the old job: status, urgent, product cc /
       type, create time)
     - its tr_job_from_location / tr_job_to_location / tr_lot_location /
       tr_job_total_pallet_snapshot / tr_pallet rows moved to the new job
     - a copy of the old job's active tr_job_assigness rows (same forklifts)

   Jobs already started (status > 2) are skipped and listed, not changed.

   Every split is logged in dbo.bak_split_picking_job_20261111, which the
   rollback reads: rollback_75_split_multi_do_picking_jobs_20261111.sql
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('dbo.bak_split_picking_job_20261111') IS NULL
BEGIN
    CREATE TABLE dbo.bak_split_picking_job_20261111 (
        id                  INT IDENTITY(1, 1) PRIMARY KEY,
        old_job_main_id     BIGINT      NOT NULL,
        new_job_main_id     BIGINT      NOT NULL,
        old_header_id       BIGINT      NOT NULL,
        new_header_id       BIGINT      NOT NULL,
        picking_detail_id   INT         NOT NULL,
        delivery_id         BIGINT      NOT NULL,
        split_datetime      DATETIME    NOT NULL DEFAULT GETDATE()
    );
END

--  Jobs started already: not split, shown for a manual check.
SELECT jm.id AS skipped_job_main_id, jm.job_status_id, COUNT(*) AS do_count
FROM dbo.tr_job_main jm
JOIN dbo.tr_picking_detail pd
    ON pd.header_id = jm.interface_job_id AND pd.is_active = 'Y' AND pd.status_flag = 'A'
WHERE jm.job_type_id = 4 AND jm.is_active = 'Y' AND jm.status_flag = 'A'
  AND jm.job_status_id NOT IN (1, 2)
GROUP BY jm.id, jm.job_status_id
HAVING COUNT(*) > 1;

BEGIN TRANSACTION;

IF OBJECT_ID('tempdb..#to_split') IS NOT NULL DROP TABLE #to_split;

--  Every DO except the first one of each multi-DO job.
SELECT
    jm.id AS old_job_main_id,
    jm.interface_job_id AS old_header_id,
    pd.id AS picking_detail_id,
    pd.delivery_id
INTO #to_split
FROM dbo.tr_job_main jm
JOIN dbo.tr_picking_detail pd
    ON pd.header_id = jm.interface_job_id AND pd.is_active = 'Y' AND pd.status_flag = 'A'
WHERE jm.job_type_id = 4 AND jm.is_active = 'Y' AND jm.status_flag = 'A'
  AND jm.job_status_id IN (1, 2)
  AND pd.id > (
        SELECT MIN(pd1.id)
        FROM dbo.tr_picking_detail pd1
        WHERE pd1.header_id = jm.interface_job_id AND pd1.is_active = 'Y' AND pd1.status_flag = 'A'
  );

DECLARE @old_job BIGINT, @old_header BIGINT, @pd_id INT, @delivery_id BIGINT;
DECLARE @new_header BIGINT, @new_job BIGINT, @pk_seq INT;

DECLARE split_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT old_job_main_id, old_header_id, picking_detail_id, delivery_id
    FROM #to_split
    ORDER BY old_job_main_id, picking_detail_id;

OPEN split_cursor;
FETCH NEXT FROM split_cursor INTO @old_job, @old_header, @pd_id, @delivery_id;

WHILE @@FETCH_STATUS = 0
BEGIN
    --  Same PK- numbering as pServiceSyncWmsShipment.
    SET @pk_seq = (
        SELECT COUNT(*) + 1
        FROM dbo.tr_picking_header
        WHERE CAST(create_datetime AS DATE) = CAST(GETDATE() AS DATE)
    );

    INSERT INTO dbo.tr_picking_header (
        system_no, status_id, from_wh_id, from_wh_cc_code, from_wh_cc_desc,
        to_pre_zone_id, to_pre_zone_cc_code, to_pre_zone_cc_desc,
        is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag
    )
    SELECT
        'PK-' + CONVERT(VARCHAR(10), GETDATE(), 112) + RIGHT('000' + CAST(@pk_seq AS VARCHAR(3)), 3),
        ph.status_id, ph.from_wh_id, ph.from_wh_cc_code, ph.from_wh_cc_desc,
        ph.to_pre_zone_id, ph.to_pre_zone_cc_code, ph.to_pre_zone_cc_desc,
        ph.is_active, ph.create_user_id, ph.create_datetime, 1, GETDATE(), ph.status_flag
    FROM dbo.tr_picking_header ph
    WHERE ph.id = @old_header;

    SET @new_header = SCOPE_IDENTITY();

    UPDATE dbo.tr_picking_detail
    SET header_id = @new_header, update_user_id = 1, update_datetime = GETDATE()
    WHERE id = @pd_id;

    INSERT INTO dbo.tr_job_main (
        interface_job_id, job_type_id, job_status_id, is_urgent, is_multi_forklift,
        start_datetime, end_datetime, product_cc, product_type, is_active,
        create_user_id, create_datetime, update_user_id, update_datetime, status_flag, is_advance_order
    )
    SELECT
        @new_header, jm.job_type_id, jm.job_status_id, jm.is_urgent, jm.is_multi_forklift,
        jm.start_datetime, jm.end_datetime, jm.product_cc, jm.product_type, jm.is_active,
        jm.create_user_id, jm.create_datetime, 1, GETDATE(), jm.status_flag, jm.is_advance_order
    FROM dbo.tr_job_main jm
    WHERE jm.id = @old_job;

    SET @new_job = SCOPE_IDENTITY();

    UPDATE dbo.tr_job_from_location SET job_main_id = @new_job
    WHERE job_main_id = @old_job AND interface_job_item_id = @delivery_id;

    UPDATE dbo.tr_job_to_location SET job_main_id = @new_job
    WHERE job_main_id = @old_job AND interface_job_item_id = @delivery_id;

    UPDATE dbo.tr_lot_location SET job_main_id = @new_job
    WHERE job_main_id = @old_job AND job_item_id = @delivery_id;

    UPDATE dbo.tr_job_total_pallet_snapshot SET job_main_id = @new_job
    WHERE job_main_id = @old_job AND item_id = @delivery_id;

    UPDATE dbo.tr_pallet SET current_job_id = @new_job
    WHERE current_job_id = @old_job AND current_job_item_id = @delivery_id;

    INSERT INTO dbo.tr_job_assigness (
        job_main_id, assigner_user_id, assignee_forklift_id, assignee_user_id, is_read,
        is_active, create_user_id, create_datetime, update_user_id, update_datetime, status_flag
    )
    SELECT
        @new_job, ja.assigner_user_id, ja.assignee_forklift_id, ja.assignee_user_id, ja.is_read,
        ja.is_active, ja.create_user_id, ja.create_datetime, 1, GETDATE(), ja.status_flag
    FROM dbo.tr_job_assigness ja
    WHERE ja.job_main_id = @old_job AND ja.is_active = 'Y' AND ja.status_flag = 'A';

    INSERT INTO dbo.bak_split_picking_job_20261111 (
        old_job_main_id, new_job_main_id, old_header_id, new_header_id, picking_detail_id, delivery_id
    )
    VALUES (@old_job, @new_job, @old_header, @new_header, @pd_id, @delivery_id);

    FETCH NEXT FROM split_cursor INTO @old_job, @old_header, @pd_id, @delivery_id;
END

CLOSE split_cursor;
DEALLOCATE split_cursor;

COMMIT TRANSACTION;

--  Result: one row per job that was created.
SELECT b.old_job_main_id, b.new_job_main_id, b.new_header_id, ph.system_no AS new_pk_no, d.do_no
FROM dbo.bak_split_picking_job_20261111 b
JOIN dbo.tr_picking_header ph ON ph.id = b.new_header_id
JOIN dbo.tr_delivery d ON d.id = b.delivery_id
ORDER BY b.old_job_main_id, b.new_job_main_id;
GO
