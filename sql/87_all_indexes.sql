/* =====================================================================
   All Indexes - IRPC_QTRACK
   -----------------------------------------------------------------
   Script ของ index ทั้งหมดใน DB (ดึงจาก sys.indexes ณ 2026-10-25)
   รวม 135 ตัว : PRIMARY KEY 58 , UNIQUE constraint 4 , index อื่น ๆ 73
   ครอบคลุม schema dbo และ HangFire

   - รันซ้ำได้ : ทุกตัวเช็ค IF NOT EXISTS ก่อน -> ตัวที่มีอยู่แล้วข้ามไป
     ไม่ DROP / ไม่ rebuild index เดิม
   - index บน tr_bag ที่อยู่บน partition scheme [ps_tr_bag_datetime]
     ต้องมี partition function/scheme นั้นก่อน (ดู script partition ของ tr_bag)
   - PK_tr_bag เป็น NONCLUSTERED, clustered index ของ tr_bag คือ
     CIX_tr_bag_create_datetime (ให้ PK สร้างก่อน CIX ตามลำดับในไฟล์)
   - ตาราง heap (ไม่มี PK) : tr_broken_bag_replace_detail, tr_broken_bag_status_log,
     tr_job_assigness, tr_special_history
   Dependencies: ตารางทั้งหมดต้องมีอยู่แล้ว
   ===================================================================== */
USE [IRPC_QTRACK]
GO

/* ---------------------------------------------------------------------
   dbo - master (ct_ / sys_)
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_auto_warehouse' AND object_id = OBJECT_ID(N'[dbo].[ct_auto_warehouse]'))
    ALTER TABLE [dbo].[ct_auto_warehouse] ADD CONSTRAINT [PK_ct_auto_warehouse] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ct_auto_warehouse_wh_code' AND object_id = OBJECT_ID(N'[dbo].[ct_auto_warehouse]'))
    ALTER TABLE [dbo].[ct_auto_warehouse] ADD CONSTRAINT [UQ_ct_auto_warehouse_wh_code] UNIQUE NONCLUSTERED ([wh_code] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__ct_bag_s__3213E83FF2ACF281' AND object_id = OBJECT_ID(N'[dbo].[ct_bag_status]'))
    ALTER TABLE [dbo].[ct_bag_status] ADD CONSTRAINT [PK__ct_bag_s__3213E83FF2ACF281] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_bg_plant_location' AND object_id = OBJECT_ID(N'[dbo].[ct_bg_plant_location]'))
    ALTER TABLE [dbo].[ct_bg_plant_location] ADD CONSTRAINT [PK_ct_bg_plant_location] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_cost_center' AND object_id = OBJECT_ID(N'[dbo].[ct_cost_center]'))
    ALTER TABLE [dbo].[ct_cost_center] ADD CONSTRAINT [PK_ct_cost_center] PRIMARY KEY CLUSTERED ([ID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_forklift' AND object_id = OBJECT_ID(N'[dbo].[ct_forklift]'))
    ALTER TABLE [dbo].[ct_forklift] ADD CONSTRAINT [PK_ct_forklift] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_grade_package_ratio' AND object_id = OBJECT_ID(N'[dbo].[ct_grade_package_ratio]'))
    ALTER TABLE [dbo].[ct_grade_package_ratio] ADD CONSTRAINT [PK_ct_grade_package_ratio] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ct_grade_package_ratio_grade' AND object_id = OBJECT_ID(N'[dbo].[ct_grade_package_ratio]'))
    ALTER TABLE [dbo].[ct_grade_package_ratio] ADD CONSTRAINT [UQ_ct_grade_package_ratio_grade] UNIQUE NONCLUSTERED ([grade] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_job_status' AND object_id = OBJECT_ID(N'[dbo].[ct_job_status]'))
    ALTER TABLE [dbo].[ct_job_status] ADD CONSTRAINT [PK_ct_job_status] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_pallet_status' AND object_id = OBJECT_ID(N'[dbo].[ct_pallet_status]'))
    ALTER TABLE [dbo].[ct_pallet_status] ADD CONSTRAINT [PK_ct_pallet_status] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ct_pallet_status_code' AND object_id = OBJECT_ID(N'[dbo].[ct_pallet_status]'))
    ALTER TABLE [dbo].[ct_pallet_status] ADD CONSTRAINT [UQ_ct_pallet_status_code] UNIQUE NONCLUSTERED ([code] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_process' AND object_id = OBJECT_ID(N'[dbo].[ct_process]'))
    ALTER TABLE [dbo].[ct_process] ADD CONSTRAINT [PK_ct_process] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_replace_location' AND object_id = OBJECT_ID(N'[dbo].[ct_replace_location]'))
    ALTER TABLE [dbo].[ct_replace_location] ADD CONSTRAINT [PK_ct_replace_location] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_special_location' AND object_id = OBJECT_ID(N'[dbo].[ct_special_location]'))
    ALTER TABLE [dbo].[ct_special_location] ADD CONSTRAINT [PK_ct_special_location] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_wh_cc_code' AND object_id = OBJECT_ID(N'[dbo].[ct_wh_cc_code]'))
    ALTER TABLE [dbo].[ct_wh_cc_code] ADD CONSTRAINT [PK_ct_wh_cc_code] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_ct_wms_cost_center' AND object_id = OBJECT_ID(N'[dbo].[ct_wms_cost_center]'))
    ALTER TABLE [dbo].[ct_wms_cost_center] ADD CONSTRAINT [PK_ct_wms_cost_center] PRIMARY KEY CLUSTERED ([ID] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__sys_pall__3213E83FC9F73193' AND object_id = OBJECT_ID(N'[dbo].[sys_pallet_scan_setting]'))
    ALTER TABLE [dbo].[sys_pallet_scan_setting] ADD CONSTRAINT [PK__sys_pall__3213E83FC9F73193] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_sys_pallet_scan_setting_pallet_type' AND object_id = OBJECT_ID(N'[dbo].[sys_pallet_scan_setting]'))
    ALTER TABLE [dbo].[sys_pallet_scan_setting] ADD CONSTRAINT [UQ_sys_pallet_scan_setting_pallet_type] UNIQUE NONCLUSTERED ([pallet_type] ASC);
GO

/* ---------------------------------------------------------------------
   dbo.tr_bag (partitioned on [ps_tr_bag_datetime] ([create_datetime]))
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_bag' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    ALTER TABLE [dbo].[tr_bag] ADD CONSTRAINT [PK_tr_bag] PRIMARY KEY NONCLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'CIX_tr_bag_create_datetime' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE CLUSTERED INDEX [CIX_tr_bag_create_datetime]
        ON [dbo].[tr_bag] ([create_datetime] ASC, [id] ASC)
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_cost_center_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_cost_center_lookup]
        ON [dbo].[tr_bag] ([cost_center] ASC, [create_datetime] ASC)
        INCLUDE ([is_active], [status_flag], [pallet_id], [grade], [qr_text_data])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_grade_cc_lot' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_grade_cc_lot]
        ON [dbo].[tr_bag] ([grade] ASC, [cost_center] ASC, [lot] ASC)
        INCLUDE ([is_active], [bag_status_id], [pallet_id], [bag_no], [ton_no], [pallet_running_no], [qr_text_data], [create_datetime], [status_flag]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_manual_status' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_manual_status]
        ON [dbo].[tr_bag] ([bag_status_id] ASC)
        INCLUDE ([qr_text_data], [pallet_id], [bag_no], [is_active], [status_flag])
        WHERE ([bag_status_id] IN ((3), (6)))
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_match_group' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_match_group]
        ON [dbo].[tr_bag] ([grade] ASC, [cost_center] ASC, [lot] ASC)
        INCLUDE ([is_active], [status_flag], [bag_status_id], [pallet_id], [bag_no], [pallet_running_no], [ton_no], [qr_text_data])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_match_status' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_match_status]
        ON [dbo].[tr_bag] ([is_active] ASC, [bag_status_id] ASC, [pallet_id] ASC)
        INCLUDE ([grade], [cost_center], [lot], [status_flag], [bag_no], [qr_text_data])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_pallet_id]
        ON [dbo].[tr_bag] ([pallet_id] ASC)
        INCLUDE ([grade], [is_active])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id_aligned' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_pallet_id_aligned]
        ON [dbo].[tr_bag] ([pallet_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([bag_no], [create_datetime])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id_covering' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_pallet_id_covering]
        ON [dbo].[tr_bag] ([pallet_id] ASC)
        INCLUDE ([grade], [lot], [is_active], [status_flag], [qr_text_data])
        ON [ps_tr_bag_datetime] ([create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pending_match' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_pending_match]
        ON [dbo].[tr_bag] ([grade] ASC, [cost_center] ASC, [lot] ASC)
        INCLUDE ([is_active], [status_flag], [create_datetime])
        WHERE ([pallet_id] IS NULL AND [bag_status_id]=(1));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_qr_text_data' AND object_id = OBJECT_ID(N'[dbo].[tr_bag]'))
    CREATE NONCLUSTERED INDEX [IX_tr_bag_qr_text_data]
        ON [dbo].[tr_bag] ([qr_text_data] ASC, [mode_id] ASC, [bag_status_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_bag_test' AND object_id = OBJECT_ID(N'[dbo].[tr_bag_test]'))
    ALTER TABLE [dbo].[tr_bag_test] ADD CONSTRAINT [PK_tr_bag_test] PRIMARY KEY NONCLUSTERED ([id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - broken bag
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_broke__3213E83FECD3026E' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_detail]'))
    ALTER TABLE [dbo].[tr_broken_bag_detail] ADD CONSTRAINT [PK__tr_broke__3213E83FECD3026E] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_detail_header' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_detail_header]
        ON [dbo].[tr_broken_bag_detail] ([header_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_broke__3213E83FE600CC70' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_header]'))
    ALTER TABLE [dbo].[tr_broken_bag_header] ADD CONSTRAINT [PK__tr_broke__3213E83FE600CC70] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_header_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_header]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_header_lookup]
        ON [dbo].[tr_broken_bag_header] ([report_location_id] ASC, [report_location_type] ASC, [do_no] ASC, [system_no] ASC, [create_datetime] ASC, [status_id] ASC, [is_active] ASC, [status_flag] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_header_wh_status' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_header]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_header_wh_status]
        ON [dbo].[tr_broken_bag_header] ([report_location_id] ASC, [report_location_type] ASC, [status_id] ASC, [is_active] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_broken_bag_reason' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_reason]'))
    ALTER TABLE [dbo].[tr_broken_bag_reason] ADD CONSTRAINT [PK_tr_broken_bag_reason] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_reason_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_reason]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_reason_header_id]
        ON [dbo].[tr_broken_bag_reason] ([header_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_replace_detail_header' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_replace_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_replace_detail_header]
        ON [dbo].[tr_broken_bag_replace_detail] ([header_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_status_log_header' AND object_id = OBJECT_ID(N'[dbo].[tr_broken_bag_status_log]'))
    CREATE NONCLUSTERED INDEX [IX_tr_broken_bag_status_log_header]
        ON [dbo].[tr_broken_bag_status_log] ([header_id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - delivery / forklift
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_shipment' AND object_id = OBJECT_ID(N'[dbo].[tr_delivery]'))
    ALTER TABLE [dbo].[tr_delivery] ADD CONSTRAINT [PK_tr_shipment] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_delivery_do_no' AND object_id = OBJECT_ID(N'[dbo].[tr_delivery]'))
    CREATE NONCLUSTERED INDEX [IX_tr_delivery_do_no]
        ON [dbo].[tr_delivery] ([do_no] ASC)
        INCLUDE ([id], [is_active], [status_flag]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_delivery_shipment_id' AND object_id = OBJECT_ID(N'[dbo].[tr_delivery]'))
    CREATE NONCLUSTERED INDEX [IX_tr_delivery_shipment_id]
        ON [dbo].[tr_delivery] ([shipment_id] ASC)
        INCLUDE ([id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_forklift_usage_1' AND object_id = OBJECT_ID(N'[dbo].[tr_forklift_usage]'))
    ALTER TABLE [dbo].[tr_forklift_usage] ADD CONSTRAINT [PK_tr_forklift_usage_1] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_forklift_usage_forklift' AND object_id = OBJECT_ID(N'[dbo].[tr_forklift_usage]'))
    CREATE NONCLUSTERED INDEX [IX_tr_forklift_usage_forklift]
        ON [dbo].[tr_forklift_usage] ([forklift_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([checkin_datetime], [checkout_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_forklift_usage_open' AND object_id = OBJECT_ID(N'[dbo].[tr_forklift_usage]'))
    CREATE NONCLUSTERED INDEX [IX_tr_forklift_usage_open]
        ON [dbo].[tr_forklift_usage] ([usage_user_id] ASC, [forklift_id] ASC)
        INCLUDE ([checkin_datetime])
        WHERE ([checkout_datetime] IS NULL);
GO

/* ---------------------------------------------------------------------
   dbo - internal transfer
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_internal_transfer_detail' AND object_id = OBJECT_ID(N'[dbo].[tr_internal_transfer_detail]'))
    ALTER TABLE [dbo].[tr_internal_transfer_detail] ADD CONSTRAINT [PK_tr_internal_transfer_detail] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_internal_transfer_detail_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_internal_transfer_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_internal_transfer_detail_header_id]
        ON [dbo].[tr_internal_transfer_detail] ([header_id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_internal_transfer_detail_location' AND object_id = OBJECT_ID(N'[dbo].[tr_internal_transfer_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_internal_transfer_detail_location]
        ON [dbo].[tr_internal_transfer_detail] ([job_location_id] ASC, [job_location_type] ASC)
        INCLUDE ([header_id], [grade_id], [grade], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_internal_transfer_header' AND object_id = OBJECT_ID(N'[dbo].[tr_internal_transfer_header]'))
    ALTER TABLE [dbo].[tr_internal_transfer_header] ADD CONSTRAINT [PK_tr_internal_transfer_header] PRIMARY KEY CLUSTERED ([id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - job
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_assigness_forklift' AND object_id = OBJECT_ID(N'[dbo].[tr_job_assigness]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_assigness_forklift]
        ON [dbo].[tr_job_assigness] ([assignee_forklift_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([job_main_id], [assignee_user_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_assigness_forklift_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_job_assigness]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_assigness_forklift_lookup]
        ON [dbo].[tr_job_assigness] ([job_main_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([assignee_forklift_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_job_location' AND object_id = OBJECT_ID(N'[dbo].[tr_job_from_location]'))
    ALTER TABLE [dbo].[tr_job_from_location] ADD CONSTRAINT [PK_tr_job_location] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_from_location_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_job_from_location]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_from_location_lookup]
        ON [dbo].[tr_job_from_location] ([job_main_id] ASC, [interface_job_item_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([from_location_id], [from_location_type], [qty], [actual_qty]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_job_main' AND object_id = OBJECT_ID(N'[dbo].[tr_job_main]'))
    ALTER TABLE [dbo].[tr_job_main] ADD CONSTRAINT [PK_tr_job_main] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_main_interface_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_job_main]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_main_interface_lookup]
        ON [dbo].[tr_job_main] ([job_type_id] ASC, [interface_job_id] ASC)
        INCLUDE ([job_status_id], [is_active], [status_flag]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_main_type_create' AND object_id = OBJECT_ID(N'[dbo].[tr_job_main]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_main_type_create]
        ON [dbo].[tr_job_main] ([job_type_id] ASC, [create_datetime] ASC)
        INCLUDE ([interface_job_id], [job_status_id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_job_to_location' AND object_id = OBJECT_ID(N'[dbo].[tr_job_to_location]'))
    ALTER TABLE [dbo].[tr_job_to_location] ADD CONSTRAINT [PK_tr_job_to_location] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_to_location_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_job_to_location]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_to_location_lookup]
        ON [dbo].[tr_job_to_location] ([job_main_id] ASC, [interface_job_item_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([to_location_id], [to_location_type], [qty], [actual_qty]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_job_total_pallet_snapshot' AND object_id = OBJECT_ID(N'[dbo].[tr_job_total_pallet_snapshot]'))
    ALTER TABLE [dbo].[tr_job_total_pallet_snapshot] ADD CONSTRAINT [PK_tr_job_total_pallet_snapshot] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_total_pallet_snapshot_job' AND object_id = OBJECT_ID(N'[dbo].[tr_job_total_pallet_snapshot]'))
    CREATE NONCLUSTERED INDEX [IX_tr_job_total_pallet_snapshot_job]
        ON [dbo].[tr_job_total_pallet_snapshot] ([job_main_id] ASC, [item_id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - loading / lot location
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_loadi__3213E83FD164182F' AND object_id = OBJECT_ID(N'[dbo].[tr_loading_detail]'))
    ALTER TABLE [dbo].[tr_loading_detail] ADD CONSTRAINT [PK__tr_loadi__3213E83FD164182F] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_loading_detail_delivery_id' AND object_id = OBJECT_ID(N'[dbo].[tr_loading_detail]'))
    CREATE UNIQUE NONCLUSTERED INDEX [IX_tr_loading_detail_delivery_id]
        ON [dbo].[tr_loading_detail] ([delivery_id] ASC)
        WHERE ([is_active]='Y' AND [status_flag]='A');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_loading_detail_loading_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_loading_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_loading_detail_loading_header_id]
        ON [dbo].[tr_loading_detail] ([header_id] ASC)
        INCLUDE ([delivery_id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_loading_header' AND object_id = OBJECT_ID(N'[dbo].[tr_loading_header]'))
    ALTER TABLE [dbo].[tr_loading_header] ADD CONSTRAINT [PK_tr_loading_header] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_lot_location' AND object_id = OBJECT_ID(N'[dbo].[tr_lot_location]'))
    ALTER TABLE [dbo].[tr_lot_location] ADD CONSTRAINT [PK_tr_lot_location] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_lot_location_from_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_lot_location]'))
    CREATE NONCLUSTERED INDEX [IX_tr_lot_location_from_lookup]
        ON [dbo].[tr_lot_location] ([job_main_id] ASC, [job_item_id] ASC, [job_location_type] ASC, [job_location_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([lot_no], [id]);
GO

/* ---------------------------------------------------------------------
   dbo - pallet
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_palle__3213E83F25F1C3D7' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    ALTER TABLE [dbo].[tr_pallet] ADD CONSTRAINT [PK__tr_palle__3213E83F25F1C3D7] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_active' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_active]
        ON [dbo].[tr_pallet] ([is_active] ASC)
        INCLUDE ([pallet_no], [pallet_type], [pd_group_code], [pd_type_code], [unit_ratio], [unit_pallet], [current_job_id], [current_location_type], [current_location_id], [pallet_status_id], [create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_current_location' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_current_location]
        ON [dbo].[tr_pallet] ([current_location_type] ASC, [current_location_id] ASC)
        INCLUDE ([is_active], [status_flag], [pallet_no], [unit_ratio], [create_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_fGetPalletNo' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_fGetPalletNo]
        ON [dbo].[tr_pallet] ([create_datetime] ASC, [pallet_type] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_lookup_covering' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_lookup_covering]
        ON [dbo].[tr_pallet] ([id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([pallet_no], [pd_group_code], [pd_type_code]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_pallet_no' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_pallet_no]
        ON [dbo].[tr_pallet] ([pallet_no] ASC)
        INCLUDE ([is_active], [status_flag], [pallet_type]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_ref' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_ref]
        ON [dbo].[tr_pallet] ([ref_pallet] ASC)
        INCLUDE ([pallet_no], [pallet_type], [status_flag], [is_active], [inbound_to_wh_id], [unit_pallet], [pallet_status_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_ref_pallet' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_ref_pallet]
        ON [dbo].[tr_pallet] ([ref_pallet] ASC)
        INCLUDE ([pallet_type], [status_flag], [is_active], [inbound_to_wh_id], [pallet_no]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_type_createdatetime' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_type_createdatetime]
        ON [dbo].[tr_pallet] ([pallet_type] ASC, [create_datetime] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_tr_pallet_pallet_no' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet]'))
    CREATE UNIQUE NONCLUSTERED INDEX [UX_tr_pallet_pallet_no]
        ON [dbo].[tr_pallet] ([pallet_no] ASC)
        WHERE ([pallet_no] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_pallet_history' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    ALTER TABLE [dbo].[tr_pallet_history] ADD CONSTRAINT [PK_tr_pallet_history] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_create_dt' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_history_create_dt]
        ON [dbo].[tr_pallet_history] ([create_datetime] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_filtering' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_history_filtering]
        ON [dbo].[tr_pallet_history] ([is_active] ASC, [status_flag] ASC, [job_main_id] ASC, [job_item_id] ASC, [pallet_id] ASC, [process_id] ASC, [create_datetime] ASC)
        INCLUDE ([id], [pallet_seq], [bag_id], [location_type], [location_id], [create_user_id], [update_user_id], [update_datetime]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_filtering_bag' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_history_filtering_bag]
        ON [dbo].[tr_pallet_history] ([is_active] ASC, [status_flag] ASC, [job_main_id] ASC, [job_item_id] ASC, [pallet_id] ASC, [bag_id] ASC, [process_id] ASC, [create_datetime] ASC)
        INCLUDE ([id], [pallet_seq], [location_type], [location_id], [create_user_id], [update_user_id], [update_datetime])
        WHERE ([bag_id] IS NOT NULL);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_pallet_lookup' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_history_pallet_lookup]
        ON [dbo].[tr_pallet_history] ([job_main_id] ASC, [job_item_id] ASC, [pallet_id] ASC, [process_id] ASC, [create_datetime] DESC)
        INCLUDE ([location_id], [location_type], [create_user_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_pallet_history_archive' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history_archive]'))
    ALTER TABLE [dbo].[tr_pallet_history_archive] ADD CONSTRAINT [PK_tr_pallet_history_archive] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'idx_tr_pallet_history_archive_job_main_id' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history_archive]'))
    CREATE NONCLUSTERED INDEX [idx_tr_pallet_history_archive_job_main_id]
        ON [dbo].[tr_pallet_history_archive] ([job_main_id] ASC, [job_item_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_palle__3213E83F4CFB5877' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_manual_item]'))
    ALTER TABLE [dbo].[tr_pallet_manual_item] ADD CONSTRAINT [PK__tr_palle__3213E83F4CFB5877] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_manual_item_item' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_manual_item]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_manual_item_item]
        ON [dbo].[tr_pallet_manual_item] ([wms_plus_item_id] ASC, [job_type_id] ASC)
        INCLUDE ([pallet_id], [is_active], [status_flag]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_manual_item_pallet_id_wms' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_manual_item]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_manual_item_pallet_id_wms]
        ON [dbo].[tr_pallet_manual_item] ([pallet_id] ASC)
        INCLUDE ([wms_plus_item_id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_tr_pallet_manual_item_pallet_id' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_manual_item]'))
    CREATE UNIQUE NONCLUSTERED INDEX [UQ_tr_pallet_manual_item_pallet_id]
        ON [dbo].[tr_pallet_manual_item] ([pallet_id] ASC)
        WHERE ([pallet_id] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_palle__99AF8959042743D0' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_reset_snapshot]'))
    ALTER TABLE [dbo].[tr_pallet_reset_snapshot] ADD CONSTRAINT [PK__tr_palle__99AF8959042743D0] PRIMARY KEY CLUSTERED ([pallet_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_palle__3213E83F25F1C3D' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_test]'))
    ALTER TABLE [dbo].[tr_pallet_test] ADD CONSTRAINT [PK__tr_palle__3213E83F25F1C3D] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_test_pallet_no' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_test]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_test_pallet_no]
        ON [dbo].[tr_pallet_test] ([wms_plus_manual_item_id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - picking / shipment / shipping
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_picki__3213E83F1483FD6E' AND object_id = OBJECT_ID(N'[dbo].[tr_picking_detail]'))
    ALTER TABLE [dbo].[tr_picking_detail] ADD CONSTRAINT [PK__tr_picki__3213E83F1483FD6E] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_picking_detail_delivery_id' AND object_id = OBJECT_ID(N'[dbo].[tr_picking_detail]'))
    CREATE UNIQUE NONCLUSTERED INDEX [IX_tr_picking_detail_delivery_id]
        ON [dbo].[tr_picking_detail] ([delivery_id] ASC)
        WHERE ([is_active]='Y' AND [status_flag]='A');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_picking_detail_picking_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_picking_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_picking_detail_picking_header_id]
        ON [dbo].[tr_picking_detail] ([header_id] ASC)
        INCLUDE ([delivery_id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_picking_header' AND object_id = OBJECT_ID(N'[dbo].[tr_picking_header]'))
    ALTER TABLE [dbo].[tr_picking_header] ADD CONSTRAINT [PK_tr_picking_header] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_shipm__3213E83F13F4D6D4' AND object_id = OBJECT_ID(N'[dbo].[tr_shipment]'))
    ALTER TABLE [dbo].[tr_shipment] ADD CONSTRAINT [PK__tr_shipm__3213E83F13F4D6D4] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_shipment_shipment_no' AND object_id = OBJECT_ID(N'[dbo].[tr_shipment]'))
    CREATE UNIQUE NONCLUSTERED INDEX [IX_tr_shipment_shipment_no]
        ON [dbo].[tr_shipment] ([shipment_no] ASC)
        WHERE ([status_flag]='A' AND [is_active]='Y');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK__tr_shipp__3213E83FE5736E82' AND object_id = OBJECT_ID(N'[dbo].[tr_shipping_detail]'))
    ALTER TABLE [dbo].[tr_shipping_detail] ADD CONSTRAINT [PK__tr_shipp__3213E83FE5736E82] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_shipping_detail_delivery_id' AND object_id = OBJECT_ID(N'[dbo].[tr_shipping_detail]'))
    CREATE UNIQUE NONCLUSTERED INDEX [IX_tr_shipping_detail_delivery_id]
        ON [dbo].[tr_shipping_detail] ([delivery_id] ASC)
        WHERE ([is_active]='Y' AND [status_flag]='A');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_shipping_detail_shipping_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_shipping_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_shipping_detail_shipping_header_id]
        ON [dbo].[tr_shipping_detail] ([header_id] ASC)
        INCLUDE ([delivery_id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_shipping_header' AND object_id = OBJECT_ID(N'[dbo].[tr_shipping_header]'))
    ALTER TABLE [dbo].[tr_shipping_header] ADD CONSTRAINT [PK_tr_shipping_header] PRIMARY KEY CLUSTERED ([id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - special
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_special_detail' AND object_id = OBJECT_ID(N'[dbo].[tr_special_detail]'))
    ALTER TABLE [dbo].[tr_special_detail] ADD CONSTRAINT [PK_tr_special_detail] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_detail_aggregation' AND object_id = OBJECT_ID(N'[dbo].[tr_special_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_special_detail_aggregation]
        ON [dbo].[tr_special_detail] ([item_id] ASC, [is_active] ASC, [status_flag] ASC)
        INCLUDE ([qty], [id]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_detail_item_id' AND object_id = OBJECT_ID(N'[dbo].[tr_special_detail]'))
    CREATE NONCLUSTERED INDEX [IX_tr_special_detail_item_id]
        ON [dbo].[tr_special_detail] ([item_id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_special_header' AND object_id = OBJECT_ID(N'[dbo].[tr_special_header]'))
    ALTER TABLE [dbo].[tr_special_header] ADD CONSTRAINT [PK_tr_special_header] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_history_create_dt' AND object_id = OBJECT_ID(N'[dbo].[tr_special_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_special_history_create_dt]
        ON [dbo].[tr_special_history] ([create_user_datetime] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_history_detail' AND object_id = OBJECT_ID(N'[dbo].[tr_special_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_special_history_detail]
        ON [dbo].[tr_special_history] ([special_detail_id] ASC)
        INCLUDE ([bag_id], [is_active], [status_flag]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_special_history_archive' AND object_id = OBJECT_ID(N'[dbo].[tr_special_history_archive]'))
    ALTER TABLE [dbo].[tr_special_history_archive] ADD CONSTRAINT [PK_tr_special_history_archive] PRIMARY KEY CLUSTERED ([id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_special_item' AND object_id = OBJECT_ID(N'[dbo].[tr_special_item]'))
    ALTER TABLE [dbo].[tr_special_item] ADD CONSTRAINT [PK_tr_special_item] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_item_delivery_id' AND object_id = OBJECT_ID(N'[dbo].[tr_special_item]'))
    CREATE UNIQUE NONCLUSTERED INDEX [IX_tr_special_item_delivery_id]
        ON [dbo].[tr_special_item] ([delivery_id] ASC)
        WHERE ([delivery_id] IS NOT NULL AND [is_active]='Y' AND [status_flag]='A');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_item_header_id' AND object_id = OBJECT_ID(N'[dbo].[tr_special_item]'))
    CREATE NONCLUSTERED INDEX [IX_tr_special_item_header_id]
        ON [dbo].[tr_special_item] ([header_id] ASC);
GO

/* ---------------------------------------------------------------------
   dbo - log
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_transaction_log' AND object_id = OBJECT_ID(N'[dbo].[tr_transaction_log]'))
    ALTER TABLE [dbo].[tr_transaction_log] ADD CONSTRAINT [PK_tr_transaction_log] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_transaction_log_update_dt' AND object_id = OBJECT_ID(N'[dbo].[tr_transaction_log]'))
    CREATE NONCLUSTERED INDEX [IX_tr_transaction_log_update_dt]
        ON [dbo].[tr_transaction_log] ([update_datetime] DESC)
        INCLUDE ([topic], [activity], [create_user_id], [create_datetime], [update_user_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_tr_wms_plus_interface_log' AND object_id = OBJECT_ID(N'[dbo].[tr_wms_plus_interface_log]'))
    ALTER TABLE [dbo].[tr_wms_plus_interface_log] ADD CONSTRAINT [PK_tr_wms_plus_interface_log] PRIMARY KEY CLUSTERED ([id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NonClusteredIndex-20261005-154524' AND object_id = OBJECT_ID(N'[dbo].[tr_wms_plus_interface_log]'))
    CREATE NONCLUSTERED INDEX [NonClusteredIndex-20261005-154524]
        ON [dbo].[tr_wms_plus_interface_log] ([job_main_id] ASC, [mode] ASC, [is_success] ASC);
GO

/* ---------------------------------------------------------------------
   HangFire (ปกติ HangFire สร้างเองตอน start -- ใส่ไว้ให้ครบ)
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_CounterAggregated' AND object_id = OBJECT_ID(N'[HangFire].[AggregatedCounter]'))
    ALTER TABLE [HangFire].[AggregatedCounter] ADD CONSTRAINT [PK_HangFire_CounterAggregated] PRIMARY KEY CLUSTERED ([Key] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_AggregatedCounter_ExpireAt' AND object_id = OBJECT_ID(N'[HangFire].[AggregatedCounter]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_AggregatedCounter_ExpireAt]
        ON [HangFire].[AggregatedCounter] ([ExpireAt] ASC)
        WHERE ([ExpireAt] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Counter' AND object_id = OBJECT_ID(N'[HangFire].[Counter]'))
    ALTER TABLE [HangFire].[Counter] ADD CONSTRAINT [PK_HangFire_Counter] PRIMARY KEY CLUSTERED ([Key] ASC, [Id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Hash' AND object_id = OBJECT_ID(N'[HangFire].[Hash]'))
    ALTER TABLE [HangFire].[Hash] ADD CONSTRAINT [PK_HangFire_Hash] PRIMARY KEY CLUSTERED ([Key] ASC, [Field] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Hash_ExpireAt' AND object_id = OBJECT_ID(N'[HangFire].[Hash]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Hash_ExpireAt]
        ON [HangFire].[Hash] ([ExpireAt] ASC)
        WHERE ([ExpireAt] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Job' AND object_id = OBJECT_ID(N'[HangFire].[Job]'))
    ALTER TABLE [HangFire].[Job] ADD CONSTRAINT [PK_HangFire_Job] PRIMARY KEY CLUSTERED ([Id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Job_ExpireAt' AND object_id = OBJECT_ID(N'[HangFire].[Job]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Job_ExpireAt]
        ON [HangFire].[Job] ([ExpireAt] ASC)
        INCLUDE ([StateName])
        WHERE ([ExpireAt] IS NOT NULL);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Job_StateName' AND object_id = OBJECT_ID(N'[HangFire].[Job]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Job_StateName]
        ON [HangFire].[Job] ([StateName] ASC)
        WHERE ([StateName] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_JobParameter' AND object_id = OBJECT_ID(N'[HangFire].[JobParameter]'))
    ALTER TABLE [HangFire].[JobParameter] ADD CONSTRAINT [PK_HangFire_JobParameter] PRIMARY KEY CLUSTERED ([JobId] ASC, [Name] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_JobQueue' AND object_id = OBJECT_ID(N'[HangFire].[JobQueue]'))
    ALTER TABLE [HangFire].[JobQueue] ADD CONSTRAINT [PK_HangFire_JobQueue] PRIMARY KEY CLUSTERED ([Queue] ASC, [Id] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_List' AND object_id = OBJECT_ID(N'[HangFire].[List]'))
    ALTER TABLE [HangFire].[List] ADD CONSTRAINT [PK_HangFire_List] PRIMARY KEY CLUSTERED ([Key] ASC, [Id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_List_ExpireAt' AND object_id = OBJECT_ID(N'[HangFire].[List]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_List_ExpireAt]
        ON [HangFire].[List] ([ExpireAt] ASC)
        WHERE ([ExpireAt] IS NOT NULL);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Schema' AND object_id = OBJECT_ID(N'[HangFire].[Schema]'))
    ALTER TABLE [HangFire].[Schema] ADD CONSTRAINT [PK_HangFire_Schema] PRIMARY KEY CLUSTERED ([Version] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Server' AND object_id = OBJECT_ID(N'[HangFire].[Server]'))
    ALTER TABLE [HangFire].[Server] ADD CONSTRAINT [PK_HangFire_Server] PRIMARY KEY CLUSTERED ([Id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Server_LastHeartbeat' AND object_id = OBJECT_ID(N'[HangFire].[Server]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Server_LastHeartbeat]
        ON [HangFire].[Server] ([LastHeartbeat] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_Set' AND object_id = OBJECT_ID(N'[HangFire].[Set]'))
    ALTER TABLE [HangFire].[Set] ADD CONSTRAINT [PK_HangFire_Set] PRIMARY KEY CLUSTERED ([Key] ASC, [Value] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Set_ExpireAt' AND object_id = OBJECT_ID(N'[HangFire].[Set]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Set_ExpireAt]
        ON [HangFire].[Set] ([ExpireAt] ASC)
        WHERE ([ExpireAt] IS NOT NULL);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_Set_Score' AND object_id = OBJECT_ID(N'[HangFire].[Set]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_Set_Score]
        ON [HangFire].[Set] ([Key] ASC, [Score] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'PK_HangFire_State' AND object_id = OBJECT_ID(N'[HangFire].[State]'))
    ALTER TABLE [HangFire].[State] ADD CONSTRAINT [PK_HangFire_State] PRIMARY KEY CLUSTERED ([JobId] ASC, [Id] ASC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HangFire_State_CreatedAt' AND object_id = OBJECT_ID(N'[HangFire].[State]'))
    CREATE NONCLUSTERED INDEX [IX_HangFire_State_CreatedAt]
        ON [HangFire].[State] ([CreatedAt] ASC);
GO
