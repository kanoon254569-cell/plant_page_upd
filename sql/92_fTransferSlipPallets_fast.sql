-- =============================================================
-- 92_fTransferSlipPallets_fast.sql  (IRPC_QTRACK)
-- =============================================================
-- GET process/job (pProcessGetJobList) is slow for a date range of more
-- than a few days. 70% of the time is the fTransferSlipJob INSERT, and
-- all of that is its pallet CTE: CROSS APPLY dbo.fTransferSlipPallets
-- once per transfer-slip job (2026-10-25, plan cache: 575 ms /
-- 23.7k reads per call for 114 rows; a 1-day range is 16 ms).
--
-- Cause (from the plan): per job, the LEFT JOIN to tr_pallet_manual_item
-- is a Hash Match fed by a full scan of tr_pallet_manual_item
-- (15,896 rows), because the join is made on the raw tr_bag rows
-- (6.5k rows for 101 jobs) and the estimate is ~4,600 rows per job.
-- So the 15,896-row hash table is built again for every job: high CPU
-- with low reads.
--
-- Change (92), same rows and columns as before:
--   1. tr_pallet_manual_item : LEFT JOIN -> scalar subquery in the
--      SELECT list, a seek per result row. pallet_id is unique in
--      tr_pallet_manual_item (UQ_tr_pallet_manual_item_pallet_id,
--      WHERE pallet_id IS NOT NULL), so the LEFT JOIN gave at most one
--      row per pallet; the value only depends on p.id, which is in the
--      GROUP BY, so it is removed from the GROUP BY.
--   2. tr_bag : count the bags per (pallet_id, grade, lot) before the
--      join instead of joining every bag and grouping after.
--      bag_count = SUM(b.bag_count) : each output group has exactly one
--      (pallet, grade, lot) row, so it is the same count as COUNT(*).
--
-- Measured on IRPC_QTRACK 2026-10-25, the 101 transfer-slip jobs of
-- 2026-10-01..25:
--   pallet CTE of fTransferSlipJob (what the job list uses)
--                      1,922 ms / 23,285 reads -> 63 ms / 3,624 reads
--   all columns (with fGetPalletQty)
--                      1,401 ms / 24,301 reads -> 1,016 ms / 8,823 reads
--   all 286 rows, all 31 columns : EXCEPT both ways = 0 rows.
--
-- Callers (all get the same rows): fTransferSlipJob,
-- vTransferSlipPallets, the pallet list proc (CROSS APPLY by fj.id) and
-- the proc that runs SELECT * FROM dbo.fTransferSlipPallets(@job_main_id).
-- Column order is not changed.
--
-- Patched from the live definition with REPLACE (same way as sql/85):
-- every piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the patch is already there.
-- Rollback: sql/92_rollback_fTransferSlipPallets.sql (the definition
-- before this patch, SHA-256 checked).
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @proc SYSNAME       = N'dbo.fTransferSlipPallets';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @nl   NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%SUM(b.bag_count)%'
BEGIN
    PRINT 'fTransferSlipPallets already patched (92_) - skipped.';
    RETURN;
END

--  1. tr_pallet_manual_item : LEFT JOIN -> scalar subquery
DECLARE @o1 NVARCHAR(400) = N'pmi.wms_plus_item_id AS wms_plus_manual_item_id,';
DECLARE @n1 NVARCHAR(400) = N'(SELECT pmi.wms_plus_item_id FROM dbo.tr_pallet_manual_item pmi WHERE pmi.pallet_id = p.id) AS wms_plus_manual_item_id,   -- (92_) seek ต่อแถว แทน LEFT JOIN';
DECLARE @o2 NVARCHAR(400) = @nl + N'    LEFT JOIN dbo.tr_pallet_manual_item pmi'
                          + @nl + N'        ON pmi.pallet_id = p.id' + @nl;
DECLARE @n2 NVARCHAR(400) = @nl;
DECLARE @o3 NVARCHAR(400) = @nl + N'        pmi.wms_plus_item_id,' + @nl;
DECLARE @n3 NVARCHAR(400) = @nl;

--  2. tr_bag : count per (pallet_id, grade, lot) before the join
DECLARE @o4 NVARCHAR(400) = N'COUNT(*) AS bag_count,';
DECLARE @n4 NVARCHAR(400) = N'SUM(b.bag_count) AS bag_count,';
DECLARE @o5 NVARCHAR(1000) = N'    INNER JOIN dbo.tr_bag b'
    + @nl + N'        ON b.pallet_id = p.id'
    + @nl + N'       AND'
    + @nl + N'       ('
    + @nl + N'            (b.status_flag IS NULL AND b.is_active IS NULL)'
    + @nl + N'            OR'
    + @nl + N'            (b.status_flag = ''A'' AND b.is_active = ''Y'')'
    + @nl + N'       )';
DECLARE @n5 NVARCHAR(1000) = N'    -- (92_) นับถุงต่อ (pallet_id, grade, lot) ก่อน join แทนการ join ถุงทุกใบแล้วค่อย GROUP BY'
    + @nl + N'    INNER JOIN'
    + @nl + N'    ('
    + @nl + N'        SELECT pallet_id, grade, lot, COUNT(*) AS bag_count'
    + @nl + N'        FROM   dbo.tr_bag'
    + @nl + N'        WHERE  (status_flag IS NULL AND is_active IS NULL)'
    + @nl + N'            OR (status_flag = ''A'' AND is_active = ''Y'')'
    + @nl + N'        GROUP BY pallet_id, grade, lot'
    + @nl + N'    ) b'
    + @nl + N'        ON b.pallet_id = p.id';

IF   (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o2, N''))) / DATALENGTH(@o2) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o3, N''))) / DATALENGTH(@o3) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o4, N''))) / DATALENGTH(@o4) <> 1
  OR (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o5, N''))) / DATALENGTH(@o5) <> 1
BEGIN
    RAISERROR('fTransferSlipPallets: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

-- order : 4 before 5 (5 adds a new COUNT(*) AS bag_count), 3 before 1
SET @d = REPLACE(@d, @o4, @n4);
SET @d = REPLACE(@d, @o5, @n5);
SET @d = REPLACE(@d, @o2, @n2);
SET @d = REPLACE(@d, @o3, @n3);
SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'fTransferSlipPallets patched (92_: pmi seek + bag count before join).';
GO
