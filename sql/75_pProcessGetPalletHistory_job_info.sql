/* =====================================================================
   pProcessGetPalletHistory -- job status, job times, forklift
   ---------------------------------------------------------------------
   Base: sql/74. Backs GET api/v1/process/pallet/history (Pallet History
   on the Pallet Information page).

   Change (75): adds job information to every event (each timeline row
   shows its own job, operator and forklift):
     - job_status_id, job_status_name     (tr_job_main + ct_job_status)
     - job_start_datetime, job_end_datetime (tr_job_main)
     - forklift_id, forklift_name         the forklift assigned to the
       user who scanned the event (tr_job_assigness + ct_forklift). For a
       single-forklift job with no assignment for that user, the job's
       forklift is used; a multi-forklift job then returns NULL.
   Job document numbers (system_no) are still not returned: they come
   from the per-job-type TVFs (fReceiveJob, fTransferSlipJob, ...), which
   took ~12 s for a pallet with 173 jobs.

   Source: tr_pallet_history plus tr_pallet_history_archive (rows older
   than 90 days are moved there daily by pServiceArchivePalletHistory).
   Rows are grouped into one event per (job, job item, process, location)
   so a repeated scan of the same step shows once, at its first time.

   Result sets (same shape as the other process/* list procs):
     dbResult   status, message
     dbResult1  every event of the pallet, newest first (not paginated --
                the page shows the whole timeline)
     dbResult2  total_count (events, not raw rows)

   location_name is resolved here for every type except MWH, whose names
   live in WMS Plus -- the API fills those from location_type_code +
   location_id, the same way as for pProcessGetPalletList.
   ===================================================================== */
GO
CREATE OR ALTER PROC [dbo].[pProcessGetPalletHistory]
	@pallet_id				INT						= NULL
AS
BEGIN
	SET NOCOUNT ON

	IF @pallet_id IS NULL
	BEGIN
		SELECT 'error' AS status, 'pallet_id is required.' AS message
		RETURN
	END

	-- =============================================================
	-- 1. One row per event (live + archived history).
	-- =============================================================

	IF OBJECT_ID('tempdb..#events') IS NOT NULL
		DROP TABLE #events

	SELECT
		h.job_main_id,
		h.job_item_id,
		h.process_id,
		h.location_type,
		h.location_id,
		MIN(h.create_datetime) AS event_datetime,
		MIN(h.create_user_id) AS create_user_id
	INTO #events
	FROM (
		SELECT job_main_id, job_item_id, process_id, location_type, location_id, create_user_id, create_datetime
		FROM dbo.tr_pallet_history
		WHERE pallet_id = @pallet_id
			AND is_active = 'Y'
			AND status_flag = 'A'
		UNION ALL
		SELECT job_main_id, job_item_id, process_id, location_type, location_id, create_user_id, create_datetime
		FROM dbo.tr_pallet_history_archive
		WHERE pallet_id = @pallet_id
			AND is_active = 'Y'
			AND status_flag = 'A'
	) h
	GROUP BY h.job_main_id, h.job_item_id, h.process_id, h.location_type, h.location_id

	-- =============================================================
	-- Return status and message based on data retrieval result.
	-- =============================================================

	SELECT 'success' AS status,
		   CASE WHEN EXISTS (SELECT 1 FROM #events) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message

	-- =============================================================
	-- 2. All events, newest first: process, job type, location, user.
	-- =============================================================

	SELECT
		pg.event_datetime,
		pg.process_id,
		cp.name AS process_name,
		pg.job_main_id,
		pg.job_item_id,
		jm.job_type_id,
		cjt.short_name AS job_type_short_name,
		cjt.name AS job_type_name,
		jm.job_status_id,
		cjs.name AS job_status_name,
		jm.start_datetime AS job_start_datetime,
		jm.end_datetime AS job_end_datetime,
		fk.forklift_id,
		fk.forklift_name,
		pg.location_type AS location_type_code,
		COALESCE(clt.name, pg.location_type) AS location_type,
		pg.location_id,
		COALESCE(
			MAX(cpl.bg_plant_desc COLLATE DATABASE_DEFAULT),
			MAX(rqcc.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(csz.zone_name COLLATE DATABASE_DEFAULT),
			MAX(csl.cc_desc COLLATE DATABASE_DEFAULT),
			MAX(sd.dock_name COLLATE DATABASE_DEFAULT),
			MAX(vm.VEHICLE COLLATE DATABASE_DEFAULT)
		) AS location_name,
		pg.create_user_id,
		MAX(ul.user_name COLLATE DATABASE_DEFAULT) AS create_user_name,
		MAX(ul.Thia_name COLLATE DATABASE_DEFAULT) AS create_user_thai_name,
		MAX(ul.eng_name COLLATE DATABASE_DEFAULT) AS create_user_eng_name
	FROM #events pg
	LEFT JOIN dbo.ct_process cp
		ON cp.id = pg.process_id
	LEFT JOIN dbo.tr_job_main jm
		ON jm.id = pg.job_main_id
	LEFT JOIN dbo.ct_job_type cjt
		ON cjt.id = jm.job_type_id
	LEFT JOIN dbo.ct_job_status cjs
		ON cjs.id = jm.job_status_id
	OUTER APPLY (
		SELECT TOP 1
			cf.id AS forklift_id,
			cf.name AS forklift_name
		FROM dbo.tr_job_assigness ja
		INNER JOIN dbo.ct_forklift cf
			ON cf.id = ja.assignee_forklift_id
		WHERE ja.job_main_id = pg.job_main_id
			AND (ja.assignee_user_id = pg.create_user_id OR jm.is_multi_forklift = 'N')
			AND ja.is_active = 'Y'
			AND ja.status_flag = 'A'
		ORDER BY CASE WHEN ja.assignee_user_id = pg.create_user_id THEN 0 ELSE 1 END, ja.id DESC
	) fk
	LEFT JOIN dbo.ct_location_type clt
		ON clt.code = pg.location_type
		AND clt.is_active = 'Y'
		AND clt.status_flag = 'A'
	LEFT JOIN dbo.ct_bg_plant_location cpl
		ON cpl.id = pg.location_id
		AND cpl.is_active = 'Y'
		AND cpl.status_flag = 'A'
		AND pg.location_type = 'BG-PLANT'
	LEFT JOIN IRPC_E_TRANSFER.dbo.ct_request_cost_center rqcc
		ON rqcc.id = pg.location_id
		AND rqcc.is_active = 'Y'
		AND rqcc.status_flag = 'A'
		AND pg.location_type = 'RQ-PLANT'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_dock] sd
		ON sd.id = pg.location_id
		AND sd.is_active = 'Y'
		AND sd.status_flag = 'A'
		AND pg.location_type = 'DOCK'
	LEFT JOIN [IRPC].[dbo].[ct_strorage_zone] csz
		ON csz.id = pg.location_id
		AND csz.is_active = 'Y'
		AND csz.status_flag = 'A'
		AND pg.location_type = 'PRE-ZONE'
	LEFT JOIN dbo.ct_special_location csl
		ON csl.id = pg.location_id
		AND csl.is_active = 'Y'
		AND csl.status_flag = 'A'
		AND pg.location_type = 'SPC-ZONE'
	LEFT JOIN [IRPC].[dbo].[VVehicleMaster] vm
		ON vm.vechicle_id = pg.location_id
		AND pg.location_type = 'VEHICLE'
	LEFT JOIN [IRPC_E_TRANSFER].dbo.ct_user_login ul
		ON ul.ID = pg.create_user_id
		AND ul.status_flag = 'A'
	GROUP BY pg.event_datetime, pg.process_id, cp.name, pg.job_main_id, pg.job_item_id, jm.job_type_id, cjt.short_name, cjt.name,
		jm.job_status_id, cjs.name, jm.start_datetime, jm.end_datetime, fk.forklift_id, fk.forklift_name,
		pg.location_type, clt.name, pg.location_id, pg.create_user_id
	ORDER BY pg.event_datetime DESC, pg.job_main_id DESC, pg.process_id DESC

	-- =============================================================
	-- total_count -- events, not raw history rows.
	-- =============================================================

	SELECT COUNT(*) AS total_count FROM #events
END
GO
