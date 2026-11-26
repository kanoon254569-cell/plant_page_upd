/* =====================================================================
   deploy_75_pallet_adjustment_permission_20261112.sql
   ---------------------------------------------------------------------
   BG01 - Pallet Adjustment (Boardman) now has its own permission key
   'data.pallet_adjustment', ticked in role-list > Data Management.
   Before this it shared 'data.pallet_management'.

   Web  : menu-access.service.ts palletAdjustment -> data.pallet_adjustment
   API  : PalletController pallet-adjustment/* -> [RequirePermission("data.pallet_adjustment")]
          (pallet-adjustment/bag + add-missing-bag also accept
           data.pallet_management, used by pallet-information)

   This script copies every active data.pallet_management row (role x
   department) to data.pallet_adjustment with the same value, so nobody
   loses BG01 on deploy. Run BEFORE (or together with) the new API/web.
   Re-runnable: existing data.pallet_adjustment rows are left alone.
   Rollback: rollback_75_pallet_adjustment_permission_20261112.sql
   ===================================================================== */
SET NOCOUNT ON;

BEGIN TRAN;

INSERT INTO [IRPC_E_TRANSFER].dbo.ct_role_permission
    (role_id, department_id, permission_key, permission_value, status_flag,
     create_user_id, create_datetime, last_update_user_id, last_update_datetime)
SELECT
    src.role_id, src.department_id, 'data.pallet_adjustment', src.permission_value, 'A',
    0, GETDATE(), 0, GETDATE()
FROM [IRPC_E_TRANSFER].dbo.ct_role_permission src
WHERE src.permission_key = 'data.pallet_management'
  AND ISNULL(src.status_flag, 'A') = 'A'
  AND NOT EXISTS (
      SELECT 1
      FROM [IRPC_E_TRANSFER].dbo.ct_role_permission dst
      WHERE dst.role_id       = src.role_id
        AND dst.department_id = src.department_id
        AND dst.permission_key = 'data.pallet_adjustment'
  );

PRINT CONCAT('data.pallet_adjustment rows inserted: ', @@ROWCOUNT);

COMMIT TRAN;

--  Check
SELECT role_id, department_id, permission_key, permission_value, status_flag
FROM [IRPC_E_TRANSFER].dbo.ct_role_permission
WHERE permission_key IN ('data.pallet_management', 'data.pallet_adjustment')
ORDER BY role_id, department_id, permission_key;
