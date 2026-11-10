-- Deploy IRPC_QTRACK: 10.31.1.74 -> 10.31.1.75
-- Generated 2026-10-28 from 10.31.1.74
-- Only objects changed since 2026-10-27 where .74 is newer than .75.
-- Objects where .75 is newer are not in this script.

USE IRPC_QTRACK;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

-- ===== dbo.vPalletBagGroup (new indexed view, used WITH (NOEXPAND) by pProcessGetPalletList) =====
IF OBJECT_ID(N'dbo.vPalletBagGroup', N'V') IS NULL
    EXEC (N'CREATE VIEW dbo.vPalletBagGroup AS SELECT 1 AS x');
GO
ALTER VIEW dbo.vPalletBagGroup
WITH SCHEMABINDING
AS
SELECT
	b.pallet_id,
	b.grade,
	b.lot,
	b.pallet_running_no,
	COUNT_BIG(*) AS bag_rows
FROM dbo.tr_bag b
WHERE b.is_active = 'Y'
	AND b.status_flag = 'A'
	AND b.pallet_id IS NOT NULL
GROUP BY b.pallet_id, b.grade, b.lot, b.pallet_running_no;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UCX_vPalletBagGroup' AND object_id = OBJECT_ID(N'dbo.vPalletBagGroup'))
    CREATE UNIQUE CLUSTERED INDEX UCX_vPalletBagGroup
        ON dbo.vPalletBagGroup (pallet_id, grade, lot, pallet_running_no);
GO

-- ===== dbo.pProcessGetPalletList =====
-- =============================================================
-- pProcessGetPalletList: also return ton_no
-- =============================================================
-- Boardman Pallet Management shows a Ton No. column. The real Ton No.
-- is tr_bag.ton_no; it is not the same as pallet_running_no (returned
-- as pallet_id) for 29,824 active bags on 10.31.1.74 (2026-10-28).
-- ton_no = MIN(tr_bag.ton_no) over the pallet's active bags. Only 4
-- pallets had more than one ton_no (2026-10-28).
--
-- Only step 3c (#ton) and the ton_no output column are new; the rest
-- is the same as sql/pProcessGetPalletList_use_vPalletBagGroup.sql.
--
-- Rollback: run sql/backup_20261028_pProcessGetPalletList.sql
-- =============================================================

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetPalletList]
	@id INT = NULL,
	@pallet_id INT = NULL,
	@pallet_no NVARCHAR(100) = NULL,
	@grade NVARCHAR(255) = NULL,
	@lot NVARCHAR(255) = NULL,
	@location_type NVARCHAR(255) = NULL,
	@location_id INT = NULL,
	@pallet_type_id INT = NULL,
	@pallet_location_id INT = NULL,
	@qr_code VARCHAR(100) = NULL,
	@page INT = 1,
	@page_size INT = 20
AS
BEGIN
	SET NOCOUNT ON

	-- Resolve @qr_code (scanned QR text) to a pallet id via fQrCodeToPalletBag
	-- (tr_bag.qr_text_data first, then tr_pallet.pallet_no). @id still wins.
	DECLARE @qr_resolved_id INT = NULL

	IF @qr_code IS NOT NULL
	BEGIN
		SELECT @qr_resolved_id = pallet_id FROM dbo.fQrCodeToPalletBag(@qr_code)
	END

	DECLARE @find_id INT = COALESCE(@id, @qr_resolved_id)

	-- 1. total_count -- one row per (pallet, grade, lot) that matches the
	--    filters. A pallet can hold bags with several pallet_running_no
	--    values; they are one row (see
	--    sql/pProcessGetPalletList_one_row_per_pallet.sql).
	DECLARE @total_count INT

	SELECT @total_count = COUNT(*)
	FROM (
		SELECT 1 AS x
		FROM dbo.tr_pallet tp
		INNER JOIN dbo.vPalletBagGroup v WITH (NOEXPAND)
			ON v.pallet_id = tp.id
		WHERE tp.is_active = 'Y'
			AND tp.status_flag = 'A'
			AND (@find_id IS NULL OR tp.id = @find_id)
			AND (@pallet_no IS NULL OR tp.pallet_no = @pallet_no)
			AND (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
			AND (@location_id IS NULL OR tp.current_location_id = @location_id)
			AND (@grade IS NULL OR v.grade LIKE '%' + @grade + '%')
			AND (@lot IS NULL OR v.lot LIKE '%' + @lot + '%')
			AND (@pallet_id IS NULL OR v.pallet_running_no = @pallet_id)
		GROUP BY v.pallet_id, v.grade, v.lot
	) c
	OPTION (RECOMPILE, MERGE JOIN, ORDER GROUP)

	SELECT 'success' AS status,
		   CASE WHEN @total_count > 0 THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- 2. One page of rows, in the view's clustered index order.
	IF OBJECT_ID('tempdb..#page') IS NOT NULL
		DROP TABLE #page

	SELECT
		v.pallet_id AS pallet_id,
		MIN(v.pallet_running_no) AS pallet_running,
		v.grade AS grade,
		v.lot AS lot
	INTO #page
	FROM dbo.tr_pallet tp
	INNER JOIN dbo.vPalletBagGroup v WITH (NOEXPAND)
		ON v.pallet_id = tp.id
	WHERE tp.is_active = 'Y'
		AND tp.status_flag = 'A'
		AND (@find_id IS NULL OR tp.id = @find_id)
		AND (@pallet_no IS NULL OR tp.pallet_no = @pallet_no)
		AND (@location_type IS NULL OR COALESCE(tp.current_location_type, 'BG-PLANT') = @location_type)
		AND (@location_id IS NULL OR tp.current_location_id = @location_id)
		AND (@grade IS NULL OR v.grade LIKE '%' + @grade + '%')
		AND (@lot IS NULL OR v.lot LIKE '%' + @lot + '%')
		AND (@pallet_id IS NULL OR v.pallet_running_no = @pallet_id)
	GROUP BY v.pallet_id, v.grade, v.lot
	ORDER BY v.pallet_id, v.grade, v.lot
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY
	OPTION (RECOMPILE)

	-- 3a. bag_count per pallet -- distinct (running no, bag no, grade, lot)
	--     among the bags that match the grade/lot/running filters.
	IF OBJECT_ID('tempdb..#bag_count') IS NOT NULL
		DROP TABLE #bag_count

	SELECT
		d.pallet_id,
		COUNT(*) AS bag_count
	INTO #bag_count
	FROM (
		SELECT DISTINCT b.pallet_id, b.pallet_running_no, b.bag_no, b.grade, b.lot
		FROM dbo.tr_bag b
		WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
			AND b.is_active = 'Y'
			AND b.status_flag = 'A'
			AND (@grade IS NULL OR b.grade LIKE '%' + @grade + '%')
			AND (@lot IS NULL OR b.lot LIKE '%' + @lot + '%')
			AND (@pallet_id IS NULL OR b.pallet_running_no = @pallet_id)
	) d
	GROUP BY d.pallet_id

	-- 3b. All active bags per pallet (what fGetPalletQty counts).
	IF OBJECT_ID('tempdb..#qty_bag_count') IS NOT NULL
		DROP TABLE #qty_bag_count

	SELECT
		b.pallet_id,
		COUNT(*) AS bag_count
	INTO #qty_bag_count
	FROM dbo.tr_bag b
	WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
		AND b.is_active = 'Y'
		AND b.status_flag = 'A'
	GROUP BY b.pallet_id

	-- 3c. Ton No. per pallet -- MIN(tr_bag.ton_no) over active bags.
	IF OBJECT_ID('tempdb..#ton') IS NOT NULL
		DROP TABLE #ton

	SELECT
		b.pallet_id,
		MIN(b.ton_no) AS ton_no
	INTO #ton
	FROM dbo.tr_bag b
	WHERE b.pallet_id IN (SELECT pallet_id FROM #page)
		AND b.is_active = 'Y'
		AND b.status_flag = 'A'
	GROUP BY b.pallet_id

	-- 3d. Paginated pallet list.
	SELECT
		tp.id AS id,
		pg.pallet_running AS pallet_id,
		tp.pallet_no AS pallet_no,
		t.ton_no AS ton_no,
		pg.grade AS grade,
		pg.lot AS lot,
		tp.pd_type_code AS pallet_type,
		tp.current_location_id AS current_location_id,
		COALESCE(clt.name, 'Bagging Area') AS location_type,
		tp.current_location_type AS location_type_code,
		COALESCE(
			MAX(cpl.bg_plant_desc COLLATE DATABASE_DEFAULT),
			MAX(rqcc.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(csz.zone_name COLLATE DATABASE_DEFAULT),
			MAX(csl.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(sd.dock_name COLLATE DATABASE_DEFAULT),
			MAX(vm.VEHICLE COLLATE DATABASE_DEFAULT),
			IIF(tp.current_location_id IS NULL, 'Bagging Area', NULL)
		) AS current_location,
		tp.unit_pallet,
		tp.unit_ratio,
		CASE
			WHEN tp.pallet_type IN ('M', 'S') THEN ISNULL(tp.unit_ratio, 0) * ISNULL(tp.unit_pallet, 0)
			ELSE ISNULL(qbc.bag_count, 0) * ISNULL(tp.unit_ratio, 0)
		END AS qty,
		CASE WHEN tp.pallet_type IN ('M', 'S') THEN 'Y' WHEN bc.bag_count >= tp.unit_pallet THEN 'Y' ELSE 'N' END AS is_full_pallet,
		tp.create_datetime AS create_datetime
	FROM #page pg
	INNER JOIN dbo.tr_pallet tp
		ON tp.id = pg.pallet_id
	LEFT JOIN #bag_count bc
		ON bc.pallet_id = pg.pallet_id
	LEFT JOIN #qty_bag_count qbc
		ON qbc.pallet_id = pg.pallet_id
	LEFT JOIN #ton t
		ON t.pallet_id = pg.pallet_id
	LEFT JOIN dbo.ct_location_type clt
		ON clt.code = tp.current_location_type
		AND clt.is_active = 'Y'
		AND clt.status_flag = 'A'
	LEFT JOIN dbo.ct_bg_plant_location cpl
		ON cpl.id = tp.current_location_id
		AND cpl.is_active = 'Y'
		AND cpl.status_flag = 'A'
		AND tp.current_location_type = 'BG-PLANT'
	LEFT JOIN IRPC_E_TRANSFER.dbo.ct_request_cost_center rqcc
		ON rqcc.id = tp.current_location_id
		AND rqcc.is_active = 'Y'
		AND rqcc.status_flag = 'A'
		AND tp.current_location_type = 'RQ-PLANT'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_dock] sd
		ON sd.id = tp.current_location_id
		AND sd.is_active = 'Y'
		AND sd.status_flag = 'A'
		AND tp.current_location_type = 'DOCK'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_zone] csz
		ON csz.id = tp.current_location_id
		AND csz.is_active = 'Y'
		AND csz.status_flag = 'A'
		AND tp.current_location_type = 'PRE-ZONE'
	LEFT JOIN dbo.ct_special_location csl
		ON csl.id = tp.current_location_id
		AND csl.is_active = 'Y'
		AND csl.status_flag = 'A'
		AND tp.current_location_type = 'SPC-ZONE'
	LEFT JOIN [IRPC].[dbo].[VVehicleMaster] vm
		ON vm.vechicle_id = tp.current_location_id
		AND tp.current_location_type = 'VEHICLE'
	GROUP BY tp.id, pg.pallet_running, tp.pallet_no, pg.grade, pg.lot, tp.pd_type_code, tp.pallet_type, tp.current_location_id, tp.current_location_type, tp.unit_pallet, tp.unit_ratio, bc.bag_count, qbc.bag_count, tp.create_datetime, clt.name, t.ton_no
	ORDER BY tp.id, pg.grade, pg.lot

	-- total_count -- same rows paging walks over (1 per pallet+grade+lot).
	SELECT @total_count AS total_count
END
GO

-- ===== dbo.pProcessGetBagList =====
-- =============================================================
-- pProcessGetBagList: seek bags by tr_bag.pallet_id, return mode_id
-- =============================================================
-- Speed: the old SP filtered on tp.id (the joined tr_pallet), so it
-- could not seek tr_bag and scanned ~1.28M active bags: ~2.9s for one
-- pallet (40 bags) on 10.31.1.74, measured 2026-10-28. Filtering on
-- trb.pallet_id seeks IX_tr_bag_pallet_id_aligned
-- (pallet_id, is_active, status_flag): ~30ms for the same pallet, same
-- 40 rows. "tp.id IS NOT NULL" keeps the old rule that the pallet must
-- be active (is_active = 'Y', status_flag = 'A').
-- @pallet_id NULL (all bags) keeps the old query unchanged.
--
-- mode_id: Boardman Pallet Information shows a Mode column.
-- tr_bag.mode_id has no master table; Boardman shows
-- 1 = Auto, 2 = Manual, 3 = Test (2026-10-28).
--
-- Rollback: run sql/backup_20261028_pProcessGetBagList.sql
-- =============================================================

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetBagList]
	@pallet_id				INT						= NULL,
	@page					INT						= 1,
	@page_size				INT						= 10
AS
BEGIN
	SET NOCOUNT ON

	-- =============================================================
	-- Retrieve bag list based on pallet number with pagination.
	-- =============================================================

	IF OBJECT_ID('tempdb..#data_bags') IS NOT NULL
		DROP TABLE #data_bags

	-- Same types as tr_bag / tr_pallet, so the API JSON stays the same
	CREATE TABLE #data_bags (
		id					BIGINT,
		cost_center			VARCHAR(20) COLLATE DATABASE_DEFAULT,
		pallet_no			VARCHAR(50) COLLATE DATABASE_DEFAULT,
		bag_no				INT,
		pallet_running_no	INT,
		ton_no				INT,
		mode_id				INT,
		grade				VARCHAR(30) COLLATE DATABASE_DEFAULT,
		lot					VARCHAR(20) COLLATE DATABASE_DEFAULT,
		qr_text_data		VARCHAR(100) COLLATE DATABASE_DEFAULT,
		unit_ratio			INT,
		create_datetime		DATETIME
	)

	IF @pallet_id IS NOT NULL
	BEGIN
		-- One pallet: seek tr_bag by pallet_id
		INSERT INTO #data_bags
		SELECT
			trb.id,
			trb.cost_center,
			tp.pallet_no,
			trb.bag_no,
			trb.pallet_running_no,
			trb.ton_no,
			trb.mode_id,
			trb.grade,
			trb.lot,
			trb.qr_text_data,
			tp.unit_ratio,
			trb.create_datetime
		FROM dbo.tr_bag trb
		INNER JOIN dbo.tr_pallet tp
			ON tp.id = trb.pallet_id
			AND tp.is_active = 'Y'
			AND tp.status_flag = 'A'
		WHERE trb.pallet_id = @pallet_id
			AND trb.is_active = 'Y'
			AND trb.status_flag = 'A'
		OPTION (RECOMPILE)
	END
	ELSE
	BEGIN
		-- All bags: same as the old SP
		INSERT INTO #data_bags
		SELECT
			trb.id,
			trb.cost_center,
			tp.pallet_no,
			trb.bag_no,
			trb.pallet_running_no,
			trb.ton_no,
			trb.mode_id,
			trb.grade,
			trb.lot,
			trb.qr_text_data,
			tp.unit_ratio,
			trb.create_datetime
		FROM dbo.tr_bag trb
		LEFT JOIN dbo.tr_pallet tp
			ON tp.id = trb.pallet_id
			AND tp.is_active = 'Y'
			AND tp.status_flag = 'A'
		WHERE trb.is_active = 'Y'
			AND trb.status_flag = 'A'
	END

	-- =============================================================
	-- Return status and message based on data retrieval result.
	-- =============================================================

	SELECT 'success' AS status,
		   CASE WHEN EXISTS (SELECT 1 FROM #data_bags) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- =============================================================
	-- Return paginated bag list and total count.
	-- =============================================================

	SELECT
		id,
		cost_center,
		pallet_no,
		bag_no,
		pallet_running_no,
		ton_no,
		mode_id,
		grade,
		lot,
		qr_text_data,
		unit_ratio,
		create_datetime
	FROM #data_bags
	ORDER BY CASE WHEN bag_no IS NULL THEN 1 ELSE 0 END, bag_no, id
	OFFSET (@page - 1) * @page_size ROWS
	FETCH NEXT @page_size ROWS ONLY

	SELECT
		COUNT(*) AS total_count
	FROM #data_bags
END
GO

-- ===== dbo.pProcessPalletMgmtEditBag =====
/* ---------------------------------------------------------------------
   4) pProcessPalletMgmtEditBag
   ต้องกรอกครบ: cost_center, grade, lot, bag_no, pallet_running_no (Ton No.)
   bag_no ต้องอยู่ในช่วง 1..unit_pallet และไม่ซ้ำกับถุงอื่นบนพาเลทเดียวกัน
   แก้เฉพาะคอลัมน์ของ tr_bag -- qr_text_data ไม่เปลี่ยน (ต้องตรงกับป้าย QR จริงที่ติดถุง)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtEditBag]
    @BagId           BIGINT,
    @CostCenter      VARCHAR(20),
    @BagNo           INT,
    @PalletRunningNo INT,
    @Grade           VARCHAR(30),
    @Lot             VARCHAR(20),
    @UserId          INT,
    @ResultCode      INT           OUTPUT,
    @ResultMessage   NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CostCenter = NULLIF(LTRIM(RTRIM(@CostCenter)), '');
    SET @Grade      = NULLIF(LTRIM(RTRIM(@Grade)), '');
    SET @Lot        = NULLIF(LTRIM(RTRIM(@Lot)), '');

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletId BIGINT, @PalletNo VARCHAR(50), @UnitPallet INT,
                @OldBagNo INT, @OldGrade VARCHAR(30), @OldLot VARCHAR(20),
                @OldCostCenter VARCHAR(20), @OldPalletRunningNo INT;

        SELECT @PalletId = b.pallet_id, @OldBagNo = b.bag_no, @OldGrade = b.grade, @OldLot = b.lot,
               @OldCostCenter = b.cost_center, @OldPalletRunningNo = b.pallet_running_no,
               @PalletNo = p.pallet_no, @UnitPallet = p.unit_pallet
        FROM   dbo.tr_bag b WITH (UPDLOCK)
        JOIN   dbo.tr_pallet p ON p.id = b.pallet_id
        WHERE  b.id = @BagId AND b.is_active = 'Y' AND b.status_flag = 'A';

        IF @PalletId IS NULL
        BEGIN
            SET @ResultCode = 1;  SET @ResultMessage = N'ไม่พบถุงบนพาเลท';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @CostCenter IS NULL OR @Grade IS NULL OR @Lot IS NULL
           OR ISNULL(@BagNo, 0) <= 0 OR ISNULL(@PalletRunningNo, 0) <= 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'กรุณากรอก Cost Center, Grade, Lot, Bag No. และ Running Pallet No. (Ton No.) ให้ครบ';
            ROLLBACK TRANSACTION;  RETURN;
        END

        --  รูปแบบเดียวกับ QR ถุง: cost_center 4 หลัก, bag_no 2 หลัก (1-99), Ton No. 3 หลัก (1-999)
        IF LEN(@CostCenter) > 4 OR @PalletRunningNo > 999
        BEGIN
            SET @ResultCode = 5;
            SET @ResultMessage = N'รูปแบบข้อมูลไม่ถูกต้อง (Cost Center ไม่เกิน 4 หลัก, Ton No. 1 - 999)';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @BagNo > 99 OR (@UnitPallet > 0 AND @BagNo > @UnitPallet)
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'Bag No. ต้องอยู่ระหว่าง 1 - ' + CAST(CASE WHEN ISNULL(@UnitPallet, 0) BETWEEN 1 AND 99 THEN @UnitPallet ELSE 99 END AS NVARCHAR(10));
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.tr_bag
                   WHERE pallet_id = @PalletId AND bag_no = @BagNo AND id <> @BagId
                     AND is_active = 'Y' AND status_flag = 'A')
        BEGIN
            SET @ResultCode = 4;
            SET @ResultMessage = N'Bag No. ' + CAST(@BagNo AS NVARCHAR(10)) + N' มีอยู่แล้วบนพาเลทนี้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        UPDATE dbo.tr_bag
        SET    cost_center       = @CostCenter,
               bag_no            = @BagNo,
               pallet_running_no = @PalletRunningNo,
               ton_no            = @PalletRunningNo,   -- Ton No. ที่ user กรอกเอง
               grade             = @Grade,
               lot               = @Lot,
               bag_status_id     = 3,   -- MANUAL_MATCHED
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @BagId;

        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'*' + ISNULL(@PalletNo, N'-') + N'* ถุง #' + CAST(@BagNo AS VARCHAR(10)) + N': ' + ISNULL(STUFF(
              CASE WHEN ISNULL(@OldCostCenter, '') <> @CostCenter THEN N', CC ' + ISNULL(@OldCostCenter, N'-') + N' → ' + @CostCenter ELSE N'' END
            + CASE WHEN ISNULL(@OldGrade, '') <> @Grade THEN N', Grade ' + ISNULL(@OldGrade, N'-') + N' → ' + @Grade ELSE N'' END
            + CASE WHEN ISNULL(@OldLot, '') <> @Lot THEN N', Lot ' + ISNULL(@OldLot, N'-') + N' → ' + @Lot ELSE N'' END
            + CASE WHEN ISNULL(@OldBagNo, -1) <> @BagNo THEN N', Bag ' + ISNULL(CAST(@OldBagNo AS VARCHAR(10)), N'-') + N' → ' + CAST(@BagNo AS VARCHAR(10)) ELSE N'' END
            + CASE WHEN ISNULL(@OldPalletRunningNo, -1) <> @PalletRunningNo THEN N', Ton ' + ISNULL(CAST(@OldPalletRunningNo AS VARCHAR(10)), N'-') + N' → ' + CAST(@PalletRunningNo AS VARCHAR(10)) ELSE N'' END
            , 1, 2, N''), N'ไม่มีการเปลี่ยนแปลง');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Edit Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;  SET @ResultMessage = N'แก้ไขข้อมูลสำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;  SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

-- ===== dbo.pProcessPalletMgmtReplaceBag =====
/* ---------------------------------------------------------------------
   3) pProcessPalletMgmtReplaceBag
   @ResultCode : 0 = success , > 0 = business error , -1 = system error
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[pProcessPalletMgmtReplaceBag]
    @PalletId      BIGINT,
    @OldBagId      BIGINT,
    @NewBagId      BIGINT,
    @Reason        NVARCHAR(255) = NULL,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PalletNo VARCHAR(50), @SlotNo INT, @OldQr VARCHAR(100), @NewQr VARCHAR(100);
        DECLARE @NewPalletId BIGINT, @NewSlotNo INT, @NewPalletNo VARCHAR(50);

        SELECT @PalletNo = pallet_no
        FROM   dbo.tr_pallet WITH (UPDLOCK)
        WHERE  id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @PalletNo IS NULL
        BEGIN
            SET @ResultCode = 1;  SET @ResultMessage = N'ไม่พบพาเลท';
            ROLLBACK TRANSACTION;  RETURN;
        END

        SELECT @SlotNo = bag_no, @OldQr = qr_text_data
        FROM   dbo.tr_bag WITH (UPDLOCK)
        WHERE  id = @OldBagId AND pallet_id = @PalletId AND is_active = 'Y' AND status_flag = 'A';

        IF @OldQr IS NULL
        BEGIN
            SET @ResultCode = 2;  SET @ResultMessage = N'ไม่พบถุงเดิมบนพาเลทนี้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        --  ถุงใหม่: orphan หรืออยู่บนพาเลทอื่นก็ได้ (สลับที่กัน)
        SELECT @NewQr = qr_text_data, @NewPalletId = pallet_id, @NewSlotNo = bag_no
        FROM   dbo.tr_bag WITH (UPDLOCK)
        WHERE  id = @NewBagId AND is_active = 'Y' AND status_flag = 'A';

        IF @NewQr IS NULL
        BEGIN
            SET @ResultCode = 3;  SET @ResultMessage = N'ไม่พบข้อมูลถุงใหม่ หรือถุงถูก Reject แล้ว';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @OldBagId = @NewBagId
        BEGIN
            SET @ResultCode = 4;  SET @ResultMessage = N'ถุงใหม่ต้องไม่ใช่ถุงเดิม';
            ROLLBACK TRANSACTION;  RETURN;
        END

        IF @NewPalletId = @PalletId
        BEGIN
            SET @ResultCode = 5;  SET @ResultMessage = N'ถุงใหม่อยู่ในพาเลทเดียวกัน ไม่สามารถสลับได้';
            ROLLBACK TRANSACTION;  RETURN;
        END

        DECLARE @LogDetail NVARCHAR(MAX);

        --  ถุงใหม่อยู่บนพาเลทอื่น -> สลับที่กันจริง: ถุงเดิมไปแทนช่องของถุงใหม่ (ไม่ Reject ถุงใด)
        IF @NewPalletId IS NOT NULL
        BEGIN
            SELECT @NewPalletNo = pallet_no
            FROM   dbo.tr_pallet WITH (UPDLOCK)
            WHERE  id = @NewPalletId AND is_active = 'Y' AND status_flag = 'A';

            IF @NewPalletNo IS NULL
            BEGIN
                SET @ResultCode = 6;  SET @ResultMessage = N'ไม่พบพาเลทของถุงใหม่ หรือพาเลทถูกยกเลิกแล้ว';
                ROLLBACK TRANSACTION;  RETURN;
            END

            UPDATE dbo.tr_bag
            SET    pallet_id       = @NewPalletId,
                   bag_no          = @NewSlotNo,
                   bag_status_id   = 3,   -- MANUAL_MATCHED
                   update_user_id  = @UserId,
                   update_datetime = GETDATE()
            WHERE  id = @OldBagId;

            UPDATE dbo.tr_bag
            SET    pallet_id       = @PalletId,
                   bag_no          = @SlotNo,
                   bag_status_id   = 3,   -- MANUAL_MATCHED
                   update_user_id  = @UserId,
                   update_datetime = GETDATE()
            WHERE  id = @NewBagId;

            SET @LogDetail = N'*' + @NewPalletNo + N'* #' + ISNULL(CAST(@NewSlotNo AS VARCHAR(10)), N'-') + N' ↔ *' + @PalletNo + N'* #' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N'-');

            EXEC dbo.pInsertTransactionLog
                 @topic    = 'Pallet Management',
                 @activity = 'Swap Bag',
                 @detail   = @LogDetail,
                 @user_id  = @UserId;

            SET @ResultCode = 0;  SET @ResultMessage = N'สลับถุงกับพาเลท ' + @NewPalletNo + N' สำเร็จ';
            COMMIT TRANSACTION;
            RETURN;
        END

        --  ถุงเดิม -> Reject (6 = REPLACED, ดู 00_master_bag_status.sql)
        UPDATE dbo.tr_bag
        SET    is_active       = 'R',
               pallet_id       = NULL,
               bag_no          = NULL,
               bag_status_id   = 6,
               remark          = COALESCE(NULLIF(LTRIM(RTRIM(@Reason)), ''), remark, N'Replace bag'),
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @OldBagId;

        --  ถุงใหม่ -> ช่องเดิม
        UPDATE dbo.tr_bag
        SET    pallet_id       = @PalletId,
               bag_no          = @SlotNo,
               bag_status_id   = 3,   -- MANUAL_MATCHED
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @NewBagId;

        SET @LogDetail = N'*' + @PalletNo + N'* #' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N'-') + N': ' + @OldQr + N' → ' + @NewQr + N' (ถุงเดิม Reject)'
                         + ISNULL(N' เหตุผล: ' + NULLIF(LTRIM(RTRIM(@Reason)), ''), N'');

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Management',
             @activity = 'Replace Bag',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;  SET @ResultMessage = N'เปลี่ยนถุงสำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;  SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

-- ===== dbo.sp_PalletAdjustment_CreatePallet =====
--  2) บันทึก ratio + สร้างพาเลทใหม่ให้ถุง orphan 1 ใบ
--     ResultCode : 0 สำเร็จ , 1 ไม่พบถุง/ถุงถูกผูกพาเลทแล้ว , 2 ข้อมูล ratio ไม่ถูกต้อง , -1 error
CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_CreatePallet]
    @BagId         BIGINT,
    @UnitRatio     INT,
    @UnitPallet    INT,
    @UnitCode      VARCHAR(20)   = NULL,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @NewPalletId   BIGINT        OUTPUT,
    @NewPalletNo   VARCHAR(50)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Grade VARCHAR(30), @GradeKey VARCHAR(30), @Cc VARCHAR(20), @Lot VARCHAR(20),
            @Qr VARCHAR(100), @Prn INT, @Fmt TINYINT, @Ref NVARCHAR(100) = NULL,
            @RatioAction NVARCHAR(20) = N'ไม่เปลี่ยน',
            @OldRatio INT, @OldPallet INT, @OldCode VARCHAR(20), @HasRatio BIT = 0,
            @IsActive VARCHAR(1), @LogDetail NVARCHAR(MAX);

    SET @UnitCode = NULLIF(LTRIM(RTRIM(@UnitCode)), '');

    BEGIN TRY
        IF ISNULL(@UnitRatio, 0) <= 0 OR ISNULL(@UnitPallet, 0) <= 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'กรุณาระบุ Unit Ratio และ Unit Pallet มากกว่า 0';
            RETURN;
        END

        BEGIN TRANSACTION;

        --  orphan (is_active='Y' ยังไม่ผูกพาเลท) หรือถุง Reject (is_active='R' -- อาจยังค้าง pallet_id
        --  เดิมถ้า matching ยังไม่ได้ปลด ; ย้ายมาพาเลทใหม่ได้เลย)
        SELECT @Grade = grade, @Cc = cost_center, @Lot = lot, @Qr = qr_text_data, @IsActive = is_active
        FROM   dbo.tr_bag WITH (UPDLOCK, ROWLOCK)
        WHERE  id = @BagId
          AND  ( (is_active = 'Y' AND pallet_id IS NULL) OR is_active = 'R' );

        IF @@ROWCOUNT = 0
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบถุง หรือถุงนี้ถูกผูกพาเลทไปแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @GradeKey = REPLACE(ISNULL(@Grade, ''), ' ', '');
        IF @GradeKey = ''
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'ถุงนี้ไม่มีข้อมูล Grade';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  ct_grade_package_ratio : insert ถ้ายังไม่มี / update ถ้าผู้ใช้แก้ค่า
        SELECT @HasRatio = 1, @OldRatio = unit_ratio, @OldPallet = unit_pallet, @OldCode = unit_code
        FROM   dbo.ct_grade_package_ratio WITH (UPDLOCK, HOLDLOCK)
        WHERE  grade = @GradeKey;

        IF @HasRatio = 0
        BEGIN
            INSERT INTO dbo.ct_grade_package_ratio (grade, unit_ratio, unit_pallet, unit_code, last_update_datetime)
            VALUES (@GradeKey, @UnitRatio, @UnitPallet, @UnitCode, GETDATE());
            SET @RatioAction = N'เพิ่มใหม่';
        END
        ELSE IF ISNULL(@OldRatio, -1) <> @UnitRatio OR ISNULL(@OldPallet, -1) <> @UnitPallet
             OR ISNULL(@OldCode, '') <> ISNULL(@UnitCode, '')
        BEGIN
            UPDATE dbo.ct_grade_package_ratio
            SET    unit_ratio = @UnitRatio, unit_pallet = @UnitPallet, unit_code = @UnitCode,
                   last_update_datetime = GETDATE()
            WHERE  grade = @GradeKey;
            SET @RatioAction = N'แก้ไข';
        END

        --  ref_pallet ตามตันใน QR ถ้ายังว่าง (ดูหัวไฟล์)
        --  QR format ใหม่ (มี |ddHHmm) ต่อท้าย '|F6' ให้ตรงกับพาเลทกลุ่ม format ใหม่ของ 13_
        SELECT @Prn = pallet_running_no, @Fmt = qr_format FROM dbo.fParseBagQr(@Qr);
        IF @Prn > 0
        BEGIN
            SET @Ref = CONCAT(@Cc, '|', @Grade, '|', @Lot, '|', @Prn, CASE WHEN @Fmt = 6 THEN '|F6' ELSE '' END);
            IF EXISTS (SELECT 1 FROM dbo.tr_pallet WHERE ref_pallet = @Ref AND status_flag = 'A')
                SET @Ref = NULL;
        END

        SET @NewPalletNo = dbo.fGetPalletNo('A');

        INSERT INTO dbo.tr_pallet
            ( ref_pallet, pallet_no, pallet_type, pd_group_code, unit_ratio, unit_pallet,
              pallet_status_id, is_active, remark,
              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
        VALUES
            ( @Ref, @NewPalletNo, 'A', 'A', @UnitRatio, @UnitPallet,
              CASE WHEN @UnitPallet <= 1 THEN 2 ELSE 1 END,   -- 1 ถุงก็เต็มแล้ว -> 2=COMPLETED
              'Y', CONCAT('Manual create: ', @Grade, ' / ', @Lot),
              @UserId, GETDATE(), @UserId, GETDATE(), 'A' );

        SET @NewPalletId = SCOPE_IDENTITY();

        UPDATE dbo.tr_bag
        SET    pallet_id       = @NewPalletId,
               bag_no          = 1,
               bag_status_id   = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               is_active       = 'Y', -- ถุง Reject กลับเป็นถุงปกติ
               --  ถุง Reject ที่ถูกปลดจากพาเลทแล้วมี ton_no = NULL -> ใช้เลขตันจาก QR
               ton_no          = CASE WHEN @IsActive = 'R' THEN COALESCE(ton_no, NULLIF(@Prn, 0)) ELSE ton_no END,
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @BagId;

        SET @LogDetail = N'*' + @NewPalletNo + N'* จาก' + CASE WHEN @IsActive = 'R' THEN N'ถุง Reject ' ELSE N'ถุงที่ยังไม่ผูกพาเลท ' END + ISNULL(@Qr, N'-')
                         + N', ratio ' + CAST(@UnitRatio AS VARCHAR(10)) + N'×' + CAST(@UnitPallet AS VARCHAR(10)) + ISNULL(N' ' + @UnitCode, N'')
                         + CASE WHEN @RatioAction = N'แก้ไข'
                                THEN N' (เดิม ' + ISNULL(CAST(@OldRatio AS VARCHAR(10)), N'-') + N'×' + ISNULL(CAST(@OldPallet AS VARCHAR(10)), N'-') + ISNULL(N' ' + @OldCode, N'') + N')'
                                WHEN @RatioAction = N'ไม่เปลี่ยน' THEN N''
                                ELSE N' (' + @RatioAction + N' ratio)' END;

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Create Pallet',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สร้างพาเลท ' + @NewPalletNo + N' สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = ERROR_MESSAGE();
        SET @NewPalletId = NULL;
        SET @NewPalletNo = NULL;
    END CATCH

    --  หลังสร้างพาเลทสำเร็จ (commit แล้ว) -> รัน auto-matching ทันที ให้ถุงค้างอื่นของ grade นี้
    --  (ตอนนี้มี ratio แล้ว) ถูกสร้าง/จับเข้าพาเลทเลย ไม่ต้องรอ SQL Agent job 1 นาที
    --  แยก TRY ของตัวเอง : matching ล้มเหลวต้องไม่ทำให้การสร้างพาเลทถูกรายงานว่า error
    --  (ถ้า job รายนาทีกำลังรันอยู่ 14_ จะข้ามรอบนี้เอง แล้ว job นั้นจับให้แทน)
    IF @ResultCode = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.pServiceRunPalletMatching @create_user_id = 0, @preview = 0;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SET @ResultMessage = LEFT(@ResultMessage + N' (จับคู่ถุงอัตโนมัติไม่สำเร็จ: ' + ERROR_MESSAGE()
                                      + N' -- job รายนาทีจะจับให้ภายหลัง)', 255);
        END CATCH
    END
END
GO
