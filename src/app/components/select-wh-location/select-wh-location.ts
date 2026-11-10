import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import Swal, { SweetAlertIcon } from 'sweetalert2';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';

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
  receivedQty: FormControl<number | null>;
  completeQty: FormControl<number | null>;
  availableQty: FormControl<number | null>;
  qtyLock: FormControl<number | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
  isVisible: FormControl<boolean | null>;
}>;

type locationInput = {
  id: number | null;
  itemId: number | null;
  whCode: string | null;
  ccCode: string | null;
  grade: string | null;
  lotNo: string | null;
  locationId: number | null;
  locationType: string | null;
  locationName: string | null;
  qty: number | null;
  confirmQty: number | null;
  actualQty: number | null;
  receivedQty: number | null;
  completeQty: number | null;
  availableQty: number | null;
  qtyLock: number | null;
  isChecked: boolean;
  isSelected: boolean;
  isVisible: boolean;
};

@Component({
  selector: 'app-select-wh-location',
  standalone: false,
  templateUrl: './select-wh-location.html',
  styleUrl: './select-wh-location.css',
})
export class SelectWhLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Defaults match this component's original hardcoded ids, so job-detail's
  //  existing single-instance usage (isMWHSource / isMWHDestination, never
  //  both at once) keeps working unchanged. job-list's Create Picking tab
  //  needs a GET *and* PUT instance mounted at the same time, so it passes
  //  distinct ids to each to avoid colliding on the same DOM element.
  @Input() modalId = 'whLocationModal';
  @Input() confirmModalId = 'whLocationConfirmModal';
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() currentItemQty = 0;
  @Input() warehouseCode: WarehouseCode = 'MWH';
  @Input({ required: true }) costCenter = '';
  @Input() itemData: Type.Item | null = null;
  @Input() isRequiredStock = false;
  @Input() isShipmentJob = false;
  @Input() openRequestId = 0;
  @Input() qtyUnit: string | null = null;
  //  Display-only item for the header Grade / Lot chips. Kept separate from
  //  itemData so passing it doesn't trigger the stock inquiry flow.
  @Input() headerItem: Type.Item | null = null;
  //  Hides the per-location Lot pill in the list. job-detail's Put instance
  //  sets it; Get / picking source keep showing lot since they pick by it.
  @Input() hideLocationLot = false;

  _whLocationData!: Type.ResultProcessWhLocation[] | null;

  wmsCcCodeOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = [];
  whLocationOptions: Type.ResultProcessGetOptionsWh[] | null = [];
  areaLocationOptions: Type.ResultProcessGetOptionsArea[] | null = [];
  levelLocationOptions: Type.ResultProcessGetOptionsLevel[] | null = [];

  _stockInquiryData!: Type.ResultProcessStockInquiry[] | null;
  _allStockInquiryData!: Type.ResultProcessGetAllStockInquiry[] | null;
  _gradeWithSapCcCodeData!: Type.ResultProcessGetGradeWithSapCcCode[] | null;

  _isExplandSearch = false;
  _isExplandStockInquiry = true;

  searchForm = new FormGroup({
    wh: new FormControl<WarehouseCode>('MWH', { nonNullable: true }),
    whCode: new FormControl(''),
    //  Area waits for a warehouse, level waits for an area
    areaCode: new FormControl({ value: '', disabled: true }),
    levelCode: new FormControl({ value: '', disabled: true }),
    locationCode: new FormControl(''),
  });

  stockInquiryForm = new FormGroup({
    code: new FormControl({ sap_cc_code: '', cc_code: '' }),
    grade: new FormControl(''),
    lotNo: new FormControl(''),
    invDate: new FormControl<Date | null>(null),
    prodType: new FormControl(''),
  });

  private isInitialized = false;
  //  Resolves once whLocationOptions / wmsCcCodeOptions for the current
  //  warehouseCode are loaded, so openRequestId handling can read wmsCode
  //  without racing the async option fetch (which would otherwise patch
  //  the cost center back to '' after it was set).
  private warehouseOptionsReady: Promise<void> = Promise.resolve();
  //  Guards against an older stock inquiry response landing after a newer one.
  private stockInquiryRequestSeq = 0;

  constructor(private restService: CrudService) {}

  //  Sub-modal for lot search within this picker -- also needs to be unique
  //  per instance, same reason as modalId/confirmModalId above.
  get lotSelectModalId(): string {
    return `${this.modalId}LotSelect`;
  }

  get currentItem(): Type.Item | null {
    if (!this.itemData) return null;
    if (this.selectedItemId === null) return this.itemData;
    return this.itemData.id === this.selectedItemId ? this.itemData : null;
  }

  get headerGrade(): string {
    return (this.headerItem ?? this.currentItem)?.grade?.trim() ?? '';
  }

  get headerLotNo(): string {
    return (this.headerItem ?? this.currentItem)?.lot_no?.trim() ?? '';
  }

  //  Lot to prefill the stock inquiry filter with. Picking items carry no
  //  lot_no, so fall back to the header lot (taken from the source
  //  locations) -- only when it's a single lot, a joined list can't filter.
  get defaultStockLotNo(): string {
    const itemLotNo = this.currentItem?.lot_no?.trim() ?? '';
    if (itemLotNo) return itemLotNo;
    return this.headerLotNo.includes(',') ? '' : this.headerLotNo;
  }

  get currentWhLocations(): locationForm[] {
    return this.locations.controls
      .filter((loc) => loc.value.itemId === this.selectedItemId && loc.value.isVisible)
      .sort((a, b) => Number(a.value.locationId) - Number(b.value.locationId));
  }

  get currentWhLocationQty(): number {
    return this.locations.controls
      .filter((loc) => loc.value.itemId === this.selectedItemId && loc.value.isChecked)
      .reduce((sum, loc) => sum + (Number(loc.value.confirmQty) || 0), 0);
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

  isHiddenLot(location: locationForm): boolean {
    return this.isRequiredStock && !location.value.availableQty;
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
      !location.value.isChecked &&
      this.isRequiredStock &&
      (location.value.availableQty === 0 ||
        !location.value.availableQty ||
        location.value.locationId === null ||
        location.value.locationId === 0)
    );
  }

  //  Same clean-up location-management applies to the QR value, so the name shown,
  //  saved and matched here is the one on the printed QR. Saved jobs may still hold
  //  the raw form, so run both sides through this when comparing names.
  displayLocationName(locationName: string | null | undefined): string {
    return (locationName || '').replace(/[-\s]/g, '');
  }

  getLocationName(location: any | null): string {
    return location
      ? this.displayLocationName(
          `${location.wh_code === '-' ? '' : location.wh_code}${location.area_code === '-' ? '' : location.area_code}${location.level_code === '-' ? '' : location.level_code}${location.location_code === '-' ? '' : location.location_code}`,
        )
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

  get lotNoOptions(): Type.ResultProcessGetAllStockInquiry[] {
    const stocks = Array.isArray(this._allStockInquiryData) ? this._allStockInquiryData : [];
    const byLotNo = new Map<string, Type.ResultProcessGetAllStockInquiry>();
    stocks.forEach((stock) => {
      if (stock?.pdlotno && !byLotNo.has(stock.pdlotno)) byLotNo.set(stock.pdlotno, stock);
    });
    return Array.from(byLotNo.values()).sort((a, b) => a.pdlotno.localeCompare(b.pdlotno));
  }

  get wmsCode() {
    var data = this.wmsCcCodeOptions?.find((item) => item.cc_code === this.costCenter);
    return data
      ? { sap_cc_code: data.sap_cc_code, cc_code: data.cc_code }
      : { sap_cc_code: '', cc_code: '' };
  }

  async ngOnInit() {
    this.isInitialized = true;
    this._isExplandSearch = !this.isRequiredStock;
    this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });

    this.registerSearchHandlers();
    this.registerStockInquiryHandlers();
    this.warehouseOptionsReady = this.initializeWarehouseOptions();
  }

  async ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;

    if (changes['warehouseCode']) {
      this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });
      this.warehouseOptionsReady = this.initializeWarehouseOptions();
    }

    //  Cost Center comes solely from the parent page's header selection
    //  (see job-detail.html's [costCenter] binding) -- the modal no longer
    //  has its own Cost Center picker, so a change here has to drive the
    //  stock search itself instead of a dropdown valueChange.
    if (changes['costCenter']) {
      await this.warehouseOptionsReady;

      const code = this.wmsCode;
      this.stockInquiryForm.patchValue({ code }, { emitEvent: false });

      if (code.cc_code && this.stockInquiryForm.controls.grade.value) {
        await Promise.all([this.loadGradeWithSapCcCode(), this.loadStockInquiryData()]);
      }
    }

    if (!changes['openRequestId']?.currentValue) return;

    await this.warehouseOptionsReady;

    //  Refresh grade/lot for the item the modal is opened for on every open --
    //  a Put (no stock) instance reads them straight into the new location,
    //  so leaving them unset kept the first item's lot for every later item.
    const code = this.wmsCode;
    const grade = this.currentItem?.grade?.trim() ?? '';
    const lotNo = this.defaultStockLotNo;
    const prodType = this.currentItem?.wms_group || this.currentItem?.pd_type || '';

    this.setStockInquiryForm(code, grade, lotNo, new Date(), prodType);

    if (this.isRequiredStock) {
      if (code.cc_code && grade) {
        await Promise.all([this.loadGradeWithSapCcCode(), this.loadStockInquiryData()]);
      }
    }

    //  Re-run the location filter the user left in place last time the modal
    //  was open. Runs after the stock inquiry so isRequiredStock filtering
    //  sees the fresh _stockInquiryData.
    const { whCode, areaCode, levelCode } = this.searchForm.getRawValue();
    if (whCode && areaCode && this.hasSelectedValue(levelCode)) {
      await this.loadWhLocationData(levelCode);
    }
  }

  //  Level codes can legitimately be 0 (e.g. "W43A00"), which is falsy in JS --
  //  a plain `!value` check would wrongly treat a selected level 0 as "nothing selected".
  private hasSelectedValue<T>(value: T | null | undefined | ''): value is T {
    return value !== null && value !== undefined && value !== '';
  }

  setStockInquiryForm(
    code: { sap_cc_code: string; cc_code: string } | null,
    grade: string,
    lotNo: string,
    invDate: Date | null,
    prodType: string,
  ) {
    this.stockInquiryForm.patchValue(
      {
        code: code || { sap_cc_code: '', cc_code: '' },
        grade: grade || '',
        lotNo: lotNo || '',
        invDate: invDate || null,
        prodType: prodType || '',
      },
      { emitEvent: false },
    );
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

      this.searchForm.controls.areaCode.enable({ emitEvent: false });
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
      //  WMS+ CLEVELMASTER returns several rows per level code (SELECT *,
      //  no DISTINCT) -- keep one option per code.
      const levels =
        (
          await this.fetchOptionLocationLevel(
            this.searchForm.controls.wh.value,
            this.searchForm.controls.whCode.value || '',
            areaCode,
            '',
          )
        ).data ?? [];
      this.levelLocationOptions = levels.filter(
        (level, index) => levels.findIndex((other) => other.clevelcode === level.clevelcode) === index,
      );
    });

    this.searchForm.controls.levelCode.valueChanges.subscribe(async (levelCode) => {
      this.resetWhLocationForm();
      this.searchForm.patchValue({ locationCode: '' }, { emitEvent: false });

      if (!this.hasSelectedValue(levelCode)) return;

      await this.loadWhLocationData(levelCode);
    });
  }

  registerStockInquiryHandlers() {
    this.stockInquiryForm.controls.code.valueChanges.subscribe(async (code) => {
      if (!code?.cc_code && this.isRequiredStock) return;

      await this.loadStockInquiryData();
      await this.loadGradeWithSapCcCode();
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

  async initializeWarehouseOptions() {
    this.whLocationOptions = (await this.fetchOptionLocationWh(this.warehouseCode)).data;
    this.wmsCcCodeOptions = (await this.fetchOptionWmsCcCode(this.warehouseCode)).data;

    this.stockInquiryForm.patchValue(
      {
        code: this.wmsCode,
        grade: this.currentItem?.grade ?? '',
        lotNo: this.defaultStockLotNo,
        invDate: new Date(),
        prodType: this.currentItem?.wms_group || this.currentItem?.pd_type || '',
      },
      { emitEvent: false },
    );
  }

  onClose() {
    const hasChanges = this.locations.controls.some(
      (loc) =>
        loc.value.isChecked !== loc.value.isSelected || loc.value.qty !== loc.value.confirmQty,
    );

    if (!hasChanges) {
      if (document.getElementById(this.modalId)) {
        this.hideWhLocationModal();
        this.hideWhLocationConfirmModal();
        return;
      }
    }

    this.showWhLocationConfirmModal();
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

  //  Clears Lot No and puts Inv Date back to today. Grade is kept as is
  //  (read-only here, comes from the job item) and Cost Center stays the
  //  page header's selection.
  async onResetStockInquiry() {
    const code = this.wmsCode;
    const grade = this.stockInquiryForm.controls.grade.value?.trim() ?? '';

    this.setStockInquiryForm(code, grade, '', new Date(), this.currentItem?.wms_group || this.currentItem?.pd_type || '');

    this._gradeWithSapCcCodeData = [];
    this._stockInquiryData = [];
    this.resetWhLocationForm();

    if (code.cc_code && grade) {
      await Promise.all([this.loadGradeWithSapCcCode(), this.loadStockInquiryData()]);
    }
  }

  async onOpenLotModal() {
    const formValue = this.stockInquiryForm.getRawValue();
    const invDate = this.formatDate(formValue.invDate);

    try {
      const response = await this.fetchAllStockInquiry(
        this.warehouseCode,
        formValue.grade || '',
        formValue.lotNo || '',
        formValue.code?.cc_code || '',
        formValue.code?.sap_cc_code || '',
        invDate,
        formValue.prodType || '',
        this.itemData?.qty_unit == 'bag' ? 'Y' : 'N'
      );

      this._allStockInquiryData = response?.result ?? [];

      if (this.lotNoOptions.length === 0) {
        this.SwalAlert(
          'info',
          response?.message.split(' ').slice(1).join(' ') || 'ไม่พบข้อมูล Lot No',
        );
        return;
      }

      this.showLotSelectModal();
    } catch (error) {
      console.error('Error fetching all stock for lot selection:', error);
      this.SwalAlert('error', 'ไม่สามารถดึงข้อมูล Lot No ได้');
    }
  }

  onSelectLotNo(lotNo: string) {
    this.stockInquiryForm.patchValue({ lotNo });
    this.hideLotSelectModal();
  }

  onCheckLocation(location: locationForm) {
    if (location.value.isChecked) {
      return;
    }

    const control = this.currentWhLocations.find(
      (currentLocation) => currentLocation.value.locationId === location.value.locationId,
    );

    if (control) {
      this.onAssignLocationQty(location.value);
    }
  }

  //  Clicking the qty pill of a checked row reopens the qty prompt so the
  //  user can change it without removing the location first.
  onEditLocationQty(location: locationForm, event: MouseEvent) {
    event.stopPropagation();
    this.onAssignLocationQty(location.value);
  }

  async onUncheckLocation(location: locationForm) {
    if (this.hasActualQty(location)) {
      return;
    }

    //  Patch the row that was clicked directly -- looking it up again by
    //  locationId could hit a sibling row (same location, other lot). Keep it
    //  visible so the user can re-check it; the stock reload below re-applies
    //  the lot filter's isVisible for rows that no longer match.
    location.patchValue({ confirmQty: 0, isChecked: false });

    this.loadStockInquiryData();
  }

  onSave() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isSelected.setValue(loc.controls.isChecked.value, { emitEvent: true });
      loc.controls.qty.setValue(
        loc.controls.isChecked.value ? loc.controls.confirmQty.value : loc.controls.qty.value,
        { emitEvent: true },
      );
    });

    this.hideWhLocationModal();
    this.hideWhLocationConfirmModal();
  }

  onCancel() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isChecked.setValue(loc.controls.isSelected.value, { emitEvent: true });
      loc.controls.confirmQty.setValue(loc.controls.qty.value, { emitEvent: true });
      //  onUncheckLocation hides the row; a cancelled uncheck must bring it back.
      if (loc.controls.isSelected.value) {
        loc.controls.isVisible.setValue(true, { emitEvent: true });
      }
    });

    this.hideWhLocationModal();
    this.hideWhLocationConfirmModal();
  }

  resetWhLocationForm() {
    //  Remove by position (walking backwards) rather than re-looking up by
    //  locationId: the same location can appear more than once (e.g. per lot),
    //  and a lookup could hit a checked sibling row instead.
    for (let i = this.locations.length - 1; i >= 0; i--) {
      const loc = this.locations.at(i);
      if (!loc.value.isChecked && !loc.value.isSelected) {
        this.locations.removeAt(i);
      }
    }
  }

  addWhLocation(location: locationInput) {
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
      availableQty: new FormControl<number | null>(location.availableQty ?? 0),
      qtyLock: new FormControl<number | null>(location.qtyLock ?? 0),
      receivedQty: new FormControl<number | null>(location.receivedQty ?? 0),
      completeQty: new FormControl<number | null>(location.completeQty ?? 0),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
      isVisible: new FormControl<boolean | null>(true),
    });

    this.locations.push(form);
  }

  confirmQtyWhLocations(itemId?: number): number {
    return this.locations.controls
      .filter((loc) => loc.value.isChecked && (itemId === undefined || loc.value.itemId === itemId))
      .reduce((sum, loc) => sum + (Number(loc.value.confirmQty) || 0), 0);
  }

  async onBlurWhLocation(): Promise<HTMLElement | null> {
    const modalContent = document.querySelector(
      `#${this.modalId} .modal-content`,
    ) as HTMLElement | null;

    const activeElement = document.activeElement as HTMLElement | null;
    activeElement?.blur();

    return modalContent;
  }

  //  "Select All" = whatever's left to reach currentItemQty, excluding what
  //  THIS location already contributes so re-opening a filled location still
  //  offers the correct room. Capped by availableQty when stock is required.
  private getSelectAllQty(data: locationForm['value']): number | null {
    const othersConfirmed =
      this.confirmQtyWhLocations(data.itemId ?? undefined) -
      (data.isChecked ? Number(data.confirmQty) || 0 : 0);
    let remaining = this.currentItemQty - othersConfirmed;

    if (this.isRequiredStock && data.availableQty != null) {
      remaining = Math.min(remaining, data.availableQty);
    }

    return remaining > 0 ? remaining : null;
  }

  //  Shows (message) or hides (null) the red error box under the qty input in
  //  the Swal prompt, and rings the input red while it is shown.
  private toggleQtyError(message: string | null) {
    const error = document.getElementById('swal-qty-error');
    const text = document.getElementById('swal-qty-error-text');
    const field =
      document.getElementById('swal-qty-group') ?? document.getElementById('swal-qty-input');
    if (error) error.style.display = message ? 'flex' : 'none';
    if (text) text.textContent = message ?? '';
    if (field) field.style.boxShadow = message ? '0 0 0 2px rgba(220, 38, 38, 0.45)' : '';
  }

  async onAssignLocationQty(data: locationForm['value']) {
    if (!data) return;

    const modalContent = await this.onBlurWhLocation();
    const selectAllQty = this.getSelectAllQty(data);
    const initialValue = data.confirmQty === 0 ? '' : String(data.confirmQty ?? '');
    const actualQty = Number(data.actualQty) || 0;
    const actualQtyError = `จำนวนต้องไม่น้อยกว่าที่ขนย้ายจริง (${actualQty.toLocaleString('en-US')} ${this.qtyUnit})`;

    //  Same inline "select all" pill as select-internal-transfer-location:
    //  clicking it fills the input with the remaining qty and submits.
    Swal.fire({
      target: modalContent ?? undefined,
      backdrop: modalContent ? false : true,
      returnFocus: false,
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (${this.qtyUnit}) : ${this.displayLocationName(data.locationName)}</span>`,
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
          #swal-actual-qty-btn:hover {
            background: #e0e7ff;
          }
          #swal-actual-qty-btn:active {
            background: #c7d2fe;
          }
        </style>
        <span style="font-size: 16px;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</span>
        <div
          id="swal-qty-group"
          style="display: flex; align-items: stretch; margin-top: 12px; height: 44px; border: 1px solid #cbd5e1; border-radius: 6px; overflow: hidden; background: #fff; transition: border-color 0.15s ease, box-shadow 0.15s ease;"
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
            actualQty > 0
              ? `<button type="button" id="swal-actual-qty-btn" title="ใช้จำนวนที่ขนย้ายจริง" style="display: flex; align-items: center; gap: 6px; margin: 0; padding: 0 16px; border: none; border-left: 1px solid #cbd5e1; border-radius: 0; background: #f1f5f9; color: #1e3a8a; font-size: 14px; line-height: 1; cursor: pointer; white-space: nowrap; transition: background 0.15s ease;"><span style="font-weight: 500; color: #64748b;">ขนย้ายจริง</span><span style="font-weight: 700;">${actualQty.toLocaleString('en-US')} ${this.qtyUnit}</span></button>`
              : ''
          }
          ${
            //  Location already has actual moved qty -> only the "ขนย้ายจริง" button is shown.
            selectAllQty !== null && actualQty <= 0
              ? `<button type="button" id="swal-select-all-btn" aria-label="เลือกทั้งหมด ${selectAllQty} ${this.qtyUnit}" title="เลือกทั้งหมด" style="display: flex; align-items: center; gap: 6px; margin: 0; padding: 0 16px; border: none; border-left: 1px solid #cbd5e1; border-radius: 0; background: #f1f5f9; color: #1e3a8a; font-size: 14px; line-height: 1; cursor: pointer; white-space: nowrap; transition: background 0.15s ease;"><span style="font-weight: 500; color: #64748b;">ทั้งหมด</span><span style="font-weight: 700;">${selectAllQty.toLocaleString('en-US')} ${this.qtyUnit}</span></button>`
              : ''
          }
        </div>
        <div id="swal-qty-error" role="alert" style="display: none; align-items: center; gap: 8px; margin-top: 10px; padding: 8px 12px; border: 1px solid #fecaca; border-radius: 6px; background: #fef2f2; color: #b91c1c; font-size: 14px; font-weight: 500; line-height: 1.4; text-align: left;"><span style="flex: none; display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; border-radius: 50%; background: #dc2626; color: #fff; font-size: 12px; font-weight: 700;">!</span><span id="swal-qty-error-text"></span></div>
      `,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
      focusConfirm: false,
      didOpen: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        input?.focus();
        //  The actualQty error only shows on Submit (preConfirm); typing clears it.
        input?.addEventListener('input', () => this.toggleQtyError(null));
        document.getElementById('swal-select-all-btn')?.addEventListener('click', () => {
          if (input) input.value = String(selectAllQty ?? 0);
          Swal.clickConfirm();
        });
        //  "ขนย้ายจริง" button: fill the input with the actual moved qty and submit.
        document.getElementById('swal-actual-qty-btn')?.addEventListener('click', () => {
          if (input) input.value = String(actualQty);
          Swal.clickConfirm();
        });
      },
      preConfirm: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        const qty = input ? Number(input.value) : NaN;
        if (!input?.value || !Number.isFinite(qty) || qty <= 0) {
          Swal.showValidationMessage('กรุณาระบุจำนวนมากกว่า 0');
          return false;
        }
        if (qty < actualQty) {
          this.toggleQtyError(actualQtyError);
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
          //  a filled location (or using "select all") double counts it.
          const othersConfirmed =
            this.confirmQtyWhLocations(data.itemId ?? undefined) -
            (data.isChecked ? Number(data.confirmQty) || 0 : 0);
          if (othersConfirmed + Number(result.value) > this.currentItemQty) {
            this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
            return;
          }

          this.locations.at(locationIndex).patchValue({
            confirmQty: Number(result.value),
            isChecked: true,
          });
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
    }
  }

  hideWhLocationModal() {
    const modalEl = document.getElementById(this.modalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideWhLocationConfirmModal() {
    const modalEl = document.getElementById(this.confirmModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showWhLocationConfirmModal() {
    const modalEl = document.getElementById(this.confirmModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  hideLotSelectModal() {
    const modalEl = document.getElementById(this.lotSelectModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showLotSelectModal() {
    const modalEl = document.getElementById(this.lotSelectModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  async loadGradeWithSapCcCode() {
    const formValue = this.stockInquiryForm.getRawValue();
    this._gradeWithSapCcCodeData = (
      await this.fetchGradeWithSapCcCode(
        formValue.grade ?? '',
        formValue.code?.cc_code ?? '',
        formValue.prodType ?? '',
      )
    ).result.table;
  }

  async loadWhLocationData(levelCode?: string) {
    this._whLocationData = (
      await this.fetchWhLocation(
        this.searchForm.controls.wh.value,
        this.searchForm.controls.whCode.value || '',
        this.searchForm.controls.areaCode.value || '',
        levelCode ?? '',
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

    const selectedItemId = this.selectedItemId;
    const locationExists = (locationId: number | null) =>
      this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === locationId &&
          currentLocation.value.itemId === selectedItemId,
      );

    //  Sequential (not forEach(async)) and re-checked after the await, so a
    //  concurrent load can't slip in and add the same location twice.
    for (const location of this._whLocationData ?? []) {
      const itemLocation = locationMap.get(location.location_id);
      const stockInquiry = stockInquiryMap.get(
        `${location.wh_code}_${location.area_code}_${location.level_code}_${location.location_code}`,
      );

      if (this.isRequiredStock && !stockInquiry) continue;
      if (locationExists(location.location_id)) continue;

      const locationId =
        location.location_id ??
        (await this.findLocationId(
          location.wh_code,
          location.area_code,
          location.level_code,
          location.location_code,
        )) ??
        null;

      if (locationExists(locationId)) continue;

      this.addWhLocation({
        id: itemLocation?.value?.id ?? null,
        itemId: selectedItemId,
        whCode: location.wh_code ?? null,
        ccCode: this.stockInquiryForm.controls.code.value?.cc_code ?? null,
        grade: this.stockInquiryForm.controls.grade.value ?? null,
        //  Put locations carry the item's lot, not whatever lot already sits there.
        lotNo:
          (this.isRequiredStock ? stockInquiry?.pdlotno : null) ??
          this.stockInquiryForm.controls.lotNo.value ??
          null,
        locationId,
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
        isVisible: true,
      });
    }
  }

  async loadStockInquiryData(): Promise<void> {
    const formValue = this.stockInquiryForm.getRawValue();
    const invDate = this.formatDate(formValue.invDate);

    if (!formValue.code?.cc_code || !formValue.grade || !invDate) return;

    const requestSeq = ++this.stockInquiryRequestSeq;
    const response = await this.fetchStockInquiry(
      this.warehouseCode,
      formValue.grade || '',
      formValue.lotNo || '',
      formValue.code?.cc_code || '',
      invDate,
      formValue.prodType || '',
      this.itemData?.qty_unit == 'bag' ? 'Y' : 'N'
    );

    //  A newer request was fired while this one was in flight -- drop this result.
    if (requestSeq !== this.stockInquiryRequestSeq) return;

    //  The API returns result: "" (not []) when there's no matching stock,
    //  so a plain array method call here would throw.
    const stocks = (Array.isArray(response?.result) ? response.result : []).filter(
      (stock) => stock.invdate.slice(0, 10) === invDate,
    );

    if (stocks.length === 0) {
      this._stockInquiryData = [];
      this.resetWhLocationForm();
      return;
    }

    this._stockInquiryData = stocks;
    this.pruneLocationsNotInStock(stocks);
    //  Sequential so two stock rows for the same location don't both miss the
    //  lookup (while awaiting findLocationId) and get added twice.
    for (const stock of stocks) {
      await this.updateOrAddLocation(stock);
    }
  }

  private async updateOrAddLocation(stock: any): Promise<void> {
    const selectedItemId = this.selectedItemId;
    const locationName = this.getLocationName({
      wh_code: stock.whcode,
      area_code: stock.careacode,
      level_code: stock.clevelcode,
      location_code: stock.clocationcode,
    });

    const findLocation = () =>
      this.locations.controls.find(
        (loc) =>
          this.displayLocationName(loc.value.locationName) === locationName &&
          loc.value.itemId === selectedItemId,
      );

    const patchLocation = (location: locationForm) => {
      const currentLotNo = location.controls.lotNo.value;
      location.patchValue({
        availableQty: stock.available,
        qtyLock: stock.qtylock,
        lotNo: currentLotNo || stock.pdlotno || null,
        isVisible:
          !currentLotNo || currentLotNo.toLowerCase() === (stock.pdlotno ?? '').toLowerCase(),
      });
    };

    const existing = findLocation();
    if (existing) {
      patchLocation(existing);
      return;
    }

    const locationId =
      (await this.findLocationId(
        stock.whcode,
        stock.careacode,
        stock.clevelcode,
        stock.clocationcode,
      )) ?? null;

    //  Another load may have added this location while we were awaiting.
    const addedMeanwhile = findLocation();
    if (addedMeanwhile) {
      patchLocation(addedMeanwhile);
      return;
    }

    this.addWhLocation({
      id: null,
      itemId: selectedItemId,
      whCode: stock.whcode ?? null,
      ccCode: this.stockInquiryForm.controls.code.value?.cc_code ?? null,
      grade: this.stockInquiryForm.controls.grade.value ?? null,
      lotNo: stock.pdlotno ?? this.stockInquiryForm.controls.lotNo.value ?? null,
      locationId,
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
      isVisible: true,
    });
  }

  private pruneLocationsNotInStock(stocks: Type.ResultProcessStockInquiry[]): void {
    const stockLocationNames = new Set(
      stocks.map((stock) =>
        this.getLocationName({
          wh_code: stock.whcode,
          area_code: stock.careacode,
          level_code: stock.clevelcode,
          location_code: stock.clocationcode,
        }),
      ),
    );

    for (let i = this.locations.length - 1; i >= 0; i--) {
      const loc = this.locations.at(i);

      if (loc.value.itemId !== this.selectedItemId) continue;

      const locationName = this.displayLocationName(loc.value.locationName);
      const notFoundInStock = !stockLocationNames.has(locationName);

      const shouldKeep = !!loc.value.isSelected || !!loc.value.isChecked;

      if (notFoundInStock && !shouldKeep) {
        this.locations.removeAt(i);
      }
    }
  }

  async findLocationId(
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
  ): Promise<number | null> {
    var data = await this.fetchWhLocation(
      this.warehouseCode,
      whCode,
      areaCode,
      levelCode,
      locationCode,
    );
    const location = data?.data?.[0] ?? null;
    return location ? location.location_id : null;
  }

  fetchWhLocation(
    wh: WarehouseCode,
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
  ): Promise<Type.ResponseProcessWhLocation> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetWhLocation(wh, whCode, areaCode, levelCode, locationCode)
        .subscribe(
          (response: Type.ResponseProcessWhLocation) => {
            resolve(response);
          },
          (error) => {
            console.error('Error fetching wh location:', error);
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

  fetchOptionLocationArea(
    wh: WarehouseCode,
    whCode: string,
    areaCode?: string,
  ): Promise<Type.ResponseProcessGetOptionsArea> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationArea(wh, whCode, areaCode).subscribe(
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
      this.restService.ProcessGetOptionsLocationLevel(wh, whCode, areaCode, levelCode).subscribe(
        (response: Type.ResponseProcessGetOptionsLevel) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location level options:', error);
          reject(error);
        },
      );
    });
  }

  fetchStockInquiry(
    whType: 'MWH' | 'A41' | 'A43',
    grade: string,
    lotNo: string,
    costCenter: string,
    invDate: string,
    prodType: string,
    isBag: string = 'N'
  ): Promise<Type.ResponseProcessGetStockInquiry> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetStockInquiry(whType, grade, lotNo, costCenter, invDate, prodType, isBag)
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

  fetchAllStockInquiry(
    whType: 'MWH' | 'A41' | 'A43',
    grade: string,
    lotNo: string,
    costCenter: string,
    sapCostCenter: string,
    invDate: string,
    prodType: string,
    isBag: string = 'N'
  ): Promise<Type.ResponseProcessGetAllStockInquiry> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetAllStockInquiry(
          whType,
          grade,
          lotNo,
          costCenter,
          sapCostCenter,
          invDate,
          prodType,
          isBag
        )
        .subscribe(
          (response: Type.ResponseProcessGetAllStockInquiry) => {
            resolve(response);
          },
          (error) => {
            console.error('Error fetching all stock:', error);
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
      title: `<span style="font-size:22px;font-weight:500;">${titles[icon] ?? 'Notice'}</span>`,
      html: `<span style="font-size:16px;">${message}</span>`,
      showConfirmButton: false,
      timer: 2000,
    });
  }
}
