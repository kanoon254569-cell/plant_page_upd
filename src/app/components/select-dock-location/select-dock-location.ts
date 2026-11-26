import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import Notify, { NotifyIcon } from '../../shared/notify';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';

type WarehouseCode = 'DOCK';

type locationForm = FormGroup<{
  id: FormControl<number | null>;
  itemId: FormControl<number | null>;
  whCode: FormControl<string | null>;
  locationId: FormControl<number | null>;
  locationType: FormControl<string | null>;
  locationName: FormControl<string | null>;
  lotNo: FormControl<string | null>;
  qty: FormControl<number | null>;
  confirmQty: FormControl<number | null>;
  actualQty: FormControl<number | null>;
  receivedQty: FormControl<number | null>;
  completeQty: FormControl<number | null>;
  availableQty: FormControl<number | null>;
  qtyLock: FormControl<number | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
}>;

type locationInput = {
  id: number | null;
  itemId: number | null;
  whCode: string | null;
  locationId: number | null;
  locationType: string | null;
  locationName: string | null;
  lotNo?: string | null;
  qty: number | null;
  confirmQty: number | null;
  actualQty: number | null;
  receivedQty: number | null;
  completeQty: number | null;
  availableQty: number | null;
  qtyLock: number | null;
  isChecked: boolean;
  isSelected: boolean;
};

export type SourceLotLocation = { lotNo: string; qty: number };

@Component({
  selector: 'app-select-dock-location',
  standalone: false,
  templateUrl: './select-dock-location.html',
  styleUrl: './select-dock-location.css',
})
export class SelectDockLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Display-only item for the header Grade / Lot chips.
  @Input() headerItem: Type.Item | null = null;
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() currentItemQty = 0;
  @Input() warehouseCode: WarehouseCode = 'DOCK';
  @Input({ required: true }) costCenter = '';
  @Input() itemData: Type.Item | null = null;
  @Input() isRequiredStock = false;
  @Input() openRequestId = 0;
  //  Selected value (wms_group) of the page header's Product Type dropdown.
  @Input() productType = '';
  @Input() enableQty = false;
  @Input() sourceLotLocations: SourceLotLocation[] = [];

  selectedLotNo: string | null = null;
  allLotsSelected = false;

  //  When there's only one source lot there's nothing to choose, so it's
  //  applied automatically; with more than one, the user must click a chip
  //  (or "All") first -- mirrors the "select A, then pick B" pairing
  //  pattern used for Map DO in job-list.
  get effectiveLotNo(): string | null {
    if (this.sourceLotLocations.length === 1) return this.sourceLotLocations[0].lotNo;
    return this.selectedLotNo;
  }

  get isUsingAllLots(): boolean {
    return this.sourceLotLocations.length > 1 && this.allLotsSelected;
  }

  onSelectSourceLot(lotNo: string) {
    if (this.isLotExhausted(lotNo)) return;
    this.allLotsSelected = false;
    this.selectedLotNo = this.selectedLotNo === lotNo ? null : lotNo;
  }

  onSelectAllLots() {
    if (this.isAllLotsExhausted) return;
    this.selectedLotNo = null;
    this.allLotsSelected = !this.allLotsSelected;
  }

  //  A lot is exhausted once its full qty has already been committed to
  //  checked locations for the current item -- at that point it can't take
  //  any more, so the chip is disabled instead of letting the user pick it
  //  and immediately hit the qty-overflow guard.
  isLotExhausted(lotNo: string): boolean {
    const lot = this.sourceLotLocations.find((l) => l.lotNo === lotNo);
    if (!lot) return false;

    return this.qtyAssignedForLot(lotNo, this.selectedItemId ?? undefined) >= lot.qty;
  }

  get isAllLotsExhausted(): boolean {
    return this.sourceLotLocations.every((lot) => this.isLotExhausted(lot.lotNo));
  }

  //  Total qty still available across every source lot combined, for the
  //  "All" mode where a location can draw from whichever lots still have
  //  stock left rather than being pinned to one specific lot.
  totalRemainingLotQty(itemId?: number, excludeLocationId?: number | null): number {
    return this.sourceLotLocations.reduce(
      (sum, lot) =>
        sum + Math.max(0, lot.qty - this.qtyAssignedForLot(lot.lotNo, itemId, excludeLocationId)),
      0,
    );
  }

  //  Draws `qty` out of the source lots in order (first lot first), and
  //  returns the comma-joined list of lots it was actually drawn from --
  //  mirrors the comma-join convention job-detail already uses when a
  //  single src location holds more than one lot.
  private allocateAcrossLots(qty: number, itemId?: number, excludeLocationId?: number | null): string {
    let remaining = qty;
    const consumedLots: string[] = [];

    for (const lot of this.sourceLotLocations) {
      if (remaining <= 0) break;

      const availableInLot = lot.qty - this.qtyAssignedForLot(lot.lotNo, itemId, excludeLocationId);
      if (availableInLot <= 0) continue;

      consumedLots.push(lot.lotNo);
      remaining -= Math.min(availableInLot, remaining);
    }

    return consumedLots.join(',');
  }

  get isFullQtyAssigned(): boolean {
    return this.confirmQtyWhLocations(this.selectedItemId ?? undefined) >= this.currentItemQty;
  }
  
  _dockLocationData!: Type.ResultProcessDockLocation[] | null;

  wmsCcCodeOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = [];
  whLocationOptions: Type.ResultProcessGetOptionsWh[] | null = [];
  areaLocationOptions: Type.ResultProcessGetOptionsArea[] | null = [];
  levelLocationOptions: Type.ResultProcessGetOptionsLevel[] | null = [];

  _stockInquiryData!: Type.ResultProcessStockInquiry[] | null;
  _gradeWithSapCcCodeData!: Type.ResultProcessGetGradeWithSapCcCode[] | null;

  _isExplandSearch = false;
  _isExplandStockInquiry = true;

  searchForm = new FormGroup({
    wh: new FormControl<WarehouseCode>('DOCK', { nonNullable: true }),
    whCode: new FormControl(''),
    //  Area needs a Warehouse first, Level needs an Area (registerSearchHandlers).
    areaCode: new FormControl({ value: '', disabled: true }),
    levelCode: new FormControl({ value: '', disabled: true }),
    locationCode: new FormControl(''),
  });

  stockInquiryForm = new FormGroup({
    ccCode: new FormControl(''),
    grade: new FormControl(''),
    lotNo: new FormControl(''),
    invDate: new FormControl<Date | null>(null),
    prodType: new FormControl(''),
  });

  private isInitialized = false;

  constructor(private restService: CrudService) {}

  get headerGrade(): string {
    return (this.headerItem ?? this.currentItem)?.grade?.trim() ?? '';
  }

  get headerLotNo(): string {
    return (this.headerItem ?? this.currentItem)?.lot_no?.trim() ?? '';
  }

  getCcCode(sapCcCode: string): string {
    return this.wmsCcCodeOptions?.find((cc) => cc.sap_cc_code === sapCcCode)?.cc_code ?? '';
  }

  get currentItem(): Type.Item | null {
    if (!this.itemData) return null;
    if (this.selectedItemId === null) return this.itemData;
    return this.itemData.id === this.selectedItemId ? this.itemData : null;
  }

  //  Product type sent to the stock search: the page header's Product Type
  //  dropdown first, then the job item's own wms_group / pd_type.
  get defaultProdType(): string {
    return this.productType || this.currentItem?.wms_group || this.currentItem?.pd_type || '';
  }

  get currentWhLocations(): locationForm[] {
    return this.locations.controls
      .filter((loc) => loc.value.itemId === this.selectedItemId)
      .sort((a, b) => Number(a.value.locationId) - Number(b.value.locationId));
  }

  get currentWhLocationQty(): number {
    return this.locations.controls
      .filter((loc) => loc.value.itemId === this.selectedItemId && loc.value.isChecked)
      .reduce((sum, loc) => sum + (Number(loc.value.confirmQty) ?? 0), 0);
  }

  checkedWhLocation(itemId?: number): locationForm[] {
    return this.locations.controls.filter(
      (loc) => loc.value.isChecked && (itemId === undefined || loc.value.itemId === itemId),
    );
  }

  isHiddenAvailableQty(location: locationForm): boolean {
    return (
      location.value.availableQty === 0 || !location.value.availableQty || !this.isRequiredStock
    );
  }

  isHiddenLockQty(location: locationForm): boolean {
    return (
      location.value.availableQty === 0 || !location.value.availableQty || !this.isRequiredStock
    );
  }

  //  A location the forklift already moved stock into/out of (actualQty > 0)
  //  can't be removed from the job anymore.
  hasActualQty(location: locationForm): boolean {
    return (location.value.actualQty ?? 0) > 0;
  }

  isDisabledLocation(location: locationForm): boolean {
    return (
      (location.value.availableQty === 0 || !location.value.availableQty) && this.isRequiredStock
    );
  }

  //  Dock name as on Location Management, the signage and the QR: the raw
  //  dock_name (location_desc, eg. "40D04"). pILogistic_ProcessGetDockLocation
  //  prefixes "WH" onto wh_code, so joining the parts gave "WH40D04". Rows
  //  without location_desc (stock inquiry) fall back to the joined parts with
  //  that leading "WH" dropped.
  getLocationName(location: any | null): string {
    if (!location) return '';
    const locationDesc = (location.location_desc ?? '').trim();
    if (locationDesc) return locationDesc;
    return this.stripWhPrefix(
      `${location.wh_code === '-' || !location.wh_code ? '' : location.wh_code}${location.area_code === '-' || !location.area_code ? '' : location.area_code}${location.level_code === '-' || !location.level_code ? '' : location.level_code}${location.location_code === '-' || !location.location_code ? '' : location.location_code}`,
    );
  }

  private stripWhPrefix(name: string): string {
    return name.toUpperCase().startsWith('WH') ? name.slice(2) : name;
  }

  get isGradeCorrect(): boolean {
    return (
      (this._gradeWithSapCcCodeData && this._gradeWithSapCcCodeData?.length > 0) ||
      !this.isRequiredStock
    );
  }

  get isHidenTitleFilter(): boolean {
    return !this.isRequiredStock;
  }

  get isHidenStockFilter(): boolean {
    return !this.isRequiredStock;
  }

  async ngOnInit() {
    this.isInitialized = true;
    this._isExplandSearch = !this.isRequiredStock;
    this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });
    this.stockInquiryForm.patchValue(
      {
        ccCode: this.costCenter ?? '',
        grade: this.currentItem?.grade ?? '',
        lotNo: this.currentItem?.lot_no ?? '',
        invDate: new Date(),
        prodType: this.defaultProdType,
      },
      { emitEvent: false },
    );
    this.registerSearchHandlers();
    this.registerStockInquiryHandlers();
    this.initializeWarehouseOptions();
    this.initializeLocationData();
  }

  ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;

    if (changes['productType'] || changes['openRequestId']?.currentValue) {
      this.stockInquiryForm.patchValue({ prodType: this.defaultProdType }, { emitEvent: false });
    }

    if (changes['openRequestId']?.currentValue) {
      this.selectedLotNo = null;
      this.allLotsSelected = false;
    }

    if (changes['warehouseCode']) {
      this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });
      this.initializeWarehouseOptions();
    }

    if (changes['openRequestId']?.currentValue && this.isRequiredStock) {
      this.loadStockInquiryData();
      this.loadGradeWithSapCcCode();
    }

    if (
      changes['openRequestId']?.currentValue &&
      this.searchForm.controls.whCode.value
    ) {
      this.loadDockLocationData();
    }
  }

  registerSearchHandlers() {
    this.searchForm.controls.whCode.valueChanges.subscribe(async (whCode) => {
      this.areaLocationOptions = [];
      this.levelLocationOptions = [];
      this.resetWhLocationForm();
      this.searchForm.controls.areaCode.disable({ emitEvent: false });
      this.searchForm.controls.levelCode.disable({ emitEvent: false });

      this.searchForm.patchValue(
        { areaCode: '', levelCode: '', locationCode: '' },
        { emitEvent: false },
      );

      if (!whCode) return;

      //  Area / level dropdowns were removed: picking a warehouse lists all
      //  of its dock locations directly.
      await this.loadDockLocationData();
    });

    this.searchForm.controls.areaCode.valueChanges.subscribe(async (areaCode) => {
      this.levelLocationOptions = [];
      this.resetWhLocationForm();

      this.searchForm.patchValue({ levelCode: '', locationCode: '' }, { emitEvent: false });
      this.searchForm.controls.levelCode.disable({ emitEvent: false });

      if (!areaCode) return;

      this.searchForm.controls.levelCode.enable({ emitEvent: false });
      this.levelLocationOptions = (
        await this.fetchOptionLocationLevel(
          this.searchForm.controls.wh.value,
          this.searchForm.controls.whCode.value || '',
          areaCode,
          '',
        )
      ).data;
    });

    this.searchForm.controls.levelCode.valueChanges.subscribe(async (levelCode) => {
      this.resetWhLocationForm();
      this.searchForm.patchValue({ locationCode: '' }, { emitEvent: false });

      if (!levelCode) return;

      await this.loadDockLocationData(levelCode);
    });
  }

  registerStockInquiryHandlers() {
    this.stockInquiryForm.controls.ccCode.valueChanges.subscribe(async (ccCode) => {
      if (!ccCode && this.isRequiredStock) return;

      await this.loadStockInquiryData();
    });

    this.stockInquiryForm.controls.grade.valueChanges.subscribe(async (grade) => {
      if (!grade && this.isRequiredStock) return;

      await this.loadStockInquiryData();
      await this.loadGradeWithSapCcCode();
    });

    this.stockInquiryForm.controls.lotNo.valueChanges.subscribe(async (lotNo) => {
      if (!lotNo && this.isRequiredStock) return;

      await this.loadStockInquiryData();
    });

    this.stockInquiryForm.controls.invDate.valueChanges.subscribe(async (invDate) => {
      if (!invDate && this.isRequiredStock) return;

      await this.loadStockInquiryData();
    });
  }

  async initializeLocationData() {
    this.loadDockLocationData();
  }

  async initializeWarehouseOptions() {
    this.whLocationOptions = (await this.fetchOptionLocationDockWh(this.warehouseCode)).data;
    this.wmsCcCodeOptions = (await this.fetchOptionWmsCcCode(this.warehouseCode)).data;
  }

  onClose() {
    const hasChanges = this.locations.controls.some(
      (loc) => loc.value.isChecked !== loc.value.isSelected,
    );

    if (!hasChanges) {
      if (document.getElementById('dockLocationModal')) {
        this.hideDockLocationModal();
        this.hideDockLocationConfirmModal();
        return;
      }
    }

    this.showDockLocationConfirmModal();
  }

  onResetSearch() {
    this.searchForm.patchValue({
      whCode: '',
      areaCode: '',
      levelCode: '',
      locationCode: '',
    });

    this.loadStockInquiryData();
  }

  onCheckLocation(location: locationForm) {
    if (location.value.isChecked) {
      return;
    }

    if (this.sourceLotLocations.length > 1 && !this.selectedLotNo && !this.allLotsSelected) {
      this.SwalAlert('warning', 'กรุณาเลือก Lot ก่อน แล้วค่อยเลือก Location');
      return;
    }

    const control = this.currentWhLocations.find(
      (currentLocation) => currentLocation.value.locationId === location.value.locationId,
    );

    if (control) {
      if (this.enableQty) this.onAssignLocationQty(location.value);
      else
        this.locations.at(this.locations.controls.indexOf(control)).patchValue({ isChecked: true });
    }
  }

  //  Clicking the qty pill of a checked row reopens the qty prompt so the
  //  user can change it without removing the location first.
  onEditLocationQty(location: locationForm, event: MouseEvent) {
    event.stopPropagation();
    this.onAssignLocationQty(location.value);
  }

  onUncheckLocation(location: locationForm) {
    if (this.hasActualQty(location)) {
      return;
    }

    const control = this.currentWhLocations.find(
      (currentLocation) => currentLocation.value.locationId === location.value.locationId,
    );

    control?.patchValue({ confirmQty: 0, lotNo: null, isChecked: false });
  }

  onSave() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isSelected.setValue(loc.controls.isChecked.value, { emitEvent: true });
      loc.controls.qty.setValue(
        loc.controls.isChecked.value ? loc.controls.confirmQty.value : loc.controls.qty.value,
        { emitEvent: true },
      );
    });

    this.hideDockLocationModal();
    this.hideDockLocationConfirmModal();
  }

  onCancel() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isChecked.setValue(loc.controls.isSelected.value, { emitEvent: true });
      loc.controls.confirmQty.setValue(loc.controls.qty.value, { emitEvent: true });
    });

    this.hideDockLocationModal();
    this.hideDockLocationConfirmModal();
  }

  resetWhLocationForm() {
    this.locations.controls
      .filter((loc) => !loc.value.isChecked && !loc.value.isSelected)
      .forEach((loc) => {
        const index = this.locations.controls.findIndex(
          (currentLocation) =>
            currentLocation.value.locationId === loc.value.locationId &&
            currentLocation.value.itemId === loc.value.itemId,
        );
        if (index !== -1) {
          this.locations.removeAt(index);
        }
      });
  }

  addWhLocation(location: locationInput) {
    const form: locationForm = new FormGroup({
      id: new FormControl<number | null>(location.id ?? null),
      itemId: new FormControl<number | null>(location.itemId ?? null),
      whCode: new FormControl<string | null>(location.whCode ?? null),
      locationId: new FormControl<number | null>(location.locationId ?? null),
      locationType: new FormControl<string | null>(location.locationType ?? null),
      locationName: new FormControl<string | null>(location.locationName ?? null),
      lotNo: new FormControl<string | null>(location.lotNo ?? null),
      qty: new FormControl<number | null>(location.qty ?? 0),
      confirmQty: new FormControl<number | null>(location.confirmQty ?? 0),
      actualQty: new FormControl<number | null>(location.actualQty ?? 0),
      availableQty: new FormControl<number | null>(location.availableQty ?? 0),
      qtyLock: new FormControl<number | null>(location.qtyLock ?? 0),
      receivedQty: new FormControl<number | null>(location.receivedQty ?? 0),
      completeQty: new FormControl<number | null>(location.completeQty ?? 0),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
    });

    this.locations.push(form);
  }

  confirmQtyWhLocations(itemId?: number): number {
    return this.locations.controls
      .filter((loc) => loc.value.isChecked && (itemId === undefined || loc.value.itemId === itemId))
      .reduce((sum, loc) => sum + (Number(loc.value.confirmQty) ?? 0), 0);
  }

  async onBlurWhLocation(): Promise<HTMLElement | null> {
    const modalContent = document.querySelector(
      '#dockLocationModal .modal-content',
    ) as HTMLElement | null;

    const activeElement = document.activeElement as HTMLElement | null;
    activeElement?.blur();

    return modalContent;
  }

  //  A location assigned in "All" mode stores its lotNo as a comma-joined
  //  list (e.g. "L0001,230000001") since it may draw from more than one
  //  source lot at once. Reconstructs how much of that combined qty came
  //  from each individual lot by replaying the same FIFO order used at
  //  assignment time (see allocateAcrossLots) -- a plain `lotNo === X`
  //  match would never recognize such a location against either lot it
  //  actually drew from, so exhaustion would never trigger.
  private computeLotUsage(itemId?: number, excludeLocationId?: number | null): Map<string, number> {
    const usage = new Map<string, number>(this.sourceLotLocations.map((lot) => [lot.lotNo, 0]));

    const checkedLocations = this.locations.controls.filter(
      (loc) =>
        loc.value.isChecked &&
        loc.value.lotNo &&
        (itemId === undefined || loc.value.itemId === itemId) &&
        loc.value.locationId !== excludeLocationId,
    );

    for (const loc of checkedLocations) {
      const confirmQty = Number(loc.value.confirmQty) || 0;
      const touchedLots = loc.value
        .lotNo!.split(',')
        .map((lotNo) => lotNo.trim())
        .filter((lotNo) => usage.has(lotNo));

      if (touchedLots.length === 0 || confirmQty <= 0) continue;

      if (touchedLots.length === 1) {
        usage.set(touchedLots[0], (usage.get(touchedLots[0]) ?? 0) + confirmQty);
        continue;
      }

      let remaining = confirmQty;
      for (const lot of this.sourceLotLocations) {
        if (remaining <= 0) break;
        if (!touchedLots.includes(lot.lotNo)) continue;

        const alreadyUsed = usage.get(lot.lotNo) ?? 0;
        const availableInLot = lot.qty - alreadyUsed;
        if (availableInLot <= 0) continue;

        const draw = Math.min(availableInLot, remaining);
        usage.set(lot.lotNo, alreadyUsed + draw);
        remaining -= draw;
      }
    }

    return usage;
  }

  //  Qty already committed to `lotNo` across other checked locations, so a
  //  location being (re)assigned can't push the lot's total past what the
  //  source actually has.
  qtyAssignedForLot(lotNo: string, itemId?: number, excludeLocationId?: number | null): number {
    return this.computeLotUsage(itemId, excludeLocationId).get(lotNo) ?? 0;
  }

  async onAssignLocationQty(data: locationForm['value']) {
    if (!data) return;

    const modalContent = await this.onBlurWhLocation();
    const usingAllLots = this.isUsingAllLots;
    const singleLotNo = usingAllLots ? null : this.effectiveLotNo;
    const itemId = data.itemId ?? undefined;
    const excludeLocationId = data.locationId;

    const lotRemainingQty = usingAllLots
      ? this.totalRemainingLotQty(itemId, excludeLocationId)
      : singleLotNo
        ? (this.sourceLotLocations.find((lot) => lot.lotNo === singleLotNo)?.qty ?? 0) -
          this.qtyAssignedForLot(singleLotNo, itemId, excludeLocationId)
        : null;

    const lotLabel = usingAllLots ? 'ทั้งหมด' : singleLotNo;

    //  Same input + "ทั้งหมด" pill as select-wh-location: the pill fills the
    //  input with what is left (item qty minus other locations, capped by the
    //  lot's remaining qty) and submits.
    const othersConfirmed =
      this.confirmQtyWhLocations(itemId) - (data.isChecked ? Number(data.confirmQty) || 0 : 0);
    const itemRemainingQty = this.currentItemQty - othersConfirmed;
    const remainingQty =
      lotRemainingQty !== null ? Math.min(itemRemainingQty, lotRemainingQty) : itemRemainingQty;
    const selectAllQty = remainingQty > 0 ? remainingQty : null;
    const initialValue = data.confirmQty === 0 ? '' : String(data.confirmQty ?? '');
    const fmt = (qty: number) => qty.toLocaleString('en-US');

    Notify.fire({
      target: modalContent ?? undefined,
      backdrop: modalContent ? false : true,
      returnFocus: false,
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (kg) : ${data.locationName}</span>`,
      html: `
        <style>
          #swal-qty-input::-webkit-outer-spin-button,
          #swal-qty-input::-webkit-inner-spin-button {
            -webkit-appearance: none;
            margin: 0;
          }
          #swal-qty-input {
            -moz-appearance: textfield;
          }
          #swal-qty-group:focus-within {
            border-color: #1d4ed8;
            box-shadow: 0 0 0 3px rgba(29, 78, 216, 0.12);
          }
          #swal-select-all-btn:hover {
            background: #e0e7ff;
          }
          #swal-select-all-btn:active {
            background: #c7d2fe;
          }
        </style>
        ${
          lotLabel
            ? `<div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 12px; border: 1px solid #dbeafe; border-radius: 8px; background: #eff6ff; text-align: left;">
                <div style="display: flex; flex-direction: column; gap: 2px; min-width: 0;">
                  <span style="font-size: 12px; font-weight: 600; letter-spacing: 0.04em; color: #64748b;">LOT</span>
                  <span style="font-size: 15px; font-weight: 700; color: #1e3a8a; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">${lotLabel}</span>
                </div>
                ${
                  lotRemainingQty !== null
                    ? `<div style="display: flex; flex-direction: column; align-items: flex-end; gap: 2px; flex: none;">
                        <span style="font-size: 12px; font-weight: 600; color: #64748b;">คงเหลือ</span>
                        <span style="font-size: 15px; font-weight: 700; color: #1d4ed8;">${fmt(lotRemainingQty)} kg</span>
                      </div>`
                    : ''
                }
              </div>`
            : ''
        }
        <!-- Label lines up with the input box's left edge (same as select-wh-location's lot prompt). -->
        <div style="margin-top: 14px; padding: 0 2px; font-size: 14px; font-weight: 500; color: #475569; text-align: left;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</div>
        <div
          id="swal-qty-group"
          style="display: flex; align-items: stretch; margin-top: 6px; height: 44px; border: 1px solid #cbd5e1; border-radius: 6px; overflow: hidden; background: #fff; transition: border-color 0.15s ease, box-shadow 0.15s ease;"
        >
          <input
            id="swal-qty-input"
            type="number"
            min="1"
            step="1"
            value="${initialValue}"
            style="flex: 1; min-width: 0; height: 100%; box-sizing: border-box; padding: 0 12px; font-size: 16px; border: none; outline: none; background: transparent;"
          />
          ${
            selectAllQty !== null
              ? `<button type="button" id="swal-select-all-btn" aria-label="เลือกทั้งหมด ${selectAllQty} kg" title="เลือกทั้งหมด" style="display: flex; align-items: center; gap: 6px; margin: 0; padding: 0 16px; border: none; border-left: 1px solid #cbd5e1; border-radius: 0; background: #f1f5f9; color: #1e3a8a; font-size: 14px; line-height: 1; cursor: pointer; white-space: nowrap; transition: background 0.15s ease;"><span style="font-weight: 500; color: #64748b;">ทั้งหมด</span><span style="font-weight: 700;">${fmt(selectAllQty)} kg</span></button>`
              : ''
          }
        </div>
      `,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
      focusConfirm: false,
      didOpen: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        input?.focus();
        document.getElementById('swal-select-all-btn')?.addEventListener('click', () => {
          if (input) input.value = String(selectAllQty ?? 0);
          Notify.clickConfirm();
        });
      },
      preConfirm: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        const qty = input ? Number(input.value) : NaN;
        if (!input?.value || !Number.isFinite(qty) || qty <= 0) {
          Notify.showValidationMessage('กรุณาระบุจำนวนมากกว่า 0');
          return false;
        }
        return qty;
      },
    }).then((result) => {
      if (result.isConfirmed) {
        const locationIndex = this.locations.controls.findIndex(
          (loc) => loc.value.locationId === data.locationId && loc.value.itemId === data.itemId,
        );
        if (locationIndex !== -1) {
          //  Exclude this location's own current qty -- otherwise re-editing
          //  a filled location (or using "ทั้งหมด") double counts it.
          if (othersConfirmed + Number(result.value) > this.currentItemQty) {
            this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
            return;
          }

          if (lotRemainingQty !== null && Number(result.value) > lotRemainingQty) {
            this.SwalAlert(
              'warning',
              `จำนวนเกินกว่าที่เหลืออยู่ของ Lot ${lotLabel} (คงเหลือ ${lotRemainingQty} kg)`,
            );
            return;
          }

          const lotNo = usingAllLots
            ? this.allocateAcrossLots(Number(result.value), itemId, excludeLocationId)
            : singleLotNo;

          this.locations.at(locationIndex).patchValue({
            confirmQty: Number(result.value),
            lotNo,
            isChecked: true,
          });

          if (usingAllLots) {
            if (this.isAllLotsExhausted) this.allLotsSelected = false;
          } else if (singleLotNo && this.isLotExhausted(singleLotNo)) {
            this.selectedLotNo = null;
          }
        }
      }
    });
  }

  onDeleteWhLocation(location: locationForm) {
    if (this.hasActualQty(location)) {
      return;
    }

    const index = this.locations.controls.findIndex(
      (currentLocation) =>
        currentLocation.value.locationId === location.value.locationId &&
        currentLocation.value.itemId === location.value.itemId,
    );

    if (index !== -1) {
      this.locations.removeAt(index);

      if (this.isRequiredStock) this.loadStockInquiryData();
      if (
        this.searchForm.controls.wh.value &&
        this.searchForm.controls.whCode.value
      )
        this.loadDockLocationData();
    }
  }

  hideDockLocationModal() {
    const modalEl = document.getElementById('dockLocationModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideDockLocationConfirmModal() {
    const modalEl = document.getElementById('dockLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showDockLocationConfirmModal() {
    const modalEl = document.getElementById('dockLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  async loadGradeWithSapCcCode() {
    const formValue = this.stockInquiryForm.getRawValue();
    this._gradeWithSapCcCodeData = (
      await this.fetchGradeWithSapCcCode(formValue.grade ?? '', '', formValue.prodType ?? '')
    ).result.table;
  }

  async loadDockLocationData(levelCode?: string) {
    this._dockLocationData = (
      await this.fetchDockLocation(
        this.searchForm.controls.wh.value,
        this.searchForm.controls.whCode.value || '',
        this.searchForm.controls.areaCode.value || '',
        levelCode != null && levelCode != '-' ? levelCode : '',
        '',
      )
    ).data;

    if (this.selectedItemId == null) return;

    const locationMap = new Map(
      this.locations.controls
        .filter((loc) => loc.value.isSelected && loc.value.itemId === this.selectedItemId)
        .map((loc) => [loc.value.locationId, loc]),
    );

    const stockInquiryData = Array.isArray(this._stockInquiryData) ? this._stockInquiryData : [];
    const stockInquiryMap = new Map(
      stockInquiryData.map((stock) => [
        `${stock.whcode}_${stock.careacode}_${stock.clevelcode}_${stock.clocationcode}`,
        stock,
      ]),
    );

    this._dockLocationData.forEach((location) => {
      const itemLocation = locationMap.get(location.id);
      const stockInquiry = stockInquiryMap.get(
        `${location.wh_code}_${location.area_code}_${location.level_code}_${location.location_code}`,
      );

      const exists = this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === location.id &&
          currentLocation.value.itemId === this.selectedItemId,
      );

      if (exists) return;

      this.addWhLocation({
        id: itemLocation?.value?.id ?? null,
        itemId: this.selectedItemId,
        whCode: location.wh_code ?? null,
        locationId: location.id ?? null,
        locationType: this.warehouseCode,
        locationName: this.getLocationName(location),
        qty: itemLocation?.value?.qty ?? null,
        confirmQty: itemLocation?.value?.confirmQty ?? null,
        actualQty: itemLocation?.value?.actualQty ?? null,
        receivedQty: itemLocation?.value?.receivedQty ?? null,
        completeQty: itemLocation?.value?.completeQty ?? null,
        availableQty: stockInquiry?.available ?? null,
        qtyLock: stockInquiry?.qtylock ?? null,
        isChecked: !!itemLocation,
        isSelected: !!itemLocation,
      });
    });
  }

  async loadStockInquiryData(): Promise<void> {
    const formValue = this.stockInquiryForm.getRawValue();
    const invDate = this.formatDate(formValue.invDate);

    const response = await this.fetchStockInquiry(
      this.warehouseCode,
      formValue.grade || '',
      formValue.lotNo || '',
      this.getCcCode(formValue.ccCode ?? '') || '',
      invDate,
      formValue.prodType || '',
    );

    const stocks = response?.result ?? [];

    if (stocks.length === 0) {
      this._stockInquiryData = [];
      this.resetWhLocationForm();
      return;
    }

    this._stockInquiryData = stocks;
    stocks.forEach((stock) => this.updateOrAddLocation(stock));
  }

  private updateOrAddLocation(stock: any): void {
    const locationName = this.getLocationName({
      wh_code: stock.whcode,
      area_code: stock.careacode,
      level_code: stock.clevelcode,
      location_code: stock.clocationcode,
    });

    //  Saved rows from older jobs may still carry the "WH"-prefixed name.
    const location = this.locations.controls.find(
      (loc) => this.stripWhPrefix(loc.value.locationName ?? '') === locationName,
    );

    if (location) {
      location.patchValue({
        availableQty: stock.available,
        qtyLock: stock.qtylock,
      });
      return;
    }

    this.addWhLocation({
      id: null,
      itemId: this.selectedItemId,
      whCode: stock.whcode ?? null,
      locationId: null,
      locationType: this.warehouseCode,
      locationName,
      qty: null,
      confirmQty: null,
      actualQty: null,
      receivedQty: null,
      completeQty: null,
      availableQty: stock.available ?? null,
      qtyLock: stock.qtylock ?? null,
      isChecked: false,
      isSelected: false,
    });
  }

  fetchDockLocation(
    wh: WarehouseCode,
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
  ): Promise<Type.ResponseProcessDockLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetDockLocation(whCode, areaCode, levelCode, locationCode).subscribe(
        (response: Type.ResponseProcessDockLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching dock location:', error);
          reject(error);
        },
      );
    });
  }

  fetchGradeWithSapCcCode(
    grade: string,
    sapCcCode: string,
    prodType?: string,
  ): Promise<Type.ResponseProcessGetGradeWithSapCcCode> {
    return new Promise((resolve, reject) => {
      this.restService.processGetGradeWithSapCcCode(grade, sapCcCode, prodType).subscribe(
        (response: Type.ResponseProcessGetGradeWithSapCcCode) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching grade with SAP CC code:', error);
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
          console.error('Error fetching wms cc code options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionLocationDockWh(wh: WarehouseCode): Promise<Type.ResponseProcessGetOptionsWh> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationDockWh().subscribe(
        (response: Type.ResponseProcessGetOptionsWh) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location dock wh options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionLocationArea(
    wh: WarehouseCode,
    whCode: string,
    areaCode?: string,
  ): Promise<Type.ResponseProcessGetOptionsArea> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationDockArea(whCode, areaCode).subscribe(
        (response: Type.ResponseProcessGetOptionsArea) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location area options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionLocationLevel(
    wh: WarehouseCode,
    whCode: string,
    areaCode: string,
    levelCode?: string,
  ): Promise<Type.ResponseProcessGetOptionsLevel> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationDockLevel(whCode, areaCode, levelCode).subscribe(
        (response: Type.ResponseProcessGetOptionsLevel) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location dock level options:', error);
          reject(error);
        },
      );
    });
  }

  fetchStockInquiry(
    whType: 'MWH' | 'A41' | 'A43' | 'PRE-ZONE' | 'DOCK',
    grade: string,
    lotNo: string,
    costCenter: string,
    invDate: string,
    prodType: string,
  ): Promise<Type.ResponseProcessGetStockInquiry> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetStockInquiry(whType, grade, lotNo, costCenter, invDate, prodType)
        .subscribe(
          (response: Type.ResponseProcessGetStockInquiry) => {
            resolve(response);
          },
          (error) => {
            console.error('Error fetching stock inquiry:', error);
            reject(error);
          },
        );
    });
  }

  formatDate(date: Date | null): string {
    if (!date) return '';

    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  SwalAlert(icon: NotifyIcon, message: string) {
    const titles = {
      success: 'Success',
      error: 'Error',
      warning: 'Warning',
      info: 'Information',
      question: 'Confirmation',
    };

    Notify.fire({
      position: 'center',
      icon,
      title: titles[icon] ?? 'Notice',
      text: message,
      showConfirmButton: true,
    });
  }
}
