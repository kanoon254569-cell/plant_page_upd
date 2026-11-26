-- Rollback of deploy_75_fix_pProcessPickingPutAway_dbResult1_alias_20261112.sql (10.31.1.75)
DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
SET @d = STUFF(@d, PATINDEX('%CREATE%PROC%', @d), 6, 'ALTER');
SET @d = REPLACE(@d, 'ISNULL(fp.code_pallet_id, 0) AS code_pallet_id,',                   'ISNULL(fp.code_pallet_id, 0),');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_lot, ''-'') AS pallet_lot,',                       'ISNULL(fp.pallet_lot, ''-''),');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_qty, 0) AS pallet_qty,',                           'ISNULL(fp.pallet_qty, 0),');
SET @d = REPLACE(@d, 'ISNULL(fp.pallet_weight, 0) AS pallet_weight,',                     'ISNULL(fp.pallet_weight, 0),');
SET @d = REPLACE(@d, 'ISNULL(fp.special_type_package_id, 0) AS special_type_package_id,', 'ISNULL(fp.special_type_package_id, 0),');
EXEC sp_executesql @d;
