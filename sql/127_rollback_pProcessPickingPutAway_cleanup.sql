-- =============================================================
-- 127 rollback : put back the blocks 127_pProcessPickingPutAway_cleanup.sql
-- removed (reverse REPLACE on the live definition).
-- =============================================================

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @r TABLE (seq INT, old_text NVARCHAR(MAX), new_text NVARCHAR(MAX));

INSERT INTO @r (seq, old_text, new_text) VALUES
(1,
N'    IF NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND jm.status_flag = ''A''
          AND jm.is_active = ''Y''
          AND f.item_id = @job_item_id
    )',
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
    )'),
(2,
N'IF @complete_qty >= @job_qty
',
N'IF @complete_qty >= @job_qty AND ISNULL(@current_job_status_id, 0) <> 5
'),
(3,
N'        SELECT TOP (1)
            ss.Shipment_id AS shipment_id,',
N'        SELECT
            ss.Shipment_id AS shipment_id,'),
(4,
N'            fp.to_location_id,
            fp.code_pallet_id,',
N'            fp.to_location_id,
            fp.to_location_cc_desc,
            fp.code_pallet_id,');

--  LF from this file, then the server's line ends (CRLF on 10.31.1.75).
UPDATE @r SET old_text = REPLACE(old_text, NCHAR(13), N''), new_text = REPLACE(new_text, NCHAR(13), N'');
IF CHARINDEX(NCHAR(13) + NCHAR(10), @d) > 0
    UPDATE @r SET old_text = REPLACE(old_text, NCHAR(10), NCHAR(13) + NCHAR(10)),
                  new_text = REPLACE(new_text, NCHAR(10), NCHAR(13) + NCHAR(10));

--  Not applied = the dbResult1 column is still there (line-end independent).
IF CHARINDEX(N'fp.to_location_cc_desc', @d) > 0
BEGIN
    PRINT 'pProcessPickingPutAway: 127 not applied, nothing to roll back';
    RETURN;
END

DECLARE @bad INT = (
    SELECT TOP (1) seq FROM @r
    WHERE (LEN(@d) - LEN(REPLACE(@d, old_text, N''))) / NULLIF(LEN(old_text), 0) <> 1
    ORDER BY seq
);
IF @bad IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('pProcessPickingPutAway rollback: block ', @bad, ' not found exactly once -- nothing changed');
    THROW 50128, @msg, 1;
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
