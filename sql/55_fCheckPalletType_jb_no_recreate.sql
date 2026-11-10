-- =============================================================
-- 55_fCheckPalletType_jb_no_recreate.sql  (IRPC_QTRACK)
-- =============================================================
-- On top of 40_fCheckPalletType.sql (identical to live as of 2026-10-01).
--
-- Change (55):
--   1) A JB (J) pallet / bag is never created twice. The lookups for an
--      existing J pallet (ref_pallet + type) and an existing JB bag
--      (qr_text_data) now ignore is_active / status_flag / mode_id, so a
--      pallet or bag that was created before but is now inactive still
--      counts as existing (is_new_* = 'N'). Before, an inactive pallet made
--      42 create a second pallet with no bag, and an inactive bag was never
--      found by fQrCodeToPalletBag, so the scan failed with a vague message.
--      Normal (A) bags keep the old rule of pProcessInsertTrBag.
--   2) New columns so 42 can say why it stops instead of creating:
--        pallet_exist_active  'Y'/'N' (is_active = 'Y' AND status_flag = 'A')
--        bag_exist_active     'Y'/'N' (same rule as fQrCodeToPalletBag)
--        bag_exist_pallet_id  tr_bag.pallet_id of the existing bag
--   3) JB qty must be a whole number: tr_pallet.unit_ratio is INT and the
--      old CAST(qty AS INT) silently dropped the decimals (750.5 -> 750).
--
-- Not changed: pallet running no max 3 digits (LEN > 3 -> 'invalid
-- pallet id.'), pd_group_code 'A' (same as the A pallets made by
-- pServiceMatchBagToPallet).
--
-- Only caller: pProcessInsertJbPalletBag (42 / 56). Deploy 55 -> 56.
-- =============================================================

CREATE OR ALTER FUNCTION [dbo].[fCheckPalletType]
(
    @qr_code VARCHAR(100)
)
RETURNS @result TABLE
(
    cost_center         VARCHAR(20),
    grade               VARCHAR(20),
    lot                 VARCHAR(20),
    pallet_running_no   INT,
    bag_no_int          INT,
    qty_num             DECIMAL(18, 3),
    qr_text_data        VARCHAR(100),
    pallet_type_code    VARCHAR(1),
    pd_group_code       VARCHAR(20),
    unit_ratio          INT,
    unit_pallet         INT,
    pallet_exist_id     BIGINT,
    pallet_exist_no     VARCHAR(50),
    bag_exist_id        BIGINT,
    is_new_pallet       VARCHAR(1),
    is_new_bag          VARCHAR(1),
    status              VARCHAR(20),
    message             VARCHAR(100),
    pallet_exist_active VARCHAR(1),
    bag_exist_active    VARCHAR(1),
    bag_exist_pallet_id BIGINT
)
AS
BEGIN

    DECLARE @cost_center VARCHAR(100);
    DECLARE @grade       VARCHAR(100);
    DECLARE @lot         VARCHAR(100);
    DECLARE @bag_no      VARCHAR(100);
    DECLARE @pallet_id   VARCHAR(100);
    DECLARE @qty         VARCHAR(100);
    DECLARE @jb_type     VARCHAR(100);

    DECLARE @qr          VARCHAR(100) = LTRIM(RTRIM(@qr_code));
    DECLARE @msg         VARCHAR(100) = NULL;

    -- ================================================
    -- Parse QR (positional, order-safe)
    -- ================================================
    DECLARE @rest  VARCHAR(101) = @qr + '|';
    DECLARE @pos   INT;
    DECLARE @idx   INT = 1;
    DECLARE @value VARCHAR(100);

    WHILE @rest IS NOT NULL AND LEN(@rest) > 0 AND @idx <= 7
    BEGIN
        SET @pos   = CHARINDEX('|', @rest);
        SET @value = NULLIF(LTRIM(RTRIM(LEFT(@rest, @pos - 1))), '');

        IF @idx = 1 SET @cost_center = @value;
        IF @idx = 2 SET @grade       = @value;
        IF @idx = 3 SET @lot         = @value;
        IF @idx = 4 SET @bag_no      = @value;
        IF @idx = 5 SET @pallet_id   = @value;
        IF @idx = 6 SET @qty         = @value;
        IF @idx = 7 SET @jb_type     = @value;

        SET @rest = SUBSTRING(@rest, @pos + 1, 100);
        SET @idx += 1;
    END;

    DECLARE @pallet_running_no INT            = TRY_CONVERT(INT, @pallet_id);
    DECLARE @bag_no_int        INT            = TRY_CONVERT(INT, @bag_no);
    DECLARE @qty_num           DECIMAL(18, 3) = TRY_CONVERT(DECIMAL(18, 3), @qty);

    -- ================================================
    -- Validate (first failing rule wins)
    -- ================================================
    IF @qr IS NULL OR @qr = ''
        SET @msg = 'qr code data not found.';
    ELSE IF LEN(ISNULL(@cost_center, '')) > 4
        SET @msg = 'invalid cost center.';
    ELSE IF LEN(ISNULL(@pallet_id, '')) > 3
        SET @msg = 'invalid pallet id.';
    ELSE IF LEN(ISNULL(@bag_no, '')) > 2
        SET @msg = 'invalid bag no.';
    ELSE IF LEN(ISNULL(@grade, '')) > 20
        SET @msg = 'invalid grade.';
    ELSE IF LEN(ISNULL(@lot, '')) > 15
        SET @msg = 'invalid lot.';
    ELSE IF LEN(ISNULL(@qty, '')) > 10
        SET @msg = 'invalid qty.';
    ELSE IF LEN(ISNULL(@jb_type, '')) > 10
        SET @msg = 'invalid jb_type.';
    ELSE IF @cost_center IS NULL
        SET @msg = 'invalid cost center.';
    ELSE IF @grade IS NULL
        SET @msg = 'invalid grade.';
    ELSE IF @lot IS NULL
        SET @msg = 'invalid lot.';
    ELSE IF @bag_no_int IS NULL OR @bag_no_int <= 0
        SET @msg = 'invalid bag no.';
    ELSE IF @pallet_running_no IS NULL OR @pallet_running_no <= 0
        SET @msg = 'invalid pallet id.';
    ELSE IF @qty IS NOT NULL AND @qty_num IS NULL
        SET @msg = 'invalid qty.';
    ELSE IF @jb_type IS NOT NULL AND ISNULL(@qty_num, 0) <= 0
        SET @msg = 'invalid qty.';   -- JB needs qty: it is the pallet's unit_ratio
    ELSE IF @jb_type IS NOT NULL AND @qty_num <> FLOOR(@qty_num)
        SET @msg = 'invalid qty: JB qty must be a whole number.';   -- unit_ratio is INT
    ELSE IF @jb_type NOT LIKE 'JB%'
        SET @msg = 'invalid jb type.'

    IF @msg IS NOT NULL
    BEGIN
        INSERT INTO @result
            (cost_center, grade, lot, pallet_running_no, bag_no_int, qty_num,
             qr_text_data, status, message)
        VALUES
            (LEFT(@cost_center, 20), LEFT(@grade, 20), LEFT(@lot, 20),
             @pallet_running_no, @bag_no_int, @qty_num,
             @qr, 'error', @msg);
        RETURN;
    END;

    -- ================================================
    -- Pallet / bag data for insert
    -- ================================================
    DECLARE @pallet_type_code VARCHAR(1)   = CASE WHEN @jb_type IS NOT NULL THEN 'J' ELSE 'A' END;
    DECLARE @ref_pallet       VARCHAR(100) =
        CONCAT(@cost_center, '|', @grade, '|', @lot, '|', @pallet_running_no);

    DECLARE @unit_ratio          INT;
    DECLARE @unit_pallet         INT;
    DECLARE @pallet_exist_id     BIGINT;
    DECLARE @pallet_exist_no     VARCHAR(50);
    DECLARE @pallet_exist_active VARCHAR(1);
    DECLARE @bag_exist_id        BIGINT;
    DECLARE @bag_exist_active    VARCHAR(1);
    DECLARE @bag_exist_pallet_id BIGINT;

    -- JB : 1 bag per pallet, ratio = qty on the QR (grade kept as-is, e.g. '1105RC/750')
    -- normal : package ratio of the grade
    IF @pallet_type_code = 'J'
    BEGIN
        SET @unit_ratio  = CAST(@qty_num AS INT);   -- whole number, checked above
        SET @unit_pallet = 1;
    END
    ELSE
    BEGIN
        SELECT @unit_ratio  = r.unit_ratio,
               @unit_pallet = r.unit_pallet
        FROM   dbo.ct_grade_package_ratio r
        WHERE  r.grade = @grade;
    END;

    -- existing pallet with this ref + type. J: any status (never create a
    -- second one); A: active only, as before.
    SELECT TOP 1
           @pallet_exist_id     = p.id,
           @pallet_exist_no     = p.pallet_no,
           @pallet_exist_active = CASE WHEN p.is_active = 'Y' AND p.status_flag = 'A' THEN 'Y' ELSE 'N' END
    FROM   dbo.tr_pallet p
    WHERE  p.ref_pallet  = @ref_pallet
      AND  p.pallet_type = @pallet_type_code
      AND  (@pallet_type_code = 'J' OR p.status_flag = 'A')
    ORDER BY p.id;

    -- existing bag with this QR. J: any status / mode; A: same duplicate
    -- rule as pProcessInsertTrBag.
    SELECT TOP 1
           @bag_exist_id        = b.id,
           @bag_exist_pallet_id = b.pallet_id,
           @bag_exist_active    = CASE WHEN b.is_active = 'Y' AND b.status_flag = 'A' THEN 'Y' ELSE 'N' END
    FROM   dbo.tr_bag b
    WHERE  b.qr_text_data = @qr
      AND  (@pallet_type_code = 'J' OR (b.mode_id <> 3 AND b.status_flag = 'A'))
    ORDER BY b.id;

    INSERT INTO @result
    (
        cost_center, grade, lot, pallet_running_no, bag_no_int, qty_num,
        qr_text_data, pallet_type_code, pd_group_code, unit_ratio, unit_pallet,
        pallet_exist_id, pallet_exist_no, bag_exist_id, is_new_pallet, is_new_bag,
        status, message, pallet_exist_active, bag_exist_active, bag_exist_pallet_id
    )
    VALUES
    (
        @cost_center, @grade, @lot, @pallet_running_no, @bag_no_int, @qty_num,
        @qr, @pallet_type_code, 'A', @unit_ratio, @unit_pallet,
        @pallet_exist_id, @pallet_exist_no, @bag_exist_id,
        CASE WHEN @pallet_exist_id IS NULL THEN 'Y' ELSE 'N' END,
        CASE WHEN @bag_exist_id    IS NULL THEN 'Y' ELSE 'N' END,
        'success', 'ok', @pallet_exist_active, @bag_exist_active, @bag_exist_pallet_id
    );

    RETURN;
END
GO
