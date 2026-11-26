/* =====================================================================
   Put Away -> pProcessSyncJobAssigneeUser
   ---------------------------------------------------------------------
   Base: live on IRPC_QTRACK as of 2026-10-09.

   Only the Get Pallet procs called pProcessSyncJobAssigneeUser, so on a
   multi-forklift job a driver who only did Put Away never got written to
   tr_job_assigness.assignee_user_id (eg. job #763: TLWL-18 stayed NULL).

   Change (78): the 7 Put Away procs call
       EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id;
   right before each COMMIT TRANSACTION (all of them commit once on the
   success path; pProcessPickingPutAway has two success paths, both get
   it), so the fill is part of the same transaction as the scan.
   Nothing else in the procs changes. pProcessSyncJobAssigneeUser only
   fills rows whose assignee_user_id is still NULL (fCheckForkliftUser),
   so a row already holding a user is not changed.

   Procs (SHA2_256 of the definition before this change):
     pProcessInboundPutAway            3889FCAE010419FB301FDF0EC4AE5B7F42466DA78592ECE3030D5010B7E76808
     pProcessInternalTransferPutAway   6D632E63AD6A77C56C5B7D3EC4CFD211525F8A8D5761A14BA860EA7C1708EA4C
     pProcessLoadingPutAway            8BCFD2298C016D70112BA4A27391DDF98E541CF891057F7133E4C258702EB572
     pProcessPickingPutAway            7BBBC179A9CE3BDDF7A4F8E7EA0A306A214E1D23CB7B2D7A4BAEA249E476A63F
     pProcessRequestPutAway            54CFC67890B7289FD1EAF9C2041882580951EBF5B676821FEC60A9CE78A75569
     pProcessShippingPutAway           49B01475CEF6E8E2BDF7189FCE20A334EFD315D33F466B990628D49F5BFAB388
     pProcessSpecialPutAway            C432A43371EA9FBFB05DDD79B94C9E80C532C8682B986619386D355B6026A9B3

   The edit is applied to the live definition text (REPLACE), not from a
   copy in this repo, and is tagged with the marker below so the ROLLBACK
   section at the end removes exactly what was added. A proc that already
   calls pProcessSyncJobAssigneeUser is skipped.
   ===================================================================== */

-- ===================== APPLY =====================
DECLARE @marker NVARCHAR(100) = N'/* sql/78 */ EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id; ';
DECLARE @procs TABLE (name SYSNAME);
INSERT @procs VALUES
	(N'pProcessInboundPutAway'), (N'pProcessInternalTransferPutAway'), (N'pProcessLoadingPutAway'),
	(N'pProcessPickingPutAway'), (N'pProcessRequestPutAway'), (N'pProcessShippingPutAway'),
	(N'pProcessSpecialPutAway');

DECLARE @name SYSNAME, @def NVARCHAR(MAX), @pos INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @procs;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
	SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @name));

	IF @def IS NOT NULL AND @def NOT LIKE N'%pProcessSyncJobAssigneeUser%'
	BEGIN
		SET @def = REPLACE(@def, N'COMMIT TRANSACTION;', @marker + N'COMMIT TRANSACTION;');
		SET @pos = PATINDEX(N'%CREATE%PROC%[[]dbo]%', @def);
		SET @def = STUFF(@def, @pos, 6, N'CREATE OR ALTER');
		EXEC sys.sp_executesql @def;
		PRINT N'updated ' + @name;
	END
	ELSE
		PRINT N'skipped ' + @name;

	FETCH NEXT FROM c INTO @name;
END
CLOSE c;
DEALLOCATE c;
GO

/* ===================== ROLLBACK (run only to undo) =====================
DECLARE @marker NVARCHAR(100) = N'/* sql/78 */ EXEC dbo.pProcessSyncJobAssigneeUser @job_main_id, @user_id; ';
DECLARE @name SYSNAME, @def NVARCHAR(MAX), @pos INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
	SELECT o.name FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id
	WHERE m.definition LIKE N'%/* sql/78 */%';
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
	SET @def = REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @name)), @marker, N'');
	SET @pos = PATINDEX(N'%CREATE%PROC%[[]dbo]%', @def);
	-- the applied text already starts with CREATE OR ALTER
	IF SUBSTRING(@def, @pos, 15) <> N'CREATE OR ALTER'
		SET @def = STUFF(@def, @pos, 6, N'CREATE OR ALTER');
	EXEC sys.sp_executesql @def;
	PRINT N'rolled back ' + @name;
	FETCH NEXT FROM c INTO @name;
END
CLOSE c;
DEALLOCATE c;
   ===================================================================== */
