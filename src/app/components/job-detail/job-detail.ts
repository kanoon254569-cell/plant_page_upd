import { Component } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { Location } from '@angular/common';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import Swal, { SweetAlertIcon } from 'sweetalert2';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import { confirmOfflineForklift } from '../../services/offline-forklift-confirm';

type WarehouseCode = 'A41' | 'A43' | 'MWH';

type locationForm = FormGroup<{
  id: FormControl<number | null>;
  itemId: FormControl<number | null>;
  whCode: FormControl<string | null>;
  ccCode: FormControl<string | null>;
  grade: FormControl<string | null>;
  lotNo: FormControl<string | null>;
  locationId: FormControl<number | null>;
  locationType: FormControl<string | null>;
  locationName: FormControl<string | null>;
  qty: FormControl<number | null>;
  confirmQty: FormControl<number | null>;
  actualQty: FormControl<number | null>;
  movementUnit: FormControl<string | null>;
  receivedQty: FormControl<number | null>;
  completeQty: FormControl<number | null>;
  availableQty: FormControl<number | null>;
  qtyLock: FormControl<number | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
  isVisible: FormControl<boolean | null>;
}>;

type ForkliftForm = FormGroup<{
  id: FormControl<number | null>;
  forkliftName: FormControl<string | null>;
  whCode: FormControl<string | null>;
  sectionName: FormControl<string | null>;
  currentUserId: FormControl<number | null>;
  currentUserName: FormControl<string | null>;
  currentThaiName: FormControl<string | null>;
  currentEngName: FormControl<string | null>;
  isOnline: FormControl<boolean | null>;
  jobCount: FormControl<number | null>;
  //  'Y' / 'N' for a saved assignment, null for one just picked (not saved yet).
  isRead: FormControl<string | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
}>;

//  ct_forklift.section_id values (no master table -- same mapping as
//  pProcessInsertUpdateCtForklift / pProcessGetForkliftAvailable)
const FORKLIFT_SECTION_OPTIONS = [
  { id: '1', name: 'Warehouse' },
  { id: '2', name: 'Loading' },
  { id: '3', name: 'Pallet' },
];

@Component({
  selector: 'app-job-detail',
  standalone: false,
  templateUrl: './job-detail.html',
  styleUrl: './job-detail.css',
})
export class JobDetail {
  _id: number = 0;
  _isLoading: boolean = false;
  skeletonItems = Array.from({ length: 3 }, (_, index) => index);

  _jobData!: Type.ResultProcessJobListData[] | null;
  //  Newest log entry -- drives the badge's success/failed look.
  _wmsPlusStatus: Type.ResultProcessWmsPlusLogStatus | null = null;
  //  Full history for this job, newest first -- feeds #wmsPlusDetailModal.
  _wmsPlusLogs: Type.ResultProcessWmsPlusLogStatus[] | null = null;
  //  Items whose source grade / qty / CC changed after the approve
  //  calculated total_pallet; null = unchanged. Save recalculates it.
  _totalPalletSourceChanged: Type.ResultTotalPalletSourceChangedItem[] | null = null;
  _wmsPlusLogPage: number = 1;
  readonly wmsPlusLogPageSize: number = 1;
  _isResendingWmsPlus: boolean = false;
  _forkliftAvailableData!: Type.ResultProcessForkliftAvailable[] | null;
  //  Kept separate (rather than one shared _plantLocationData field
  //  overwritten by whichever of initializeSrcLocation/initializeDestLocation
  //  ran last) so that on a job with Plant on one side only - the common
  //  case - the other side's initializer setting its own field to null
  //  doesn't wipe out the plant candidates the first one just fetched,
  //  which used to make canModifyLocation see the wrong (null) data and
  //  incorrectly disable location-swapping for a plant with multiple
  //  candidate locations.
  _srcPlantLocationData!: Type.ResultProcessBgPlantLocation[] | null;
  _destPlantLocationData!: Type.ResultProcessBgPlantLocation[] | null;

  whLocationOptions: Type.ResultProcessGetOptionsWh[] | null = [];
  costCenterOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = [];
  selectedCostCenter = new FormControl<Type.ResultProcessGetOptionsWmsCcCode | null>(null);
  //  true when costCenterOptions is the job's own WH Prod CC list (TS / RC / RQ)
  isWmsProdCcByJob: boolean = false;
  productTypeOptions: Type.ResultProcessGetOptionsProductType[] | null = [];
  selectedProductType = new FormControl<Type.ResultProcessGetOptionsProductType | null>(null);

  //  DO Preparing modal (per Grade & Lot item) - options + form state
  codePalletOptions: Type.ResultProcessGetOptionsCodePallet[] | null = [];
  specialPackageTypeOptions: Type.ResultProcessGetOptionsSpecialPackageType[] | null = [];
  selectedDoPreparingItemId: number | null = null;
  _isSavingDoPreparing: boolean = false;
  _isLoadingDoPreparing: boolean = false;
  //  Approve/Save in-flight flag -- same role as job-wh-internal-transfer-
  //  detail's isSubmitting: canApproveJob reads it so the button disables
  //  (and onApproveJob bails) while the request is pending, so a double
  //  click can't approve/save the same job twice.
  isSubmitting: boolean = false;
  doPreparingSavedItemIds = new Set<number>();
  doPreparingForm = new FormGroup({
    selectedCodePallet: new FormControl<Type.ResultProcessGetOptionsCodePallet | null>(null),
    codePalletName: new FormControl<string>(''),
    palletLot: new FormControl<string>('-'),
    palletQty: new FormControl<number | null>(null),
    palletWeight: new FormControl<number | null>(null),
    selectedSpecialPackageType: new FormControl<Type.ResultProcessGetOptionsSpecialPackageType | null>(null),
  });

  _searchForklift = new FormGroup({
    forkliftName: new FormControl(''),
    //  Warehouse filter (multi-select) -- empty = the job's PUT warehouses
    whCodes: new FormControl<string[]>([]),
    currentUser: new FormControl(''),
    //  Section filter (multi-select) -- forklift matches any selected section
    sectionIds: new FormControl<string[]>([]),
  });
  readonly forkliftSectionOptions = FORKLIFT_SECTION_OPTIONS;

  selectedItemId: number | null = null;
  plantLocationModalRequestId = 0;
  whLocationModalRequestId = 0;
  canModifyLocation = false;

  validationErrors = { srcLocation: false, destLocation: false, forklift: false };

  srcLocationForm = new FormGroup({
    locations: new FormArray<locationForm>([]),
  });

  get srcLocations(): FormArray<locationForm> {
    return this.srcLocationForm.controls.locations;
  }

  selectedSrcLocations(itemId?: number): locationForm[] {
    return this.srcLocations.controls.filter(
      (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
    );
  }

  isEmptySrcLocations(itemId?: number): boolean {
    if (itemId === undefined) {
      return this.jobItems.some((item) => this.selectedSrcLocations(item.id).length === 0);
    }

    return this.selectedSrcLocations(itemId).length === 0;
  }

  get srcWarehouseCode(): WarehouseCode {
    const warehouseCode = this.jobData?.from_location_type;

    if (warehouseCode === 'A41' || warehouseCode === 'A43' || warehouseCode === 'MWH') {
      return warehouseCode;
    }

    return 'MWH';
  }

  qtySrcLocations(itemId?: number): number {
    return this.srcLocations.controls
      .filter(
        (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
      )
      .reduce((sum, loc) => sum + (Number(loc.value.qty) ?? 0), 0);
  }

  confirmQtySrcLocations(itemId?: number): number {
    return this.srcLocations.controls
      .filter(
        (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
      )
      .reduce((sum, loc) => {
        const qty = Number(loc.value.confirmQty);
        return sum + (isNaN(qty) ? 0 : qty);
      }, 0);
  }

  isEnoughSrcLocations(itemId?: number): boolean {
    if (itemId === undefined) {
      return this.jobItems.every((item) => this.confirmQtySrcLocations(item.id) >= item.qty);
    }

    const itemQty = this.jobItems.find((i) => i.id === itemId)?.qty ?? 0;
    const confirmQty = this.confirmQtySrcLocations(itemId);
    return confirmQty >= itemQty;
  }

  destLocationForm = new FormGroup({
    locations: new FormArray<locationForm>([]),
  });

  get destLocations(): FormArray<locationForm> {
    return this.destLocationForm.controls.locations;
  }

  get currentDestLocations(): locationForm[] {
    return this.destLocationForm.controls.locations.controls.filter(
      (loc) => loc.value.itemId === this.selectedItemId,
    );
  }

  get selectedItemQty(): number {
    return this.jobItems.find((item) => item.id === this.selectedItemId)?.qty ?? 0;
  }

  get destWarehouseCode(): WarehouseCode {
    const warehouseCode = this.jobData?.to_location_type;

    if (warehouseCode === 'A41' || warehouseCode === 'A43' || warehouseCode === 'MWH') {
      return warehouseCode;
    }

    return 'MWH';
  }

  //  Job can no longer be approved/saved (status_id >= 5, e.g. Completed) --
  //  same role as job-wh-internal-transfer-detail's readOnlyMode: disables
  //  every Add button (forklift + location panels), the header selects and
  //  the 1/2 Step / Urgent toggles, so nothing can be changed that the
  //  disabled Approve/Save button couldn't persist anyway.
  get readOnlyMode(): boolean {
    return (this.jobData?.status_id || 0) >= 5;
  }

  //  Advance order: the WMS+ interface is held back when the job completes
  //  and is sent only when the user presses the send button. The flag can be
  //  set only while the job is Pending (1) or WH Approved (2).
  get canSetAdvanceOrder(): boolean {
    const statusId = this.jobData?.status_id || 0;
    return statusId === 1 || statusId === 2;
  }

  get isAdvanceOrder(): boolean {
    return this.jobData?.is_advance_order === 'Y';
  }

  //  Completed advance-order job whose interface has not gone through yet.
  get canSendAdvanceInterface(): boolean {
    return this.isAdvanceOrder && this.readOnlyMode && this._wmsPlusStatus?.is_success !== 'Y';
  }

  //  Send-button label: the WMS+ interface codes the resend sends for this
  //  job type (pre-approve + confirm location; TW = one of its two forms).
  get advanceInterfaceLabel(): string {
    switch (this.jobData?.type_id) {
      case 1: return 'WMS211 / WMS212';
      case 2: return 'WMS220 / WMS221';
      case 3: return 'WMS242';
      case 11: return 'WMS222 / WMS216';
      default: return 'ส่ง Interface';
    }
  }

  get canApproveJob(): boolean {
    if (this.readOnlyMode) {
      return false;
    }

    if (this.isSubmitting) {
      return false;
    }

    if (!this.selectedCostCenter.value || !this.selectedProductType.value) {
      return false;
    }

    if (this.hasOverQtyLocations()) {
      return false;
    }

    const hasValidationErrors =
      this.validationErrors.srcLocation ||
      this.validationErrors.destLocation ||
      this.validationErrors.forklift;

    if (!hasValidationErrors) {
      return true;
    }

    const hasRequiredSelections =
      !this.isEmptySrcLocations() && !this.isEmptyDestLocations() && !this.isEmptyForklifts;

    const srcIsValid =
      this.isEnoughSrcLocations() || this.isPlantSource || this.showAutoWhSource || this.isPreZoneSource;
    const destIsValid =
      this.isEnoughDestLocations() ||
      this.isPlantDestination ||
      this.showAutoWhDestination ||
      this.isDockDestination ||
      this.isPreZoneDestination ||
      this.isSpecialZoneDestination ||
      this.isReplaceZoneDestination;

    return hasRequiredSelections && srcIsValid && destIsValid;
  }

  selectedDestLocations(itemId?: number): locationForm[] {
    return this.destLocations.controls.filter(
      (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
    );
  }

  //  Item header's "ตำแหน่ง" pill: the picked location names of one side --
  //  the first one, plus "+N" for the rest; '' when none is picked yet.
  locationSummary(locations: locationForm[]): string {
    if (locations.length === 0) return '';
    const first = locations[0].value.locationName || '-';
    return locations.length > 1 ? `${first} +${locations.length - 1}` : first;
  }

  qtyDestLocations(itemId?: number): number {
    return this.destLocations.controls
      .filter(
        (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
      )
      .reduce((sum, loc) => sum + (Number(loc.value.qty) ?? 0), 0);
  }

  confirmQtyDestLocations(itemId?: number): number {
    return this.destLocations.controls
      .filter(
        (loc) => loc.value.isSelected && (itemId === undefined || loc.value.itemId === itemId),
      )
      .reduce((sum, loc) => {
        const qty = Number(loc.value.confirmQty);
        return sum + (isNaN(qty) ? 0 : qty);
      }, 0);
  }

  isEmptyDestLocations(itemId?: number): boolean {
    if (itemId === undefined) {
      return this.jobItems.some((item) => this.selectedDestLocations(item.id).length === 0);
    }

    return this.selectedDestLocations(itemId).length === 0;
  }

  //  Locations of some item hold more than the item itself -- the location
  //  modals already refuse that, so it only happens when the item's qty was
  //  cut in the source after approve. Blocks Approve/Save (canApproveJob).
  //  Same sums the location panels show as "QTY: x / y" (qtySrc/DestLocations),
  //  so the button is disabled exactly when a panel shows the over-qty message.
  hasOverQtyLocations(): boolean {
    return this.jobItems.some(
      (item) => this.qtySrcLocations(item.id) > item.qty || this.qtyDestLocations(item.id) > item.qty,
    );
  }

  isEnoughDestLocations(itemId?: number): boolean {
    if (itemId === undefined) {
      return this.jobItems.every((item) => this.confirmQtyDestLocations(item.id) >= item.qty);
    }

    const itemQty = this.jobItems.find((i) => i.id === itemId)?.qty ?? 0;
    const confirmQty = this.confirmQtyDestLocations(itemId);
    return confirmQty >= itemQty;
  }

  forkliftForm = new FormGroup({
    forklifts: new FormArray<ForkliftForm>([]),
  });

  get forklifts(): FormArray<ForkliftForm> {
    return this.forkliftForm.controls.forklifts;
  }

  get selectedForklifts(): ForkliftForm[] {
    return this.forklifts.controls.filter((forklift) => forklift.value.isSelected);
  }

  //  Unselected forklifts for the picker, in the order the API returned them
  //  (pProcessGetForkliftAvailable already sorts) -- no client-side sorting.
  //  Rows kept from an earlier fetch (ticked but not saved) that the latest
  //  response doesn't include go last.
  get currentForklifts(): ForkliftForm[] {
    const order = new Map<number | null | undefined, number>(
      (this._forkliftAvailableData ?? []).map((forklift, index) => [forklift.id, index]),
    );
    return this.forklifts.controls
      .filter((forklift) => !forklift.value.isSelected)
      .sort((a, b) => (order.get(a.value.id) ?? Infinity) - (order.get(b.value.id) ?? Infinity));
  }

  //  "Add" button -- fetches a fresh forklift list every time the picker
  //  opens (drops unticked rows from the previous fetch first), instead of
  //  showing whatever was loaded when the page opened.
  async openForkliftModal() {
    if (this.readOnlyMode) return;
    this.resetForkliftForm();
    await this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
  }

  get isEmptyForklifts(): boolean {
    return this.selectedForklifts.length === 0;
  }

  get jobData() {
    return this._jobData ? this._jobData[0] : null;
  }

  //  Page code shown in the header (see job-detail.html's "{{ pageCode }} -
  //  Job Detail" title) - job-detail is reached from several different
  //  sidebar list pages (WH01 Inbound, WH02 Outbound, SP01 Shipping, SPC01
  //  Special all route here via goToJobDetail/Inspect), so the code has to
  //  be derived from the job's own type rather than hardcoded, to match
  //  whichever list page the user actually came from. Shipping (type_id 5)
  //  and Special (type_id 7) get their own dedicated codes since they have
  //  dedicated sidebar pages; every other Outbound type (Request/Picking/
  //  BrokenBag) falls under the general WH02 Outbound list, and Inbound
  //  falls under WH01, except Transfer WH (type_id 11) which has its own
  //  WH04 page.
  get pageCode(): string {
    if (this.jobData?.type_id === 5) return 'SP01';
    if (this.jobData?.type_id === 7) return 'SPC01';
    if (this.jobData?.type_id === 11) return 'WH04';
    if (this.jobData?.type_topic === 'Outbound') return 'WH02';
    return 'WH01';
  }

  get isRequiredStock(): boolean {
    return (
      this.jobData?.type_id === 3 || this.jobData?.type_id === 4 || this.jobData?.type_id === 7 || this.jobData?.type_id === 6 || (this.jobData?.type_id === 11 && this.isMWHSource)
    );
  }

  get isShipmentJob(): boolean {
    return this.jobData?.type_id === 4 || this.jobData?.type_id === 5;
  }

  get isPickingJob(): boolean {
    return this.jobData?.type_id === 4;
  }

  get isShippingJob(): boolean {
    return this.jobData?.type_id === 5;
  }

  get fromCostCenter() {
    return this.jobItems.find((item) => item.id === this.selectedItemId)?.pd_cc_code ?? '';
  }

  get toCostCenter() {
    return this.jobItems.find((item) => item.id === this.selectedItemId)?.pd_cc_code ?? '';
  }

  //  Cost Center for the MWH location modals' Stock inquiry APIs: only the
  //  header's selection (the modal has no Cost Center picker of its own).
  //  Add stays disabled until one is chosen (locationAddDisabledReason).
  get headerCostCenter() {
    return this.selectedCostCenter.value?.cc_code ?? '';
  }

  //  Same rule as job-wh-internal-transfer-detail's Add buttons.
  get locationAddDisabledReason() {
    return this.selectedCostCenter.value && this.selectedProductType.value
      ? ''
      : 'กรุณาเลือก Product Cost Center และ Product Type ก่อน';
  }

  get jobItems() {
    return this.jobData?.items ?? [];
  }

  //  Remark is per item. Fall back to the job-level remark only when the
  //  API is older and doesn't send items[].remark at all.
  itemRemark(item: Type.Item) {
    return item.remark !== undefined ? item.remark : this.jobData?.remark;
  }

  jobItem(itemId: number) {
    return this.jobItems.find((item) => item.id === itemId) ?? null;
  }

  //  Items' pd_type (code_t) first; falls back to the job's saved
  //  tr_job_main.product_type -- Picking items carry no code_t, so without
  //  this the Product Type saved on Approve never shows / re-selects.
  get productType() {
    return this.jobItems[0]?.pd_type || this.jobData?.product_type || '';
  }

  get jobSrcLocations() {
    return (
      this.jobItems?.filter((item) => item.id === this.selectedItemId)?.[0]?.locations
        .from_locations ?? []
    );
  }

  get jobDestLocations() {
    return (
      this.jobItems?.filter((item) => item.id === this.selectedItemId)?.[0]?.locations
        .to_locations ?? []
    );
  }

  get jobForklifts() {
    return this.jobData?.forklifts ?? [];
  }

  get isBGPlantSource(): boolean {
    return this.jobData?.from_location_type === 'BG-PLANT';
  }

  get isRQPlantSource(): boolean {
    return this.jobData?.from_location_type === 'RQ-PLANT';
  }

  get isBGPlantDestination(): boolean {
    return this.jobData?.to_location_type === 'BG-PLANT';
  }

  get isRQPlantDestination(): boolean {
    return this.jobData?.to_location_type === 'RQ-PLANT';
  }

  get isPlantSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('BG-PLANT') || type.includes('RQ-PLANT');
  }

  //  Plant rows (either side) have no qty picker, so they were saved with
  //  qty 0 -- and the *GetPallet / *PutAway procs only write
  //  tr_job_from/to_location.actual_qty when qty <> 0, so plant progress was
  //  never recorded. The item's only plant location gets the item qty
  //  instead: the qty changed after approve (source-changed banner) first,
  //  then the saved row qty, then the item qty before the first approve.
  //  null = not a single plant location, so each row keeps its own qty (no
  //  way to split one item qty over several). Shared by the save payload
  //  and job-plant-location's progress, so both show the same total.
  private plantQty(item: { id?: number | null; qty?: number | null }, locations: locationForm[]): number | null {
    if (locations.length !== 1) return null;
    const changed = this._totalPalletSourceChanged?.find(
      (change) => change.item_id === item.id && change.change_type === 'changed',
    );
    return changed?.new_qty ?? (Number(locations[0].value.qty ?? 0) || Number(item.qty ?? 0));
  }

  plantSrcQty(item: { id?: number | null; qty?: number | null }): number | null {
    return this.isPlantSource ? this.plantQty(item, this.selectedSrcLocations(item.id ?? undefined)) : null;
  }

  plantDestQty(item: { id?: number | null; qty?: number | null }): number | null {
    return this.isPlantDestination ? this.plantQty(item, this.selectedDestLocations(item.id ?? undefined)) : null;
  }

  srcLocationQty(item: { id?: number | null; qty?: number | null }, location: locationForm): number {
    return this.plantSrcQty(item) ?? Number(location.value.qty ?? 0);
  }

  destLocationQty(item: { id?: number | null; qty?: number | null }, location: locationForm): number {
    return this.plantDestQty(item) ?? Number(location.value.qty ?? 0);
  }

  get isPlantDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('BG-PLANT') || type.includes('RQ-PLANT');
  }

  get isAutoWHSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('A41') || type.includes('A43');
  }

  get isAutoWHDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('A41') || type.includes('A43');
  }

  //  A41/A43 picked from ct_auto_warehouse (job-auto-wh-location /
  //  select-auto-wh-location) instead of job-wh-location. Only
  //  job-wh-transfer-detail turns this on; job-detail keeps A41/A43 on
  //  job-wh-location.
  useAutoWhLocation = false;

  //  Paints the title icon sky blue (TW) instead of the inbound/outbound
  //  colors. Only job-wh-transfer-detail turns this on.
  useWhTransferIcon = false;
  _srcAutoWhLocationData: Type.ResultProcessAutoWhLocation[] | null = null;
  _destAutoWhLocationData: Type.ResultProcessAutoWhLocation[] | null = null;

  get showAutoWhSource(): boolean {
    return this.useAutoWhLocation && this.isAutoWHSource;
  }

  get showAutoWhDestination(): boolean {
    return this.useAutoWhLocation && this.isAutoWHDestination;
  }

  get isMWHSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('MWH');
  }

  get isMWHDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('MWH');
  }

  get isWHSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('A41') || type.includes('A43') || type.includes('MWH');
  }

  get isWHDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('A41') || type.includes('A43') || type.includes('MWH');
  }

  get preZoneSource(): string {
    return this.jobData?.from_location_cc_code ?? '';
  }

  get isPreZoneSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('PRE-ZONE');
  }

  get srcPreZoneWarehouseCode() {
    const warehouseCode = this.jobData?.from_location_type;
    return warehouseCode === 'PRE-ZONE' ? warehouseCode : '';
  }

  get destPreZoneWarehouseCode() {
    const warehouseCode = this.jobData?.to_location_type;
    return warehouseCode === 'PRE-ZONE' ? warehouseCode : '';
  }

  get preZoneDestination(): string {
    return this.jobData?.to_location_cc_code ?? '';
  }

  get isPreZoneDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('PRE-ZONE');
  }

  get isDockSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('DOCK');
  }

  get isDockDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('DOCK');
  }

  get srcDockWarehouseCode() {
    const warehouseCode = this.jobData?.from_location_type;
    return warehouseCode === 'DOCK' ? warehouseCode : '';
  }

  get destDockWarehouseCode() {
    const warehouseCode = this.jobData?.to_location_type;
    return warehouseCode === 'DOCK' ? warehouseCode : '';
  }

  get isSpecialZoneSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('SPC-ZONE');
  }

  get isSpecialZoneDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('SPC-ZONE');
  }

  get destSpecialZoneWarehouseCode() {
    const warehouseCode = this.jobData?.to_location_type;
    return warehouseCode === 'SPC-ZONE' ? warehouseCode : '';
  }

  get isReplaceZoneSource(): boolean {
    const type = this.jobData?.from_location_type ?? '';
    return type.includes('REPLACE-ZONE');
  }

  get isReplaceZoneDestination(): boolean {
    const type = this.jobData?.to_location_type ?? '';
    return type.includes('REPLACE-ZONE');
  }

  get destReplaceZoneWarehouseCode() {
    const warehouseCode = this.jobData?.to_location_type;
    return warehouseCode === 'REPLACE-ZONE' ? warehouseCode : '';
  }

  //  Step order comes from the column, not the location type: the source
  //  (GET) column is always 1 and the destination (PUT) column always 2.
  //  Deriving it from the type showed "GET" on the PUT side for e.g.
  //  PRE-ZONE -> MWH or MWH -> MWH jobs.
  readonly srcStepOrder = 1;
  readonly destStepOrder = 2;

  stepStyle(order: number): any {
    const step = this.jobData?.is_multi_fl === 'Y' ? 2 : 1;

    if (step == 1 && order === 1) return { header_text: 'GET', name: 'Step 1', color: '#22c55e' };
    if (step == 1 && order === 2) return { header_text: 'PUT', name: 'Step 1', color: '#22c55e' };
    if (step == 2 && order === 1) return { header_text: 'GET', name: 'Step 1', color: '#22c55e' };
    if (step == 2 && order === 2) return { header_text: 'PUT', name: 'Step 2', color: '#1708f5' };
  }

  get lotLocations(): any[] {
    const data = this.srcLocations.controls
      .filter((loc) => loc.value.isSelected && loc.value.itemId !== null)
      .flatMap((loc) => {
        const itemId = loc.value.itemId ?? 0;
        const grade = loc.value.grade ?? '';
        const whCode = loc.value.whCode ?? '';
        const ccCode = loc.value.ccCode ?? '';

        //  Prefer the raw addon_lot breakdown so a single location holding
        //  multiple lots shows as one chip per lot with its own qty, instead
        //  of the comma-joined lotNo the form control carries for submission.
        const rawLocation = this.jobItem(itemId)?.locations.from_locations.find(
          (fromLocation) => fromLocation.location_id === loc.value.locationId,
        );

        if (rawLocation?.addon_lot?.length) {
          return rawLocation.addon_lot
            .filter((addonLot) => !!addonLot.lot?.trim())
            .map((addonLot) => ({
              id: itemId,
              locationId: loc.value.locationId ?? 0,
              grade,
              lotNo: addonLot.lot.trim(),
              whCode,
              ccCode,
              qty: addonLot.qty,
            }));
        }

        if (!loc.value.lotNo) return [];

        return [
          {
            id: itemId,
            locationId: loc.value.locationId ?? 0,
            grade,
            lotNo: loc.value.lotNo,
            whCode,
            ccCode,
            qty: loc.value.qty ?? 0,
          },
        ];
      });

    const result = Array.from(
      data.reduce((map, item) => {
        const key = `${item.id}|${item.grade}|${item.lotNo}`;

        if (map.has(key)) {
          map.get(key)!.qty += item.qty;
        } else {
          map.set(key, { ...item });
        }

        return map;
      }, new Map<string, any>()),
    ).map(([_, item]) => item);

    return result;
  }

  itemLotLocations(itemId: number | null) {
    return this.lotLocations.filter((loc) => loc.id === itemId);
  }

  //  Item for the location pickers' header Grade / Lot chips. Picking items
  //  carry no lot_no (the lot lives on the source locations), so fall back
  //  to the selected source lots. Cached so the same object is returned
  //  while nothing changes -- a fresh object every check would re-fire the
  //  pickers' ngOnChanges.
  private _headerItemCache = new Map<number, { lotNo: string; source: any; item: any }>();

  headerItem(itemId: number | null) {
    const item = this.jobItem(itemId ?? 0);
    if (!item) return null;

    const lotNo =
      item.lot_no?.trim() ||
      Array.from(new Set(this.itemLotLocations(item.id).map((loc) => loc.lotNo))).join(', ');

    const cached = this._headerItemCache.get(item.id);
    if (cached && cached.source === item && cached.lotNo === lotNo) return cached.item;

    const headerItem = { ...item, lot_no: lotNo };
    this._headerItemCache.set(item.id, { lotNo, source: item, item: headerItem });
    return headerItem;
  }

  qtyUnit(item: any) {
    if (!item) return null;

    return item.qty_unit || null;
  }

  //  TODO: mock data until the pallet lot has a real API -- one editable Lot
  //  field under the GET column and one under the PUT column. Cached per
  //  item id so the inputs keep whatever the user typed across
  //  change-detection cycles instead of being regenerated.
  private _mockItemLotsCache = new Map<number, { size: string; lotNo: string }>();

  mockItemLots(item: any): { size: string; lotNo: string } {
    const itemId = Number(item?.id) || 0;
    const cached = this._mockItemLotsCache.get(itemId);
    if (cached) return cached;

    const baseSize = item?.lot_no?.trim() || 'ไม้ 110X110X13 cm.';
    const baseLot = item?.lot_no?.trim() || '0236336';
    const lots = { size: baseSize, lotNo: baseLot };

    this._mockItemLotsCache.set(itemId, lots);
    return lots;
  }

  constructor(
    private route: ActivatedRoute,
    private restService: CrudService,
    private location: Location,
  ) {}

  //  job-detail is reached from more than one list page (job-wh-list,
  //  job-shipping-list), so there's no single fixed route to navigate back
  //  to the way job-special-detail's goBack does -- browser history back
  //  returns to whichever list actually brought the user here.
  goBack() {
    this.location.back();
  }

  async ngOnInit() {
    this._id = Number(this.route.snapshot.paramMap.get('id') || '0');

    this._isLoading = true;

    try {
      this._jobData = (await this.fetchJobData(this._id, '', '', '', 0, 0, '')).data;

      this.selectedItemId = this.jobItems.length > 0 ? (this.jobItems[0].id ?? null) : null;

      this.jobItems.forEach((item, index) => {
        if (index === 0) {
          item.is_expanded = true;
        } else {
          item.is_expanded = false;
        }
      });

      //  initializeSrcLocation/initializeDestLocation now write to their own
      //  _srcPlantLocationData/_destPlantLocationData fields (previously a
      //  single shared _plantLocationData, which meant running them one after
      //  another still wasn't safe to parallelize -- whichever one ran last
      //  would overwrite the other's result before canModifyLocation below
      //  ever read it), so they can run concurrently.
      await Promise.all([
        !this.jobSrcLocations || this.jobSrcLocations.length === 0
          ? this.initializeSrcLocation()
          : Promise.resolve(),
        !this.jobDestLocations || this.jobDestLocations.length === 0
          ? this.initializeDestLocation()
          : Promise.resolve(),
      ]);

      this.defaultSrcLocationForm();
      this.defaultDestLocationForm();
      this.defaultForkliftForm();

      this.canModifyLocation =
        (this._srcPlantLocationData?.length ?? 0) > 1 ||
        (this._destPlantLocationData?.length ?? 0) > 1 ||
        (this._srcAutoWhLocationData?.length ?? 0) > 1 ||
        (this._destAutoWhLocationData?.length ?? 0) > 1;

      //  whLocationOptions/costCenterOptions/productTypeOptions/wmsPlusLogStatus/
      //  codePalletOptions/specialPackageTypeOptions are independent
      //  dropdown-option (and status) fetches that don't depend on each
      //  other's results -- used to run one after another (sequential
      //  round trips), same anti-pattern already fixed in job-list.ts's
      //  ngOnInit. Run them concurrently instead: total wait becomes ~max
      //  of them instead of their sum.
      const [
        whLocationOptions,
        costCenterOptions,
        productTypeOptions,
        wmsPlusLogStatus,
        codePalletOptions,
        specialPackageTypeOptions,
        ,
        totalPalletSourceChanged,
        wmsProdCcByJobOptions,
      ] = await Promise.all([
        //  A failed option fetch only leaves its dropdown empty -- it must
        //  not reject the whole Promise.all, which used to blank the page
        //  (catch below) even though the job itself had loaded.
        this.fetchOptionLocationWh(this.destWarehouseCode).catch(() => ({ data: [] })),
        this.fetchOptionWmsCcCode(this.destWarehouseCode).catch(() => ({ data: [] })),
        this.fetchOptionProductType().catch(() => ({ data: [] })),
        this.fetchWmsPlusLogStatus().catch(() => ({ data: [] })),
        this.fetchOptionCodePallet().catch(() => ({ data: [] })),
        this.fetchOptionSpecialPackageType().catch(() => ({ data: [] })),
        this.loadDoPreparingStatuses(),
        this.fetchTotalPalletSourceChanged(),
        this.fetchOptionWmsProdCcByJob(),
      ]);
      this._totalPalletSourceChanged = totalPalletSourceChanged;
      this.whLocationOptions = whLocationOptions.data;
      //  TS / RC / RQ: WH Prod CC limited to the document's plant + sloc config,
      //  same as WMS+ -- otherwise (other job types, or no config rows) the full list.
      this.isWmsProdCcByJob = (wmsProdCcByJobOptions.data?.length ?? 0) > 0;
      this.costCenterOptions = this.isWmsProdCcByJob ? wmsProdCcByJobOptions.data : costCenterOptions.data;
      this.productTypeOptions = productTypeOptions.data; 
      this.codePalletOptions = codePalletOptions.data;
      this.specialPackageTypeOptions = specialPackageTypeOptions.data;
      this.applyDefaultDoPreparingOptions();
      const wmsPlusGroup = (wmsPlusLogStatus.data ?? []).find((group) => group.job_main_id === this._id) ?? null;
      this._wmsPlusLogs = wmsPlusGroup?.logs ?? null;
      this._wmsPlusStatus = wmsPlusGroup?.logs?.[0] ?? null;
      this._wmsPlusLogPage = 1;

      if (this.jobData?.status_id && this.jobData?.status_id > 1) this.applyDefaultCostCenterAndProductType();
    } catch (error) {
      console.error('Error fetching job detail:', error);
      this._jobData = [];
    } finally {
      this._isLoading = false;
    }

    //  Pre-select the forklift Section for this page before the filter
    //  subscriptions below are wired, so it doesn't trigger a reload.
    this._searchForklift.controls.sectionIds.setValue(this.defaultForkliftSectionIds);

    this._searchForklift.controls.forkliftName.valueChanges.subscribe(async (forkliftName) => {
      this.resetForkliftForm();

      await this.loadForkliftAvailable(forkliftName || '');
    });

    this._searchForklift.controls.whCodes.valueChanges.subscribe(async () => {
      this.resetForkliftForm();

      await this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
    });

    this._searchForklift.controls.sectionIds.valueChanges.subscribe(async () => {
      this.resetForkliftForm();

      await this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
    });
  }

  compareCostCenter = (
    a: Type.ResultProcessGetOptionsWmsCcCode | null,
    b: Type.ResultProcessGetOptionsWmsCcCode | null,
  ): boolean => {
    return !!a && !!b && a.sap_cc_code === b.sap_cc_code && a.cc_code === b.cc_code;
  };

  compareCodePallet = (
    a: Type.ResultProcessGetOptionsCodePallet | null,
    b: Type.ResultProcessGetOptionsCodePallet | null,
  ): boolean => {
    return !!a && !!b && a.pallet_id === b.pallet_id;
  };

  compareSpecialPackageType = (
    a: Type.ResultProcessGetOptionsSpecialPackageType | null,
    b: Type.ResultProcessGetOptionsSpecialPackageType | null,
  ): boolean => {
    return !!a && !!b && a.special_type_package_id === b.special_type_package_id;
  };

  private applyDefaultDoPreparingOptions(): void {
    const defaultCodePallet =
      this.codePalletOptions && this.codePalletOptions.length > 0 ? this.codePalletOptions[0] : null;
    const defaultSpecialPackageType =
      this.specialPackageTypeOptions && this.specialPackageTypeOptions.length > 0
        ? this.specialPackageTypeOptions[0]
        : null;

    this.doPreparingForm.patchValue({
      selectedCodePallet: defaultCodePallet,
      codePalletName: defaultCodePallet?.name ?? '',
      selectedSpecialPackageType: defaultSpecialPackageType,
    });
  }

  //  Header's Cost Center / Product Type selects default to whatever the job's first item
  //  already carries (eg. {"pd_cc_code": "1600", "pd_type": "FG"}), same source as the
  //  fromCostCenter/toCostCenter/productType getters above - but only when that value is
  //  actually set (not null/'') and a matching option exists, otherwise the selects stay empty
  //  for the user to pick.
  //  An approved job keeps the Cost Center picked on Approve
  //  (tr_job_main.product_cc) -- prefer it over the item's pd_cc_code, or a
  //  Save would silently send the item's CC back and overwrite the pick (and
  //  recalculate total_pallet with another CC's ratio).
  private applyDefaultCostCenterAndProductType(): void {
    const savedProductCc = this.jobData?.product_cc?.trim();
    const defaultPdCcCode = this.jobItems[0]?.pd_cc_code;
    const matchedCostCenter =
      (savedProductCc && this.costCenterOptions?.find((cc) => cc.cc_code === savedProductCc)) ||
      (defaultPdCcCode && this.costCenterOptions?.find((cc) => cc.cc_code === defaultPdCcCode)) ||
      null;
    if (matchedCostCenter) this.selectedCostCenter.setValue(matchedCostCenter);

    const defaultPdType = this.productType;
    if (defaultPdType) {
      const matchedProductType = this.productTypeOptions?.find((pt) => pt.product_type === defaultPdType);
      if (matchedProductType) this.selectedProductType.setValue(matchedProductType);
    }
  }

  //  Product Type Select Event - the job's actual product type (this.productType, from the
  //  first item's pd_type) is the source of truth; a different pick is rejected outright - warn
  //  and revert back to the matching option (or null if none exists) rather than letting a
  //  mismatched value stick, so a mismatched Approve/Save request can never be sent.
  onProductTypeSelectionChange(): void {
    const jobPdType = this.productType;
    if (!jobPdType) return;

    const selectedProdType = this.selectedProductType.value?.product_type;
    if (selectedProdType && selectedProdType !== jobPdType) {
      this.SwalAlert(
        'warning',
        `Product Type ที่เลือก <b>${this.selectedProductType.value?.product_type}</b> ไม่ตรงกับ Job <b>${jobPdType}</b>`,
      );

      const matchedProductType = this.productTypeOptions?.find((pt) => pt.product_type === jobPdType);
      this.selectedProductType.setValue(matchedProductType ?? null);
    }
  }

  hasDoPreparing(itemId: number): boolean {
    return this.doPreparingSavedItemIds.has(itemId);
  }

  canShowDoPreparing(item: Type.Item | null | undefined): boolean {
    return this.isPickingJob && !!item?.do_no && item.do_no.trim() !== '';
  }

  async loadDoPreparingStatuses(): Promise<void> {
    if (!this.isPickingJob || this.jobItems.length === 0) return;

    const targetItems = this.jobItems.filter((item) => this.canShowDoPreparing(item));
    if (targetItems.length === 0) return;

    await Promise.all(
      targetItems.map(async (item) => {
        try {
          const res = await this.fetchDoPreparing(item.id);
          console.log('DO Preparing response for item', item.id, res);
          if (res?.data && res.data.length > 0) {
            this.doPreparingSavedItemIds.add(item.id);
          } else {
            this.doPreparingSavedItemIds.delete(item.id);
          }
        } catch {
          this.doPreparingSavedItemIds.delete(item.id);
        }
      }),
    );
  }

  //  DO Preparing modal (per Grade & Lot item) --------------------------------

  async onOpenDoPreparing(itemId: number): Promise<void> {
    this.selectedDoPreparingItemId = itemId;
    const defaultCodePallet =
      this.codePalletOptions && this.codePalletOptions.length > 0 ? this.codePalletOptions[0] : null;
    const defaultSpecialPackageType =
      this.specialPackageTypeOptions && this.specialPackageTypeOptions.length > 0
        ? this.specialPackageTypeOptions[0]
        : null;

    this.doPreparingForm.reset({
      selectedCodePallet: defaultCodePallet,
      codePalletName: defaultCodePallet?.name ?? '',
      palletLot: '-',
      palletQty: null,
      palletWeight: null,
      selectedSpecialPackageType: defaultSpecialPackageType,
    });

    this._isLoadingDoPreparing = true;
    try {
      const response = await this.fetchDoPreparing(itemId);
      if (this.selectedDoPreparingItemId !== itemId) return;

      if (response?.data && response.data.length > 0) {
        this.doPreparingSavedItemIds.add(itemId);
        const row = response.data[0];
        const matchedPallet =
          this.codePalletOptions?.find((p) => p.pallet_id === row.code_pallet_id) ?? defaultCodePallet;
        const matchedPackageType =
          this.specialPackageTypeOptions?.find(
            (s) => s.special_type_package_id === row.special_type_package_id,
          ) ?? defaultSpecialPackageType;

        this.doPreparingForm.patchValue({
          selectedCodePallet: matchedPallet,
          codePalletName: matchedPallet?.name ?? '',
          palletLot: row.pallet_lot != null && row.pallet_lot.trim() !== '' ? row.pallet_lot : '-',
          palletQty: row.pallet_qty ?? null,
          palletWeight: row.pallet_weight ?? null,
          selectedSpecialPackageType: matchedPackageType,
        });
      } else {
        this.doPreparingSavedItemIds.delete(itemId);
      }
    } catch (error) {
      console.warn('Could not load existing DO Preparing data for item', itemId, error);
    } finally {
      if (this.selectedDoPreparingItemId === itemId) {
        this._isLoadingDoPreparing = false;
      }
    }
  }

  onBlurPalletLot(): void {
    const current = this.doPreparingForm.controls.palletLot.value;
    if (!current || current.trim() === '') {
      this.doPreparingForm.controls.palletLot.setValue('-');
    }
  }

  get selectedDoPreparingItem() {
    return this.selectedDoPreparingItemId ? this.jobItem(this.selectedDoPreparingItemId) : null;
  }

  //  Code Pallet Select Event - the readonly "Code Pallet" textbox always
  //  mirrors the `name` of whichever pallet code was picked in the combobox.
  onCodePalletSelectionChange(): void {
    const selectedCodePallet = this.doPreparingForm.controls.selectedCodePallet.value;
    this.doPreparingForm.controls.codePalletName.setValue(selectedCodePallet?.name ?? '');
  }

  get isDoPreparingInvalid(): boolean {
    return (
      !this.doPreparingForm.controls.selectedCodePallet.value ||
      !this.doPreparingForm.controls.selectedSpecialPackageType.value
    );
  }

  onSaveDoPreparing(): void {
    if (!this.selectedDoPreparingItemId || this.isDoPreparingInvalid) {
      this.SwalAlert('warning', 'กรุณาเลือก Code Pallet และ Special Package Type ให้ครบถ้วน');
      return;
    }

    const formValue = this.doPreparingForm.value;
    const data: Type.RequestProcessUpdateDoPreparing = {
      item_id: this.selectedDoPreparingItemId,
      code_pallet_id: formValue.selectedCodePallet?.pallet_id ?? null,
      pallet_lot: formValue.palletLot?.trim() ? formValue.palletLot.trim() : '-',
      pallet_qty: formValue.palletQty ?? null,
      pallet_weight: formValue.palletWeight ?? null,
      special_type_package_id: formValue.selectedSpecialPackageType?.special_type_package_id ?? null,
    };

    console.log('Saving DO Preparing with data:', data);

    this._isSavingDoPreparing = true;
    this.restService.ProcessUpdateDoPreparing(data).subscribe({
      next: () => {
        this._isSavingDoPreparing = false;
        if (this.selectedDoPreparingItemId) {
          this.doPreparingSavedItemIds.add(this.selectedDoPreparingItemId);
        }
        this.SwalAlert('success', 'บันทึกข้อมูล DO Preparing สำเร็จ');
        document.getElementById('doPreparingModalCloseButton')?.click();
      },
      error: (error) => {
        this._isSavingDoPreparing = false;
        console.error('Error saving DO Preparing:', error);
        this.SwalAlert('error', 'บันทึกข้อมูล DO Preparing ไม่สำเร็จ');
      },
    });
  }

  async initializeSrcLocation() {
    if (this.showAutoWhSource) {
      await this.initializeAutoWhLocation('src');
      return;
    }

    this._srcPlantLocationData =
      this.jobData?.from_location_type === 'BG-PLANT'
        ? (await this.fetchBgPlantLocation(this.jobData?.from_location_cc_code || '')).data
        : this.jobData?.from_location_type === 'RQ-PLANT'
          ? (await this.fetchRqPlantLocation(this.jobData?.from_location_cc_code || '')).data
          : null;

    //  Auto-select only when the plant has exactly one location. An empty
    //  list (plant code missing from ct_bg_plant_location, e.g. 1305 PLBG)
    //  used to fall through here and add a placeholder row with
    //  locationId null / empty name -- shown as "1305 ()" on the card.
    if (this._srcPlantLocationData?.length !== 1) return;

    const location = this._srcPlantLocationData.find(
      (loc) => loc.plant_code === this.jobData?.from_location_cc_code,
    );
    if (!location) return;

    this.jobItems.forEach((item) => {
      this.addSrcLocation({
        id: null,
        itemId: item.id ?? null,
        ccCode: this.jobItem(item.id)?.pd_cc_code ?? null,
        grade: this.jobItem(item.id)?.grade ?? null,
        lotNo: this.jobItem(item.id)?.lot_no ?? null,
        locationId: location.id ?? null,
        locationType: this.jobData?.from_location_type ?? null,
        locationName: location.plant_location ?? '',
        isChecked: true,
        isSelected: true,
      });
    });
  }

  async initializeDestLocation() {
    if (this.showAutoWhDestination) {
      await this.initializeAutoWhLocation('dest');
      return;
    }

    this._destPlantLocationData =
      this.jobData?.to_location_type === 'BG-PLANT'
        ? (await this.fetchBgPlantLocation(this.jobData?.to_location_cc_code || '')).data
        : this.jobData?.to_location_type === 'RQ-PLANT'
          ? (await this.fetchRqPlantLocation(this.jobData?.to_location_cc_code || '')).data
          : null;

    //  Same exactly-one-location rule as initializeSrcLocation.
    if (this._destPlantLocationData?.length !== 1) return;

    const location = this._destPlantLocationData.find(
      (loc) => loc.plant_code === this.jobData?.to_location_cc_code,
    );
    if (!location) return;

    this.jobItems.forEach((item) => {
      this.addDestLocation({
        id: null,
        itemId: item.id ?? null,
        locationId: location.id ?? null,
        locationType: this.jobData?.to_location_type ?? null,
        locationName: location.plant_location ?? '',
        isChecked: true,
        isSelected: true,
      });
    });
  }

  //  Auto WH (A41/A43) side -- same exactly-one-location auto-select rule as
  //  the plant flow above, options from ct_auto_warehouse.
  async initializeAutoWhLocation(side: 'src' | 'dest') {
    const whCode = (side === 'src' ? this.jobData?.from_location_type : this.jobData?.to_location_type) ?? '';
    const data = (await this.fetchAutoWhLocation(whCode)).data ?? [];
    if (side === 'src') this._srcAutoWhLocationData = data;
    else this._destAutoWhLocationData = data;

    if (data.length !== 1) return;
    const location = data[0];

    this.jobItems.forEach((item) => {
      const form = {
        id: null,
        itemId: item.id ?? null,
        whCode: location.wh_code ?? null,
        locationId: location.id ?? null,
        locationType: whCode || null,
        locationName: location.wh_name ?? '',
        isChecked: true,
        isSelected: true,
      };
      if (side === 'src') {
        this.addSrcLocation({
          ...form,
          ccCode: this.jobItem(item.id)?.pd_cc_code ?? null,
          grade: this.jobItem(item.id)?.grade ?? null,
          lotNo: this.jobItem(item.id)?.lot_no ?? null,
        });
      } else {
        this.addDestLocation(form);
      }
    });
  }

  fetchAutoWhLocation(whCode: string): Promise<Type.ResponseProcessAutoWhLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetAutoWhLocation(whCode).subscribe(
        (response: Type.ResponseProcessAutoWhLocation) => resolve(response),
        (error) => {
          console.error('Error fetching auto warehouse location:', error);
          reject(error);
        },
      );
    });
  }

  //  A location can carry more than one addon_lot (e.g. a shared dock spot
  //  filled from two different source lots), so this is joined into one
  //  comma-separated string -- both the source-location and dest-location
  //  forms need the same treatment.
  private joinAddonLots(addonLots: Type.addonLot[] | null | undefined): string | null {
    return (
      addonLots
        ?.map((addonLot) => addonLot.lot?.trim())
        .filter((lot) => !!lot)
        .join(',') || null
    );
  }

  defaultSrcLocationForm() {
    this.jobItems.forEach((item) => {
      item.locations.from_locations.forEach((location) => {
        this.addSrcLocation({
          id: location.id ?? null,
          itemId: item.id ?? null,
          whCode: location.wh_code ?? null,
          ccCode: this.jobItem(item.id)?.pd_cc_code ?? null,
          grade: this.jobItem(item.id)?.grade ?? null,
          lotNo: !this.jobItem(item.id)?.lot_no
            ? this.joinAddonLots(location.addon_lot)
            : this.jobItem(item.id)?.lot_no ?? null,
          locationId: location.location_id ?? null,
          locationType: this.jobData?.from_location_type ?? null,
          locationName: location.location_name ?? '',
          qty: location.qty ?? null,
          confirmQty: location.qty ?? null,
          actualQty: location.actual_qty ?? null,
          receivedQty: location.receive_qty ?? null,
          completeQty: location.complete_qty ?? null,
          isChecked: true,
          isSelected: true,
        });
      });
    });
  }

  defaultDestLocationForm() {
    this.jobItems.forEach((item) => {
      item.locations.to_locations.forEach((location) => {
        this.addDestLocation({
          id: location.id ?? null,
          itemId: item.id ?? null,
          whCode: location.wh_code ?? null,
          ccCode: this.jobItem(item.id)?.pd_cc_code ?? null,
          grade: this.jobItem(item.id)?.grade ?? null,
          lotNo: this.joinAddonLots(location.addon_lot),
          locationId: location.location_id ?? null,
          locationType: this.jobData?.to_location_type ?? null,
          locationName: location.location_name ?? '',
          qty: location.qty ?? null,
          confirmQty: location.qty ?? null,
          actualQty: location.actual_qty ?? null,
          receivedQty: location.receive_qty ?? null,
          completeQty: location.complete_qty ?? null,
          isChecked: true,
          isSelected: true,
        });
      });
    });
  }

  //  'Warehouse,Pallet' -> 'Warehouse, Pallet' for the section chip.
  formatSectionName(sectionName: string | null | undefined): string {
    return (sectionName || '')
      .split(',')
      .map((name) => name.trim())
      .filter((name) => name.length > 0)
      .join(', ');
  }

  defaultForkliftForm() {
    this.jobForklifts.forEach((forklift) => {
      this.addForklift({
        id: forklift.id ?? null,
        forkliftName: forklift.name ?? '',
        whCode: forklift.wh_code ?? '',
        sectionName: this.formatSectionName(forklift.section_name),
        ccCode: forklift.cc_code ?? '',
        currentUserId: forklift.assignee_user_id ?? null,
        currentUserName: forklift.assignee_user_name ?? '',
        currentThaiName: forklift.assignee_user_thai_name ?? '',
        currentEngName: forklift.assignee_user_eng_name ?? '',
        jobCount: forklift.job_count ?? 0,
        isRead: forklift.is_read ?? null,
        isChecked: true,
        isSelected: true,
      });
    });
  }

  addSrcLocation(location: any) {
    const form: locationForm = new FormGroup({
      id: new FormControl<number | null>(location.id ?? null),
      itemId: new FormControl<number | null>(location.itemId ?? null),
      whCode: new FormControl<string | null>(location.whCode ?? null),
      ccCode: new FormControl<string | null>(location.ccCode ?? null),
      grade: new FormControl<string | null>(location.grade ?? null),
      lotNo: new FormControl<string | null>(location.lotNo ?? null),
      locationId: new FormControl<number | null>(location.locationId ?? null),
      locationType: new FormControl<string | null>(location.locationType ?? null),
      locationName: new FormControl<string | null>(location.locationName ?? null),
      qty: new FormControl<number | null>(location.qty ?? 0),
      confirmQty: new FormControl<number | null>(location.confirmQty ?? 0),
      actualQty: new FormControl<number | null>(location.actualQty ?? 0),
      movementUnit: new FormControl<string | null>(location.movementUnit ?? null),
      receivedQty: new FormControl<number | null>(location.receivedQty ?? 0),
      completeQty: new FormControl<number | null>(location.completeQty ?? 0),
      availableQty: new FormControl<number | null>(location.availableQty ?? 0),
      qtyLock: new FormControl<number | null>(location.qtyLock ?? 0),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
      isVisible: new FormControl<boolean | null>(true),
    });

    this.srcLocations.push(form);
  }

  onAddSrcLocation(itemId: number) {
    const parsedItemId = Number(itemId);
    if (Number.isNaN(parsedItemId)) return;

    this.selectedItemId = parsedItemId;
    this.plantLocationModalRequestId += 1;
  }

  onEditSrcLocation(location: any) {
    const itemId = Number(location?.value?.itemId);
    if (Number.isNaN(itemId)) return;

    this.selectedItemId = itemId;
    this.plantLocationModalRequestId += 1;
  }

  onDeleteSrcLocation(event: any) {
    if (!event.location || event.itemId == null) return;

    const index = this.srcLocations.controls.findIndex(
      (l) =>
        l.value.locationId === event.location!.value.locationId && l.value.itemId === event.itemId,
    );
    if (index !== -1) {
      this.srcLocations.removeAt(index);
    }
  }

  addDestLocation(location: any) {
    const form: locationForm = new FormGroup({
      id: new FormControl<number | null>(location.id ?? null),
      itemId: new FormControl<number | null>(location.itemId ?? null),
      whCode: new FormControl<string | null>(location.whCode ?? null),
      ccCode: new FormControl<string | null>(location.ccCode ?? null),
      grade: new FormControl<string | null>(location.grade ?? null),
      lotNo: new FormControl<string | null>(location.lotNo ?? null),
      locationId: new FormControl<number | null>(location.locationId ?? null),
      locationType: new FormControl<string | null>(location.locationType ?? null),
      locationName: new FormControl<string | null>(location.locationName ?? null),
      qty: new FormControl<number | null>(location.qty ?? 0),
      confirmQty: new FormControl<number | null>(location.confirmQty ?? 0),
      actualQty: new FormControl<number | null>(location.actualQty ?? 0),
      movementUnit: new FormControl<string | null>(location.movementUnit ?? null),
      receivedQty: new FormControl<number | null>(location.receivedQty ?? 0),
      completeQty: new FormControl<number | null>(location.completeQty ?? 0),
      availableQty: new FormControl<number | null>(location.availableQty ?? 0),
      qtyLock: new FormControl<number | null>(location.qtyLock ?? 0),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
      isVisible: new FormControl<boolean | null>(true),
    });

    this.destLocations.push(form);
  }

  onAddDestLocation(itemId: number) {
    const parsedItemId = Number(itemId);
    if (Number.isNaN(parsedItemId)) return;

    this.selectedItemId = parsedItemId;
    this.whLocationModalRequestId += 1;
  }

  onEditDestLocation(location: any) {
    this.selectedItemId = location?.value?.itemId || null;
    this.whLocationModalRequestId += 1;
  }

  addForklift(forklift: any) {
    const form: ForkliftForm = new FormGroup({
      id: new FormControl<number | null>(forklift.id ?? null),
      forkliftName: new FormControl<string | null>(forklift.forkliftName ?? null),
      whCode: new FormControl<string | null>(forklift.whCode ?? null),
      sectionName: new FormControl<string | null>(forklift.sectionName ?? null),
      currentUserId: new FormControl<number | null>(forklift.currentUserId ?? null),
      currentUserName: new FormControl<string | null>(forklift.currentUserName ?? null),
      currentThaiName: new FormControl<string | null>(forklift.currentThaiName ?? null),
      currentEngName: new FormControl<string | null>(forklift.currentEngName ?? null),
      isOnline: new FormControl<boolean | null>(forklift.isOnline ?? false),
      jobCount: new FormControl<number | null>(forklift.jobCount ?? 0),
      isRead: new FormControl<string | null>(forklift.isRead ?? null),
      isChecked: new FormControl<boolean | null>(forklift.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(forklift.isSelected ?? false),
    });

    this.forklifts.push(form);
  }

  onDeleteDestLocation(event: any) {
    if (!event.location || event.itemId == null) return;

    const index = this.destLocations.controls.findIndex(
      (l) =>
        l.value.locationId === event.location!.value.locationId && l.value.itemId === event.itemId,
    );
    if (index !== -1) {
      this.destLocations.removeAt(index);
    }
  }

  onSaveForklift() {
    this.forklifts.controls.forEach((forklift) => {
      forklift.controls.isSelected.setValue(forklift.controls.isChecked.value, { emitEvent: true });
    });

    this.hideForkliftModal();
    this.hideForkliftConfirmModal();
  }

  onNotSaveForklift() {
    this.forklifts.controls.forEach((forklift) => {
      forklift.controls.isChecked.setValue(forklift.controls.isSelected.value, { emitEvent: true });
    });

    this.hideForkliftModal();
    this.hideForkliftConfirmModal();
  }

  onCloseForkliftModal() {
    const hasChanges = this.forklifts.controls.some(
      (f) => f.value.isChecked !== f.value.isSelected,
    );

    if (!hasChanges) {
      if (document.getElementById('forkliftModal')) {
        this.hideForkliftModal();
        this.hideForkliftConfirmModal();
        return;
      }
    }

    this.showForkliftConfirmModal();
  }

  hideForkliftModal() {
    const modalEl = document.getElementById('forkliftModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideForkliftConfirmModal() {
    const modalEl = document.getElementById('forkliftConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showForkliftConfirmModal() {
    const modalEl = document.getElementById('forkliftConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  //  Default Section filter in the Select Forklift modal: every section
  //  (Warehouse, Loading, Pallet) on every page.
  get defaultForkliftSectionIds(): string[] {
    return FORKLIFT_SECTION_OPTIONS.map((section) => section.id);
  }

  selectAllForkliftSections() {
    this._searchForklift.controls.sectionIds.setValue(this.defaultForkliftSectionIds);
  }

  //  Trigger text for the modal's multi-selects. Every section picked reads
  //  as "ทั้งหมด"; warehouses show by name (wh_name), falling back to code.
  forkliftSectionLabels(): string[] {
    const ids = this._searchForklift.controls.sectionIds.value ?? [];
    if (ids.length === FORKLIFT_SECTION_OPTIONS.length) return ['ทั้งหมด'];
    return FORKLIFT_SECTION_OPTIONS.filter((section) => ids.includes(section.id)).map((section) => section.name);
  }

  forkliftWhLabels(): string[] {
    return (this._searchForklift.controls.whCodes.value ?? []).map(
      (code) => this.whLocationOptions?.find((wh) => wh.wh_code === code)?.wh_name || code,
    );
  }

  resetSearchForklift() {
    this._searchForklift.patchValue({
      forkliftName: '',
      whCodes: [],
      currentUser: '',
      sectionIds: this.defaultForkliftSectionIds,
    });
  }

  resetForkliftForm() {
    this.forklifts.controls
      .filter((forklift) => !forklift.value.isChecked && !forklift.value.isSelected)
      .forEach((forklift) => {
        const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
        if (index !== -1) {
          this.forklifts.removeAt(index);
        }
      });
  }

  onClickItem(itemId: number) {
    const index = this.jobItems.findIndex((item) => item.id === itemId);
    if (index !== -1) {
      this.jobItems[index].is_expanded = !this.jobItems[index].is_expanded;
    }
  }

  //  Offline forklifts can be picked too, but only after the user confirms a
  //  warning -- nobody may be logged in on that forklift to take the job yet.
  async onCheckForklift(forklift: any) {
    if (forklift.value.isChecked) return;

    if (!forklift.value.isOnline) {
      const confirmed = await confirmOfflineForklift({
        forkliftName: forklift.value.forkliftName,
        //  Job's own warehouse first, same order as the modal's badge.
        whCode: this.orderedForkliftWhCode(forklift.value.whCode),
        lastUserName: forklift.value.currentThaiName,
        jobCount: forklift.value.jobCount,
      });
      if (!confirmed) return;
    }

    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      this.forklifts.at(index).patchValue({ isChecked: true });
    }
  }

  onUnCheckForklift(forklift: any) {
    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      const currentValue = this.forklifts.at(index).value.isChecked;
      this.forklifts.at(index).patchValue({ isChecked: !currentValue });
    }
  }

  onToggleUrgent() {
    if (this.readOnlyMode) return;
    this.jobData?.is_urgent === 'Y'
      ? (this.jobData.is_urgent = 'N')
      : (this.jobData!.is_urgent = 'Y');
  }

  onToggleAdvanceOrder() {
    if (!this.canSetAdvanceOrder || !this.jobData) return;
    this.jobData.is_advance_order = this.isAdvanceOrder ? 'N' : 'Y';
  }

  //  Each Step button sets its own value -- a shared toggle flipped the
  //  value when the already-active button was clicked.
  onSetMultiForklift(value: 'Y' | 'N') {
    if (this.readOnlyMode || !this.jobData) return;
    this.jobData.is_multi_fl = value;
  }

  checkValidationErrors() {
    this.validationErrors.forklift = this.isEmptyForklifts;
    this.validationErrors.srcLocation =
      (this.isEmptySrcLocations() || !this.isEnoughSrcLocations()) &&
      (this.isEmptySrcLocations() || !this.isPlantSource) &&
      (this.isEmptySrcLocations() || !this.showAutoWhSource) &&
      (this.isEmptySrcLocations() || !this.isPreZoneSource);
    this.validationErrors.destLocation =
      (this.isEmptyDestLocations() || !this.isEnoughDestLocations()) &&
      (this.isEmptyDestLocations() || !this.isPlantDestination) &&
      (this.isEmptyDestLocations() || !this.showAutoWhDestination) &&
      !this.isPreZoneDestination &&
      !this.isSpecialZoneDestination &&
      !this.isReplaceZoneDestination;
  }

  async onApproveJob() {
    this.checkValidationErrors();

    if (!this.jobData) return;
    if (!this.canApproveJob) return;

    const requestData = {
      items: this.jobItems.map((item) => ({
        id: item.id ?? 0,
        locations: {
          fromLocations: this.selectedSrcLocations(item.id)
            .filter((fromLocation) => fromLocation.value.itemId === item.id)
            .map((fromLocation) => ({
              id: fromLocation.value.id ?? 0,
              locationId: fromLocation.value.locationId ?? 0,
              locationType: fromLocation.value.locationType ?? '',
              locationName: fromLocation.value.locationName ?? '',
              lotNo: this.isRequiredStock ? fromLocation.value.lotNo ?? '' : '',
              qty: this.srcLocationQty(item, fromLocation),
            })),
          toLocations: this.selectedDestLocations(item.id)
            .filter((toLocation) => toLocation.value.itemId === item.id)
            .map((toLocation) => ({
              id: toLocation.value.id ?? 0,
              locationId: toLocation.value.locationId ?? 0,
              locationType: toLocation.value.locationType ?? '',
              locationName: toLocation.value.locationName ?? '',
              lotNo: this.isShippingJob ? toLocation.value.lotNo ?? '' : '',
              qty: this.destLocationQty(item, toLocation),
            })),
        },
      })),
      forklifts: this.selectedForklifts.map((forklift) => ({
        id: forklift.value.id ?? 0,
      })),
      isUrgent: this.jobData.is_urgent,
      isMultiForklift: this.jobData.is_multi_fl,
      isAdvanceOrder: this.isAdvanceOrder ? 'Y' : 'N',
      productType: this.selectedProductType?.value?.product_type ?? null,
      productCostCenter: this.selectedCostCenter?.value?.cc_code ?? null,
      updateBy: 0,
    };

    //  Disable the Approve/Save button for the whole request (approve + the
    //  shipment DO edit that follows) -- same isSubmitting flow as
    //  job-wh-internal-transfer-detail's submitTransfer. requestApproveJob
    //  rejects on HTTP error, so catch it here too; otherwise the flag would
    //  never reset and the button would stay disabled with no error shown.
    this.isSubmitting = true;

    try {
      const responseApprove = await this.requestApproveJob(this.jobData.id, requestData);

      if (responseApprove?.status !== 'success') {
        Swal.fire({
          icon: 'error',
          title: 'ผิดพลาด',
          text: responseApprove?.message || 'เกิดข้อผิดพลาดขณะอนุมัติงาน',
        });
        return;
      }

      //  Shipment DO edit only after a successful approve, and before leaving
      //  the page -- its failure is reported on its own, since the approve
      //  itself has already gone through.
      if (this.isShipmentJob) {
        try {
          await this.submitEditDo();
        } catch (error) {
          await Swal.fire({
            icon: 'error',
            title: 'ผิดพลาด',
            text: 'อนุมัติงานแล้ว แต่อัปเดต DO ไม่สำเร็จ',
          });
        }
      }

      //  Guessing the list page from department id was wrong whenever the
      //  approver's department didn't match the job's actual origin (e.g. a
      //  department-6 user approving a WH job sent them to job-shipping-list
      //  instead of back to job-wh-list). goBack() already solves this
      //  exact multi-entry-point problem correctly elsewhere in this file --
      //  reuse it here instead of re-guessing.
      this.goBack();
    } catch (error) {
      Swal.fire({
        icon: 'error',
        title: 'ผิดพลาด',
        text: 'เกิดข้อผิดพลาดขณะอนุมัติงาน',
      });
    } finally {
      this.isSubmitting = false;
    }
  }

  async submitEditDo() {
    const map = new Map<number, (typeof this.lotLocations)[number]>();

    this.lotLocations.forEach((item) => {
      const existing = map.get(item.id);

      if (existing) {
        existing.qty = (existing.qty ?? 0) + (item.qty ?? 0);
      } else {
        map.set(item.id, {
          id: item.id,
          grade: item.grade,
          qty: item.qty ?? 0,
          ccCode: item.ccCode,
        });
      }
    });

    const payload = Array.from(map.values());

    if (payload.length === 0) return;

    return await this.requestEditDo({ shipments: payload });
  }

  onDeleteForklift(forklift: any) {
    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      this.forklifts.removeAt(index);
    }
  }

  //  A forklift's whCode is a comma-joined list of every warehouse it serves
  //  (e.g. "WH41, WH35, WH36, ..."), which stretched its badge into a tall
  //  column. Show one badge + "+N more" instead, with the job's own
  //  warehouse first: the Warehouse filter in the modal, then the job's PUT
  //  locations, then its GET locations. Warehouses are matched by code
  //  (M35) or name (WH35) via whLocationOptions.
  forkliftWhBadge(whCode: string | null | undefined): { first: string; rest: string[] } | null {
    const names = (whCode || '')
      .split(',')
      .map((name) => name.trim())
      .filter((name) => name.length > 0);
    if (names.length === 0) return null;

    const jobWhCodes = [
      ...(this._searchForklift.controls.whCodes.value ?? []),
      ...this.selectedDestLocations().map((loc) => loc.value.whCode),
      ...this.selectedSrcLocations().map((loc) => loc.value.whCode),
    ].filter((code): code is string => !!code);

    //  Priority order kept: first job warehouse (by the order above) that
    //  this forklift serves wins.
    let firstIndex = 0;
    for (const code of jobWhCodes) {
      const whName = this.whLocationOptions?.find((wh) => wh.wh_code === code)?.wh_name;
      const index = names.findIndex((name) => name === code || name === whName);
      if (index >= 0) {
        firstIndex = index;
        break;
      }
    }
    const first = names[firstIndex];
    const rest = names.filter((_, index) => index !== firstIndex);
    return { first, rest };
  }

  orderedForkliftWhCode(whCode: string | null | undefined): string {
    const wh = this.forkliftWhBadge(whCode);
    return wh ? [wh.first, ...wh.rest].join(', ') : '';
  }

  //  "Warehouse, Loading, Pallet" -> one chip per section on the forklift card.
  splitSections(sectionName: string | null | undefined): string[] {
    return (sectionName ?? '')
      .split(',')
      .map((section) => section.trim())
      .filter((section) => section.length > 0);
  }

  async loadForkliftAvailable(forkliftName?: string) {
    const pickedWhCodes = this._searchForklift.controls.whCodes.value ?? [];
    const whCode =
      pickedWhCodes.join(',') ||
      this.selectedDestLocations()
        ?.map((loc) => loc.value.whCode)
        .filter((code) => code !== null)
        .join(',') ||
      '';

    const isInnerWh = pickedWhCodes.length > 0 ? 'Y' : 'N';
    const sectionIds = (this._searchForklift.controls.sectionIds.value ?? []).join(',');

    this._forkliftAvailableData = (
      await this.fetchForkliftAvailable(
        whCode || '',
        forkliftName || '',
        this._searchForklift.controls.currentUser.value || '',
        isInnerWh,
        sectionIds,
      )
    ).data;

    const forkliftMap = new Map(this.selectedForklifts.map((f) => [f.value.id, f]) ?? []);

    this._forkliftAvailableData.forEach((forklift) => {
      const fl = forkliftMap.get(forklift.id);

      //  Already in the form (e.g. loaded from the saved job, which carries no
      //  online status) -- refresh its live online status/queue from this
      //  response instead of skipping it, so a saved forklift isn't shown (and
      //  warned about) as offline when it is actually online. The user fields
      //  are left alone: for a saved job they hold the job's assignee.
      const existing = this.forklifts.controls.find((f) => f.value.id === forklift.id);
      if (existing) {
        existing.patchValue({
          isOnline: forklift?.is_online === 'Y',
          jobCount: forklift?.job_count ?? 0,
          sectionName: this.formatSectionName(forklift?.section_name) || existing.value.sectionName || null,
        });
        return;
      }

      this.addForklift({
        id: forklift?.id ?? null,
        forkliftName: forklift?.fl_name ?? '',
        whCode: forklift?.wh_code ?? '',
        sectionName: this.formatSectionName(forklift?.section_name),
        ccCode: forklift?.cc_code ?? '',
        currentUserId: forklift?.current_user_id ?? null,
        currentUserName: forklift?.current_user_name ?? '',
        currentThaiName: forklift?.current_user_thai_name ?? '',
        currentEngName: forklift?.current_user_eng_name ?? '',
        isOnline: forklift?.is_online === 'Y',
        jobCount: forklift?.job_count ?? 0,
        isChecked: !!fl,
        isSelected: !!fl,
      });
    });
  }

  fetchJobData(
    id: number,
    systemNo: string,
    fromCcCode: string,
    toCcCode: string,
    jobStatus: number,
    jobType: number,
    topicName: string,
  ): Promise<Type.ResponseProcessJobListData> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetJobList(
          id,
          systemNo,
          fromCcCode,
          toCcCode,
          jobStatus,
          jobType,
          topicName,
          1,
          1,
          '',
          '',
        )
        .subscribe(
          (response: Type.ResponseProcessJobListData) => {
            resolve(response);
          },
          (error) => {
            console.error('Error fetching job data:', error);
            reject(error);
          },
        );
    });
  }

  fetchForkliftAvailable(
    whCodes: string,
    flName: string,
    currentUser: string,
    isInnerWh: string,
    sectionIds: string = '',
  ): Promise<Type.ResponseProcessForkliftAvailable> {
    return new Promise((resolve, reject) => {
      this.restService.processGetForkliftAvailable(whCodes, flName, currentUser, isInnerWh, sectionIds).subscribe(
        (response: Type.ResponseProcessForkliftAvailable) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching forklift list:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionLocationWh(wh: WarehouseCode): Promise<Type.ResponseProcessGetOptionsWh> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationWh(wh).subscribe(
        (response: Type.ResponseProcessGetOptionsWh) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location wh options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionWmsCcCode(wh: WarehouseCode): Promise<Type.ResponseProcessGetOptionsWmsCcCode> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsWmsCcCode(wh).subscribe(
        (response: Type.ResponseProcessGetOptionsWmsCcCode) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching WMS cost center options:', error);
          reject(error);
        },
      );
    });
  }

  //  WH Prod CC options of this job (TS / RC / RQ) -- same list WMS+ shows.
  //  Resolves an empty list on error so the page falls back to the full list.
  fetchOptionWmsProdCcByJob(): Promise<Type.ResponseProcessGetOptionsWmsCcCode> {
    return new Promise((resolve) => {
      this.restService.ProcessGetOptionsWmsProdCcByJob(this._id).subscribe(
        (response: Type.ResponseProcessGetOptionsWmsCcCode) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching WH Prod CC options:', error);
          resolve({ status: 'error', message: null, data: [] });
        },
      );
    });
  }

  fetchOptionProductType(): Promise<Type.ResponseProcessGetOptionsProductType> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsProductType().subscribe(
        (response: Type.ResponseProcessGetOptionsProductType) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching product type options:', error);
          reject(error);
        },
      );
    });
  }

  fetchWmsPlusLogStatus(): Promise<Type.ResponseProcessWmsPlusLogStatus> {
    return new Promise((resolve, reject) => {
      this.restService.processGetWmsPlusLogStatus(String(this._id)).subscribe(
        (response: Type.ResponseProcessWmsPlusLogStatus) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching WMS+ interface log status:', error);
          reject(error);
        },
      );
    });
  }

  //  Never rejects: a failed lookup only hides the banner, it must not
  //  break the Promise.all that loads the rest of the page.
  fetchTotalPalletSourceChanged(): Promise<Type.ResultTotalPalletSourceChangedItem[] | null> {
    return new Promise((resolve) => {
      this.restService.processGetTotalPalletSourceChanged(String(this._id)).subscribe(
        (response: Type.ResponseProcessTotalPalletSourceChanged) => {
          const items = (response.data ?? []).find((group) => group.job_main_id === this._id)?.items ?? [];
          resolve(items.length > 0 ? items : null);
        },
        (error) => {
          console.error('Error fetching total pallet source changes:', error);
          resolve(null);
        },
      );
    });
  }

  fetchOptionCodePallet(): Promise<Type.ResponseProcessGetOptionsCodePallet> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsCodePallet().subscribe(
        (response: Type.ResponseProcessGetOptionsCodePallet) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching code pallet options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionSpecialPackageType(): Promise<Type.ResponseProcessGetOptionsSpecialPackageType> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsSpecialPackageType().subscribe(
        (response: Type.ResponseProcessGetOptionsSpecialPackageType) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching special package type options:', error);
          reject(error);
        },
      );
    });
  }

  fetchDoPreparing(itemId: number): Promise<Type.ResponseProcessGetDoPreparing> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetDoPreparing(itemId).subscribe({
        next: (response: Type.ResponseProcessGetDoPreparing) => {
          resolve(response);
        },
        error: (error) => {
          console.error('Error fetching DO Preparing data:', error);
          reject(error);
        },
      });
    });
  }

  //  #wmsPlusDetailModal's payload copy button.
  copyToClipboard(text: string | null) {
    if (!text) return;
    navigator.clipboard?.writeText(text).catch((error) => console.error('Copy failed:', error));
  }

  //  #wmsPlusDetailModal's Payload box -- param is stored as a raw one-line
  //  JSON string; pretty-print with indent so items[] etc. are readable.
  //  Falls back to the raw text if it isn't valid JSON.
  formatJsonPayload(text: string | null): string {
    if (!text) return '-';
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }

  //  #wmsPlusDetailModal's Message box -- WMS+'s own reply wraps the real
  //  text in {result, message}; showing that whole envelope (e.g.
  //  {"result":[{"column1":1}],"message":"OK"}) is just noise, so pull the
  //  inner "message" out when present. Falls back to the full pretty-printed
  //  JSON for shapes without that field, or the raw text if not JSON.
  formatWmsMessage(text: string | null): string {
    if (!text) return '-';
    try {
      const parsed = JSON.parse(text);
      if (parsed && typeof parsed === 'object' && typeof parsed.message === 'string') {
        return parsed.message;
      }
      return JSON.stringify(parsed, null, 2);
    } catch {
      return text;
    }
  }

  get pagedWmsPlusLogs(): Type.ResultProcessWmsPlusLogStatus[] {
    const start = (this._wmsPlusLogPage - 1) * this.wmsPlusLogPageSize;
    return (this._wmsPlusLogs ?? []).slice(start, start + this.wmsPlusLogPageSize);
  }

  //  Re-sends the WMS+ confirm-location notification for this job (see
  //  job-detail.html's resend button on a "Failed" WMS+ badge) -- mirrors
  //  job-list.ts's resendWmsPlus. The backend rebuilds the payload from
  //  current DB state, so this just needs the job id; re-reads the real log
  //  row afterwards rather than fabricating the badge update client-side.
  async resendWmsPlus() {
    if (this._isResendingWmsPlus || !this._id) return;

    this._isResendingWmsPlus = true;

    try {
      const response = await new Promise<Type.ResponseProcessResendWmsPlus>((resolve, reject) => {
        this.restService.processResendWmsPlus(this._id).subscribe(
          (res: Type.ResponseProcessResendWmsPlus) => resolve(res),
          (error) => reject(error),
        );
      });

      if (response.wmsPlusStatus === 'not_applicable') {
        this.SwalAlert('info', 'งานนี้ไม่มีขั้นตอนแจ้งเตือน WMS+');
      } else if (response.wmsPlusStatus === 'failed') {
        this.SwalAlert('error', response.wmsPlusMessage || 'ส่งข้อมูลไปยัง WMS+ ไม่สำเร็จ');
      }

      const logResponse = await this.fetchWmsPlusLogStatus();
      const wmsPlusGroup = (logResponse.data ?? []).find((group) => group.job_main_id === this._id) ?? null;
      this._wmsPlusLogs = wmsPlusGroup?.logs ?? null;
      this._wmsPlusStatus = wmsPlusGroup?.logs?.[0] ?? null;
      this._wmsPlusLogPage = 1;
    } catch (error) {
      console.error('Error resending WMS+ notification:', error);
      this.SwalAlert('error', 'เกิดข้อผิดพลาดขณะส่งข้อมูลไปยัง WMS+ ซ้ำ');
    } finally {
      this._isResendingWmsPlus = false;
    }
  }

  fetchBgPlantLocation(bgPlantCode: string): Promise<Type.ResponseProcessBgPlantLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetBgPlantLocation(bgPlantCode).subscribe(
        (response: Type.ResponseProcessBgPlantLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching bg plant location:', error);
          reject(error);
        },
      );
    });
  }

  fetchRqPlantLocation(rqPlantCode: string): Promise<Type.ResponseProcessRqPlantLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetRqPlantLocation(rqPlantCode).subscribe(
        (response: Type.ResponseProcessRqPlantLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching rq plant location:', error);
          reject(error);
        },
      );
    });
  }

  requestApproveJob(id: number, data: any): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.restService.processApproveJob(id, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error) => {
          console.error('Error approving job:', error);
          reject(error);
        },
      );
    });
  }

  requestEditDo(data: any): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessUpdateDo(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error) => {
          console.error('Error editing DO:', error);
          reject(error);
        },
      );
    });
  }

  //  Status badge class by ct_job_status.id -- status_name now comes back
  //  in Thai (name_th), so it can no longer be kebab-cased into the
  //  .status-pending/.status-wh-approved/... classes.
  jobStatusClass(statusId?: number | null): string {
    switch (statusId) {
      case 1: return 'status-pending';
      case 2: return 'status-wh-approved';
      case 3: return 'status-sp-approve';
      case 4: return 'status-in-progress';
      case 5: return 'status-complete';
      case 6: return 'status-mapping-do';
      default: return '';
    }
  }

  replaceWhiteSpaceWithDash(input: string): string {
    return input.replace(/\s+/g, '-').toLowerCase();
  }

  //  API dates come back either as ISO (local/mock backend) or as
  //  d/m/yyyy HH:mm:ss with a Buddhist-Era year (real qas-qtrack backend,
  //  e.g. "28/8/2569 7:52:16" for 2026-08-28) -- `new Date(...)` can't
  //  parse the latter and silently yields Invalid Date, which is why
  //  dates/times render as '-' only once deployed against the real API.
  parseJobDate(value?: string | Date | null): Date | null {
    if (!value) return null;
    if (value instanceof Date) return isNaN(value.getTime()) ? null : value;

    const trimmed = value.trim();
    const m = trimmed.match(
      /^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/,
    );
    if (m) {
      const day = parseInt(m[1], 10);
      const month = parseInt(m[2], 10) - 1;
      let year = parseInt(m[3], 10);
      if (year < 100) year += 2000;
      if (year > 2400) year -= 543;
      const hours = m[4] ? parseInt(m[4], 10) : 0;
      const minutes = m[5] ? parseInt(m[5], 10) : 0;
      const seconds = m[6] ? parseInt(m[6], 10) : 0;
      const d = new Date(year, month, day, hours, minutes, seconds);
      return isNaN(d.getTime()) ? null : d;
    }

    const iso = new Date(trimmed);
    return isNaN(iso.getTime()) ? null : iso;
  }

  SwalAlert(icon: SweetAlertIcon, message: string) {
    const titles = {
      success: 'Success',
      error: 'Error',
      warning: 'Warning',
      info: 'Information',
      question: 'Confirmation',
    };

    Swal.fire({
      position: 'center',
      icon,
      title: `<span style="font-size:22px;font-weight:600;">${titles[icon] ?? 'Notice'}</span>`,
      html: `<span style="font-size:16px;">${message}</span>`,
      showConfirmButton: true,
    });
  }
}
