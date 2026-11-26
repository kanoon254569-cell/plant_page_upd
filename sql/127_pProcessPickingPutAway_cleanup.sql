-- =============================================================
-- 127 : pProcessPickingPutAway -- remove duplicate / unused parts
-- =============================================================
-- Behaviour unchanged. Patches the live definition in place (each old
-- block must be found exactly once, else nothing is changed):
--
--   1. Job check ran twice: a plain tr_job_main existence check
--      (is_active = 'Y' AND status_flag = 'A'), then the same job joined
--      to vPickingForm with looser "IS NULL OR" flags. One check now,
--      with the strict flags of the first (same result; no Picking job
--      has NULL flags).
--   2. Completion test "AND ISNULL(@current_job_status_id, 0) <> 5": a job
--      already at status 5 RETURNs right after the UPDLOCK read at the top
--      of the transaction, so this was always true.
--   3. dbResult1 (iLogistic DO Preparing payload): to_location_cc_desc is
--      never read (JobService.BuildPickingPrepareCompletePayload), and only
--      Rows[0] is used -> TOP (1), column dropped.
--
-- Kept on purpose: the Pre-zone over-qty check (@loc_qty). Most Pre-zone
-- to-locations are added here with qty 0 (check skipped), but some carry a
-- planned qty (3 rows on 10.31.1.74), so the check still runs for those.
--
-- Rollback: 127_rollback_pProcessPickingPutAway_cleanup.sql
-- =============================================================

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @r TABLE (seq INT, old_text NVARCHAR(MAX), new_text NVARCHAR(MAX));

INSERT INTO @r (seq, old_text, new_text) VALUES
(1,
N'    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = ''Y'' AND status_flag = ''A''
    )
    OR NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND (jm.status_flag IS NULL OR jm.status_flag = ''A'')
          AND (jm.is_active IS NULL OR jm.is_active = ''Y'')
          AND f.item_id = @job_item_id
    )',
N'    IF NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND jm.status_flag = ''A''
          AND jm.is_active = ''Y''
          AND f.item_id = @job_item_id
    )'),
(2,
N'IF @complete_qty >= @job_qty AND ISNULL(@current_job_status_id, 0) <> 5',
N'IF @complete_qty >= @job_qty'),
(3,
N'        SELECT
            ss.Shipment_id AS shipment_id,',
N'        SELECT TOP (1)
            ss.Shipment_id AS shipment_id,'),
(4,
N'            fp.to_location_cc_desc,
',
N'');

--  Normalise this file's own line ends to LF, then use the server's: CRLF
--  when the stored definition has CR (10.31.1.75), else LF (10.31.1.74).
UPDATE @r SET old_text = REPLACE(old_text, NCHAR(13), N''), new_text = REPLACE(new_text, NCHAR(13), N'');
IF CHARINDEX(NCHAR(13) + NCHAR(10), @d) > 0
    UPDATE @r SET old_text = REPLACE(old_text, NCHAR(10), NCHAR(13) + NCHAR(10)),
                  new_text = REPLACE(new_text, NCHAR(10), NCHAR(13) + NCHAR(10));

--  Applied = the unused dbResult1 column is gone (line-end independent).
IF CHARINDEX(N'fp.to_location_cc_desc', @d) = 0
BEGIN
    PRINT 'pProcessPickingPutAway: 127 already applied';
    RETURN;
END

DECLARE @bad INT = (
    SELECT TOP (1) seq FROM @r
    WHERE (LEN(@d) - LEN(REPLACE(@d, old_text, N''))) / NULLIF(LEN(old_text), 0) <> 1
    ORDER BY seq
);
IF @bad IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('pProcessPickingPutAway: block ', @bad, ' not found exactly once -- nothing changed');
    THROW 50127, @msg, 1;
END

DECLARE @seq INT = 1;
WHILE @seq <= (SELECT MAX(seq) FROM @r)
BEGIN
    SELECT @d = REPLACE(@d, old_text, new_text) FROM @r WHERE seq = @seq;
    SET @seq += 1;
END

SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
EXEC sys.sp_executesql @d;
GO
