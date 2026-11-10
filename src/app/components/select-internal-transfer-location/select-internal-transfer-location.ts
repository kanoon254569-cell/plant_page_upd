import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import Swal, { SweetAlertIcon } from 'sweetalert2';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';

type WarehouseCode = 'A41' | 'A43' | 'MWH';

type PalletPick = {
  id: number | null;
  palletNo: string;
  grade: string | null;
  lot: string | null;
  qty: number;
  text: string | null;
  scannedQrCode: string | null;
};

type locationForm = FormGroup<{
  id: FormControl<number | null>;
  itemId: FormControl<number | null>;
  whCode: FormControl<string | null>;
  ccCode: FormControl<string | null>;
  grade: FormControl<string | null>;
  gradeId: FormControl<number | null>;
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
  isPalletMode: FormControl<boolean | null>;
  selectedPallets: FormControl<PalletPick[] | null>;
  remark: FormControl<string | null>;
}>;

type locationInput = {
  id: number | null;
  itemId: number | null;
  whCode: string | null;
  ccCode: string | null;
  grade: string | null;
  gradeId?: number | null;
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
  isPalletMode?: boolean;
  selectedPallets?: PalletPick[] | null;
  remark?: string | null;
};

//  Dedicated to job-wh-internal-transfer-list, which mounts two instances of
//  this component at once -- one to pick source locations, one to pick
//  destination locations, for many-to-many internal transfers. Unlike
//  select-wh-location (job-detail), there's no source job item to pre-fill
//  grade/lot from, so here Grade stays editable. The Warehouse/Area/Level
//  filter still starts collapsed like job-detail's -- it only narrows down
//  locations already returned by the Stock inquiry filter, so it has
//  nothing to filter until that's been searched first.
@Component({
  selector: 'app-select-internal-transfer-location',
  standalone: false,
  templateUrl: './select-internal-transfer-location.html',
  styleUrl: './select-internal-transfer-location.css',
})
export class SelectInternalTransferLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Display-only item for the header Grade / Lot chips.
  @Input() headerItem: Type.Item | null = null;
  //  job-wh-internal-transfer-list mounts a source AND a destination instance
  //  of this component at the same time (many-to-many transfer), so each
  //  needs its own modal ids to avoid colliding on the same DOM element.
  @Input() modalId = 'whLocationModal';
  @Input() confirmModalId = 'whLocationConfirmModal';
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() warehouseCode: WarehouseCode = 'MWH';
  @Input({ required: true }) costCenter = '';
  @Input() itemData: Type.Item | null = null;
  @Input() isRequiredStock = false;
  //  Source locations must already hold real stock -- you can't pick from
  //  somewhere empty. Destination locations don't: putting stock somewhere
  //  new/empty is the whole point, so job-wh-internal-transfer-list sets
  //  this false for its destination picker to allow any physical location,
  //  not only ones the Stock inquiry filter already found holding this grade.
  @Input() requireExistingStock = true;
  //  Destination locations have no availableQty to cap "Select All" against
  //  (see requireExistingStock above), so "Select All" there instead means
  //  "whatever's left to match the source total" -- job-wh-internal-transfer-list
  //  binds this to its totalSourceQty for the destination picker only.
  @Input() targetTotalQty: number | null = null;
  @Input() isShipmentJob = false;
  @Input() openRequestId = 0;
  @Input() qtyUnit: string | null = null;
  //  job-wh-internal-transfer-detail's destination picker only -- defaults
  //  the Stock inquiry filter's Grade/Lot No to whatever the source picker
  //  already has selected, so re-opening "Add Destination Location" doesn't
  //  make the user retype the same grade/lot the source side already fixed.
  @Input() defaultGrade: string | null = null;
  @Input() defaultLotNo: string | null = null;
  //  job-wh-internal-transfer-detail.ts already fetches both of these once
  //  in its own ngOnInit (warehouseCode is always the same static 'MWH' for
  //  every picker on that page) -- taking them as Inputs instead of each of
  //  this component's 2 instances (source + destination) fetching its own
  //  copy cuts what was 1 (parent) + 2 x 2 (each picker instance) = 5 redundant
  //  GET calls for the same 2 option lists down to the parent's original 2.
  @Input() whLocationOptions: Type.ResultProcessGetOptionsWh[] | null = [];
  @Input() wmsCcCodeOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = [];

  _whLocationData!: Type.ResultProcessWhLocation[] | null;

  areaLocationOptions: Type.ResultProcessGetOptionsArea[] | null = [];
  levelLocationOptions: Type.ResultProcessGetOptionsLevel[] | null = [];

  _stockInquiryData!: Type.ResultProcessStockInquiry[] | null;
  _allStockInquiryData!: Type.ResultProcessGetAllStockInquiry[] | null;
  _gradeWithSapCcCodeData!: Type.ResultProcessGetGradeWithSapCcCode[] | null;

  _isExplandSearch = false;
  _isExplandStockInquiry = true;

  //  Pallet picker (source only, see requireExistingStock): opened instead of
  //  the qty-entry Swal.fire when a location's own isPalletMode checkbox is
  //  ticked, so the user can pick specific physical pallets rather than a
  //  bare quantity.
  _palletPickerLocation: locationForm | null = null;
  _palletPickerData: Type.ResultProcessPalletListByLocation[] = [];
  _palletPickerSelectedNos = new Set<string>();
  _isPalletPickerLoading = false;

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

  constructor(private restService: CrudService) {}

  //  Falls back to defaultGrade/defaultLotNo -- the destination picker's
  //  itemData is a stub with no grade/lot, so its chips come from the
  //  source side's selection instead.
  get headerGrade(): string {
    return (
      (this.headerItem ?? this.currentItem)?.grade?.trim() || this.defaultGrade?.trim() || ''
    );
  }

  get headerLotNo(): string {
    return (
      (this.headerItem ?? this.currentItem)?.lot_no?.trim() || this.defaultLotNo?.trim() || ''
    );
  }

  get lotSelectModalId(): string {
    return `${this.modalId}LotSelect`;
  }

  get palletPickerModalId(): string {
    return `${this.modalId}PalletPicker`;
  }

  get palletPickerSelectedQty(): number {
    return this._palletPickerData
      .filter((pallet) => this._palletPickerSelectedNos.has(pallet.pallet_no))
      .reduce((sum, pallet) => sum + (Number(pallet.qty) || 0), 0);
  }

  get currentItem(): Type.Item | null {
    if (!this.itemData) return null;
    if (this.selectedItemId === null) return this.itemData;
    return this.itemData.id === this.selectedItemId ? this.itemData : null;
  }

  //  Location filter narrows down locations already fetched by the Stock
  //  inquiry filter -- it doesn't require Warehouse, Area *and* Level to all
  //  be picked. locationName is built as wh_code+area_code+level_code+...,
  //  so whatever prefix of that has been picked so far is enough to filter.
  //  '-' means "no area/level" and getLocationName leaves it out of the
  //  location name (WH38 / A / - -> "M38A01"), so it must not be part of the
  //  prefix either -- "M38A-" matched nothing and the list showed empty.
  get locationFilterPrefix(): string {
    const part = (value: string | null | undefined) => (value === '-' ? '' : (value ?? ''));

    const whCode = part(this.searchForm.controls.whCode.value);
    if (!whCode) return '';

    const areaCode = this.searchForm.controls.areaCode.value ?? '';
    if (!areaCode) return whCode;

    const levelCode = this.searchForm.controls.levelCode.value;
    if (!this.hasSelectedValue(levelCode)) return `${whCode}${part(areaCode)}`;

    return `${whCode}${part(areaCode)}${part(levelCode)}`;
  }

  get currentWhLocations(): locationForm[] {
    const prefix = this.displayLocationName(this.locationFilterPrefix);

    return this.locations.controls
      .filter((loc) => loc.value.itemId === this.selectedItemId && loc.value.isVisible)
      .filter((loc) => !prefix || this.displayLocationName(loc.value.locationName).startsWith(prefix))
      .sort((a, b) => Number(a.value.locationId) - Number(b.value.locationId));
  }

  //  There's no job item with a fixed pick target here (unlike job-detail),
  //  so the cap shown/enforced is the real total available stock currently
  //  in view -- summed from the same (filtered) locations the list shows.
  get totalAvailableQty(): number {
    return this.currentWhLocations.reduce(
      (sum, loc) => sum + (Number(loc.value.availableQty) || 0),
      0,
    );
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
      !location.value.isChecked &&
      this.isRequiredStock &&
      ((this.requireExistingStock &&
        (location.value.availableQty === 0 || !location.value.availableQty)) ||
        location.value.locationId === null ||
        location.value.locationId === 0)
    );
  }

  //  Same clean-up as select-wh-location, so the name shown, saved and matched
  //  here is the one on the printed QR. Saved jobs may still hold the raw
  //  form, so run both sides through this when comparing names.
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

  //  An empty Grade isn't "not found" yet -- only flag a grade that was
  //  actually typed and has no match.
  get isGradeCorrect(): boolean {
    return (
      !this.stockInquiryForm.controls.grade.value?.trim() ||
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

  get lotNoOptions(): any[] {
    const stocks = Array.isArray(this._allStockInquiryData) ? this._allStockInquiryData : [];
    return Array.from(new Set(stocks.filter((lotNo) => !!lotNo))).sort();
  }

  get wmsCode() {
    var data = this.wmsCcCodeOptions?.find((item) => item.cc_code === this.costCenter);
    return data
      ? { sap_cc_code: data.sap_cc_code, cc_code: data.cc_code }
      : { sap_cc_code: '', cc_code: '' };
  }

  async ngOnInit() {
    this.isInitialized = true;
    this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });
    //  Destination picker (requireExistingStock false) picks targets mainly
    //  by Warehouse/Area/Level: open the Location filter and start the Stock
    //  inquiry filter collapsed (still there to expand).
    if (!this.requireExistingStock) {
      this._isExplandSearch = true;
      this._isExplandStockInquiry = false;
    }

    this.registerSearchHandlers();
    this.registerStockInquiryHandlers();
    this.initializeWarehouseOptions();
  }

  ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;

    if (changes['warehouseCode']) {
      this.searchForm.patchValue({ wh: this.warehouseCode }, { emitEvent: false });
      this.initializeWarehouseOptions();
    }

    //  Cost Center now comes solely from the page header's own selection
    //  (see job-wh-internal-transfer-detail.html's [costCenter] binding) --
    //  the modal no longer has its own Cost Center picker, so a change here
    //  has to drive the stock search itself instead of a dropdown valueChange.
    if (changes['costCenter']) {
      this.stockInquiryForm.patchValue({ code: this.wmsCode }, { emitEvent: false });
      this.loadStockInquiryData();

      if (this.wmsCode.cc_code && this.stockInquiryForm.controls.grade.value) {
        this.loadGradeWithSapCcCode();
      }
    }

    if (changes['openRequestId']?.currentValue && this.isRequiredStock) {
      //  currentItem is always the blank stub for internal transfer (no real
      //  job line to derive grade/lot from -- see job-wh-internal-transfer-
      //  detail.ts's sourceItem/destinationItem), so the Stock inquiry
      //  filter would otherwise open blank every time even after a location
      //  was already picked. Falls back to whatever's already checked for
      //  this item, then to defaultGrade/defaultLotNo (destination picker
      //  only -- the source side's own grade/lot), so re-opening "Add
      //  Location" defaults to searching for more of the same stock instead
      //  of making the user retype it. Last fallback is what's already in the
      //  filter, so closing without picking a location keeps the typed search.
      const checkedLocation = this.locations.controls.find(
        (loc) => loc.value.itemId === this.selectedItemId && loc.value.isChecked,
      );
      const grade =
        this.currentItem?.grade?.trim() ||
        checkedLocation?.value.grade?.trim() ||
        this.defaultGrade?.trim() ||
        this.stockInquiryForm.controls.grade.value?.trim() ||
        '';
      const lotNo =
        this.currentItem?.lot_no?.trim() ||
        checkedLocation?.value.lotNo?.trim() ||
        this.defaultLotNo?.trim() ||
        this.stockInquiryForm.controls.lotNo.value?.trim() ||
        '';

      this.setStockInquiryForm(this.wmsCode, grade, lotNo, new Date());

      if (this.wmsCode.cc_code && grade) {
        this.loadGradeWithSapCcCode();
      }

      if (this.wmsCode.cc_code && grade) {
        this.loadStockInquiryData();
      } else if (!grade) {
        //  Re-opened with a blank Grade -- don't keep showing the last
        //  session's search results under an empty filter.
        this.clearStockResults();
      }
    }

    if (
      changes['openRequestId']?.currentValue &&
      this.searchForm.controls.whCode.value &&
      this.searchForm.controls.areaCode.value &&
      this.hasSelectedValue(this.searchForm.controls.levelCode.value) &&
      this.searchForm.controls.locationCode.value
    ) {
      this.loadWhLocationData(this.searchForm.controls.locationCode.value);
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
  ) {
    this.stockInquiryForm.patchValue(
      {
        code: code || { sap_cc_code: '', cc_code: '' },
        grade: grade || '',
        lotNo: lotNo || '',
        invDate: invDate || null,
      },
      { emitEvent: false },
    );
  }

  registerSearchHandlers() {
    this.searchForm.controls.whCode.valueChanges.subscribe(async (whCode) => {
      this.areaLocationOptions = [];
      this.levelLocationOptions = [];
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
      if (!grade && this.isRequiredStock) {
        await this.clearStockResults();
        return;
      }

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

  //  Grade is blank: drop the previous search's results (picked rows stay)
  //  instead of leaving a stale list + "สต็อกที่แสดง" total.
  private async clearStockResults(): Promise<void> {
    this._stockInquiryData = [];
    this.resetWhLocationForm();
    //  Destination picker also lists empty locations from the Location
    //  filter browse, which don't depend on the grade -- re-run that browse
    //  so those candidates come back without the stock rows.
    const levelCode = this.searchForm.controls.levelCode.value;
    if (!this.requireExistingStock && this.hasSelectedValue(levelCode)) {
      await this.loadWhLocationData(levelCode ?? '');
    }
  }

  //  whLocationOptions/wmsCcCodeOptions come in as Inputs now (see their
  //  declarations above) instead of being fetched here -- this just seeds
  //  the Stock inquiry form once those Inputs (and currentItem) are set.
  initializeWarehouseOptions() {
    this.stockInquiryForm.patchValue(
      {
        code: this.wmsCode,
        grade: this.currentItem?.grade ?? '',
        lotNo: this.currentItem?.lot_no ?? '',
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

  onResetStockInquiry() {
    //  emitEvent: false -- the individual valueChanges handlers would just
    //  call loadStockInquiryData/loadGradeWithSapCcCode with now-blank values
    //  and return early anyway, so reset the derived state directly instead.
    //  Keeps the Cost Center (it comes from the page header -- the modal has
    //  no picker to set it back) and resets Inv Date to today: blanking
    //  either left every later Grade search empty / 400ing until reopen.
    this.stockInquiryForm.patchValue(
      {
        code: this.wmsCode,
        grade: '',
        lotNo: '',
        invDate: new Date(),
        prodType: '',
      },
      { emitEvent: false },
    );

    this._gradeWithSapCcCodeData = [];
    this._stockInquiryData = [];
    this.resetWhLocationForm();
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
    //  Pallet-mode locations reopen the picker even once checked, so the
    //  user can revise which pallets they picked without first removing
    //  the location -- unlike the plain qty flow below.
    if (location.value.isPalletMode && this.requireExistingStock) {
      this.onOpenPalletPicker(location);
      return;
    }

    if (location.value.isChecked) {
      return;
    }

    //  Reference check, not a locationId re-lookup -- locationId alone isn't
    //  unique when the same physical location holds more than one lot (see
    //  updateOrAddLocation), so re-finding by it could resolve a different
    //  lot's row than the one actually clicked. `location` here already IS
    //  that exact row (from the *ngFor); this just confirms it's still
    //  current/visible before opening the qty prompt for it.
    if (this.currentWhLocations.includes(location)) {
      this.onAssignLocationQty(location.value);
    }
  }

  //  isVisible is NOT reset to false here -- it's the same flag
  //  updateOrAddLocation recomputes from the lot match every time
  //  loadStockInquiryData() resolves (called right below), so forcing it
  //  false only hid the row until that refetch overwrote it back to true a
  //  moment later: a visible flicker on every uncheck, and if that refetch
  //  was slow, failed, or the lot momentarily didn't match mid-search, the
  //  row could get stuck invisible even though it's still valid stock.
  //  Clicking the qty pill of a checked row reopens the qty prompt (or the
  //  pallet picker for pallet-mode rows) without removing the location first.
  onEditLocationQty(location: locationForm, event: MouseEvent) {
    event.stopPropagation();
    if (location.value.isPalletMode && this.requireExistingStock) {
      this.onOpenPalletPicker(location);
      return;
    }
    this.onAssignLocationQty(location.value);
  }

  async onUncheckLocation(location: locationForm) {
    if (this.hasActualQty(location)) {
      return;
    }

    location.patchValue({
      confirmQty: 0,
      isChecked: false,
      selectedPallets: null,
    });

    this.loadStockInquiryData();
  }

  //  Source locations only (see requireExistingStock) -- lets the user tick
  //  a per-location checkbox to pick specific physical pallets instead of
  //  just typing a quantity. Disabled once the location is checked so the
  //  mode can't change out from under an existing selection; remove the
  //  location first to switch modes.
  togglePalletMode(location: locationForm, event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    location.controls.isPalletMode.setValue(checked);
  }

  //  Per-location remark -- shown once a location is checked, for either the
  //  Source or Destination picker (both instances share this component).
  onRemarkInput(location: locationForm, event: Event): void {
    const value = (event.target as HTMLInputElement).value;
    location.controls.remark.setValue(value.trim() ? value : null);
  }

  isPalletChecked(palletNo: string): boolean {
    return this._palletPickerSelectedNos.has(palletNo);
  }

  onTogglePallet(pallet: Type.ResultProcessPalletListByLocation, event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    if (checked) {
      this._palletPickerSelectedNos.add(pallet.pallet_no);
    } else {
      this._palletPickerSelectedNos.delete(pallet.pallet_no);
    }
  }

  onSelectAllPallets(): void {
    const allSelected = this._palletPickerData.every((pallet) =>
      this._palletPickerSelectedNos.has(pallet.pallet_no),
    );

    this._palletPickerSelectedNos = allSelected
      ? new Set()
      : new Set(this._palletPickerData.map((pallet) => pallet.pallet_no));
  }

  async onOpenPalletPicker(location: locationForm): Promise<void> {
    this._palletPickerLocation = location;
    this._palletPickerSelectedNos = new Set(
      (location.value.selectedPallets ?? []).map((pallet) => pallet.palletNo),
    );
    this._isPalletPickerLoading = true;
    this._palletPickerData = [];

    try {
      const response = await this.fetchPalletListByLocation(location.value.locationId ?? 0);
      this._palletPickerData = response?.data ?? [];

      if (this._palletPickerData.length === 0) {
        this.SwalAlert('info', 'ไม่พบข้อมูลพาเลทในตำแหน่งนี้');
        return;
      }

      this.showPalletPickerModal();
    } catch (error) {
      console.error('Error fetching pallet list:', error);
      this.SwalAlert('error', 'ไม่สามารถดึงข้อมูลพาเลทได้');
    } finally {
      this._isPalletPickerLoading = false;
    }
  }

  onClosePalletPicker(): void {
    this.hidePalletPickerModal();
  }

  onConfirmPalletPicker(): void {
    const location = this._palletPickerLocation;
    if (!location) return;

    const selectedPallets: PalletPick[] = this._palletPickerData
      .filter((pallet) => this._palletPickerSelectedNos.has(pallet.pallet_no))
      .map((pallet) => ({
        id: pallet.id ?? null,
        palletNo: pallet.pallet_no,
        grade: pallet.grade ?? null,
        lot: pallet.lot ?? null,
        qty: Number(pallet.qty) || 0,
        text: pallet.text ?? null,
        scannedQrCode: pallet.scanned_qr_code ?? null,
      }));

    if (selectedPallets.length === 0) {
      this.SwalAlert('warning', 'กรุณาเลือกอย่างน้อย 1 พาเลท');
      return;
    }

    //  Also matched by lotNo -- locationId alone isn't unique when the same
    //  physical location holds more than one lot (see updateOrAddLocation),
    //  so this could otherwise patch a different lot's row at that location.
    const locationIndex = this.locations.controls.findIndex(
      (loc) =>
        loc.value.locationId === location.value.locationId &&
        loc.value.itemId === location.value.itemId &&
        (loc.value.lotNo ?? '') === (location.value.lotNo ?? ''),
    );
    if (locationIndex === -1) return;

    this.locations.at(locationIndex).patchValue({
      confirmQty: selectedPallets.reduce((sum, pallet) => sum + pallet.qty, 0),
      isChecked: true,
      selectedPallets,
    });

    this.hidePalletPickerModal();
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
    });

    this.hideWhLocationModal();
    this.hideWhLocationConfirmModal();
  }

  resetWhLocationForm() {
    //  indexOf(loc) by reference, not a locationId+itemId re-lookup --
    //  locationId alone isn't unique when the same physical location holds
    //  more than one lot (see updateOrAddLocation), so re-finding by it
    //  could remove a different lot's row than the one actually being
    //  cleaned up here.
    this.locations.controls
      .filter((loc) => !loc.value.isChecked && !loc.value.isSelected)
      .forEach((loc) => {
        const index = this.locations.controls.indexOf(loc);
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
      ccCode: new FormControl<string | null>(location.ccCode ?? null),
      grade: new FormControl<string | null>(location.grade ?? null),
      gradeId: new FormControl<number | null>(location.gradeId ?? null),
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
      isPalletMode: new FormControl<boolean | null>(location.isPalletMode ?? false),
      selectedPallets: new FormControl<PalletPick[] | null>(location.selectedPallets ?? null),
      remark: new FormControl<string | null>(location.remark ?? null),
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
      `#${this.modalId} .modal-content`,
    ) as HTMLElement | null;

    const activeElement = document.activeElement as HTMLElement | null;
    activeElement?.blur();

    return modalContent;
  }

  //  Source locations: "Select All" = this location's own availableQty.
  //  Destination locations have no availableQty (requireExistingStock is
  //  false there) -- "Select All" instead means "whatever's left to reach
  //  targetTotalQty", excluding what THIS location itself already
  //  contributes so re-opening an already-filled location still offers the
  //  correct remaining room.
  private getSelectAllQty(data: locationForm['value']): number | null {
    if (this.requireExistingStock) {
      return data.availableQty && data.availableQty > 0 ? data.availableQty : null;
    }

    if (this.targetTotalQty == null) return null;

    const othersConfirmed =
      this.confirmQtyWhLocations(data.itemId ?? undefined) - (data.confirmQty ?? 0);
    const remaining = this.targetTotalQty - othersConfirmed;

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

    const maxAttr = this.requireExistingStock ? String(data.availableQty ?? '') : '';
    const initialValue = data.confirmQty === 0 ? '' : String(data.confirmQty ?? '');
    const actualQty = Number(data.actualQty) || 0;
    const actualQtyError = `จำนวนต้องไม่น้อยกว่าที่ขนย้ายจริง (${actualQty.toLocaleString('en-US')} ${this.qtyUnit})`;

    //  "เลือกทั้งหมด" lives inside the qty input itself (right-side inline
    //  button, like the app's other pill-with-action fields) instead of a
    //  separate Swal deny button -- clicking it fills the input with the
    //  computed select-all qty and submits immediately, same one-click
    //  behavior the old deny button had.
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
        <div id="swal-qty-group" style="display: flex; align-items: stretch; margin-top: 12px; height: 44px; border: 1px solid #cbd5e1; border-radius: 6px; overflow: hidden; background: #fff; transition: border-color 0.15s ease, box-shadow 0.15s ease;">
          <input
            id="swal-qty-input"
            type="number"
            min="1"
            ${maxAttr ? `max="${maxAttr}"` : ''}
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
      confirmButtonColor: '#1d4ed8',
      cancelButtonText: 'ยกเลิก',
      cancelButtonColor: '#64748b',
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
        if (input?.value && qty < actualQty) {
          this.toggleQtyError(actualQtyError);
          return false;
        }
        return qty;
      },
    }).then((result) => {
      if (!result.isConfirmed) return;

      const qtyToAssign = Number(result.value);

      //  Covers 0, negative, blank ('' -> 0) and non-numeric (NaN) input in
      //  one check -- applies to both source and destination, since both use
      //  this same method.
      if (!(qtyToAssign > 0)) {
        this.SwalAlert('warning', 'กรุณาระบุจำนวนมากกว่า 0');
        return;
      }

      //  Also matched by lotNo -- locationId alone isn't unique when the
      //  same physical location holds more than one lot (see
      //  updateOrAddLocation): without it, this could silently patch a
      //  DIFFERENT lot's row at the same location instead of the one the
      //  qty prompt was actually opened for.
      const locationIndex = this.locations.controls.findIndex(
        (loc) =>
          loc.value.locationId === data.locationId &&
          loc.value.itemId === data.itemId &&
          (loc.value.lotNo ?? '') === (data.lotNo ?? ''),
      );
      if (locationIndex === -1) return;

      if (
        this.requireExistingStock &&
        data.availableQty != null &&
        qtyToAssign > data.availableQty
      ) {
        this.SwalAlert('warning', 'จำนวนที่ต้องการเกินกว่าจำนวนที่มี ณ ตำแหน่งนี้');
        return;
      }

      if (
        this.requireExistingStock &&
        //  Exclude this row's own current qty so re-editing doesn't double count it.
        this.confirmQtyWhLocations(data.itemId ?? undefined) -
          (data.isChecked ? Number(data.confirmQty) || 0 : 0) +
          qtyToAssign >
        this.totalAvailableQty
      ) {
        this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนสต็อกที่มีอยู่จริง');
        return;
      }

      this.locations.at(locationIndex).patchValue({
        confirmQty: qtyToAssign,
        isChecked: true,
      });
    });
  }

  onDeleteWhLocation(location: locationForm) {
    //  indexOf(location) by reference -- see resetWhLocationForm's own note
    //  on why a locationId(+itemId) re-lookup can resolve the wrong row.
    const index = this.locations.controls.indexOf(location);

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

  hidePalletPickerModal() {
    const modalEl = document.getElementById(this.palletPickerModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showPalletPickerModal() {
    const modalEl = document.getElementById(this.palletPickerModalId);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  //  All pallets physically sitting in one MWH location, regardless of
  //  grade/lot -- a location can hold more than one grade/lot at once, and
  //  the pallet picker needs to show everything there, not just whatever
  //  grade/lot the Stock Inquiry filter happened to be on. Backed by a
  //  dedicated endpoint/SP (pProcessGetPalletListByLocation), separate from
  //  the grade/lot/pallet_no search used by Pallet Management/Information.
  fetchPalletListByLocation(locationId: number): Promise<Type.ResponseProcessPalletListByLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetPalletListByLocation(locationId, this.warehouseCode, 1, 1000).subscribe(
        (response: Type.ResponseProcessPalletListByLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching pallet list by location:', error);
          reject(error);
        },
      );
    });
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

  //  Fallback grade_id lookup for a location whose stock row didn't itself
  //  carry fpdgradeid (e.g. the destination picker, which browses Warehouse/
  //  Area/Level filters directly rather than a per-location Stock Inquiry
  //  match) -- matches the currently-typed grade code against whatever
  //  loadGradeWithSapCcCode already fetched for it.
  private resolveGradeId(): number | null {
    const gradeCode = this.stockInquiryForm.controls.grade.value;
    if (!gradeCode) return null;

    return (
      this._gradeWithSapCcCodeData?.find((g) => g.fpdgradecode === gradeCode)?.fpdgradeid ?? null
    );
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

    this._whLocationData.forEach(async (location) => {
      const itemLocation = locationMap.get(location.location_id);
      const stockInquiry = stockInquiryMap.get(
        `${location.wh_code}_${location.area_code}_${location.level_code}_${location.location_code}`,
      );

      if (this.isRequiredStock && this.requireExistingStock && !stockInquiry) return;

      const exists = this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === location.location_id &&
          currentLocation.value.itemId === this.selectedItemId,
      );

      if (exists) return;

      this.addWhLocation({
        id: itemLocation?.value?.id ?? null,
        itemId: this.selectedItemId,
        whCode: location.wh_code ?? null,
        ccCode: this.stockInquiryForm.controls.code.value?.cc_code ?? null,
        grade: this.stockInquiryForm.controls.grade.value ?? null,
        gradeId: itemLocation?.value?.gradeId ?? stockInquiry?.fpdgradeid ?? this.resolveGradeId(),
        lotNo: stockInquiry?.pdlotno ?? this.stockInquiryForm.controls.lotNo.value ?? null,
        locationId:
          location.location_id ??
          (await this.findLocationId(
            location.wh_code,
            location.area_code,
            location.level_code,
            location.location_code,
          )) ??
          null,
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
        isPalletMode: itemLocation?.value?.isPalletMode ?? false,
        selectedPallets: itemLocation?.value?.selectedPallets ?? null,
        remark: itemLocation?.value?.remark ?? null,
      });
    });
  }

  async loadStockInquiryData(): Promise<void> {
    const formValue = this.stockInquiryForm.getRawValue();
    const invDate = this.formatDate(formValue.invDate);

    if (!formValue.code?.cc_code || !formValue.grade || !invDate) return;

    const response = await this.fetchStockInquiry(
      this.warehouseCode,
      formValue.grade || '',
      formValue.lotNo || '',
      formValue.code?.cc_code || '',
      invDate,
      formValue.prodType || '',
      this.itemData?.qty_unit == 'bag' ? 'Y' : 'N'
    );

    //  The API returns result: "" (not []) when there's no matching stock,
    //  so a plain array method call here would throw.
    //  Previously also re-filtered by `stock.invdate.slice(0, 10) === invDate`
    //  (the requested date) -- but the backend is already asked for invDate
    //  and can legitimately answer with its latest available snapshot
    //  instead (e.g. today's inventory batch hasn't run yet, so it serves
    //  yesterday's), which that exact-string-match then silently discarded
    //  entirely, making a real, non-empty API response render as "no stock"
    //  in the modal.
    const stocks = Array.isArray(response?.result) ? response.result : [];

    if (stocks.length === 0) {
      this._stockInquiryData = [];
      //  requireExistingStock only -- destination locations come from
      //  loadWhLocationData's Warehouse/Area/Level browse, not from having
      //  stock here (an empty target location is the normal, expected case),
      //  so a zero-stock search must not wipe out the candidates the user is
      //  browsing.
      if (this.requireExistingStock) this.resetWhLocationForm();
      return;
    }

    this._stockInquiryData = stocks;

    //  updateOrAddLocation runs for both pickers -- a location already
    //  holding this grade/lot is a legitimate destination candidate too
    //  (consolidating stock into an existing location), not just a source
    //  pick. pruneLocationsNotInStock is requireExistingStock-only though:
    //  it deletes any row NOT in these stock results, which is right for
    //  the source picker (every valid pick must have real stock) but would
    //  wipe out every browsed-but-unchecked EMPTY destination candidate
    //  (no stock there yet, by design) on every re-search.
    stocks.forEach((stock) => this.updateOrAddLocation(stock));

    if (this.requireExistingStock) {
      this.pruneLocationsNotInStock(stocks);
    }
  }

  private async updateOrAddLocation(stock: any): Promise<void> {
    const locationName = this.getLocationName({
      wh_code: stock.whcode,
      area_code: stock.careacode,
      level_code: stock.clevelcode,
      location_code: stock.clocationcode,
    });

    //  Matched by locationName AND lotNo together -- the same physical
    //  location can hold more than one lot at once, and locationName alone
    //  used to collapse two different lots' stock rows into a single row:
    //  whichever stock the loop processed last would overwrite that row's
    //  availableQty/qtyLock while its lotNo/isChecked/pallet picks stayed
    //  whatever an earlier, different-lot pick had left there, so the card
    //  you clicked (this lot's numbers) wasn't actually the lot you got.
    const location = this.locations.controls.find(
      (loc) =>
        this.displayLocationName(loc.value.locationName) === locationName &&
        loc.value.itemId === this.selectedItemId &&
        (loc.value.lotNo ?? '').toLowerCase() === (stock.pdlotno ?? '').toLowerCase(),
    );

    if (location) {
      location.patchValue({
        availableQty: stock.available,
        qtyLock: stock.qtylock,
        gradeId: location.controls.gradeId.value ?? stock.fpdgradeid ?? null,
        isVisible: true,
      });
      return;
    }

    this.addWhLocation({
      id: null,
      itemId: this.selectedItemId,
      whCode: stock.whcode ?? null,
      ccCode: this.stockInquiryForm.controls.code.value?.cc_code ?? null,
      grade: this.stockInquiryForm.controls.grade.value ?? null,
      gradeId: stock.fpdgradeid ?? this.resolveGradeId(),
      lotNo: stock.pdlotno ?? this.stockInquiryForm.controls.lotNo.value ?? null,
      locationId:
        (await this.findLocationId(
          stock.whcode,
          stock.careacode,
          stock.clevelcode,
          stock.clocationcode,
        )) ?? null,
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

  //  Keyed by locationName+lotNo, same reason updateOrAddLocation matches on
  //  both -- name alone would let a stale row for a DIFFERENT lot at the
  //  same location survive as "found in stock" just because that location
  //  name happens to also hold the lot the current search is for.
  private pruneLocationsNotInStock(stocks: Type.ResultProcessStockInquiry[]): void {
    const stockLocationKeys = new Set(
      stocks.map((stock) =>
        `${this.getLocationName({
          wh_code: stock.whcode,
          area_code: stock.careacode,
          level_code: stock.clevelcode,
          location_code: stock.clocationcode,
        })}_${(stock.pdlotno ?? '').toLowerCase()}`,
      ),
    );

    for (let i = this.locations.length - 1; i >= 0; i--) {
      const loc = this.locations.at(i);

      if (loc.value.itemId !== this.selectedItemId) continue;

      const locationKey = `${this.displayLocationName(loc.value.locationName)}_${(loc.value.lotNo ?? '').toLowerCase()}`;
      const notFoundInStock = !stockLocationKeys.has(locationKey);

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
