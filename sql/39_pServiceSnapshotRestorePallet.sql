-- =============================================================
-- 39_pServiceSnapshotRestorePallet.sql  (IRPC_QTRACK)
-- =============================================================
-- Puts pallets back to a saved "before" state so the same pallets can be
-- run through a job flow again. Replaces dbo.pServiceResetTestPallet
-- (dropped at the end of this script).
--
-- The old pServiceResetTestPallet blanked every movement column to NULL.
-- This one restores the values captured earlier instead:
--
--   1. EXEC dbo.pServiceSnapshotRestorePallet @action = 'SNAPSHOT', @pallet_ids = '484,485,486'
--        -> saves the pallets' current movement columns into
--           dbo.tr_pallet_reset_snapshot (overwrites a previous snapshot
--           of the same pallet). Run this while the pallets are in the
--           state you want to come back to.
--   2. ...run the test (scan the pallets into a job)...
--   3. EXEC dbo.pServiceSnapshotRestorePallet @pallet_ids = '484,485,486'
--        (@action defaults to 'RESTORE')
--        -> copies the saved values back onto tr_pallet. Pallets that were
--           never snapshotted are left untouched and listed as skipped.
--
-- tr_pallet_test is NOT used as the snapshot store: it is an older copy of
-- pallets 1-67 still read by dbo.fGetPalletNo_test.
--
-- Deliberately NOT touched:
--   * pallet_status_id -- bag-matching status (ct_pallet_status), not a
--     movement state.
--   * tr_bag / tr_pallet_history -- job progress for the job the pallet
--     was scanned into is not rolled back here.
-- =============================================================

IF OBJECT_ID('dbo.tr_pallet_reset_snapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tr_pallet_reset_snapshot (
        pallet_id                       BIGINT        NOT NULL PRIMARY KEY,
        current_job_id                  BIGINT        NULL,
        current_job_item_id             INT           NULL,
        current_location_type           VARCHAR(10)   NULL,
        current_location_id             INT           NULL,
        inbound_to_wh_id                INT           NULL,
        inbound_to_wh_user_id           INT           NULL,
        inbound_to_wh_datetime          DATETIME      NULL,
        outbound_to_plant_id            INT           NULL,
        outbound_to_plant_user_id       INT           NULL,
        outbound_to_plant_datetime      DATETIME      NULL,
        outbound_to_pre_zone_id         INT           NULL,
        outbound_to_pre_zone_user_id    INT           NULL,
        outbound_to_pre_zone_datetime   DATETIME      NULL,
        outbound_to_dock_id             INT           NULL,
        outbound_to_dock_user_id        INT           NULL,
        outbound_to_dock_datetime       DATETIME      NULL,
        outbound_to_special_location_id INT           NULL,
        outbound_to_special_user_id     INT           NULL,
        outbound_to_special_datetime    DATETIME      NULL,
        outbound_to_vehicle_id          INT           NULL,
        outbound_to_vehicle_user_id     INT           NULL,
        outbound_to_vehicle_datetime    DATETIME      NULL,
        is_active                       VARCHAR(1)    NULL,
        status_flag                     VARCHAR(1)    NULL,
        snapshot_user_id                INT           NOT NULL DEFAULT (0),
        snapshot_datetime               DATETIME      NOT NULL DEFAULT (GETDATE())
    );
END
GO

CREATE OR ALTER PROC [dbo].[pServiceSnapshotRestorePallet]
    @pallet_ids NVARCHAR(MAX) = N'484,485,486',
    @action     VARCHAR(10)   = 'RESTORE',   -- 'SNAPSHOT' | 'RESTORE'
    @user_id    INT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, 'RESTORE'))));

    IF @action NOT IN ('SNAPSHOT', 'RESTORE')
    BEGIN
        SELECT 'error' AS status, '@action must be SNAPSHOT or RESTORE.' AS message;
        RETURN;
    END

    IF OBJECT_ID('tempdb..#pallet_ids') IS NOT NULL
        DROP TABLE #pallet_ids;

    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) AS id
    INTO #pallet_ids
    FROM STRING_SPLIT(ISNULL(@pallet_ids, N''), N',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM #pallet_ids)
    BEGIN
        SELECT 'error' AS status, 'No valid pallet id in @pallet_ids.' AS message;
        RETURN;
    END

    DECLARE @affected INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        IF @action = 'SNAPSHOT'
        BEGIN
            MERGE dbo.tr_pallet_reset_snapshot AS target
            USING (
                SELECT p.*
                FROM dbo.tr_pallet p
                INNER JOIN #pallet_ids ids ON ids.id = p.id
            ) AS src
                ON target.pallet_id = src.id
            WHEN MATCHED THEN
                UPDATE SET
                    current_job_id                  = src.current_job_id,
                    current_job_item_id             = src.current_job_item_id,
                    current_location_type           = src.current_location_type,
                    current_location_id             = src.current_location_id,
                    inbound_to_wh_id                = src.inbound_to_wh_id,
                    inbound_to_wh_user_id           = src.inbound_to_wh_user_id,
                    inbound_to_wh_datetime          = src.inbound_to_wh_datetime,
                    outbound_to_plant_id            = src.outbound_to_plant_id,
                    outbound_to_plant_user_id       = src.outbound_to_plant_user_id,
                    outbound_to_plant_datetime      = src.outbound_to_plant_datetime,
                    outbound_to_pre_zone_id         = src.outbound_to_pre_zone_id,
                    outbound_to_pre_zone_user_id    = src.outbound_to_pre_zone_user_id,
                    outbound_to_pre_zone_datetime   = src.outbound_to_pre_zone_datetime,
                    outbound_to_dock_id             = src.outbound_to_dock_id,
                    outbound_to_dock_user_id        = src.outbound_to_dock_user_id,
                    outbound_to_dock_datetime       = src.outbound_to_dock_datetime,
                    outbound_to_special_location_id = src.outbound_to_special_location_id,
                    outbound_to_special_user_id     = src.outbound_to_special_user_id,
                    outbound_to_special_datetime    = src.outbound_to_special_datetime,
                    outbound_to_vehicle_id          = src.outbound_to_vehicle_id,
                    outbound_to_vehicle_user_id     = src.outbound_to_vehicle_user_id,
                    outbound_to_vehicle_datetime    = src.outbound_to_vehicle_datetime,
                    is_active                       = src.is_active,
                    status_flag                     = src.status_flag,
                    snapshot_user_id                = ISNULL(@user_id, 0),
                    snapshot_datetime               = GETDATE()
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    pallet_id, current_job_id, current_job_item_id, current_location_type, current_location_id,
                    inbound_to_wh_id, inbound_to_wh_user_id, inbound_to_wh_datetime,
                    outbound_to_plant_id, outbound_to_plant_user_id, outbound_to_plant_datetime,
                    outbound_to_pre_zone_id, outbound_to_pre_zone_user_id, outbound_to_pre_zone_datetime,
                    outbound_to_dock_id, outbound_to_dock_user_id, outbound_to_dock_datetime,
                    outbound_to_special_location_id, outbound_to_special_user_id, outbound_to_special_datetime,
                    outbound_to_vehicle_id, outbound_to_vehicle_user_id, outbound_to_vehicle_datetime,
                    is_active, status_flag, snapshot_user_id, snapshot_datetime
                )
                VALUES (
                    src.id, src.current_job_id, src.current_job_item_id, src.current_location_type, src.current_location_id,
                    src.inbound_to_wh_id, src.inbound_to_wh_user_id, src.inbound_to_wh_datetime,
                    src.outbound_to_plant_id, src.outbound_to_plant_user_id, src.outbound_to_plant_datetime,
                    src.outbound_to_pre_zone_id, src.outbound_to_pre_zone_user_id, src.outbound_to_pre_zone_datetime,
                    src.outbound_to_dock_id, src.outbound_to_dock_user_id, src.outbound_to_dock_datetime,
                    src.outbound_to_special_location_id, src.outbound_to_special_user_id, src.outbound_to_special_datetime,
                    src.outbound_to_vehicle_id, src.outbound_to_vehicle_user_id, src.outbound_to_vehicle_datetime,
                    src.is_active, src.status_flag, ISNULL(@user_id, 0), GETDATE()
                );

            SET @affected = @@ROWCOUNT;
        END
        ELSE
        BEGIN
            UPDATE p
            SET current_job_id                  = s.current_job_id,
                current_job_item_id             = s.current_job_item_id,
                current_location_type           = s.current_location_type,
                current_location_id             = s.current_location_id,
                inbound_to_wh_id                = s.inbound_to_wh_id,
                inbound_to_wh_user_id           = s.inbound_to_wh_user_id,
                inbound_to_wh_datetime          = s.inbound_to_wh_datetime,
                outbound_to_plant_id            = s.outbound_to_plant_id,
                outbound_to_plant_user_id       = s.outbound_to_plant_user_id,
                outbound_to_plant_datetime      = s.outbound_to_plant_datetime,
                outbound_to_pre_zone_id         = s.outbound_to_pre_zone_id,
                outbound_to_pre_zone_user_id    = s.outbound_to_pre_zone_user_id,
                outbound_to_pre_zone_datetime   = s.outbound_to_pre_zone_datetime,
                outbound_to_dock_id             = s.outbound_to_dock_id,
                outbound_to_dock_user_id        = s.outbound_to_dock_user_id,
                outbound_to_dock_datetime       = s.outbound_to_dock_datetime,
                outbound_to_special_location_id = s.outbound_to_special_location_id,
                outbound_to_special_user_id     = s.outbound_to_special_user_id,
                outbound_to_special_datetime    = s.outbound_to_special_datetime,
                outbound_to_vehicle_id          = s.outbound_to_vehicle_id,
                outbound_to_vehicle_user_id     = s.outbound_to_vehicle_user_id,
                outbound_to_vehicle_datetime    = s.outbound_to_vehicle_datetime,
                is_active                       = ISNULL(s.is_active, p.is_active),
                status_flag                     = ISNULL(s.status_flag, p.status_flag),
                update_user_id                  = ISNULL(@user_id, 0),
                update_datetime                 = GETDATE()
            FROM dbo.tr_pallet p
            INNER JOIN #pallet_ids ids ON ids.id = p.id
            INNER JOIN dbo.tr_pallet_reset_snapshot s ON s.pallet_id = p.id;

            SET @affected = @@ROWCOUNT;
        END

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
        RETURN;
    END CATCH

    SELECT 'success' AS status,
           CONCAT(IIF(@action = 'SNAPSHOT', 'Snapshot ', 'Restored '), @affected, ' pallet(s).') AS message;

    IF OBJECT_ID('tempdb..#data_bags') IS NOT NULL
        DROP TABLE #data_bags;

    SELECT
        b.pallet_id,
        b.cost_center,
        b.grade,
        b.lot,
        COUNT(*) AS total_bags
    INTO #data_bags
    FROM dbo.tr_bag b
    INNER JOIN #pallet_ids ids ON ids.id = b.pallet_id
    WHERE b.is_active = 'Y'
      AND b.status_flag = 'A'
    GROUP BY b.pallet_id, b.cost_center, b.grade, b.lot;

    --  One row per requested id: skipped = no such pallet, or (RESTORE)
    --  no snapshot to restore from.
    SELECT
        ids.id,
        p.pallet_no,
        p.current_job_id,
        p.current_location_type,
        p.current_location_id,
        s.snapshot_datetime,
        CASE
            WHEN p.id IS NULL THEN 'skipped: pallet not found'
            WHEN @action = 'RESTORE' AND s.pallet_id IS NULL THEN 'skipped: no snapshot'
            ELSE 'ok'
        END AS result,
        db.cost_center,
        db.grade,
        db.lot,
        db.total_bags,
        p.unit_ratio * db.total_bags AS total_qty
    FROM #pallet_ids ids
    LEFT JOIN dbo.tr_pallet p ON p.id = ids.id
    LEFT JOIN dbo.tr_pallet_reset_snapshot s ON s.pallet_id = ids.id
    LEFT JOIN #data_bags db ON db.pallet_id = ids.id
    ORDER BY ids.id;
END
GO

-- Old name, replaced by pServiceSnapshotRestorePallet above.
DROP PROC IF EXISTS dbo.pServiceResetTestPallet;
GO
