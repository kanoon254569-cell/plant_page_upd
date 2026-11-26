/* =====================================================================
   rollback_75_pallet_adjustment_permission_20261112.sql
   Undo deploy_75_pallet_adjustment_permission_20261112.sql.
   Only run together with rolling back the web + API (they would otherwise
   block BG01 for every role). Removes every data.pallet_adjustment row,
   including ones ticked in role-list after deploy.
   ===================================================================== */
SET NOCOUNT ON;

DELETE FROM [IRPC_E_TRANSFER].dbo.ct_role_permission
WHERE permission_key = 'data.pallet_adjustment';

PRINT CONCAT('data.pallet_adjustment rows deleted: ', @@ROWCOUNT);
