import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import Notify, { NotifyIcon } from '../../shared/notify';
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
  //  JSON [{ lotNo, qty }]: planned kg per lot when this location takes
  //  several lots (lotNo "A,B"). Null otherwise.
  lotQtys: FormControl<string | null>;
}>;

export type LotQty = { lotNo: string; qty: number };

export function parseLotQtys(value: string | null | undefined): LotQty[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed
          .map((entry) => ({ lotNo: String(entry?.lotNo ?? '').trim(), qty: Number(entry?.qty) || 0 }))
          .filter((entry) => !!entry.lotNo && entry.qty > 0)
      : [];
  } catch {
    return [];
  }
}

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
  lotQtys?: string | null;
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
  //  Selected value (wms_group) of the page header's Product Type dropdown.
  @Input() productType = '';
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
  //  Raw stock rows (one per lot) keyed by location name -- _stockInquiryData
  //  holds them merged to one row per location.
  private _stockLotsByLocation = new Map<string, Type.ResultProcessStockInquiry[]>();
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

  //  Product type sent to the stock search: the page header's Product Type
  //  dropdown first, then the job item's own wms_group / pd_type.
  get defaultProdType(): string {
    return this.productType || this.currentItem?.wms_group || this.currentItem?.pd_type || '';
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

    if (changes['productType']) {
      this.stockInquiryForm.patchValue({ prodType: this.defaultProdType }, { emitEvent: false });
    }

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
    const prodType = this.defaultProdType;

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

    //  An empty lot is a valid search (every lot of the grade), so clearing
    //  the field reloads too -- otherwise the list stayed on the empty result
    //  of the half-typed lot.
    this.stockInquiryForm.controls.lotNo.valueChanges.subscribe(async () => {
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
        prodType: this.defaultProdType,
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

    this.setStockInquiryForm(code, grade, '', new Date(), this.defaultProdType);

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

    //  A location holding several lots is one row with the lots joined
    //  ("A,B"), and the job stores no qty per lot -- the forklift could take
    //  any mix of them. The user picks one lot first so the customer gets the
    //  lot on the DO.
    if (this.hasMultipleLots(location)) {
      this.onPickLocationLot(location);
      return;
    }

    const control = this.currentWhLocations.find(
      (currentLocation) => currentLocation.value.locationId === location.value.locationId,
    );

    if (control) {
      this.onAssignLocationQty(location.value);
    }
  }

  //  Lot + qty prompt for a multi-lot location, same idea as the dock picker:
  //  lot chips + one qty input that edits the active lot; each lot's qty is
  //  shown on its chip. Confirm narrows the row to the lots with a qty and
  //  saves their total; cancel leaves the row untouched.
  async onPickLocationLot(location: locationForm) {
    const locationName = this.displayLocationName(location.value.locationName);
    const rowLots = this.splitLots(location.value.lotNo).map((lot) => lot.toLowerCase());
    //  Lots with stock available first, the empty ones at the bottom. A row
    //  already picked (re-edit) offers every lot at the location again, not
    //  just the ones it was narrowed to.
    const isEdit = !!location.value.isChecked;
    const lotStocks = (this._stockLotsByLocation.get(locationName) ?? [])
      .filter((stock) => isEdit || rowLots.includes((stock.pdlotno ?? '').trim().toLowerCase()))
      .sort((a, b) => Number((Number(b.available) || 0) > 0) - Number((Number(a.available) || 0) > 0));
    if (lotStocks.length === 0) return;

    const unit = this.qtyUnit ?? '';
    const formatQty = (qty: number | null | undefined) =>
      `${(Number(qty) || 0).toLocaleString('en-US')} ${unit}`;
    const escapeHtml = (text: string) =>
      text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

    //  Room left on the item (other picked locations excluded), shared by
    //  every lot input below.
    const itemRemainingQty =
      this.currentItemQty -
      (this.confirmQtyWhLocations(location.value.itemId ?? undefined) -
        (isEdit ? Number(location.value.confirmQty) || 0 : 0));
    const lotAvailable = (stock: Type.ResultProcessStockInquiry) =>
      Math.max(0, Number(stock.available) || 0);

    //  Dock-style layout: lot chips on top and ONE qty input. Tap a chip to
    //  make it the active lot, type its qty; the qty is remembered on the chip
    //  (badge). Tap another chip to give that lot its own qty. A lot with
    //  nothing available is a grey disabled chip.
    const lotChips = lotStocks
      .map((stock, index) => {
        const isEmpty = lotAvailable(stock) <= 0;
        return `
          <button type="button" class="swal-lot-chip" data-lot-index="${index}" ${isEmpty ? 'disabled' : ''}
            title="${isEmpty ? `ไม่มีพร้อมใช้ (ล็อก ${formatQty(stock.qtylock)})` : `ล็อก ${formatQty(stock.qtylock)}`}"
            style="display: inline-flex; align-items: center; gap: 6px; margin: 0; padding: 4px 6px 4px 10px; border-radius: 999px; border: 1px solid ${isEmpty ? '#e2e8f0' : '#bfdbfe'}; background: ${isEmpty ? '#f1f5f9' : '#fff'}; font-size: 13px; line-height: 1.5; cursor: ${isEmpty ? 'not-allowed' : 'pointer'}; transition: background-color 0.15s ease, border-color 0.15s ease, transform 0.15s ease;">
            <span class="swal-lot-chip-code" style="font-weight: 600; color: ${isEmpty ? '#94a3b8' : '#1d4ed8'};">${escapeHtml(stock.pdlotno ?? '')}</span>
            <span class="swal-lot-chip-qty" style="color: ${isEmpty ? '#94a3b8' : '#64748b'};">${formatQty(stock.available)}</span>
            ${
              isEmpty
                ? '<span style="padding-right: 4px; color: #94a3b8;">✕</span>'
                : `<span class="swal-lot-chip-pick" style="display: none; margin-left: 2px; padding: 0 8px; border-radius: 999px; background: #dcfce7; color: #15803d; font-size: 12px; font-weight: 700; line-height: 20px; white-space: nowrap;"></span>`
            }
          </button>`;
      })
      .join('');

    const modalContent = await this.onBlurWhLocation();
    const qtyByLot = new Map<number, number>();
    let activeIndex: number | null = null;

    //  Re-edit: start from the per-lot qty saved on the row.
    if (isEdit) {
      parseLotQtys(location.value.lotQtys).forEach(({ lotNo, qty }) => {
        const index = lotStocks.findIndex(
          (stock) => (stock.pdlotno ?? '').trim().toLowerCase() === lotNo.toLowerCase(),
        );
        if (index !== -1) qtyByLot.set(index, qty);
      });
    }

    const otherLotsQty = (index: number) =>
      [...qtyByLot].reduce((sum, [i, qty]) => (i === index ? sum : sum + qty), 0);
    //  "ทั้งหมด" of a lot = min(lot available, item room left after the
    //  other lots' qty).
    const lotFillQty = (index: number) =>
      Math.max(0, Math.min(lotAvailable(lotStocks[index]), itemRemainingQty - otherLotsQty(index)));

    const result = await Notify.fire({
      target: modalContent ?? undefined,
      backdrop: modalContent ? false : true,
      returnFocus: false,
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (${escapeHtml(unit)}) : ${escapeHtml(locationName)}</span>`,
      html: `
        <style>
          /* Stronger shadow: popup sits on the white modal without a backdrop. */
          .swal2-popup:has(#swal-lot-qty-input) {
            box-shadow: 0 24px 64px rgba(15, 23, 42, 0.35), 0 8px 24px rgba(15, 23, 42, 0.2) !important;
            border: 1px solid #e2e8f0 !important;
          }
          #swal-lot-qty-input::-webkit-outer-spin-button,
          #swal-lot-qty-input::-webkit-inner-spin-button {
            -webkit-appearance: none;
            margin: 0;
          }
          #swal-lot-qty-input {
            -moz-appearance: textfield;
          }
          #swal-lot-qty-group:focus-within {
            border-color: #1d4ed8 !important;
            box-shadow: 0 0 0 3px rgba(29, 78, 216, 0.12);
          }
          .swal-lot-chip:not(:disabled):hover {
            border-color: #1d4ed8 !important;
            transform: translateY(-1px);
          }
          .swal-lot-chip.selected {
            background: #1d4ed8 !important;
            border-color: #1d4ed8 !important;
          }
          .swal-lot-chip.selected .swal-lot-chip-code,
          .swal-lot-chip.selected .swal-lot-chip-qty {
            color: #fff !important;
          }
          .swal-lot-chip.has-qty:not(.selected) {
            border-color: #86efac !important;
            background: #f0fdf4 !important;
          }
          /* On the blue active chip the qty badge turns white so it reads
             as part of the chip instead of a green blob on blue. */
          .swal-lot-chip.selected .swal-lot-chip-pick {
            background: #fff !important;
            color: #1d4ed8 !important;
          }
          #swal-lot-select-all-btn:not(:disabled):hover {
            background: #e0e7ff !important;
          }
          #swal-lot-select-all-btn:disabled {
            cursor: default !important;
            opacity: 0.45;
          }
        </style>
        <div style="font-size: 16px; color: #475569;">ตำแหน่งนี้มี ${lotStocks.length} ล็อต กรุณาเลือกล็อตและระบุจำนวน</div>
        <div style="display: flex; align-items: center; flex-wrap: wrap; gap: 8px; margin-top: 14px; padding: 10px 12px; border: 1px dashed #bfdbfe; border-radius: 10px; background: #eff6ff; text-align: left;">
          <span style="font-size: 13px; font-weight: 700; color: #1d4ed8; letter-spacing: 0.4px;">เลือกล็อต</span>
          ${lotChips}
          <span id="swal-lot-hint" style="width: 100%; font-size: 12px; font-weight: 500; color: #dc2626;">* กดล็อตแล้วระบุจำนวน กดล็อตอื่นเพื่อระบุจำนวนเพิ่มได้</span>
        </div>
        <div id="swal-lot-qty-label" style="margin-top: 14px; padding: 0 2px; font-size: 14px; font-weight: 500; color: #475569; text-align: left;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</div>
        <div id="swal-lot-qty-group"
          style="display: flex; align-items: stretch; margin-top: 6px; height: 44px; border: 1px solid #cbd5e1; border-radius: 6px; overflow: hidden; background: #fff; transition: border-color 0.15s ease, box-shadow 0.15s ease;">
          <input id="swal-lot-qty-input" type="number" min="0" step="1" disabled placeholder="เลือกล็อตก่อน"
            style="flex: 1; min-width: 0; height: 100%; box-sizing: border-box; padding: 0 12px; font-size: 16px; border: none; outline: none; background: transparent;" />
          <button type="button" id="swal-lot-select-all-btn" title="ใส่จำนวนที่ใบรายการยังขาด (ไม่เกินพร้อมใช้ของล็อตนี้)"
            style="display: none; align-items: center; gap: 6px; margin: 0; padding: 0 16px; border: none; border-left: 1px solid #cbd5e1; border-radius: 0; background: #f1f5f9; color: #1e3a8a; font-size: 14px; line-height: 1; cursor: pointer; white-space: nowrap;">
            <span style="font-weight: 500; color: #64748b;">ใส่ที่เหลือ</span><span id="swal-lot-select-all-qty" style="font-weight: 700;"></span>
          </button>
        </div>
        <div id="swal-lot-qty-info" style="display: none; margin-top: 6px; padding: 0 2px; font-size: 12px; color: #64748b; text-align: left;"></div>
      `,
      //  Wider than the default 440px so the lot chips fit on one line.
      width: 580,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
      focusConfirm: false,
      didOpen: (popup: HTMLElement) => {
        const input = popup.querySelector<HTMLInputElement>('#swal-lot-qty-input');
        const labelEl = popup.querySelector<HTMLElement>('#swal-lot-qty-label');
        const hintEl = popup.querySelector<HTMLElement>('#swal-lot-hint');
        const selectAllBtn = popup.querySelector<HTMLButtonElement>('#swal-lot-select-all-btn');
        const selectAllQtyEl = popup.querySelector<HTMLElement>('#swal-lot-select-all-qty');
        const chipOf = (index: number) =>
          popup.querySelector<HTMLElement>(`.swal-lot-chip[data-lot-index="${index}"]`);

        //  Badge on a chip = the qty given to that lot.
        const paintChip = (index: number) => {
          const chip = chipOf(index);
          const badge = chip?.querySelector<HTMLElement>('.swal-lot-chip-pick');
          const qty = qtyByLot.get(index) ?? 0;
          chip?.classList.toggle('selected', index === activeIndex);
          chip?.classList.toggle('has-qty', qty > 0);
          if (badge) {
            badge.textContent = qty > 0 ? `✓ ${qty.toLocaleString('en-US')}` : '';
            badge.style.display = qty > 0 ? 'inline-block' : 'none';
          }
        };

        const infoEl = popup.querySelector<HTMLElement>('#swal-lot-qty-info');

        //  "ใส่ที่เหลือ" = what the item still needs after the other lots,
        //  capped by this lot's available. Greyed out when it would change
        //  nothing (already filled in, or nothing left). The line under the
        //  input says where that number comes from.
        const paintFillButton = () => {
          if (activeIndex === null) return;
          const cap = lotFillQty(activeIndex);
          const current = qtyByLot.get(activeIndex) ?? 0;
          const total = [...qtyByLot.values()].reduce((sum, qty) => sum + qty, 0);

          if (selectAllBtn && selectAllQtyEl) {
            selectAllQtyEl.textContent = formatQty(cap);
            selectAllBtn.style.display = 'flex';
            selectAllBtn.disabled = cap <= 0 || current === cap;
          }
          if (infoEl) {
            infoEl.textContent =
              `พร้อมใช้ของล็อตนี้ ${formatQty(lotAvailable(lotStocks[activeIndex]))}` +
              ` · ใบรายการยังขาด ${formatQty(Math.max(0, itemRemainingQty - total))}`;
            infoEl.style.display = 'block';
          }
        };

        const setActive = (index: number) => {
          const previous = activeIndex;
          activeIndex = index;
          if (previous !== null) paintChip(previous);
          paintChip(index);

          //  The how-to hint is only for before the first lot is tapped.
          if (hintEl) hintEl.style.display = 'none';
          if (labelEl) labelEl.textContent = `จำนวนของล็อต ${lotStocks[index].pdlotno ?? ''}`;
          if (input) {
            input.disabled = false;
            input.placeholder = 'ระบุจำนวน';
            const qty = qtyByLot.get(index) ?? 0;
            input.value = qty > 0 ? String(qty) : '';
            input.focus();
          }
          paintFillButton();
        };

        const saveActiveQty = (value: string) => {
          if (activeIndex === null) return;
          const qty = Number(value);
          if (value && Number.isFinite(qty) && qty > 0) qtyByLot.set(activeIndex, qty);
          else qtyByLot.delete(activeIndex);
          paintChip(activeIndex);
          paintFillButton();
        };

        popup.querySelectorAll<HTMLButtonElement>('.swal-lot-chip').forEach((chip) => {
          chip.addEventListener('click', () => setActive(Number(chip.dataset['lotIndex'])));
        });

        input?.addEventListener('input', () => saveActiveQty(input.value));

        selectAllBtn?.addEventListener('click', () => {
          if (activeIndex === null || !input) return;
          const fill = lotFillQty(activeIndex);
          input.value = fill > 0 ? String(fill) : '';
          saveActiveQty(input.value);
          input.focus();
        });

        //  Re-edit: show the saved per-lot qty on the chips.
        qtyByLot.forEach((_, index) => paintChip(index));

        //  Make a lot active up front when the choice is obvious: the only lot
        //  with stock, or the lot typed in the "เลขที่ล็อต" filter.
        const pickable = lotStocks
          .map((stock, index) => (lotAvailable(stock) > 0 ? index : -1))
          .filter((index) => index !== -1);
        const lotFilter = (this.stockInquiryForm.controls.lotNo.value ?? '').trim().toLowerCase();
        const filteredIndex = pickable.find(
          (index) => (lotStocks[index].pdlotno ?? '').trim().toLowerCase() === lotFilter,
        );
        if (pickable.length === 1) setActive(pickable[0]);
        else if (lotFilter && filteredIndex !== undefined) setActive(filteredIndex);
      },
      preConfirm: () => {
        if (qtyByLot.size === 0) {
          Notify.showValidationMessage('กรุณาเลือกล็อตและระบุจำนวน');
          return false;
        }

        for (const [index, qty] of qtyByLot) {
          const stock = lotStocks[index];
          if (qty > lotAvailable(stock)) {
            Notify.showValidationMessage(
              `จำนวนเกินกว่าที่พร้อมใช้ของล็อต ${stock.pdlotno} (${formatQty(stock.available)})`,
            );
            return false;
          }
        }

        const total = [...qtyByLot.values()].reduce((sum, qty) => sum + qty, 0);
        if (total > itemRemainingQty) {
          Notify.showValidationMessage('จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
          return false;
        }

        return total;
      },
    });

    if (!result.isConfirmed) return;

    //  One row per location: the lots that got a qty, joined ("A,B"), with the
    //  summed qty -- the job stores no qty per lot.
    const pickedStocks = lotStocks.filter((_, index) => (qtyByLot.get(index) ?? 0) > 0);
    const lotNo = pickedStocks.map((stock) => stock.pdlotno).join(',');
    const total = Number(result.value);

    location.patchValue({
      lotNo,
      availableQty: pickedStocks.reduce((sum, stock) => sum + (Number(stock.available) || 0), 0),
      qtyLock: pickedStocks.reduce((sum, stock) => sum + (Number(stock.qtylock) || 0), 0),
      confirmQty: total,
      isChecked: true,
      //  Planned kg per lot, sent on approve (fromLocations[].lots).
      lotQtys: JSON.stringify(
        pickedStocks.map((stock) => ({
          lotNo: stock.pdlotno,
          qty: qtyByLot.get(lotStocks.indexOf(stock)) ?? 0,
        })),
      ),
    });
  }

  //  Clicking the qty pill of a checked row reopens the qty prompt so the
  //  user can change it without removing the location first.
  onEditLocationQty(location: locationForm, event: MouseEvent) {
    event.stopPropagation();
    //  A row holding several lots edits its per-lot qty in the lot prompt.
    if (this.hasMultipleLots(location)) {
      this.onPickLocationLot(location);
      return;
    }
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
    location.patchValue({ confirmQty: 0, isChecked: false, lotQtys: null });

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
      lotQtys: new FormControl<string | null>(location.lotQtys ?? null),
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
    //  Stock picker: can't take more than the location has available. A row
    //  already saved on the job keeps its saved qty allowed, since the stock
    //  search may no longer count what this job itself holds there.
    const availableCap =
      this.isRequiredStock && data.availableQty != null
        ? Math.max(Number(data.availableQty) || 0, Number(data.qty) || 0)
        : null;
    const availableQtyError = `จำนวนเกินกว่าที่พร้อมใช้ (${(availableCap ?? 0).toLocaleString('en-US')} ${this.qtyUnit})`;

    //  Same inline "select all" pill as select-internal-transfer-location:
    //  clicking it fills the input with the remaining qty and submits.
    Notify.fire({
      target: modalContent ?? undefined,
      backdrop: modalContent ? false : true,
      returnFocus: false,
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (${this.qtyUnit}) : ${this.displayLocationName(data.locationName)}</span>`,
      html: `
        <style>
          /* Stronger shadow: popup sits on the white modal without a backdrop. */
          .swal2-popup:has(#swal-qty-input) {
            box-shadow: 0 24px 64px rgba(15, 23, 42, 0.35), 0 8px 24px rgba(15, 23, 42, 0.2) !important;
            border: 1px solid #e2e8f0 !important;
          }
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
          Notify.clickConfirm();
        });
        //  "ขนย้ายจริง" button: fill the input with the actual moved qty and submit.
        document.getElementById('swal-actual-qty-btn')?.addEventListener('click', () => {
          if (input) input.value = String(actualQty);
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
        if (qty < actualQty) {
          this.toggleQtyError(actualQtyError);
          return false;
        }
        if (availableCap !== null && qty > availableCap) {
          this.toggleQtyError(availableQtyError);
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
    const fetchStocks = (lotNo: string) =>
      this.fetchStockInquiry(
        this.warehouseCode,
        formValue.grade || '',
        lotNo,
        formValue.code?.cc_code || '',
        invDate,
        formValue.prodType || '',
        this.itemData?.qty_unit == 'bag' ? 'Y' : 'N',
      );

    //  Stock picker with a lot filter: the filtered search says WHICH
    //  locations hold that lot, a second search without the lot gives every
    //  lot at those locations -- so a location holding the filtered lot and
    //  another one still shows both lots (and its full available / lock).
    const lotFilter = (formValue.lotNo || '').trim();
    const withAllLots = this.isRequiredStock && !!lotFilter;
    const [response, allLotsResponse] = await Promise.all([
      fetchStocks(lotFilter),
      withAllLots ? fetchStocks('').catch(() => null) : Promise.resolve(null),
    ]);

    //  A newer request was fired while this one was in flight -- drop this result.
    if (requestSeq !== this.stockInquiryRequestSeq) return;

    //  The API returns result: "" (not []) when there's no matching stock,
    //  so a plain array method call here would throw.
    const onInvDate = (result: unknown) =>
      (Array.isArray(result) ? (result as Type.ResultProcessStockInquiry[]) : []).filter(
        (stock) => stock.invdate.slice(0, 10) === invDate,
      );
    const stockKey = (stock: Type.ResultProcessStockInquiry) =>
      `${stock.whcode}_${stock.careacode}_${stock.clevelcode}_${stock.clocationcode}`;

    const filteredStocks = onInvDate(response?.result);
    const filteredLocations = new Set(filteredStocks.map(stockKey));
    const allLotStocks = allLotsResponse
      ? onInvDate(allLotsResponse.result).filter((stock) => filteredLocations.has(stockKey(stock)))
      : [];
    //  Second search failed or came back empty -> fall back to the filtered one.
    const stocks = allLotStocks.length > 0 ? allLotStocks : filteredStocks;

    //  Per-lot stock of each location, for the lot picker (onPickLocationLot).
    this._stockLotsByLocation = new Map();
    stocks.forEach((stock) => {
      const name = this.getLocationName({
        wh_code: stock.whcode,
        area_code: stock.careacode,
        level_code: stock.clevelcode,
        location_code: stock.clocationcode,
      });
      this._stockLotsByLocation.set(name, [...(this._stockLotsByLocation.get(name) ?? []), stock]);
    });

    if (stocks.length === 0) {
      this._stockInquiryData = [];
      this.resetWhLocationForm();
      return;
    }

    const locationStocks = this.mergeStocksByLocation(stocks);
    this._stockInquiryData = locationStocks;
    this.pruneLocationsNotInStock(locationStocks);
    //  Sequential so two stock rows for the same location don't both miss the
    //  lookup (while awaiting findLocationId) and get added twice.
    for (const stock of locationStocks) {
      await this.updateOrAddLocation(stock);
    }
  }

  //  The stock API returns one row per location + lot. Jobs save one row per
  //  location (the forklift / WMS Plus side counts actual qty per location),
  //  so a location holding several lots becomes one row: lots joined with ","
  //  (same format job-detail's joinAddonLots uses), available / lock summed.
  private mergeStocksByLocation(
    stocks: Type.ResultProcessStockInquiry[],
  ): Type.ResultProcessStockInquiry[] {
    const byLocation = new Map<string, Type.ResultProcessStockInquiry>();

    stocks.forEach((stock) => {
      const key = `${stock.whcode}_${stock.careacode}_${stock.clevelcode}_${stock.clocationcode}`;
      const merged = byLocation.get(key);

      if (!merged) {
        byLocation.set(key, { ...stock });
        return;
      }

      const lots = this.splitLots(merged.pdlotno);
      this.splitLots(stock.pdlotno).forEach((lot) => {
        if (!lots.some((current) => current.toLowerCase() === lot.toLowerCase())) lots.push(lot);
      });

      merged.pdlotno = lots.join(',');
      merged.available = (Number(merged.available) || 0) + (Number(stock.available) || 0);
      merged.qtylock = (Number(merged.qtylock) || 0) + (Number(stock.qtylock) || 0);
    });

    return Array.from(byLocation.values());
  }

  //  Stock picker only: Put rows carry the item's lot, not the stock lots.
  hasMultipleLots(location: locationForm): boolean {
    return this.isRequiredStock && this.splitLots(location.value.lotNo).length > 1;
  }
  private splitLots(lotNo: string | null | undefined): string[] {
    return (lotNo ?? '')
      .split(',')
      .map((lot) => lot.trim())
      .filter((lot) => !!lot);
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

      if (!this.isRequiredStock) {
        location.patchValue({
          availableQty: stock.available,
          qtyLock: stock.qtylock,
          lotNo: currentLotNo || stock.pdlotno || null,
          isVisible:
            !currentLotNo || currentLotNo.toLowerCase() === (stock.pdlotno ?? '').toLowerCase(),
        });
        return;
      }

      //  stock.pdlotno can hold several lots ("A,B", see mergeStocksByLocation).
      //  A picked row keeps the lots it was saved with and stays listed while
      //  any of them is still in the result. A row nobody picked takes the
      //  location's current lots, so a lot filter change doesn't hide it.
      const isPicked = !!location.value.isChecked || !!location.value.isSelected;
      const stockLots = this.splitLots(stock.pdlotno).map((lot) => lot.toLowerCase());
      const rowLots = this.splitLots(currentLotNo).map((lot) => lot.toLowerCase());

      //  A picked row narrowed to one lot (onPickLocationLot) shows that lot's
      //  qty, not the whole location's.
      const rowLotStocks = (this._stockLotsByLocation.get(locationName) ?? []).filter((lotStock) =>
        rowLots.includes((lotStock.pdlotno ?? '').trim().toLowerCase()),
      );
      const useRowLots = isPicked && rowLots.length > 0 && rowLotStocks.length > 0;

      location.patchValue({
        availableQty: useRowLots
          ? rowLotStocks.reduce((sum, lotStock) => sum + (Number(lotStock.available) || 0), 0)
          : stock.available,
        qtyLock: useRowLots
          ? rowLotStocks.reduce((sum, lotStock) => sum + (Number(lotStock.qtylock) || 0), 0)
          : stock.qtylock,
        lotNo: isPicked
          ? currentLotNo || stock.pdlotno || null
          : stock.pdlotno || currentLotNo || null,
        isVisible:
          !isPicked || rowLots.length === 0 || rowLots.some((lot) => stockLots.includes(lot)),
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
      title: `<span style="font-size:22px;font-weight:500;">${titles[icon] ?? 'Notice'}</span>`,
      text: message,
      showConfirmButton: false,
      timer: 2000,
    });
  }
}
