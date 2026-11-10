import { ChangeDetectorRef, Component } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import { JwtTokenService } from '../../services/jwt-token.service';
import { PermissionService } from '../../services/permission.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';
import Swal from 'sweetalert2';
import { Router } from '@angular/router';
import { ResultProcessFindLocation } from './../../../models/variables-type';
import * as XLSX from 'xlsx';

@Component({
  selector: 'app-pallet-management',
  standalone: false,
  templateUrl: './pallet-management.html',
  styleUrl: './pallet-management.css',
})
export class PalletManagement {
  //  Constructor
  constructor(
    private crudService: CrudService,
    private restService: CrudService,
    private router: Router,
    private jwtService: JwtTokenService,
    private permissionService: PermissionService,
    private changeDetectorRef: ChangeDetectorRef,
  ) {}

  //  Pallet Type tabs (top right, same as location-management):
  //  normal = Auto/Manual/Special/Jumbo pallets (process/pallet)
  //  dummy  = tr_pallet.pallet_type 'D' (PLD...), empty pallets that go round the Warehouse
  //           for withdrawals (pallet-management/dummy, sql/107_)
  palletType: 'normal' | 'dummy' = 'normal';
  private readonly palletTypeStorageKey = 'pallet-management-type';

  onSelectPalletType(type: 'normal' | 'dummy'): void {
    if (this.palletType === type) return;

    this.palletType = type;
    try {
      sessionStorage.setItem(this.palletTypeStorageKey, type);
    } catch {
      //  Storage blocked/full -- the tab just isn't remembered.
    }

    if (type === 'dummy') {
      this.fetchDummyPalletList();
    } else {
      this.fetchProcessGetPalletList();
    }
  }

  //  Define Colunm
  private readonly baseColumns: string[] = [
    'no',
    'palletNumber',
    'tonNo',
    'grade',
    'lot',
    'qty',
    'locationType',
    'palletLocation',
    'createDateTime',
  ];

  private readonly selectableColumns: string[] = ['select', ...this.baseColumns];

  //  Select column only for users who can move pallets (the API enforces the same key)
  get canMoveToBagging(): boolean {
    return this.permissionService.has('pallet.move_to_bagging');
  }

  get displayedColumns(): string[] {
    return this.canMoveToBagging ? this.selectableColumns : this.baseColumns;
  }

  //  Pallets ticked for "move to Bagging Area" -- keyed by id, kept across pages,
  //  cleared on a new search or after moving. Same limit as the API.
  readonly maxMoveToBagging = 100;
  selectedPallets = new Map<number, any>();
  isMovingToBagging = false;

  _palletListTableData: any = [];
  totalCount: number = 0;
  isExportingExcel = false;

  //  Skeleton loading -- Pallet List shows shimmer rows while process/pallet loads
  isPalletListLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  //  Filter Form
  filter: Type.PalletFilter = {
    palletNo: '',
    grade: '',
    lot: '',
    locationType: '',
    locationId: 0,
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  optionLocationType: Type.ResultProcessGetOptionsLocationType[] = [];

  //  Location Type badge icon by ct_location_type.code (color comes from .badge-chip--loc-<code>)
  readonly locationTypeIcon: Partial<Record<string, string>> = {
    'BG-PLANT': 'shopping_bag',
    'MWH': 'warehouse',
    'RQ-PLANT': 'business',
    'PRE-ZONE': 'inventory_2',
    'SPC-ZONE': 'star',
    'DOCK': 'local_shipping',
    'VEHICLE': 'directions_car',
  };

  //  Location Autocomplete
  locationSearchText: string = '';
  locationSearchOptions: Type.ResultProcessFindLocation[] = [];
  private locationSearchTimeout: any;

  //  API
  _ResponseProcessPalletListData!: Type.ResponseProcessPalletListData;

  //  onOnInit
  async ngOnInit() {
    this.restoreFilter();
    try {
      if (sessionStorage.getItem(this.palletTypeStorageKey) === 'dummy') this.palletType = 'dummy';
    } catch {
      //  Storage blocked -- open on the normal tab.
    }

    if (this.palletType === 'dummy') {
      this.fetchDummyPalletList();
    } else {
      this.fetchProcessGetPalletList();
    }

    this.optionLocationType = (await this.fetchOptionLocationType()).data;
  }

  //  Saved filter -- the last searched filter is kept in sessionStorage and
  //  restored on the next visit (same as job-wh-transfer-list.ts saveFilter/restoreFilter).
  private readonly filterStorageKey = 'pallet-management-filter';

  saveFilter(): void {
    const saved = {
      palletNo: this.filter.palletNo ?? '',
      grade: this.filter.grade ?? '',
      lot: this.filter.lot ?? '',
      locationType: this.filter.locationType ?? '',
      locationId: this.filter.locationId ?? 0,
      locationName: this.locationSearchText ?? '',
      pageSize: this.filter.pageSize ?? 25,
      sortBy: this.filter.sortBy ?? '',
      sortOrder: this.filter.sortOrder ?? '',
    };
    try {
      sessionStorage.setItem(this.filterStorageKey, JSON.stringify(saved));
    } catch {
      //  Storage blocked/full -- the filter just isn't remembered.
    }
  }

  restoreFilter(): void {
    let saved: any = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(this.filterStorageKey) || 'null');
    } catch {
      saved = null;
    }
    if (!saved || typeof saved !== 'object') return;

    const str = (value: unknown) => (typeof value === 'string' ? value : '');

    this.filter = {
      ...this.filter,
      palletNo: str(saved.palletNo),
      grade: str(saved.grade),
      lot: str(saved.lot),
      locationType: str(saved.locationType),
      locationId: typeof saved.locationId === 'number' ? saved.locationId : 0,
      pageSize: typeof saved.pageSize === 'number' && saved.pageSize > 0 ? saved.pageSize : this.filter.pageSize,
      sortBy: str(saved.sortBy),
      sortOrder: str(saved.sortOrder),
      page: 1,
    };
    this.locationSearchText = str(saved.locationName);
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;
    this.selectedPallets.clear();

    this.fetchProcessGetPalletList();
  }

  canSelectPallet(row: any): boolean {
    return row.locationTypeCode !== 'BG-PLANT';
  }

  get selectablePageRows(): any[] {
    return (this._palletListTableData ?? []).filter((row: any) => this.canSelectPallet(row));
  }

  get isAllPageSelected(): boolean {
    const rows = this.selectablePageRows;
    return rows.length > 0 && rows.every((row) => this.selectedPallets.has(row.id));
  }

  get isSomePageSelected(): boolean {
    return !this.isAllPageSelected && this.selectablePageRows.some((row) => this.selectedPallets.has(row.id));
  }

  togglePalletSelection(row: any, checked: boolean): void {
    if (checked) {
      this.selectedPallets.set(row.id, row);
    } else {
      this.selectedPallets.delete(row.id);
    }
  }

  togglePageSelection(checked: boolean): void {
    this.selectablePageRows.forEach((row) => this.togglePalletSelection(row, checked));
  }

  //  Move To Bagging Button Event -- pallets that fail are skipped by the SP, the rest still move
  async moveSelectedToBagging(): Promise<void> {
    if (this.isMovingToBagging || this.selectedPallets.size === 0) return;

    if (this.selectedPallets.size > this.maxMoveToBagging) {
      this.SweetAlert('warning', `ย้ายได้ไม่เกิน ${this.maxMoveToBagging} พาเลทต่อครั้ง กรุณาเลือกใหม่`);
      return;
    }

    const rows = Array.from(this.selectedPallets.values());
    const confirm = await Swal.fire({
      icon: 'question',
      title: `ย้าย ${rows.length} พาเลทกลับ Bagging Area?`,
      text: rows.map((row) => row.palletNumber).join(', '),
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    });
    if (!confirm.isConfirmed) return;

    this.isMovingToBagging = true;

    this.restService
      .processMovePalletsToBagging(
        rows.map((row) => row.id),
        Number(this.jwtService.getUserId() ?? 0),
      )
      .subscribe({
        next: (response) => {
          this.isMovingToBagging = false;
          this.selectedPallets.clear();
          this.showMoveToBaggingResult(response.result);
          this.fetchProcessGetPalletList();
        },
        error: (error) => {
          this.isMovingToBagging = false;
          this.SweetAlert('error', error?.error?.message ?? 'ไม่สามารถย้ายพาเลทได้');
          console.log(error);
        },
      });
  }

  private showMoveToBaggingResult(result: any): void {
    const failed = (result?.items ?? [])
      .filter((item: any) => !item.is_success)
      .map((item: any) => `${item.pallet_no || item.pallet_id}: ${item.message}`);
    const summary = `สำเร็จ ${result?.success_count ?? 0}, ไม่สำเร็จ ${result?.failed_count ?? 0}`;

    this.SweetAlert(failed.length > 0 ? 'warning' : 'success', [summary, ...failed].join(' | '));
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = {
      palletNo: '',
      grade: '',
      lot: '',
      locationType: '',
      locationId: 0,
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };

    this.locationSearchText = '';
    this.locationSearchOptions = [];
    this.selectedPallets.clear();
  }

  //  Fetch Pallet List API
  async fetchProcessGetPalletList() {
    //  Pallet Number field also takes a scanned QR (contains "|") -> send as qrCode instead
    const palletInput = (this.filter.palletNo ?? '').trim();
    const isQrCode = palletInput.includes('|');

    this.isPalletListLoading = true;
    this.saveFilter();

    await this.restService
      .processGetPalletList(
        isQrCode ? '' : palletInput,
        this.filter.grade ?? '',
        this.filter.lot ?? '',
        this.filter.locationType ?? '',
        this.filter.locationId ?? 0,
        this.filter.page ?? 1,
        this.filter.pageSize ?? 25,
        isQrCode ? palletInput : '',
        this.filter.sortBy ?? '',
        this.filter.sortOrder ?? '',
      )
      .subscribe(
        (data) => {
          this.isPalletListLoading = false;
          try {
            if (data != undefined) {
              if (data.status === 'success') {
                this._ResponseProcessPalletListData = data;

                //  MAp Total Count
                this.totalCount = data.total_count;

                //  Map Pallet List Table Data
                this._palletListTableData = data.data.map((item: any, index: number) => ({
                  no: index + 1,
                  id: item.id,
                  palletNumber: item.pallet_no,
                  tonNo: item.ton_no ?? null,
                  grade: item.grade,
                  lot: item.lot,
                  palletType: item.pallet_type ?? '-',
                  qty: item.qty ?? 0,
                  //  Package ratio (kg per bag) / bags per pallet -- shown on pallet-information
                  unitRatio: item.unit_ratio ?? null,
                  unitPallet: item.unit_pallet ?? null,
                  locationType: item.location_type ?? '-',
                  //  NULL current_location_type = Bagging Area (same default as pProcessGetPalletList)
                  locationTypeCode: item.location_type_code ?? 'BG-PLANT',
                  palletLocation: item.current_location ?? '-',
                  createDateTime: item.create_datetime,
                  //  'N' = pallet not full yet (pProcessGetPalletList.is_full_pallet) -> orange bar on the row
                  isFullPallet: item.is_full_pallet !== 'N',
                  qtyStatus: this.getQtyStatus(item),
                  action: item.id,
                }));

                // console.log(this._palletListTableData);
              } else {
                this.SweetAlert('error', 'Message : ' + data.message);
              }
            }
          } catch (error) {
            console.log(error);
          }
        },
        (error) => {
          this.isPalletListLoading = false;
          this.SweetAlert('error', 'Message : Error see in log.');
          console.log(error);
        },
      );
  }

  //  Export Excel Button Event -- exports every pallet matching the current filter (not just
  //  the rows on the current page), fetched with the full result count as the page size.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;

    const palletInput = (this.filter.palletNo ?? '').trim();
    const isQrCode = palletInput.includes('|');

    try {
      const data = await new Promise<Type.ResponseProcessPalletListData>((resolve, reject) => {
        this.restService
          .processGetPalletList(
            isQrCode ? '' : palletInput,
            this.filter.grade ?? '',
            this.filter.lot ?? '',
            this.filter.locationType ?? '',
            this.filter.locationId ?? 0,
            1,
            this.totalCount,
            isQrCode ? palletInput : '',
            this.filter.sortBy ?? '',
            this.filter.sortOrder ?? '',
          )
          .subscribe({
            next: (response) => resolve(response),
            error: (error) => reject(error),
          });
      });

      const rows = (data.data || []).map((item: any, index: number) => ({
        '#': index + 1,
        'Pallet Number': item.pallet_no || '-',
        'Ton No.': item.ton_no ?? '-',
        'Grade': item.grade || '-',
        'Lot': item.lot || '-',
        'Pallet Type': item.pallet_type || '-',
        'QTY (kg)': item.qty ?? 0,
        'Location Type': item.location_type || '-',
        'Pallet Location': item.current_location || '-',
        'Created Date': item.create_datetime
          ? new Date(item.create_datetime).toLocaleString('th-TH')
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 18 },
        { wch: 8 },
        { wch: 12 },
        { wch: 12 },
        { wch: 14 },
        { wch: 12 },
        { wch: 16 },
        { wch: 18 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'Pallet List');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `pallet-list_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting pallet list to Excel:', error);
      this.SweetAlert('error', 'ไม่สามารถ Export ข้อมูลได้');
    } finally {
      this.isExportingExcel = false;
    }
  }

  fetchOptionLocationType(): Promise<Type.ResponseProcessGetOptionsLocationType> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetOptionsLocationType().subscribe(
        (response: Type.ResponseProcessGetOptionsLocationType) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching options:', error);
          reject(error);
        },
      );
    });
  }

  findLocation(
    locationType: string,
    locationName: string,
  ): Promise<Type.ResponseProcessFindLocation> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetFindLocation(locationType, locationName).subscribe(
        (response: Type.ResponseProcessFindLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching options:', error);
          reject(error);
        },
      );
    });
  }

  //  Location Autocomplete Input Event
  onLocationSearchInput(value: string) {
    this.locationSearchText = value;
    this.filter.locationId = 0;

    clearTimeout(this.locationSearchTimeout);

    if (!value) {
      this.locationSearchOptions = [];
      return;
    }

    this.locationSearchTimeout = setTimeout(async () => {
      try {
        const response = await this.findLocation(this.filter.locationType ?? '', value);
        this.locationSearchOptions = response?.data ?? [];
      } catch (error) {
        console.log(error);
      }
    }, 300);
  }

  //  Location Autocomplete Option Select Event
  onSelectLocation(locationName: string) {
    clearTimeout(this.locationSearchTimeout);

    const selected = this.locationSearchOptions.find(
      (option) => option.location_name === locationName,
    );

    this.filter.locationId = selected?.id ?? 0;
    this.locationSearchText = locationName;
  }

  //  The row is handed over as router state so pallet-information can show
  //  its header card without re-querying process/pallet.
  viewPalletInformation(row: any) {
    this.router.navigate(['/pallet-information', row.id], { state: { pallet: row } });
  }

  get totalPages(): number {
    return Math.max(1, Math.ceil(this.totalCount / (this.filter.pageSize ?? 10)));
  }

  get pageNumbers(): number[] {
    const total = this.totalPages;
    const current = this.filter.page ?? 1;
    const delta = 2;
    const range: number[] = [];
    for (let i = Math.max(1, current - delta); i <= Math.min(total, current + delta); i++) {
      range.push(i);
    }
    return range;
  }

  goToPage(page: number): void {
    if (page < 1 || page > this.totalPages) return;
    this.filter.page = page;
  }

  onPageSizeChange(): void {
    this.filter.page = 1;
  }

  // =====================================================================
  //  Dummy Pallet tab
  // =====================================================================
  readonly dummyDisplayedColumns: string[] = [
    'select',
    'no',
    'palletNumber',
    'grade',
    'lot',
    'qty',
    'bagCount',
    'locationType',
    'palletLocation',
    'createDateTime',
    'print',
    'clear',
  ];

  dummyFilter = { palletNo: '', locationType: '' };
  dummyPage = 1;
  dummyPageSize = 25;
  dummyTotalCount = 0;
  _dummyTableData: any[] = [];
  isDummyLoading = false;
  isCreatingDummy = false;
  isClearingDummy = false;

  //  Dummy pallets ticked for printing -- keyed by id, kept across pages
  selectedDummyPallets = new Map<number, any>();

  //  One card per page on the print-out (QR text = pallet_no; fQrCodeToPalletBag
  //  resolves a bare pallet_no when it's scanned)
  printDummyPallets: string[] = [];

  fetchDummyPalletList(): void {
    this.isDummyLoading = true;

    this.restService
      .processGetDummyPalletList(
        (this.dummyFilter.palletNo ?? '').trim(),
        this.dummyFilter.locationType ?? '',
        this.dummyPage,
        this.dummyPageSize,
      )
      .subscribe({
        next: (data) => {
          this.isDummyLoading = false;
          if (data?.status !== 'success') {
            this.SweetAlert('error', 'Message : ' + data?.message);
            return;
          }

          this.dummyTotalCount = data.total_count;
          this._dummyTableData = (data.data ?? []).map((item) => ({
            id: item.id,
            palletNumber: item.pallet_no,
            grade: item.grade ?? '',
            lot: item.lot ?? '',
            qty: item.qty ?? 0,
            //  Grade package ratio -- pallet-information shows it and recounts QTY with it
            //  (a dummy pallet has no tr_pallet.unit_ratio of its own)
            unitRatio: item.unit_ratio ?? null,
            palletType: 'Dummy',
            locationType: item.location_type ?? '-',
            locationTypeCode: item.location_type_code ?? 'BG-PLANT',
            palletLocation: item.current_location ?? '-',
            bagCount: item.bag_count ?? 0,
            createDateTime: item.create_datetime,
          }));
        },
        error: (error) => {
          this.isDummyLoading = false;
          this.SweetAlert('error', 'Message : Error see in log.');
          console.log(error);
        },
      });
  }

  onClickSearchDummy(): void {
    this.dummyPage = 1;
    this.fetchDummyPalletList();
  }

  resetDummyFilter(): void {
    this.dummyFilter = { palletNo: '', locationType: '' };
    this.selectedDummyPallets.clear();
  }

  onDummyPageEvent(event: PageEvent): void {
    this.dummyPage = event.pageIndex + 1;
    this.dummyPageSize = event.pageSize;
    this.fetchDummyPalletList();
  }

  get isAllDummyPageSelected(): boolean {
    return this._dummyTableData.length > 0 && this._dummyTableData.every((row) => this.selectedDummyPallets.has(row.id));
  }

  get isSomeDummyPageSelected(): boolean {
    return !this.isAllDummyPageSelected && this._dummyTableData.some((row) => this.selectedDummyPallets.has(row.id));
  }

  toggleDummySelection(row: any, checked: boolean): void {
    if (checked) {
      this.selectedDummyPallets.set(row.id, row);
    } else {
      this.selectedDummyPallets.delete(row.id);
    }
  }

  toggleDummyPageSelection(checked: boolean): void {
    this._dummyTableData.forEach((row) => this.toggleDummySelection(row, checked));
  }

  //  Create Dummy Pallet Button Event -- asks how many, then offers to print the new ones
  async createDummyPallets(): Promise<void> {
    if (this.isCreatingDummy) return;

    const input = await Swal.fire({
      icon: 'question',
      title: 'สร้าง Dummy Pallet',
      text: 'ระบุจำนวนพาเลทที่ต้องการสร้าง (1 - 100)',
      input: 'number',
      inputValue: 1,
      inputAttributes: { min: '1', max: '100', step: '1' },
      showCancelButton: true,
      confirmButtonText: 'สร้าง',
      cancelButtonText: 'ยกเลิก',
      inputValidator: (value) => {
        const qty = Number(value);
        return Number.isInteger(qty) && qty >= 1 && qty <= 100 ? null : 'กรุณาระบุจำนวน 1 - 100';
      },
    });
    if (!input.isConfirmed) return;

    this.isCreatingDummy = true;

    this.restService
      .processCreateDummyPallet(Number(input.value), Number(this.jwtService.getUserId() ?? 0))
      .subscribe({
        next: async (response) => {
          this.isCreatingDummy = false;
          this.dummyPage = 1;
          this.fetchDummyPalletList();

          const palletNos: string[] = (response.result?.items ?? []).map((item: any) => item.pallet_no);
          const printNow = await Swal.fire({
            icon: 'success',
            title: response.message,
            text: palletNos.join(', '),
            showCancelButton: this.permissionService.has('data.print_qr'),
            showConfirmButton: true,
            confirmButtonText: this.permissionService.has('data.print_qr') ? 'พิมพ์ QR Code' : 'ตกลง',
            cancelButtonText: 'ปิด',
          });
          if (printNow.isConfirmed && this.permissionService.has('data.print_qr')) {
            this.printDummy(palletNos);
          }
        },
        error: (error) => {
          this.isCreatingDummy = false;
          this.SweetAlert('error', error?.error?.message ?? 'ไม่สามารถสร้าง Dummy Pallet ได้');
          console.log(error);
        },
      });
  }

  //  Nothing to clear: no bags and already in Bagging Area
  canClearDummy(row: any): boolean {
    return row.bagCount > 0 || row.locationTypeCode !== 'BG-PLANT';
  }

  get selectedClearableDummy(): any[] {
    return Array.from(this.selectedDummyPallets.values()).filter((row) => this.canClearDummy(row));
  }

  //  Clear Dummy Pallet Button Event -- bags on the pallet are unlinked and deactivated
  //  (they've already been withdrawn), the pallet goes back to Bagging Area so it can take
  //  another Grade / Lot. Pallets that fail are skipped by the SP, the rest still clear.
  async clearDummyPallets(rows: any[]): Promise<void> {
    rows = rows.filter((row) => this.canClearDummy(row));
    if (this.isClearingDummy || rows.length === 0) return;

    if (rows.length > this.maxMoveToBagging) {
      this.SweetAlert('warning', `ล้างได้ไม่เกิน ${this.maxMoveToBagging} พาเลทต่อครั้ง กรุณาเลือกใหม่`);
      return;
    }

    const escape = (value: unknown) =>
      String(value ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
    const confirm = await Swal.fire({
      icon: 'warning',
      title: `ล้าง ${rows.length} Dummy Pallet?`,
      html:
        rows
          .map((row) => escape(row.palletNumber) + (row.bagCount > 0 ? ` (${row.bagCount} ถุง ${escape(row.grade)} / ${escape(row.lot)})` : ''))
          .join('<br>') + '<br><br>ถุงบนพาเลทจะถูกปลดออกและปิดใช้งาน พาเลทกลับ Bagging Area',
      showCancelButton: true,
      confirmButtonText: 'ล้างพาเลท',
      cancelButtonText: 'ยกเลิก',
    });
    if (!confirm.isConfirmed) return;

    this.isClearingDummy = true;

    this.restService
      .processClearDummyPallets(
        rows.map((row) => row.id),
        Number(this.jwtService.getUserId() ?? 0),
      )
      .subscribe({
        next: (response) => {
          this.isClearingDummy = false;
          rows.forEach((row) => this.selectedDummyPallets.delete(row.id));
          this.showMoveToBaggingResult(response.result);
          this.fetchDummyPalletList();
        },
        error: (error) => {
          this.isClearingDummy = false;
          this.SweetAlert('error', error?.error?.message ?? 'ไม่สามารถล้าง Dummy Pallet ได้');
          console.log(error);
        },
      });
  }

  printSelectedDummy(): void {
    const palletNos = Array.from(this.selectedDummyPallets.values()).map((row) => row.palletNumber);
    if (palletNos.length === 0) {
      this.SweetAlert('warning', 'Message : กรุณาเลือก Dummy Pallet ที่ต้องการพิมพ์');
      return;
    }
    this.printDummy(palletNos);
  }

  printDummy(palletNos: string[]): void {
    if (palletNos.length === 0) return;

    this.printDummyPallets = palletNos;
    this.changeDetectorRef.detectChanges();

    this.loadQRScript().then(() => {
      setTimeout(() => {
        this.printDummyPallets.forEach((palletNo, index) => {
          this.renderQrCode(`print-qr-dummy-${index}`, palletNo);
        });

        setTimeout(() => {
          this.openPrintArea(() => {
            this.printDummyPallets = [];
            this.changeDetectorRef.detectChanges();
          });
        }, 200);
      }, 50);
    });
  }

  private renderQrCode(elementId: string, value: string): void {
    const el = document.getElementById(elementId);
    if (!el) return;

    const multiply = 5.2;
    el.innerHTML = '';
    new (window as any)['QRCode'](el, {
      text: value,
      width: 35 * 3.78 * multiply,
      height: 35 * 3.78 * multiply,
      colorDark: '#000000',
      colorLight: '#ffffff',
    });
  }

  //  Same as location-management.openPrintArea: #print-area is moved under <body> for printing
  //  and put back on whichever end-of-print signal fires first.
  private openPrintArea(onAfterPrint: () => void): void {
    const printArea = document.getElementById('print-area');
    if (!printArea || !printArea.parentNode) return;

    const placeholder = document.createElement('div');
    placeholder.id = 'print-area-placeholder';
    printArea.parentNode.insertBefore(placeholder, printArea);
    document.body.appendChild(printArea);

    let cleaned = false;
    const cleanup = () => {
      if (cleaned) return;
      cleaned = true;

      window.removeEventListener('afterprint', cleanup);
      mediaQueryList.removeEventListener('change', onMediaChange);
      clearTimeout(fallbackTimer);

      const printAreaElement = document.getElementById('print-area');
      const placeholderElement = document.getElementById('print-area-placeholder');

      if (printAreaElement && placeholderElement && placeholderElement.parentNode) {
        placeholderElement.parentNode.insertBefore(printAreaElement, placeholderElement);
        placeholderElement.remove();
      }

      onAfterPrint();
    };

    const mediaQueryList = window.matchMedia('print');
    const onMediaChange = (mql: MediaQueryListEvent) => {
      if (!mql.matches) cleanup();
    };
    mediaQueryList.addEventListener('change', onMediaChange);

    const fallbackTimer = setTimeout(cleanup, 10000);

    window.print();
    window.addEventListener('afterprint', cleanup, { once: true });
  }

  //  Print plate text is a fixed 13-char PLD number, but keep the same shrink rule as
  //  location-management so a long number never overflows the plate.
  getPlateFontSize(text: string | null | undefined): number {
    const length = (text || '').length;
    if (length <= 8) return 150;
    if (length <= 12) return 110;
    if (length <= 16) return 85;
    if (length <= 20) return 65;
    return 50;
  }

  private loadQRScript(): Promise<void> {
    return new Promise((resolve) => {
      if ((window as any)['QRCode']) {
        resolve();
        return;
      }
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js';
      s.onload = () => resolve();
      document.head.appendChild(s);
    });
  }

  //  mat-paginator Event
  //  สี QTY : ครบตาม unit_ratio x unit_pallet = เขียว ; ไม่ครบใช้สีสถานะเดียวกับหน้า Pallet Adjustment
  //  (pallet_status_id 3 = พาเลทเศษยืนยันแล้ว , อื่น ๆ = กำลังดำเนินการ)
  getQtyStatus(item: any): 'complete' | 'confirmed' | 'wh_process' {
    const target = (item.unit_ratio ?? 0) * (item.unit_pallet ?? 0);
    if (target > 0 && (item.qty ?? 0) >= target) return 'complete';
    return item.pallet_status_id === 3 ? 'confirmed' : 'wh_process';
  }

  readonly qtyStatusLabels: Record<string, string> = {
    complete: 'ครบตาม Pallet Ratio',
    confirmed: 'พาเลทเศษ (ยืนยันแล้ว)',
    wh_process: 'กำลังดำเนินการ',
  };

  //  Header sort, done by the API across all pages (pProcessGetPalletList @sort_by):
  //  click = ascending -> descending -> back to the default order.
  onSortColumn(column: string): void {
    if (this.filter.sortBy !== column) {
      this.filter.sortBy = column;
      this.filter.sortOrder = 'asc';
    } else if (this.filter.sortOrder === 'asc') {
      this.filter.sortOrder = 'desc';
    } else {
      this.filter.sortBy = '';
      this.filter.sortOrder = '';
    }
    this.filter.page = 1;
    this.fetchProcessGetPalletList();
  }

  sortIcon(column: string): string {
    if (this.filter.sortBy !== column) return 'unfold_more';
    return this.filter.sortOrder === 'desc' ? 'arrow_downward' : 'arrow_upward';
  }

  ariaSort(column: string): string {
    if (this.filter.sortBy !== column) return 'none';
    return this.filter.sortOrder === 'desc' ? 'descending' : 'ascending';
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;

    this.fetchProcessGetPalletList();
  }

  //  Sweet Alert
  SweetAlert(iconn: any, alert_message: string) {
    Swal.fire({
      position: 'center',
      icon: iconn,
      title: 'ข้อความจากระบบ',
      text: alert_message,
      showConfirmButton: true,
    });
  }
}
