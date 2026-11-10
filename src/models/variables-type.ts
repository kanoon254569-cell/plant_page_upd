//  Standard Response Syntax
export interface ResponseStandard {
  status: string;
  message: string;
  result: any;
}

//  Get user
export interface ResponseLogin {
  status: string;
  message: any;
  token: string;
  refreshToken: string;
}

export interface LastSelection {
  orgId: number;
  type: number;
  year: number;
  month: number;
}

// =====================================================================
//  Filter
// =====================================================================

export interface VehicleFilter {
  licensePlate?: string;
  carrierName?: string;
  vehicleType?: string;
  isActive?: string;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface PalletFilter {
  palletNo?: string;
  grade?: string;
  lot?: string;
  locationType?: string;
  locationId?: number;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface ForkliftFilter {
  forkliftName?: string;
  licensePlate?: string;
  whCodes?: string[];
  sectionIds?: string[];
  isActive?: string;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface UserFilter {
  userName?: string;
  thaiName?: string;
  engName?: string;
  departmentId?: number;
  roleId?: number;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface RoleFilter {
  roleName?: string;
  details?: string;
  isActive?: string;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface JobFilter {
  systemNo?: string;
  //  Create-date range (inclusive) from the วันที่ range picker; either end
  //  may be null -- the API then uses the other end for both.
  dateFrom?: Date | null;
  dateTo?: Date | null;
  //  Multi-select filters -- an empty array means "ทั้งหมด".
  fromCcCodes?: string[];
  toCcCodes?: string[];
  fromLocations?: JobLocationFilter[];
  toLocations?: JobLocationFilter[];
  productCcs?: string[];
  toWhCodes?: string[];
  jobStatuses?: number[];
  jobInbound?: boolean;
  jobOutbound?: boolean;
  //  Fixed type for pages without the Job Type tabs (job-shipping-list = 5).
  jobType?: number;
  //  Job Type tabs (multi-select) -- empty = ทั้งหมด.
  jobTypes?: number[];
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface TransactionLogFilter {
  topic?: string;
  activity?: string;
  detail?: string;
  editor?: number;
  modifiedDate?: string;
  page?: number;
  pageSize?: number;
}

// =====================================================================
//  Process
// =====================================================================

export interface ResponseProcessGetVehicle {
  status: string;
  message: any;
  data: ResultProcessGetVehicle[];
  total_count: number;
}

export interface ResultProcessGetVehicle {
  vehicle_id: number;
  license_plate: string;
  vehicle_text: string;
  created_date: string;
  changed_date: string | null;
  valid_plate: string;
  valid_insurance: string;
  rfid_card: string;
  valid_rfid: string;
  is_active: string;
  changed_date1: string;
  carrier_id: number;
  carrier_code: string;
  carrier_name: string;
  vehicle_type_desc: string;
  vehicle_group_desc: string;
}

export interface ResponseProcessGetUser {
  status: string;
  message: any;
  data: ResultProcessGetUser[];
  total_count: number;
}

export interface ResultProcessGetUser {
  id: number;
  user_id: string;
  user_name: string;
  password: string;
  department_id: number;
  department_name: string;
  role_id: number;
  role_name: string;
  user_type_id: number;
  thai_name: string;
  eng_name: string;
  emp_id: string | null;
  carrier_name: string | null;
  is_local: string;
  is_ad: string;
  is_ldl: string;
  last_active_datetime: string;
  last_update_datetime: string;
}

export interface ResponseProcessGetRole {
  status: string;
  message: any;
  data: ResultProcessGetRole[];
  total_count: number;
}

export interface ResultProcessGetRole {
  id: number;
  idx: number;
  role_name: string;
  role_description: string;
  is_active: string;
  create_user_id: number;
  create_datetime: string;
  last_update_user_id: number;
  last_update_datetime: string;
  user_count: number;
}

export interface ResponseProcessGetRolePermission {
  status: string;
  message: any;
  data: ResultRolePermission[];
}

//  GET master/me/permission -- granted keys, e.g. ["data.user_management", "user.delete"]
export interface ResponseProcessGetMyPermission {
  status: string;
  message: any;
  data: string[];
}

export interface ResultRolePermission {
  department_id: number;
  permission_key: string;
  permission_value: string;
}

export interface ResponseProcessTransactionLogData {
  status: string;
  message: any;
  data: ResultProcessTransactionLogData[];
  total_count: number;
}

export interface ResultProcessTransactionLogData {
  topic: string;
  activity: string;
  detail: string;
  create_user_name: string;
  create_datetime: string;
}

export interface WmsInterfaceLogFilter {
  mode?: string;
  keyword?: string;
  status?: string;
  page?: number;
  pageSize?: number;
}

export interface ResponseProcessWmsInterfaceLogData {
  status: string;
  message: any;
  data: ResultProcessWmsInterfaceLogData[];
  total_count: number;
  summary: ResultProcessWmsInterfaceLogSummary[];
}

export interface ResultProcessWmsInterfaceLogData {
  id: number;
  mode: string;
  method: string;
  route: string;
  tr_tran_no: string | null;
  wh_code: string | null;
  qr_count: number;
  pallet_count: number | null;
  pallet_from: number | null;
  pallet_to: number | null;
  total_qty: number | null;
  unit: string | null;
  grade_list: string | null;
  lot_list: string | null;
  status_code: string | null;
  //  'success' (HTTP 2xx) | 'error' | 'pending' (WMS has not answered)
  result_status: string;
  return_message: string | null;
  create_datetime: string;
  execute_datetime: string | null;
  duration_ms: number | null;
}

export interface ResponseProcessWmsInterfaceLogDetail {
  status: string;
  message: any;
  data: ResultProcessWmsInterfaceLogDetailHeader[];
  pallets: ResultProcessWmsInterfaceLogPallet[];
  qr_list: ResultProcessWmsInterfaceLogQr[];
}

export interface ResultProcessWmsInterfaceLogDetailHeader {
  id: number;
  mode: string;
  route: string;
  tr_tran_no: string | null;
  wh_code: string | null;
  rc_type: string | null;
  status_code: string | null;
  result_status: string;
  return_code: string | null;
  return_message: string | null;
  create_datetime: string;
  execute_datetime: string | null;
  duration_ms: number | null;
  param: string | null;
  message: string | null;
}

export interface ResultProcessWmsInterfaceLogPallet {
  pallet_no: number;
  grade: string | null;
  lot: string | null;
  qr_count: number;
  bag_from: number | null;
  bag_to: number | null;
  //  Bag numbers missing inside bag_from..bag_to
  missing_bag: number | null;
  total_qty: number | null;
  unit: string | null;
}

export interface ResultProcessWmsInterfaceLogQr {
  seq: number;
  pallet_no: number;
  bag_no: number | null;
  qr_text: string;
  qty: number | null;
  unit: string | null;
  cc: string | null;
  //  Earlier SUCCESS round of the same slip that already carried this QR
  sent_before_id: number | null;
}

export interface ResultProcessWmsInterfaceLogSummary {
  total_round: number;
  success_round: number;
  error_round: number;
  pending_round: number;
  total_qr: number;
  success_qr: number;
}

export interface ResponseProcessPalletListData {
  status: string;
  message: string;
  data: ResultProcessPalletListData[];
  total_count: number;
}

export interface ResultProcessPalletListData {
  id: number;
  pallet_no: string;
  grade: string;
  lot: string;
  pallet_type: any;
  current_location: any;
  unit_pallet: any;
  qty: any;
  create_datetime: string;
}

export interface ResponseProcessPalletListByLocation {
  status: string;
  message: string;
  data: ResultProcessPalletListByLocation[];
  total_count: number;
}

export interface ResultProcessPalletListByLocation {
  id: number;
  pallet_no: string;
  grade: string;
  lot: string;
  qty: any;
  text: string;
  scanned_qr_code: string;
  create_datetime: string;
}

//  GET pallet-management/dummy (pProcessGetDummyPalletList, sql/107_)
export interface ResponseProcessDummyPalletList {
  status: string;
  message: string;
  data: ResultProcessDummyPallet[];
  total_count: number;
}

export interface ResultProcessDummyPallet {
  id: number;
  pallet_no: string;
  current_location_id: number | null;
  location_type: string;
  location_type_code: string | null;
  current_location: string | null;
  current_job_id: number | null;
  bag_count: number;
  //  A dummy pallet holds one Grade / Lot only (NULL while empty)
  grade: string | null;
  lot: string | null;
  //  ct_grade_package_ratio.unit_ratio of the grade; qty = bag_count x unit_ratio (kg)
  unit_ratio: number | null;
  qty: number;
  create_datetime: string;
}

export interface ResponseProcessBagListData {
  status: string;
  message: string;
  data: ResultProcessBagListData[];
  total_count: number;
}

export interface ResultProcessBagListData {
  id: number;
  cost_center: string;
  pallet_no: string;
  bag_no: number;
  grade: string;
  lot: string;
  qr_text_data: string;
  unit_ratio: number;
  create_datetime: string;
  //  sql/73 pProcessGetBagList -- optional until that version is deployed
  pallet_running_no?: number | null;
  ton_no?: number | null;
}

//  GET api/v1/process/pallet/history (pProcessGetPalletHistory, sql/74)
export interface ResponseProcessPalletHistory {
  status: string;
  message: string;
  data: ResultProcessPalletHistory[];
  total_count: number;
}

//  Pallet History rows under one header per day on the Pallet Information page
export interface PalletHistoryDay {
  key: string;
  date: string;
  items: ResultProcessPalletHistory[];
}

export interface ResultProcessPalletHistory {
  event_datetime: string;
  process_id: number | null;
  process_name: string | null;
  job_main_id: number | null;
  job_item_id: number | null;
  job_type_id: number | null;
  job_type_short_name: string | null;
  job_type_name: string | null;
  //  sql/76 -- job document no (same rule as the job list) and WMS no
  system_no?: string | null;
  wms_no?: string | null;
  //  sql/75 -- optional until that version is deployed
  job_status_id?: number | null;
  job_status_name?: string | null;
  job_start_datetime?: string | null;
  job_end_datetime?: string | null;
  forklift_id?: number | null;
  forklift_name?: string | null;
  location_type_code: string | null;
  location_type: string | null;
  location_id: number | null;
  location_name: string | null;
  create_user_id: number | null;
  create_user_name: string | null;
  create_user_thai_name: string | null;
  create_user_eng_name: string | null;
}

export interface ResponseProcessJobListData {
  status: string;
  message: string;
  data: ResultProcessJobListData[];
  total_count: number;
}

//  GetWmsPlusInterfaceLogStatus -- batch (1 call per page load) lookup of
//  each job's full WMS+ put-away interface history, keyed by job_main_id.
//  logs[] is newest first; logs[0] is the "current" status for the badge.
export interface ResponseProcessWmsPlusLogStatus {
  status: string;
  message: string;
  data: ResultProcessWmsPlusLogGroup[];
}

export interface ResultProcessWmsPlusLogGroup {
  job_main_id: number;
  logs: ResultProcessWmsPlusLogStatus[];
}

//  GET process/job/total-pallet/source-changed?jobMainIds=... -- jobs whose
//  source grade / qty / CC changed after the approve calculated
//  total_pallet. A job missing from data is unchanged (or was approved
//  before the snapshot existed). old_* = at approve, new_* = now.
export interface ResponseProcessTotalPalletSourceChanged {
  status: string;
  message: string;
  data: ResultTotalPalletSourceChangedGroup[];
}

export interface ResultTotalPalletSourceChangedGroup {
  job_main_id: number;
  items: ResultTotalPalletSourceChangedItem[];
}

export interface ResultTotalPalletSourceChangedItem {
  item_id: number;
  change_type: 'changed' | 'removed' | 'added' | string;
  old_grade: string | null;
  old_qty: number | null;
  old_cost_center: string | null;
  old_total_pallet: number | null;
  new_grade: string | null;
  new_qty: number | null;
  new_cost_center: string | null;
  calc_datetime: string | null;
}

export interface ResultProcessWmsPlusLogStatus {
  mode: string | null;
  method: string | null;
  route: string | null;
  param: string | null;
  status_code: string | null;
  is_success: string | null;
  message: string | null;
  create_datetime: string | null;
}

//  PATCH job/{jobId}/wms-plus/resend -- wmsPlusStatus mirrors the
//  putaway/approve endpoints' own inline WMS+ result shape ('success' |
//  'failed' | 'not_applicable' when the job type has no confirm-location
//  step at all).
export interface ResponseProcessResendWmsPlus {
  status: string;
  message: string;
  wmsPlusStatus: 'success' | 'failed' | 'not_applicable';
  wmsPlusMessage: string | null;
}

export interface ResultProcessJobListData {
  id: number;
  //  WMS+ document header -- headerId of the TS/RC report links.
  header_id?: number | null;
  system_no: string;
  type_id: number;
  type_topic: string;
  type_short_name: string;
  type_name: string;
  is_urgent: string;
  is_multi_fl: string;
  is_advance_order?: string | null;
  wms_no: string;
  from_location_type: string;
  from_location_cc_code: string;
  from_location_cc_desc: string;
  to_location_type: string;
  to_location_cc_code: string;
  to_location_cc_desc: string;
  receive_qty: number;
  complete_qty: number;
  total_qty: number;
  movement_unit: string;
  status_id: number;
  status_name: string;
  remark: string | null;
  source_id: number;
  start_datetime: string;
  end_datetime: string;
  create_datetime: string;
  //  tr_job_main.product_cc (set on Approve) -- GET job only.
  product_cc?: string | null;
  //  tr_job_main.product_type (set on Approve, eg. 'FG') -- GET job only.
  product_type?: string | null;
  items: Item[];
  forklifts: Forklift[];
}

export interface Item {
  id: number;
  do_no: string;
  document_job: string;
  wh_code: string;
  cc_code: string;
  pd_cc_code: string;
  grade: string;
  lot_no: string;
  pd_type: string;
  //  WMS product group of pd_type (ct_bagging_code_t.wms_group, eg.
  //  'Code T' -> '0T') -- what WMS stock inquiry filters prodType on
  //  (sql/69). Optional: older pProcessGetJobList doesn't return it.
  wms_group?: string | null;
  //  The item's own remark (eg. TS bag positions "01B=234 , 02B=232").
  //  Optional: older API only returns the job-level remark.
  remark?: string | null;
  qty: number;
  complete_qty: number;
  qty_unit: string;
  is_expanded: boolean;
  total_qty: number;
  locations: Location;
}

export interface Location {
  from_locations: FromLocation[];
  to_locations: ToLocation[];
}

export interface FromLocation {
  id: number;
  wh_code: string;
  location_id: number;
  location_name: string | null;
  total_qty: number;
  receive_qty: number;
  complete_qty: number;
  movement_unit: string;
  qty: number;
  addon_lot: addonLot[];
  actual_qty: number;
  pallets: Pallet[];
}

export interface addonLot {
  lot: string;
  qty: number;
}

export interface ToLocation {
  id: number;
  wh_code: string;
  location_id: number;
  location_name: string | null;
  total_qty: number;
  receive_qty: number;
  complete_qty: number;
  movement_unit: string;
  qty: number;
  addon_lot: addonLot[];
  actual_qty: number;
  pallets: Pallet[];
}

export interface Forklift {
  id: number;
  name: string;
  wh_code: string;
  cc_code: string;
  //  ct_forklift.section_id ('1,3') and names ('Warehouse,Pallet') --
  //  pProcessGetJobList forklift result (sql/35).
  section_id?: string | null;
  section_name?: string | null;
  assignee_user_id: number | null;
  assignee_user_name: string | null;
  assignee_user_thai_name: string | null;
  assignee_user_eng_name: string | null;
  job_count: number;
  //  tr_job_assigness.is_read ('Y' / 'N') -- set when the forklift user
  //  opens the job (PATCH job/{jobId}/forklift/{flId}/read).
  is_read?: string | null;
}

export interface Pallet {
  id: number;
  unit_pallet: number;
  unit_ratio: number;
  grade: string;
  lot: string;
  bag_count: number;
  total_qty: number;
  pallet_text: string;
}

export interface ResponseProcessGetDo {
  status: string;
  message: any;
  data: ResultProcessGetDo[];
  total_count: number;
}

export interface ResultProcessGetDo {
  id: number;
  shipment_no: string | null;
  do_no: string;
  delivery_date: string;
  po_status: string;
  cc_code: string;
  wh_code: string;
  seq: number;
  grade: string;
  lot: string;
  qty: number;
  code_t: string | null;
  qty_bag: number | null;
  pk_unit: string;
  total_qty: number;
  truck_l: number;
  on_pallet: string | null;
  go_down: string;
  agent: string;
  owner: string;
  truck: string | null;
  shipping_instruction: string | null;
}

export interface ResponseProcessGetDoFromExcel {
  status: string;
  message: any;
  data: ResultProcessGetDoFromExcel[];
  total_count: number;
}

export interface ResultProcessGetDoFromExcel {
  id: number;
  ddo: string;
  loading_date: string;
  po_status: string;
  cc_code: string;
  wh_code: string;
  seq: number;
  grade: string;
  lot: string;
  qty: number;
  code_t: string | null;
  qty_bag: number | null;
  pk_unit: string;
  total_qty: number;
  truck_l: number;
  on_pallet: string | null;
  go_down: string;
  agent: string;
  owner: string;
  truck: string | null;
  shipping_instruction: string | null;
}

// =====================================================================
//  Process - Job Shipment (GET job/shipment -- reads live from WMS Plus,
//  enriched with local dock/weigh status) and shipment-triggered actions
// =====================================================================

export interface ShipmentFilter {
  shipmentNo?: string;
  deliveryNo?: string;
  statusIds?: number[];
  loadingFrom?: Date | null;
  loadingTo?: Date | null;
  page?: number;
  pageSize?: number;
}

export interface ResponseProcessJobShipmentListData {
  status: string;
  message: string;
  data: ResultProcessJobShipment[];
  total_count: number;
}

export interface ResultProcessJobShipment {
  shipmentno: string;
  deliveryno: string;
  deliverydate: string;
  fpdgradecode: string;
  pdlotno: string;
  qty: number;
  unit: string;
  cccode: string;
  whcode: string;
  total_pallet: number;
  remark: string | null;
  status: string;
  current_status_id: number | null;
  current_status: string | null;
  loading_datetime: string | null;
  truck_checkin_datetime: string | null;
  weight_in_datetime: string | null;
  weight_out_datetime: string | null;
}

//  Body for PATCH job/map-shipment-special -- links a WMS shipment straight
//  to one detail/pallet item (job-list.ts's shipment-list "Map DO Special"
//  action, selectSpecialItem) within an existing Special Job, not the job as
//  a whole -- one Special Job can hold several grade/pallet items, so the
//  mapping needs to say which one. Shipments aren't stored locally, so
//  they're identified by (shipmentNo, deliveryNo) rather than a local row id.
export interface RequestMapShipmentSpecialItem {
  shipmentNo: string;
  deliveryNo: string;
  specialJobItemId: number;
}

export interface RequestMapShipmentSpecial {
  updateBy?: number;
  items: RequestMapShipmentSpecialItem[];
}

//  Body for POST job/picking -- creates a brand-new picking job directly
//  from a WMS shipment row (job-list.ts's shipment-list "สร้างงาน Picking"
//  action). fromLocations/toLocations each come from their own embedded
//  <app-select-wh-location> FormArray (GET source + PUT destination), the
//  same {locationId, locationType, qty} shape job-detail.ts's onApproveJob
//  sends for items[].locations.fromLocations/toLocations.
export interface RequestCreatePickingJobLocation {
  locationId: number;
  locationType?: string;
  lot?: string;
  qty: number;
}

export interface RequestCreatePickingJobForklift {
  id: number;
}

export interface RequestCreatePickingJobItem {
  shipmentNo: string;
  deliveryNo: string;
  grade?: string;
  lot?: string;
  qty?: number;
  ccCode?: string;
  whCode?: string;
  remark?: string;
  fromLocations: RequestCreatePickingJobLocation[];
  toLocations: RequestCreatePickingJobLocation[];
  forklifts?: RequestCreatePickingJobForklift[];
  updateBy?: number;
}

//  Body for POST job/internal-transfer -- creates a WH02 Internal Transfer
//  job (job-wh-internal-transfer-list.ts submitTransfer). sourceLocations/
//  destinationLocations each come from their own <app-select-internal-
//  transfer-location> FormArray; pallets is only populated when a source
//  location was picked in "เลือกเป็นรายพาเลท" mode (locationForm.selectedPallets).
export interface RequestCreateInternalTransferJobPallet {
  id?: number | null;
  palletNo: string;
  grade?: string | null;
  lot?: string | null;
  qty: number;
  text?: string | null;
  scannedQrCode?: string | null;
}

export interface RequestCreateInternalTransferJobLocation {
  locationId: number;
  locationType?: string | null;
  locationName?: string | null;
  ccCode?: string | null;
  grade?: string | null;
  gradeId?: number | null;
  lot?: string | null;
  qty: number;
  remark?: string | null;
  pallets?: RequestCreateInternalTransferJobPallet[] | null;
}

export interface RequestCreateInternalTransferJobItem {
  whCode?: string;
  qtyUnit?: string;
  sourceRemark?: string | null;
  destinationRemark?: string | null;
  sourceLocations: RequestCreateInternalTransferJobLocation[];
  destinationLocations: RequestCreateInternalTransferJobLocation[];
  isUrgent?: string | null;
  isMultiForklift?: string | null;
  isAdvanceOrder?: string | null;
  forklifts?: { id: number }[];
  //  Saved onto tr_job_main.product_cc/product_type (same columns every
  //  other job type's create/update SP already sets) -- when omitted, the
  //  backend still auto-derives product_cc from sourceLocations[0].ccCode
  //  like it always has, so these are optional overrides, not required.
  productCc?: string | null;
  productType?: string | null;
  updateBy?: number;
}

//  GET job/transfer-wh -- WH04 Transfer Warehouse (job type 11),
//  pProcessGetTransferWhJobList (sql/50). Same shape as GET job: one entry
//  per job with items[] (each with from/to locations) and forklifts[].
export interface ResponseProcessTransferWhJobListData {
  status: string;
  message: string;
  data: ResultProcessTransferWhJobListData[];
  total_count: number;
}

export interface ResultProcessTransferWhJobListData {
  id: number;
  system_no: string;
  type_id: number;
  type_topic: string;
  type_short_name: string;
  type_name: string;
  is_urgent: string;
  is_multi_fl: string;
  wms_no: string;
  from_location_type: string;
  from_location_cc_code: string;
  from_location_cc_desc: string;
  to_location_type: string;
  to_location_cc_code: string;
  to_location_cc_desc: string;
  receive_qty: number;
  complete_qty: number;
  total_qty: number;
  movement_unit: string;
  status_id: number;
  status_name: string;
  remark: string | null;
  source_id: number;
  start_datetime: string;
  end_datetime: string;
  create_datetime: string;
  product_cc?: string | null;
  //  tr_job_main.product_type (set on Approve, eg. 'FG') -- GET job only.
  product_type?: string | null;
  items: Item[];
  forklifts: Forklift[];
}

//  GET job/internal-transfer -- job-wh-internal-transfer-list.ts loadJobs.
//  One row per job, with a structured items[] array (each item carrying a
//  locations.from_location/to_location pair) -- matches the shape job-list's
//  own job items already use (see JobItem/JobLocation below), not the
//  flattened source_summary/destination_summary strings this used to be
//  typed as.
export interface ResponseProcessInternalTransferJobListData {
  status: string;
  message: string;
  data: ResultProcessInternalTransferJobListData[];
  total_count: number;
}

export interface ResultInternalTransferJobListLocation {
  id: number;
  type: string | null;
  name: string | null;
  cc_code: string | null;
  cc_desc: string | null;
  lot_no: string | null;
  qty: number | null;
  actual_qty: number | null;
  grade_id: number | null;
  pallet_json: string | null;
  remark: string | null;
}

export interface ResultInternalTransferJobListItemLocations {
  from_location: ResultInternalTransferJobListLocation | null;
  to_location: ResultInternalTransferJobListLocation | null;
}

export interface ResultInternalTransferJobListItem {
  id: number;
  grade: string | null;
  lot_no: string | null;
  qty: number | null;
  confirm_qty: number | null;
  receive_qty: number | null;
  complete_qty: number | null;
  remark: string | null;
  locations: ResultInternalTransferJobListItemLocations;
}

export interface ResultInternalTransferJobForklift {
  id: number;
  name: string | null;
  wh_code: string | null;
  //  ct_forklift.section_id ('1,3') and names ('Warehouse,Pallet') -- sql/37.
  section_id?: string | null;
  section_name?: string | null;
  assignee_user_id: number | null;
  assignee_user_name: string | null;
  assignee_user_thai_name: string | null;
  assignee_user_eng_name: string | null;
  job_count: number;
  //  tr_job_assigness.is_read ('Y' / 'N') -- sql/pProcessGetInternalTransferJobList_is_read.sql.
  is_read?: string | null;
}

export interface ResultProcessInternalTransferJobListData {
  id: number;
  header_id: number;
  system_no: string;
  wms_no: string | null;
  job_type_id: number;
  job_type_topic: string | null;
  job_type_short_name: string | null;
  job_type_name: string | null;
  is_urgent: string | null;
  is_multi_forklift: string | null;
  is_advance_order?: string | null;
  job_status_id: number;
  job_status_name: string | null;
  wh_code: string | null;
  qty_unit: string | null;
  movement_unit: string | null;
  total_qty: number | null;
  source_remark: string | null;
  destination_remark: string | null;
  product_cc: string | null;
  product_type: string | null;
  job_start_datetime: string | null;
  job_end_datetime: string | null;
  job_create_datetime: string | null;
  forklifts: ResultInternalTransferJobForklift[];
  items: ResultInternalTransferJobListItem[];
}

//  GET job/internal-transfer/{jobId} -- job-wh-internal-transfer-list.ts
//  openEditModal, to pre-fill the same create-form/pickers used to create
//  the job (buildLocationFormGroup rebuilds each FormGroup from these rows).
export interface ResponseProcessInternalTransferJobDetailData {
  status: string;
  message: string;
  result: ResultProcessInternalTransferJobDetail | null;
}

export interface ResultProcessInternalTransferJobDetail {
  header: {
    jobMainId: number;
    headerId: number;
    systemNo: string;
    jobStatusId: number;
    status: string;
    whCode: string | null;
    sourceRemark: string | null;
    destinationRemark: string | null;
    qtyUnit: string | null;
    totalQty: number | null;
    isUrgent: string | null;
    isMultiForklift: string | null;
  };
  sourceLocations: ResultInternalTransferJobDetailLocation[];
  destinationLocations: ResultInternalTransferJobDetailLocation[];
  //  Snake_case field names on purpose -- dbo.tr_job_assigness/ct_forklift
  //  columns passed straight through as a DataTable (JobController.cs's
  //  GetInternalTransferJobDetail), same convention job-detail's own
  //  jobData.forklifts already uses.
  forklifts: ResultInternalTransferJobDetailForklift[];
}

export interface ResultInternalTransferJobDetailForklift {
  id: number;
  name: string | null;
  wh_code: string | null;
  assignee_user_id: number | null;
  assignee_user_name: string | null;
  assignee_user_thai_name: string | null;
  assignee_user_eng_name: string | null;
  job_count: number;
}

export interface ResultInternalTransferJobDetailLocation {
  locationId: number;
  locationType: string | null;
  locationName: string | null;
  grade: string | null;
  gradeId: number | null;
  lot: string | null;
  qty: number;
  remark: string | null;
  pallets: RequestCreateInternalTransferJobPallet[] | null;
}

// =====================================================================
//  Process CB
// =====================================================================

export interface ResponseProcessGetOptionsVehicleType {
  status: string;
  message: any;
  data: ResultProcessGetOptionsVehicleType[];
}

export interface ResultProcessGetOptionsVehicleType {
  vehicle_type_id: number;
  code: string;
  description: string;
}

export interface ResponseProcessGetOptionsLocationType {
  status: string;
  message: any;
  data: ResultProcessGetOptionsLocationType[];
}

export interface ResultProcessGetOptionsLocationType {
  id: number;
  code: string;
  name: string;
}

export interface ResponseProcessFindLocation {
  status: string;
  message: any;
  data: ResultProcessFindLocation[];
}

export interface ResultProcessFindLocation {
  id: number;
  location_code: string;
  location_name: string;
}

export interface ResponseProcessGetOptionsDepartment {
  status: string;
  message: any;
  data: ResultProcessGetOptionsDepartment[];
}

export interface ResultProcessGetOptionsDepartment {
  id: number;
  code: string;
  name: string;
}

export interface ResponseProcessGetOptionsRole {
  status: string;
  message: any;
  data: ResultProcessGetOptionsRole[];
}

export interface ResultProcessGetOptionsRole {
  id: number;
  role_name: string;
  role_description: string;
}

export interface ResponseProcessGetOptionsWmsCcCode {
  status: string;
  message: any;
  data: ResultProcessGetOptionsWmsCcCode[];
}

export interface ResultProcessGetOptionsWmsCcCode {
  cc_code: string;
  sap_cc_code: string;
}

export interface ResponseProcessGetOptionsSapCcCode {
  status: string;
  message: any;
  data: ResultProcessGetOptionsSapCcCode[];
}

export interface ResultProcessGetOptionsSapCcCode {
  cc_code: string;
  cc_desc: string;
}

export interface ResponseProcessGetOptionsWh {
  status: string;
  message: any;
  data: ResultProcessGetOptionsWh[];
}

export interface ResultProcessGetOptionsWh {
  id: number;
  wh_name: string;
  wh_code: string;
}

export interface ResponseProcessGetOptionsArea {
  status: string;
  message: any;
  data: ResultProcessGetOptionsArea[];
}

export interface ResultProcessGetOptionsArea {
  careaid: number;
  wh_code: string;
  careacode: string;
  careadesc: string;
}

export interface ResponseProcessGetOptionsLevel {
  status: string;
  message: any;
  data: ResultProcessGetOptionsLevel[];
}

export interface ResultProcessGetOptionsLevel {
  clevelid: number;
  wh_code: string;
  careacode: string;
  clevelcode: string;
  cleveldesc: string;
}

export interface ResponseProcessGetOptionsJobStatus {
  status: string;
  message: any;
  data: ResultProcessGetOptionsJobStatus[];
}

export interface ResultProcessGetOptionsJobStatus {
  id: number;
  name: string;
  name_th?: string | null;
}

export interface ResponseProcessGetOptionsJobType {
  status: string;
  message: any;
  data: ResultProcessGetOptionsJobType[];
}

export interface ResponseProcessGetOptionsJobLocation {
  status: string;
  message: any;
  data: ResultProcessGetOptionsJobLocation[];
}

//  sql/36 pProcessCBGetJobLocationOptions -- one row per option, ordered
//  by group. location_key null = the group's header row (whole type).
export interface ResultProcessGetOptionsJobLocation {
  location_type: string;
  type_name: string;
  location_key: string | null;
  label: string;
}

//  One From/To Location selection -- key null = whole location type.
export interface JobLocationFilter {
  type: string;
  key: string | null;
}

//  GET job multi-value filters (job-list) -- dates are yyyy-MM-dd, the
//  code/id lists go out comma-separated and locations as JSON.
export interface JobListMultiFilter {
  dateFrom?: string;
  dateTo?: string;
  fromCcCodes?: string[];
  toCcCodes?: string[];
  toWhCodes?: string[];
  statusIds?: number[];
  fromLocations?: JobLocationFilter[];
  toLocations?: JobLocationFilter[];
  productCcs?: string[];
  typeIds?: number[];
}

export interface ResultProcessGetOptionsJobType {
  id: number;
  topic: string;
  name: string;
  //  ct_job_type.is_list -- 'N' hides the type from Job List tabs
  //  (sql/33_ct_job_type_is_list.sql).
  is_list?: string;
}

export interface ResponseProcessGetOptionsBgPlant {
  status: string;
  message: any;
  data: ResultProcessGetOptionsBgPlant[];
}

export interface ResultProcessGetOptionsBgPlant {
  id: number;
  bg_plant_code: string;
  bg_plant_location: string;
}

export interface ResponseProcessGetOptionsWhCcCode {
  status: string;
  message: any;
  data: ResultProcessGetOptionsWhCcCode[];
}

export interface ResultProcessGetOptionsWhCcCode {
  id: number;
  location_type: string;
  wh_code: string;
  cc_code: string;
  cc_desc: string;
}

export interface ResponseProcessGetOptionsProductType {
  status: string;
  message: any;
  data: ResultProcessGetOptionsProductType[];
}

export interface ResultProcessGetOptionsProductType {
  product_type: string;
  wms_group: string;
}

export interface ResponseProcessGetOptionsCodePallet {
  status: string;
  message: any;
  data: ResultProcessGetOptionsCodePallet[];
}

export interface ResultProcessGetOptionsCodePallet {
  pallet_id: number;
  code: string;
  name: string; 
}

export interface ResponseProcessGetOptionsSpecialPackageType {
  status: string;
  message: any;
  data: ResultProcessGetOptionsSpecialPackageType[];
}

export interface ResultProcessGetOptionsSpecialPackageType {
  special_type_package_id: number;
  code: string;
  name: string; 
}

// DO Preparing modal (job-detail: per-item pallet preparation info)
export interface ResponseProcessGetDoPreparing {
  status: string;
  message: string;
  data: ResultProcessGetDoPreparing[];
}

export interface ResultProcessGetDoPreparing {
  code_pallet_id: number | null;
  pallet_lot: string;
  pallet_qty: number | null;
  pallet_weight: number | null;
  special_type_package_id: number | null;
}

export interface RequestProcessUpdateDoPreparing {
  item_id: number;
  code_pallet_id: number | null;
  pallet_lot: string;
  pallet_qty: number | null;
  pallet_weight: number | null;
  special_type_package_id: number | null;
}

// =====================================================================
// Master Data
// =====================================================================

export interface ResponseProcessForkliftListData {
  status: string;
  message: string;
  data: ResultProcessForkliftListData[];
  total_count: number;
}

export interface ResultProcessForkliftListData {
  id: number;
  forklift_name: string;
  license_plate: any;
  warehouse_code: string;
  forklift_status: string;
  lasted_used_datetime: string;
  updated_datetime: string;
}

export interface ResponseProcessForkliftAvailable {
  status: string;
  message: any;
  data: ResultProcessForkliftAvailable[];
}

export interface ResultProcessForkliftAvailable {
  id: number;
  fl_name: string;
  license_plate: string | null;
  wh_code: string;
  //  ct_forklift.section_id as stored ('1,3') and as names ('Warehouse,Pallet')
  section_id: string | null;
  section_name: string | null;
  cc_code: string;
  cc_desc: string;
  current_user_id: number | null;
  current_user_name: string | null;
  current_user_thai_name: string | null;
  current_user_eng_name: string | null;
  is_online: string;
  job_count: number;
}

export interface ResponseProcessWhLocation {
  status: string;
  message: any;
  data: ResultProcessWhLocation[];
  //  Only populated by the Location Management list call (processGetLocationManagementList).
  total_count?: number;
}

export interface ResultProcessWhLocation {
  id: number | null;
  location_id: number;
  wh_code: string;
  area_code: string;
  level_code: string;
  location_code: string;
  priority_id: number | null;
  priority_name: string | null;
  location_desc: string;
  //  Only populated by the Location Management list call (processGetLocationManagementList).
  //  status is a placeholder ("Available") until a real source is confirmed.
  status?: string;
  is_active?: boolean;
  updated_datetime?: string | null;
}

//  Location Management page (search filter + list request)
//  "ชื่อ Location" is sourced from location_desc (not location_code) - see LocationController.GetWhLocationAsync.
export interface LocationManagementFilter {
  locationDesc?: string;
  whCode?: string;
  priorityName?: string;
  statusId?: number;
  page?: number;
  pageSize?: number;
}

//  Location Management page (edit priority / toggle active PUT request)
export interface RequestUpdateLocation {
  locationName?: string;
  priorityId?: number | null;
  isActive?: boolean | null;
  updateBy?: number;
}

export interface ResponseProcessPreZoneLocation {
  status: string;
  message: any;
  data: ResultProcessPreZoneLocation[];
  //  Only populated once page/pageSize are passed (see processGetPrezoneLocation) - existing
  //  callers that omit them still get every matching row and can ignore this field.
  total_count?: number;
}

export interface ResultProcessPreZoneLocation {
  id: number;
  wh_code: string;
  area_code: string;
  level_code: string;
  location_code: string;
  location_desc: string;
  is_active: boolean;
}

export interface ResponseProcessDockLocation {
  status: string;
  message: any;
  data: ResultProcessDockLocation[];
  //  Only populated once page/pageSize are passed (see processGetDockLocation) - existing
  //  callers that omit them still get every matching row and can ignore this field.
  total_count?: number;
}

export interface ResultProcessDockLocation {
  id: number;
  wh_code: string;
  area_code: string;
  level_code: string;
  location_code: string;
  location_desc: string;
  is_active: boolean;
}

export interface ResponseProcessGetStockInquiry {
  status: string;
  message: any;
  result: ResultProcessStockInquiry[];
}

export interface ResultProcessStockInquiry {
  fpdgradeid: number;
  invdate: string;
  fpdgradecode: string;
  pdlotno: string;
  balance: number;
  qtyreserve: number;
  qtylock: number;
  qtyprocess: number;
  available: number;
  unit: string;
  whcode: string;
  careacode: string;
  clevelcode: string;
  clocationcode: string;
  cinvid: number;
  cccode: string;
}

export interface ResponseProcessGetAllStockInquiry {
  status: string;
  message: any;
  result: ResultProcessGetAllStockInquiry[];
}

export interface ResultProcessGetAllStockInquiry {
  fpdgradeid: number;
  invdate: string;
  fpdgradecode: string;
  pdlotno: string;
  balance: number;
  qtyreserve: number;
  qtylock: number;
  qtyprocess: number;
  available: number;
  unit: string;
  whcode: string;
  mareacode: string;
  mlevelcode: string;
  mlocationcode: string;
  minvid: number;
  cccode: string;
}

export interface ResponseProcessBgPlantLocation {
  status: string;
  message: any;
  data: ResultProcessBgPlantLocation[];
}

export interface ResultProcessBgPlantLocation {
  id: number;
  plant_code: string;
  plant_location: string;
}

//  GET master/location/auto-wh/{whCode} -- ct_auto_warehouse (A41/A43).
export interface ResponseProcessAutoWhLocation {
  status: string;
  message: any;
  data: ResultProcessAutoWhLocation[];
}

export interface ResultProcessAutoWhLocation {
  id: number;
  wh_code: string;
  wh_name: string;
}

export interface ResponseProcessRqPlantLocation {
  status: string;
  message: any;
  data: ResultProcessRqPlantLocation[];
}

export interface ResultProcessRqPlantLocation {
  id: number;
  plant_code: string;
  plant_location: string;
}

export interface ResponseProcessSpecialLocation {
  status: string;
  message: any;
  data: ResultProcessSpecialLocation[];
}

export interface ResultProcessSpecialLocation {
  id: number;
  plant_code: string;
  plant_location: string;
}

export interface ResponseProcessReplaceLocation {
  status: string;
  message: any;
  data: ResultProcessReplaceLocation[];
}

export interface ResultProcessReplaceLocation {
  id: number;
  plant_code: string;
  //  Actual API field name (confirmed from a live response) -- looks like a
  //  typo in the backend's column alias for what should be plant_location.
  aSplant_location: string;
}

export interface ResponseProcessGetGradeWithSapCcCode {
  status: string;
  message: any;
  result: { table: ResultProcessGetGradeWithSapCcCode[] };
}

export interface ResultProcessGetGradeWithSapCcCode {
  fpdgradeid: number;
  fpdgradecode: string;
  fpdgradedesc: string;
  pdtypecode: string;
  fpdgroupcode: string;
  pkunitcode: string;
  unitratio: number;
  rationame: string;
  unitpallet: number;
  cccode: string;
  fpkratioid: number;
}

//  GET api/v1/master/grade (GradeController.GetMasterGrade) -- a different
//  envelope/field-naming from grade-with-sap-cc-code above (that one wraps
//  in result.table[] with no underscores; this one is a flat data[] +
//  total_count list, mirroring the backend's ResponseGradeWMSList/
//  ResponseGradeWMS models). unit_ratio/unit_pallet are the package-ratio
//  figures (kg-per-bag x bags-per-pallet) used to convert a qty into a
//  pallet/bag count elsewhere in the app (see DoController.UpdateDo in the
//  API repo for the reference calculation).
export interface ResponseProcessGetMasterGrade {
  status: string;
  message: string;
  data: ResultProcessGetMasterGrade[];
  total_count: number;
}

export interface ResultProcessGetMasterGrade {
  fpd_grade_id: number | null;
  fpd_grade_code: string | null;
  fpd_grade_desc: string | null;
  pd_type_code: string | null;
  fpd_group_code: string | null;
  cost_center: string | null;
  pk_unit_code: string | null;
  fpk_ratio_id: number | null;
  ratio_name: string | null;
  unit_ratio: number | null;
  unit_pallet: number | null;
}

// =====================================================================
// Data Response Insert/Update/Delete
// =====================================================================

export interface RequestInsertUpdateDeleteUser {
  id?: number;
  userName?: string;
  password?: string;
  confirmPassword?: string;
  departmentId?: number;
  roleId?: number;
  thaiName?: string;
  engName?: string;
  carrierId?: number;
  empId?: string;
  userTypeId?: number;
  isLocal?: string;
  isAd?: string;
  isLdl?: string;
  userId?: number;
}

export interface RequestInsertUpdateDeleteRole {
  id?: number;
  roleName?: string;
  roleDescription?: string;
  isActive?: string;
  userId?: number;
}

export interface RolePermissionItem {
  key: string;
  departmentId?: number;
  value: string;
}

export interface RequestSaveRolePermission {
  permissions: RolePermissionItem[];
  userId?: number;
}

export interface RequestImportJobShipmentItem {
  ddo?: string;
  loadingDate?: string;
  poStatus?: string;
  status?: string;
  grade?: string;
  lot?: string;
  qty?: number;
  seq?: number;
  truckL?: number;
  onPallet?: string;
  godown?: string;
  agent?: string;
  truck?: string;
  owner?: string;
  shippingInstruction?: string;
}

// =====================================================================
//  Process - Special Job
// =====================================================================

export interface SpecialJobFilter {
  //  Searches เลขที่เอกสาร (tr_special_header.doc_no) -- was a "Job Number"
  //  search against system_no before; see job-special-list.ts's search
  //  filter row.
  docNo?: string;
  //  วันที่ search is a date RANGE -- dateFrom/dateTo are both dd/mm/yyyy
  //  strings (same format the single-date filters elsewhere use), either of
  //  which may be blank to leave that end of the range open. See
  //  job-special-list.ts's onFilterDateChange.
  dateFrom?: string;
  dateTo?: string;
  jobStatus?: number;
  jobType?: number;
  //  Added to the search filter row but not yet wired to the list API call
  //  (job/special is still a backend stub -- see fetchSpecialJobData) --
  //  filtering by this client-side isn't hooked up either yet.
  customer?: string;
  page?: number;
  pageSize?: number;
  sortBy?: string;
  sortOrder?: string;
}

export interface ResponseProcessSpecialJobListData {
  status: string;
  message: string;
  data: ResultProcessSpecialJobListData[];
  total_count: number;
}

// =====================================================================
//  Process - Pallet Adjustment (bag <-> pallet maintenance screen)
// =====================================================================

export interface PalletAdjustmentFilter {
  //  วันที่พิมพ์ range (tr_bag.create_datetime, inclusive). Bound to
  //  <mat-date-range-input> via ngModel, so at runtime these hold `Date`s (not
  //  strings) until fetchPalletOverview() formats them to 'yyyy-MM-dd' right
  //  before calling the API. Either end left empty = unbounded on that side.
  printDateFrom?: string | Date | null;
  printDateTo?: string | Date | null;
  //  Cost Center code, sourced from ProcessGetOptionsSapCcCode (single select).
  ccCode?: string;
  //  Grade textbox -- UI forces uppercase while typing (see onGradeInput).
  grade?: string;
  lot?: string;
}

//  GET /process/pallet-adjustment/overview
export interface ResponseProcessPalletAdjustmentOverview {
  status: string;
  message: string;
  data: ResultProcessPalletAdjustmentOverview;
}

export interface ResultProcessPalletAdjustmentOverview {
  summary: ResultPalletAdjustmentSummary;
  grades: ResultPalletAdjustmentGradeGroup[];
  orphan_bags: ResultPalletAdjustmentBag[];
  rejected_bags: ResultPalletAdjustmentRejectedBag[];
}

export interface ResultPalletAdjustmentSummary {
  total_pallets: number;
  wh_process: number;
  complete: number;
  total_bags: number;
  orphan_bags: number;
  //  Pallets confirmed as a "remainder pallet" via the "จบพาเลท" quick action
  //  (pallet_status_id = 3 CONFIRMED) -- counts pallets, not bags.
  confirmed_remainder: number;
}

export interface ResultPalletAdjustmentGradeGroup {
  grade: string;
  unit_pallet: number;
  pallets: ResultPalletAdjustmentPallet[];
}

export interface ResultPalletAdjustmentPallet {
  id: number;
  pallet_no: string;
  lot: string;
  //  running pallet no จาก QR ถุง (ส่วนที่ 5 ของ cost_center|grade|lot|bag_no|pallet_running_no) เช่น '001'
  pallet_running_no: string | null;
  pallet_type: string;
  bag_count: number;
  unit_pallet: number;
  location_type: string;
  current_location: string;
  create_datetime: string;
  //  'wh_process' = ถุงยังไม่ครบ unit_pallet (pallet_status_id=1) · 'complete' =
  //  เต็มเองตามธรรมชาติ (pallet_status_id=2) · 'confirmed' = ยืนยันเป็นพาเลทเศษ
  //  ผ่านปุ่ม "จบพาเลท" (pallet_status_id=3)
  status: 'complete' | 'wh_process' | 'confirmed';
}

//  GET /process/pallet-adjustment/bag?palletId=
export interface ResponseProcessPalletAdjustmentBagList {
  status: string;
  message: string;
  data: ResultPalletAdjustmentBag[];
  //  ช่องว่างที่ไม่มีข้อมูลการพิมพ์ (dbo.sp_PalletAdjustment_GetMissingSlots) -- [] ถ้า SP ยังไม่ deploy
  missing_slots?: ResultPalletAdjustmentMissingSlot[];
  total_count: number;
}

export interface ResultPalletAdjustmentMissingSlot {
  qr_text_data: string;
  qr_ton: number;
  qr_bag_no: number;
  planned_pos: number;
}

export interface ResultPalletAdjustmentBag {
  id: number;
  bag_no: number;
  //  ตันที่ระบบจัดให้ (tr_bag.ton_no) -- null ถ้าถุงไม่เคยผ่าน auto-matching / SP ยังไม่ได้ deploy
  ton_no?: number | null;
  //  มีถุง reject ก่อนถุงนี้ตามลำดับ QR = ถุงถูกเลื่อนขึ้นมาแล้ว (false ถ้า SP ยังไม่ได้ deploy)
  reject_before?: boolean;
  //  ถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" (false ถ้า SP ยังไม่ได้ deploy)
  is_manual_added?: boolean;
  grade: string;
  lot: string;
  qr_text_data: string;
  status: 'matched' | 'in_progress' | 'missing' | 'orphan';
}

//  Result Set #4 of sp_PalletAdjustment_GetOverview -- bags with
//  tr_bag.is_active = 'R' (dbo.pProcessUpdateBagRejectStatus @reject=1).
export interface ResultPalletAdjustmentRejectedBag {
  id: number;
  bag_no: number;
  grade: string;
  lot: string;
  qr_text_data: string;
  reject_reason: string | null;
  reject_datetime: string | null;
  status: 'rejected';
}

//  POST /process/pallet-adjustment/shift-missing
export interface RequestPalletAdjustmentShiftMissingBag {
  palletId: number;
  missingBagNo: number;
  userId: number;
}

//  POST /process/pallet-adjustment/pull-out
export interface RequestPalletAdjustmentPullBagOut {
  bagIds: number[];
  userId: number;
}

//  POST /process/pallet-adjustment/add-in
export interface RequestPalletAdjustmentAddBagIn {
  bagId: number;
  palletId: number;
  userId: number;
}

//  POST /process/pallet-adjustment/reorder
export interface RequestPalletAdjustmentReorderPallet {
  palletId: number;
  userId: number;
}

//  POST /process/pallet-adjustment/finish -- Quick Actions "จบพาเลท" ปุ่ม ใช้กับ
//  พาเลทสุดท้ายของ Lot ที่ไม่เต็ม unit_pallet. Backed by
//  dbo.sp_PalletAdjustment_FinishPallet (set pallet_status_id = 3 CONFIRMED,
//  dbo.ct_pallet_status).
export interface RequestPalletAdjustmentFinishPallet {
  palletId: number;
  userId: number;
}

//  GET /process/pallet-adjustment/grade-ratio?grade=
//  dbo.sp_PalletAdjustment_GetGradeRatio -- found = false คือยังไม่มีใน ct_grade_package_ratio
export interface ResultPalletAdjustmentGradeRatio {
  grade: string;
  found: boolean;
  unit_ratio: number | null;
  unit_pallet: number | null;
  unit_code: string | null;
  last_update_datetime: string | null;
}

export interface ResponsePalletAdjustmentGradeRatio {
  status: string;
  message: string;
  result: ResultPalletAdjustmentGradeRatio | null;
}

//  POST /process/pallet-adjustment/create-pallet
//  dbo.sp_PalletAdjustment_CreatePallet -- บันทึก ratio + สร้างพาเลทใหม่ให้ Orphan Bag
export interface RequestPalletAdjustmentCreatePallet {
  bagId: number;
  unitRatio: number;
  unitPallet: number;
  unitCode?: string;
  userId: number;
}

//  POST /process/pallet-adjustment/reject-bag
//  Backed by dbo.pProcessUpdateBagRejectStatus (@reject=1), called once per
//  bagId -- allowed even on a closed/WH-Process pallet.
export interface RequestPalletAdjustmentRejectBag {
  bagIds: number[];
  //  ช่องว่างที่ไม่มีข้อมูลการพิมพ์ของพาเลท palletId (QR ของช่อง)
  palletId?: number;
  missingQrs?: string[];
  reason?: string;
  userId: number;
}

//  POST /process/pallet-adjustment/add-missing-bag -- Quick Actions "เพิ่มข้อมูล"
//  Backed by dbo.sp_PalletAdjustment_AddMissingBag, called once per QR.
export interface RequestPalletAdjustmentAddMissingBag {
  palletId: number;
  missingQrs: string[];
  userId: number;
}

//  POST /process/pallet-adjustment/unreject-bag -- "คืนค่า" button on a
//  Rejected Bags row. Backed by dbo.pProcessUpdateBagRejectStatus (@reject=0).
export interface RequestPalletAdjustmentUnrejectBag {
  bagId: number;
  userId: number;
}

//  Fields below create_datetime are only used by the "Inspect" modal
//  (job-special-list.ts's openInspectJob) -- the list cards themselves only
//  read id..create_datetime. Since GET job/special already loads every job
//  up front, Inspect is built entirely from the row already in _jobData --
//  no extra round-trip needed.
export interface ResultProcessSpecialJobListData {
  job_main_id: number;
  id: number;
  system_no: string;
  status_id: number;
  status_name: string;
  total_pallet: number;
  complete_pallet: number;
  total_bag: number;
  complete_bag: number;
  special_zone: string | null;
  //  Whether this Special Job's Special Zone location has actually been
  //  assigned yet -- the Map DO Special picker (job-list.html) disables and
  //  dims a job's selectable rows while this is false.
  has_location: boolean;
  prepare_zone: string | null;
  is_arriving: boolean;
  is_arrived: boolean;
  create_datetime: string;
  doc_no: string | null;
  no: string | null;
  job_date: string | null;
  customer: string | null;
  seq: string | null;
  pallet_size: string | null;
  is_arranged: boolean;
  is_wrap_film: boolean;
  is_taped: boolean;
  sale_date: string | null;
  remark: string | null;
  invoice: string | null;
  ordered_by: string | null;
  prep_status: string | null;
  incomplete_detail: string | null;
  total_ton: number | null;
  cart_qty: number | null;
  details: SpecialJobItem[];
}

export interface SpecialJobItem {
  id: number;
  pallet_no: number;
  item_id: number;
  grade: string;
  qty: number;
  bag: number;
  lots: SpecialJobItemLot[];
}

export interface SpecialJobItemLot {
  lot: string;
  qty: number;
}

//  Create Special Job -- used by both the Manual and Upload create modes.
//  Manual mode always sends a single job with one-or-more user-built pallets;
//  Upload mode sends one job per qualifying Excel row, each with a single
//  auto-built pallet. Each bag row is ONE คัน (cart) -- its qty (kg) is that
//  cart's share of the job's ตัน x คัน total (see tonPerCart/cartQty below).
export interface RequestSpecialJobBagRow {
  grade?: string;
  lot?: string;
  qty?: number;
  bag?: number;
}

export interface RequestSpecialJobPallet {
  bags: RequestSpecialJobBagRow[];
}

//  The fields below (everything but title/pallets) mirror the columns of the
//  "Special Package" preparation sheet (NO. / วันที่ / เลขที่เอกสาร / ลูกค้า /
//  ลำดับ / ขนาดพาเลท / จัดเรียง / พันฟิล์ม / รัดเทป / ขายวันที่ / หมายเหตุ /
//  INVOICE / ผู้สั่งงาน / สถานะการจัดทำสินค้า / รายละเอียดของแต่ละรายการที่ยัง
//  ทำไม่เสร็จ). They're only ever populated by the Upload flow today -- Manual
//  mode's UI has no fields for them, so they stay undefined there.
//  tonPerCart is this job's TOTAL tonnage (sourced from the sheet's "รวม"
//  column), cartQty is how many bag rows that total is split across -- each
//  bag row's qty (kg) = (tonPerCart / cartQty) x 1000.
export interface RequestCreateSpecialJobItem {
  //  JOB No -- a separate field from "title" (เลขที่เอกสาร) and "no" (the
  //  sheet's NO. column); shown right before เลขที่เอกสาร in the create UI.
  jobNo?: string;
  title?: string;
  no?: string;
  date?: string;
  customer?: string;
  seq?: string;
  palletSize?: string;
  arranged?: boolean;
  wrapFilm?: boolean;
  taped?: boolean;
  saleDate?: string;
  remark?: string;
  invoice?: string;
  orderedBy?: string;
  prepStatus?: string;
  incompleteDetail?: string;
  tonPerCart?: number;
  cartQty?: number;
  pallets: RequestSpecialJobPallet[];
}

//  Update Special Job -- same shape as create, plus the tr_special_header
//  id being edited. Used by the Inspect modal's Save button
//  (job-special-list.ts's onSaveInspectJob) to PUT job/special/{id}.
//  Whole-pallets/bags are replaced wholesale on save (see
//  pProcessUpdateSpecialJob) rather than diffed row-by-row.
export interface RequestUpdateSpecialJobItem extends RequestCreateSpecialJobItem {
  id: number;
}
