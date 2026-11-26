/* =====================================================================
   Rollback on 10.31.1.75 -- deploy_75_split_multi_do_picking_jobs_20261111.sql
   ---------------------------------------------------------------------
   Reads dbo.bak_split_picking_job_20261111 and, for each split DO:
     - moves its tr_picking_detail row back to the old header
     - moves its from/to location, lot location, total pallet snapshot and
       tr_pallet rows back to the old job
     - deletes the new job's tr_job_assigness rows, the new tr_job_main and
       the new tr_picking_header

   Only safe while the new jobs are not started. The script stops when any
   new job has moved past status 2.
   ===================================================================== */
USE IRPC_QTRACK;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('dbo.bak_split_picking_job_20261111') IS NULL
BEGIN
    RAISERROR('dbo.bak_split_picking_job_20261111 not found: nothing to roll back.', 16, 1);
    RETURN;
END

IF EXISTS (
    SELECT 1
    FROM dbo.bak_split_picking_job_20261111 b
    JOIN dbo.tr_job_main jm ON jm.id = b.new_job_main_id
    WHERE jm.job_status_id NOT IN (1, 2)
)
BEGIN
    RAISERROR('A split job is already started (status > 2). Roll back by hand.', 16, 1);
    RETURN;
END

BEGIN TRANSACTION;

UPDATE pd SET header_id = b.old_header_id, update_user_id = 1, update_datetime = GETDATE()
FROM dbo.tr_picking_detail pd
JOIN dbo.bak_split_picking_job_20261111 b ON b.picking_detail_id = pd.id;

UPDATE fl SET job_main_id = b.old_job_main_id
FROM dbo.tr_job_from_location fl
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = fl.job_main_id;

UPDATE tl SET job_main_id = b.old_job_main_id
FROM dbo.tr_job_to_location tl
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = tl.job_main_id;

UPDATE ll SET job_main_id = b.old_job_main_id
FROM dbo.tr_lot_location ll
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = ll.job_main_id;

UPDATE s SET job_main_id = b.old_job_main_id
FROM dbo.tr_job_total_pallet_snapshot s
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = s.job_main_id;

UPDATE p SET current_job_id = b.old_job_main_id
FROM dbo.tr_pallet p
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = p.current_job_id;

DELETE ja
FROM dbo.tr_job_assigness ja
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = ja.job_main_id;

DELETE jm
FROM dbo.tr_job_main jm
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_job_main_id = jm.id;

DELETE ph
FROM dbo.tr_picking_header ph
JOIN dbo.bak_split_picking_job_20261111 b ON b.new_header_id = ph.id;

DROP TABLE dbo.bak_split_picking_job_20261111;

COMMIT TRANSACTION;
GO
