-- =============================================================
-- 61_e_transfer_item_keep_total_pallet.sql  (IRPC_E_TRANSFER, run from IRPC_QTRACK)
-- =============================================================
-- Bug: saving a TS / RC form in WMS Plus after the QTrack approve wiped
-- total_pallet (0 or NULL). pProcessInsertUpdate_tr_transfer_slip_item /
-- _tr_receive_form_item always write total_pallet = @pallet_qty_item, and
-- that value is only meaningful in manual mode (q_track_mode = 'M', the
-- pallet count typed on the form). In auto mode the web sends back the
-- value it loaded (0 when the form was opened before approve) and the
-- WMS Plus API does not pass @pallet_qty_item for RC at all (NULL).
-- Seen on TS item 796 (job 695): approved 23:34, saved in WMS Plus 23:35
-- -> total_pallet 0.
--
-- Change: take @pallet_qty_item only when the header is in manual mode;
-- otherwise keep the stored value on update and leave it NULL on insert,
-- for the QTrack approve to fill (TotalPalletService). The QTrack side
-- (pProcessGetJobItemsForTotalPallet) skips manual-mode TS / RC items, so
-- the typed pallet count is never overwritten.
--
-- Patched from the live definition with REPLACE (same way as sql/47):
-- each piece must be found exactly once, else that object is not changed.
-- Idempotent: skipped when already patched.
-- =============================================================

-- -------------------------------------------------------------
-- pProcessInsertUpdate_tr_transfer_slip_item
-- -------------------------------------------------------------
DECLARE @d NVARCHAR(MAX) = (
    SELECT m.definition FROM IRPC_E_TRANSFER.sys.sql_modules m
    WHERE m.object_id = OBJECT_ID('IRPC_E_TRANSFER.dbo.pProcessInsertUpdate_tr_transfer_slip_item'));
DECLARE @nl NVARCHAR(2) = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%@q_track_mode%'
    PRINT 'pProcessInsertUpdate_tr_transfer_slip_item already patched - skipped.';
ELSE
BEGIN
    DECLARE @o1 NVARCHAR(400) = N'declare @id int = null , @system_no varchar(15)';
    DECLARE @n1 NVARCHAR(400) = @o1 + @nl
        + N'	declare @q_track_mode varchar(5) = (select top 1 h.q_track_mode from tr_transfer_slip_header h where h.id = @header_id)';
    DECLARE @o2 NVARCHAR(400) = N'''A'',@pallet_qty_item)';
    DECLARE @n2 NVARCHAR(400) = N'''A'',case when @q_track_mode = ''M'' then @pallet_qty_item end)';
    DECLARE @o3 NVARCHAR(400) = N'[total_pallet] = @pallet_qty_item';
    DECLARE @n3 NVARCHAR(400) = N'[total_pallet] = case when @q_track_mode = ''M'' then @pallet_qty_item else [total_pallet] end';

    IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
      OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
      OR (LEN(@d) - LEN(REPLACE(@d, @o3, N''))) / LEN(@o3) <> 1
        RAISERROR('pProcessInsertUpdate_tr_transfer_slip_item: text to patch not found exactly once - not patched.', 16, 1);
    ELSE
    BEGIN
        SET @d = REPLACE(@d, @o1, @n1);
        SET @d = REPLACE(@d, @o2, @n2);
        SET @d = REPLACE(@d, @o3, @n3);
        --  'CREATE PROCEDURE', not 'CREATE': the header comment has "Create date"
        --  and CHARINDEX is case-insensitive here
        SET @d = STUFF(@d, CHARINDEX(N'CREATE PROCEDURE', @d), LEN(N'CREATE'), N'ALTER');
        EXEC IRPC_E_TRANSFER.sys.sp_executesql @d;
        IF @@ERROR = 0 PRINT 'pProcessInsertUpdate_tr_transfer_slip_item patched.';
    END
END
GO

-- -------------------------------------------------------------
-- pProcessInsertUpdate_tr_receive_form_item
-- -------------------------------------------------------------
DECLARE @d NVARCHAR(MAX) = (
    SELECT m.definition FROM IRPC_E_TRANSFER.sys.sql_modules m
    WHERE m.object_id = OBJECT_ID('IRPC_E_TRANSFER.dbo.pProcessInsertUpdate_tr_receive_form_item'));
DECLARE @nl NVARCHAR(2) = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%@q_track_mode%'
    PRINT 'pProcessInsertUpdate_tr_receive_form_item already patched - skipped.';
ELSE
BEGIN
    DECLARE @o1 NVARCHAR(400) = N'declare @id int = null , @system_no varchar(15)';
    DECLARE @n1 NVARCHAR(400) = @o1 + @nl
        + N'	declare @q_track_mode varchar(5) = (select top 1 h.q_track_mode from tr_receive_form_header h where h.id = @header_id)';
    DECLARE @o2 NVARCHAR(400) = N'''A'',@process_order,@pallet_qty_item)';
    DECLARE @n2 NVARCHAR(400) = N'''A'',@process_order,case when @q_track_mode = ''M'' then @pallet_qty_item end)';
    DECLARE @o3 NVARCHAR(400) = N'total_pallet = @pallet_qty_item';
    DECLARE @n3 NVARCHAR(400) = N'total_pallet = case when @q_track_mode = ''M'' then @pallet_qty_item else total_pallet end';

    IF   (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
      OR (LEN(@d) - LEN(REPLACE(@d, @o2, N''))) / LEN(@o2) <> 1
      OR (LEN(@d) - LEN(REPLACE(@d, @o3, N''))) / LEN(@o3) <> 1
        RAISERROR('pProcessInsertUpdate_tr_receive_form_item: text to patch not found exactly once - not patched.', 16, 1);
    ELSE
    BEGIN
        SET @d = REPLACE(@d, @o1, @n1);
        SET @d = REPLACE(@d, @o2, @n2);
        SET @d = REPLACE(@d, @o3, @n3);
        SET @d = STUFF(@d, CHARINDEX(N'CREATE PROCEDURE', @d), LEN(N'CREATE'), N'ALTER');
        EXEC IRPC_E_TRANSFER.sys.sp_executesql @d;
        IF @@ERROR = 0 PRINT 'pProcessInsertUpdate_tr_receive_form_item patched.';
    END
END
GO
