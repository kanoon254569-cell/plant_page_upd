/* =====================================================================
   110_rollback_sp_PalletAdjustment_GetMissingSlots.sql  (IRPC_QTRACK)
   ย้อน 110_ : sp_PalletAdjustment_GetMissingSlots กลับเป็น definition ของ 98_ (ใช้ fParseBagQr)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.sp_PalletAdjustment_GetMissingSlots
    @PalletId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ref VARCHAR(100), @nl INT, @p1 INT, @p2 INT, @p3 INT, @p4 INT,
            @cc VARCHAR(20), @grade VARCHAR(30), @lot VARCHAR(20), @o INT, @fmt TINYINT, @rjc INT;

    CREATE TABLE #m (
        qr_text_data VARCHAR(100), cost_center VARCHAR(20), grade VARCHAR(30), lot VARCHAR(20),
        qr_format TINYINT, qr_ton INT, qr_bag_no INT, planned_pos INT);

    SELECT @ref = ref_pallet, @nl = unit_pallet
    FROM   dbo.tr_pallet
    WHERE  id = @PalletId AND status_flag = 'A' AND pallet_type = 'A';

    -- ref_pallet = cc|grade|lot|<ordinal> หรือ cc|grade|lot|<ordinal>|F6
    SET @p1 = CHARINDEX('|', @ref);
    SET @p2 = CASE WHEN @p1 > 0 THEN CHARINDEX('|', @ref, @p1 + 1) ELSE 0 END;
    SET @p3 = CASE WHEN @p2 > 0 THEN CHARINDEX('|', @ref, @p2 + 1) ELSE 0 END;
    SET @p4 = CASE WHEN @p3 > 0 THEN CHARINDEX('|', @ref, @p3 + 1) ELSE 0 END;
    IF @p3 > 0
    BEGIN
        SET @cc    = SUBSTRING(@ref, 1, @p1 - 1);
        SET @grade = SUBSTRING(@ref, @p1 + 1, @p2 - @p1 - 1);
        SET @lot   = SUBSTRING(@ref, @p2 + 1, @p3 - @p2 - 1);
        SET @o     = TRY_CONVERT(INT, CASE WHEN @p4 > 0 THEN SUBSTRING(@ref, @p3 + 1, @p4 - @p3 - 1)
                                           ELSE SUBSTRING(@ref, @p3 + 1, LEN(@ref) - @p3) END);
        SET @fmt   = CASE WHEN @p4 = 0 THEN 5
                          WHEN SUBSTRING(@ref, @p4 + 1, LEN(@ref) - @p4) = 'F6' THEN 6 END;
    END

    IF @o > 0 AND @fmt IS NOT NULL AND @nl > 0
    BEGIN
        CREATE TABLE #g (pos INT NOT NULL, is_active VARCHAR(1), bag_status_id INT);
        INSERT INTO #g (pos, is_active, bag_status_id)
        SELECT (q.pallet_running_no - 1) * @nl + q.bag_no, b.is_active, b.bag_status_id
        FROM   dbo.tr_bag b
        CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.grade = @grade AND b.cost_center = @cc AND b.lot = @lot
          AND  b.status_flag = 'A' AND b.is_active IN ('Y', 'R')
          AND  q.qr_format = @fmt
          AND  q.pallet_running_no > 0 AND q.bag_no BETWEEN 1 AND @nl
        UNION ALL
        -- ถุงจัดการด้วยมือ ใช้กลุ่มตาม QR (คอลัมน์อาจถูก Edit Bag แก้ไปแล้ว -- เหมือน 13_)
        SELECT (q.pallet_running_no - 1) * @nl + q.bag_no, b.is_active, b.bag_status_id
        FROM   dbo.tr_bag b
        CROSS APPLY dbo.fParseBagQr(b.qr_text_data) q
        WHERE  b.bag_status_id IN (3, 6) AND b.is_active IN ('Y', 'R') AND b.status_flag = 'A'
          AND  q.cost_center = @cc AND q.grade = @grade AND q.lot = @lot
          AND  q.qr_format = @fmt
          AND  q.pallet_running_no > 0 AND q.bag_no BETWEEN 1 AND @nl;

        CREATE TABLE #rj (pos INT PRIMARY KEY);
        INSERT INTO #rj (pos)
        SELECT DISTINCT r.pos
        FROM   #g r
        WHERE  r.is_active = 'R' AND ISNULL(r.bag_status_id, 0) <> 6
          AND  NOT EXISTS (SELECT 1 FROM #g h
                           WHERE h.pos = r.pos AND (h.is_active = 'Y' OR h.bag_status_id = 6));
        SET @rjc = (SELECT COUNT(*) FROM #rj);

        -- ตำแหน่งที่อาจตกบนพาเลทนี้ : (o-1)*nl+1 .. o*nl + จำนวน reject (reject ดึงตำแหน่งถัดไปขึ้นมา)
        ;WITH n AS (
            SELECT TOP (@nl + @rjc)
                   (@o - 1) * @nl + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pos
            FROM   sys.all_columns a CROSS JOIN sys.all_columns b
        )
        INSERT INTO #m (qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos)
        SELECT CONCAT(@cc, '|', @grade, '|', @lot, '|',
                      RIGHT(CONCAT('0', m.bag_no), CASE WHEN m.bag_no > 9 THEN LEN(m.bag_no) ELSE 2 END), '|',
                      RIGHT(CONCAT('00', m.ton), CASE WHEN m.ton > 99 THEN LEN(m.ton) ELSE 3 END),
                      CASE WHEN @fmt = 6 THEN '|000000' ELSE '' END),
               @cc, @grade, @lot, @fmt, m.ton, m.bag_no, n.pos
        FROM   n
        CROSS APPLY (SELECT (n.pos - 1) / @nl + 1                                    AS ton,
                            (n.pos - 1) % @nl + 1                                    AS bag_no,
                            n.pos - (SELECT COUNT(*) FROM #rj r WHERE r.pos < n.pos) AS good_pos) m
        WHERE  NOT EXISTS (SELECT 1 FROM #g g WHERE g.pos = n.pos)
          AND  (m.good_pos - 1) / @nl + 1 = @o;
    END

    SELECT qr_text_data, cost_center, grade, lot, qr_format, qr_ton, qr_bag_no, planned_pos
    FROM   #m
    ORDER BY planned_pos;
END
GO
