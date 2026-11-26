-- 10.31.1.75: pProcessPickingPutAway dbResult1 had ISNULL(...) columns with no alias,
-- so the API (JobService.BuildPickingPrepareCompletePayload) failed with
-- "Column 'code_pallet_id' does not belong to table dbResult1."
-- Adds the aliases in place (proc is ~30k chars, so patch via OBJECT_DEFINITION + REPLACE).
DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
SET @d = STUFF(@d, PATINDEX('%CREATE%PROC%', @d), 6, 'ALTER');
SET @d = REPLACE(@d, 'ISNULL(fp.code_pallet_id, 0),',          'ISNULL(fp.code_pallet_id, 0) AS code_pallet_id,');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_lot, ''-''),',          'ISNULL(fp.pallet_lot, ''-'') AS pallet_lot,');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_qty, 0),',              'ISNULL(fp.pallet_qty, 0) AS pallet_qty,');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_weight, 0),',           'ISNULL(fp.pallet_weight, 0) AS pallet_weight,');
SET @d = REPLACE(@d, 'ISNULL(fp.special_type_package_id, 0),', 'ISNULL(fp.special_type_package_id, 0) AS special_type_package_id,');
EXEC sp_executesql @d;
