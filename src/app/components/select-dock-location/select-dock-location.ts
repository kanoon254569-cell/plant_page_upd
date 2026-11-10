import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import Swal, { SweetAlertIcon } from 'sweetalert2';
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
    areaCode: new FormControl(''),
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

  getLocationName(location: any | null): string {
    return location
      ? `${location.wh_code === '-' || !location.wh_code ? '' : location.wh_code}${location.area_code === '-' || !location.area_code ? '' : location.area_code}${location.level_code === '-' || !location.level_code ? '' : location.level_code}${location.location_code === '-' || !location.location_code ? '' : location.location_code}`
      : '';
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
        prodType: this.currentItem?.wms_group || this.currentItem?.pd_type || '',
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
      this.searchForm.controls.whCode.value &&
      this.searchForm.controls.areaCode.value &&
      this.searchForm.controls.levelCode.value
    ) {
      this.loadDockLocationData();
    }
  }

  registerSearchHandlers() {
    this.searchForm.controls.whCode.valueChanges.subscribe(async (whCode) => {
      this.areaLocationOptions = [];
      this.levelLocationOptions = [];
      this.resetWhLocationForm();
      this.searchForm.controls.levelCode.disable({ emitEvent: false });

      this.searchForm.patchValue(
        { areaCode: '', levelCode: '', locationCode: '' },
        { emitEvent: false },
      );

      if (!whCode) return;

      this.areaLocationOptions = (
        await this.fetchOptionLocationArea(this.searchForm.controls.wh.value, whCode, '')
      ).data;
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

    Swal.fire({
      target: modalContent ?? undefined,
      backdrop: modalContent ? false : true,
      returnFocus: false,
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (kg) : ${data.locationName}</span>`,
      html: `<span style="font-size: 16px;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</span>${
        lotLabel
          ? `<div style="margin-top:10px;font-size:14px;color:#1d4ed8;font-weight:600;">Lot: ${lotLabel}${lotRemainingQty !== null ? ` (คงเหลือ ${lotRemainingQty} kg)` : ''}</div>`
          : ''
      }`,
      input: 'number',
      inputAttributes: {
        min: '1',
        step: '1',
        ...(lotRemainingQty !== null ? { max: String(lotRemainingQty) } : {}),
      },
      inputValue: data.confirmQty === 0 ? '' : data.confirmQty,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (result.isConfirmed) {
        const locationIndex = this.locations.controls.findIndex(
          (loc) => loc.value.locationId === data.locationId && loc.value.itemId === data.itemId,
        );
        if (locationIndex !== -1) {
          if (
            this.confirmQtyWhLocations(data.itemId ?? undefined) + Number(result.value) >
            this.currentItemQty
          ) {
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
        this.searchForm.controls.whCode.value &&
        this.searchForm.controls.areaCode.value &&
        this.searchForm.controls.levelCode.value
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

    const location = this.locations.controls.find((loc) => loc.value.locationName === locationName);

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
