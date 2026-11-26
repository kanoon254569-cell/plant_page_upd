-- =============================================================
-- 130 : Picking Pre-zone to-location gets a planned qty
-- =============================================================
-- pProcessPickingPutAway adds the Pre-zone to-location on the first put
-- (nothing is picked at approve) with qty 0, so the row only ever had
-- actual_qty: job-detail's PUT card had no target, the API returned no
-- qty, and the Pre-zone over-qty check (@loc_qty) never ran.
--
-- Now the row is created with the item's delivery qty (vPickingForm.qty)
-- -- minus what other Pre-zone rows of the same item already plan, when
-- the item is put into a second Pre-zone location (never below 0).
-- Effects (accepted):
--   * the over-qty check now runs on Pre-zone puts: putting more kg
--     than the item's qty errors "จำนวนเกินที่กำหนด ..."
--   * the API now returns qty for the row, so the forklift PWA uses it
--     as the put-away weight limit
--
--   1. pProcessPickingPutAway: INSERT uses the planned qty (patched in
--      place on one unique block of the live definition; works whether the
--      server stored the proc with LF (10.31.1.74) or CRLF (10.31.1.75)
--      line ends)
--   2. Backfill: existing Picking Pre-zone rows with qty 0 get the same
--      planned qty
--
-- Rollback: 130_rollback_pProcessPickingPutAway_prezone_qty.sql
-- (puts the INSERT back to 0; backfilled rows keep their qty)
-- =============================================================

-- 1. ----------------------------------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @old NVARCHAR(MAX) = N'                @job_main_id, @job_item_id, @location_id, ''PRE-ZONE'',
                0, NULL, @user_id, GETDATE(), @user_id, GETDATE()';
DECLARE @new NVARCHAR(MAX) = N'                @job_main_id, @job_item_id, @location_id, ''PRE-ZONE'',
                --  sql/130: planned qty = item delivery qty - other Pre-zone rows'' qty
                (SELECT CASE WHEN ISNULL(q.item_qty, 0) - ISNULL(o.planned, 0) > 0
                             THEN ISNULL(q.item_qty, 0) - ISNULL(o.planned, 0) ELSE 0 END
                 FROM (SELECT CAST(MAX(f.qty) AS INT) AS item_qty
                       FROM dbo.tr_job_main jm
                       INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
                       WHERE jm.id = @job_main_id AND f.item_id = @job_item_id) q
                 CROSS JOIN (SELECT SUM(ISNULL(tl.qty, 0)) AS planned
                             FROM dbo.tr_job_to_location tl
                             WHERE tl.job_main_id = @job_main_id
                               AND tl.interface_job_item_id = @job_item_id
                               AND tl.to_location_type = ''PRE-ZONE''
                               AND tl.is_active = ''Y''
                               AND tl.status_flag = ''A'') o),
                NULL, @user_id, GETDATE(), @user_id, GETDATE()';

--  Normalise this file's own line ends to LF, then use the server's: CRLF
--  when the stored definition has CR characters, else LF.
SET @old = REPLACE(@old, NCHAR(13), N'');
SET @new = REPLACE(@new, NCHAR(13), N'');
IF CHARINDEX(NCHAR(13) + NCHAR(10), @d) > 0
BEGIN
    SET @old = REPLACE(@old, NCHAR(10), NCHAR(13) + NCHAR(10));
    SET @new = REPLACE(@new, NCHAR(10), NCHAR(13) + NCHAR(10));
END

IF CHARINDEX(N'sql/130', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50130, 'pProcessPickingPutAway: Pre-zone INSERT block not found exactly once -- nothing changed', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO

-- 2. ----------------------------------------------------------
--  One Pre-zone row per item in practice; when an item has several, the
--  lowest id gets the item qty and the rest stay 0 (same as new puts).
;WITH pz AS (
    SELECT tl.id,
           CAST(f.qty AS INT) AS item_qty,
           ROW_NUMBER() OVER (PARTITION BY tl.job_main_id, tl.interface_job_item_id ORDER BY tl.id) AS rn
    FROM dbo.tr_job_to_location tl
    INNER JOIN dbo.tr_job_main jm
        ON jm.id = tl.job_main_id
       AND jm.job_type_id = 4
    CROSS APPLY (
        SELECT MAX(pf.qty) AS qty
        FROM dbo.vPickingForm pf
        WHERE pf.header_id = jm.interface_job_id
          AND pf.item_id = tl.interface_job_item_id
    ) f
    WHERE tl.to_location_type = 'PRE-ZONE'
      AND tl.is_active = 'Y'
      AND tl.status_flag = 'A'
      AND ISNULL(tl.qty, 0) = 0
      AND NOT EXISTS (
          SELECT 1 FROM dbo.tr_job_to_location o
          WHERE o.job_main_id = tl.job_main_id
            AND o.interface_job_item_id = tl.interface_job_item_id
            AND o.to_location_type = 'PRE-ZONE'
            AND o.is_active = 'Y'
            AND o.status_flag = 'A'
            AND ISNULL(o.qty, 0) <> 0)
)
UPDATE tl
SET tl.qty = pz.item_qty,
    tl.update_datetime = GETDATE()
FROM dbo.tr_job_to_location tl
INNER JOIN pz ON pz.id = tl.id
WHERE pz.rn = 1
  AND ISNULL(pz.item_qty, 0) > 0;
GO
