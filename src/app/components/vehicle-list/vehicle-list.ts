import { ChangeDetectorRef, Component, OnDestroy, ViewChild } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';
import { MatAutocompleteTrigger } from '@angular/material/autocomplete';
import * as XLSX from 'xlsx';

type VehicleListRow = Type.ResultProcessGetVehicle;

@Component({
  selector: 'app-vehicle-list',
  standalone: false,
  templateUrl: './vehicle-list.html',
  styleUrl: './vehicle-list.css',
})
export class VehicleList implements OnDestroy {

  //  Constructor
  constructor(
    private crudService: CrudService,
    private changeDetectorRef: ChangeDetectorRef,
  ) { }

  @ViewChild(MatAutocompleteTrigger) carrierNameAutocompleteTrigger?: MatAutocompleteTrigger;

  //  Define Column
  displayedColumns: string[] = [
    'select',
    'no',
    'licensePlate',
    'vehicleName',
    'vehicleType',
    'vehicleGroup',
    'carrierName',
    'rfid',
    'status',
    'createdDate',
    'action'
  ];


  vehicleList: VehicleListRow[] = [];
  totalCount: number = 0;

  //  Skeleton loading -- table shows shimmer rows while the vehicle list loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  //  Filter Form
  filter: Type.VehicleFilter = {
    licensePlate: '',
    carrierName: '',
    vehicleType: '',
    isActive: '',
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  printVehicleData: VehicleListRow | null = null;
  printSelectedVehicleData: VehicleListRow[] = [];
  printMode: 'single' | 'multiple' | null = null;

  //  Selected vehicles, keyed by a composite of fields rather than a flag on the row
  //  objects -- vehicleList is replaced wholesale on every page load, so a per-row
  //  flag can't survive pagination. The API's vehicle rows carry no id field at all
  //  (ResultProcessGetVehicle.vehicle_id is never actually populated by the backend),
  //  and license_plate alone isn't unique either (repeat plates across carriers), so
  //  license_plate + carrier_code + created_date is the key -- confirmed unique
  //  against production data. Keeping the full row here (not just the key) lets
  //  Print Selected work on vehicles picked from pages that aren't currently loaded.
  private selectedVehicles = new Map<string, VehicleListRow>();
  isSelectingAllPages = false;
  isExportingExcel = false;

  private vehicleKey(vehicle: VehicleListRow): string {
    return `${vehicle.license_plate}|${vehicle.carrier_code}|${vehicle.created_date}`;
  }

  get selectedVehicleCount(): number {
    return this.selectedVehicles.size;
  }

  optionVehicleType: Type.ResultProcessGetOptionsVehicleType[] = [];

  //  Carrier Name Autocomplete -- there's no dedicated carrier-options endpoint
  //  (unlike vehicle type), so suggestions are the distinct carrier names seen
  //  across every vehicle, fetched once up front and filtered client-side as the
  //  user types.
  private carrierNameOptions: string[] = [];
  filteredCarrierNameOptions: string[] = [];

  //  ngOnInit
  async ngOnInit() {
    await this.loadVehicleList();

    this.optionVehicleType = (await this.fetchOptionVehicleType()).data;

    this.loadCarrierNameOptions();
  }

  private async loadCarrierNameOptions() {
    try {
      const result = await this.fetchVehicleList({ page: 1, pageSize: this.totalCount || 1000 });
      const uniqueNames = new Set(
        result.data.map((vehicle) => vehicle.carrier_name?.trim()).filter((name): name is string => !!name),
      );
      this.carrierNameOptions = Array.from(uniqueNames).sort((a, b) => a.localeCompare(b, 'th'));
      this.filteredCarrierNameOptions = this.carrierNameOptions;
    } catch (error) {
      console.error('Error fetching carrier name options:', error);
    }
  }

  //  Carrier Name Autocomplete Input Event
  onCarrierNameInput(value: string): void {
    this.filter.carrierName = value;

    const search = value.trim().toLowerCase();
    this.filteredCarrierNameOptions = search
      ? this.carrierNameOptions.filter((name) => name.toLowerCase().includes(search))
      : this.carrierNameOptions;
  }

  //  Load Vehicle List
  async loadVehicleList() {
    this.isLoading = true;
    try {
      const result = await this.fetchVehicleList(this.filter);
      this.vehicleList = result.data;
      this.totalCount = result.total_count;
    } finally {
      this.isLoading = false;
    }
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;
    this.clearSelectedVehicles();
    this.loadVehicleList();
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = {
      licensePlate: '',
      carrierName: '',
      vehicleType: '',
      isActive: '',
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };
    this.filteredCarrierNameOptions = this.carrierNameOptions;
    this.carrierNameAutocompleteTrigger?.closePanel();

    this.clearSelectedVehicles();
    this.loadVehicleList();
  }

  //  Fetch Vechicle List
  fetchVehicleList(filter: Type.VehicleFilter): Promise<Type.ResponseProcessGetVehicle> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetVehicle(filter).subscribe(
        (response: Type.ResponseProcessGetVehicle) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching vehicle list:', error);
          reject(error);
        },
      );
    });
  }

  //  Fetch Vehicle Type
  fetchOptionVehicleType(): Promise<Type.ResponseProcessGetOptionsVehicleType> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetOptionsVehicleType().subscribe(
        (response: Type.ResponseProcessGetOptionsVehicleType) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching options:', error);
          reject(error);
        },
      );
    });
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
    this.loadVehicleList();
  }

  onPageSizeChange(): void {
    this.filter.page = 1;
    this.loadVehicleList();
  }

  isVehicleSelected(vehicle: VehicleListRow): boolean {
    return this.selectedVehicles.has(this.vehicleKey(vehicle));
  }

  toggleVehicleSelection(vehicle: VehicleListRow, checked: boolean): void {
    if (checked) {
      this.selectedVehicles.set(this.vehicleKey(vehicle), vehicle);
    } else {
      this.selectedVehicles.delete(this.vehicleKey(vehicle));
    }
  }

  //  Selects the rows on the current page only, so one Print Selected prints at most
  //  pageSize cards (same rule as user-list / forklift-management). The selection is
  //  cleared whenever the list reloads (search, paging, page-size change).
  toggleSelectAllCurrentPage(checked: boolean): void {
    this.selectedVehicles.clear();
    if (checked) {
      this.vehicleList.forEach((vehicle) => this.selectedVehicles.set(this.vehicleKey(vehicle), vehicle));
    }
    this.changeDetectorRef.detectChanges();
  }

  isAllCurrentPageSelected(): boolean {
    return this.vehicleList.length > 0 && this.vehicleList.every((vehicle) => this.isVehicleSelected(vehicle));
  }

  isSomeCurrentPageSelected(): boolean {
    return this.vehicleList.some((vehicle) => this.isVehicleSelected(vehicle)) && !this.isAllCurrentPageSelected();
  }

  clearSelectedVehicles(): void {
    this.selectedVehicles.clear();
    this.changeDetectorRef.detectChanges();
  }

  //  Export Excel Button Event -- exports every vehicle matching the current
  //  filter (not just the rows on the current page), matching the same
  //  "fetch with the full result count as page size" approach used by
  //  toggleSelectAllCurrentPage.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;
    this.changeDetectorRef.detectChanges();

    try {
      const result = await this.fetchVehicleList({
        ...this.filter,
        page: 1,
        pageSize: this.totalCount,
      });

      const rows = result.data.map((vehicle, index) => ({
        '#': index + 1,
        'ทะเบียนรถ': vehicle.license_plate || '-',
        'ชื่อรถ': vehicle.vehicle_text || '-',
        'ประเภทรถ': vehicle.vehicle_type_desc || '-',
        'กลุ่มรถ': vehicle.vehicle_group_desc || '-',
        'ชื่อผู้ขนส่ง': vehicle.carrier_name || '-',
        'RFID': vehicle.rfid_card || '-',
        'สถานะ': vehicle.is_active === 'X' ? 'ใช้งาน' : 'ไม่ใช้งาน',
        'วันที่สร้าง': vehicle.created_date
          ? new Date(vehicle.created_date).toLocaleString('th-TH')
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 16 },
        { wch: 20 },
        { wch: 18 },
        { wch: 18 },
        { wch: 24 },
        { wch: 16 },
        { wch: 12 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'Vehicle List');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `vehicle-list_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting vehicle list to Excel:', error);
    } finally {
      this.isExportingExcel = false;
      this.changeDetectorRef.detectChanges();
    }
  }

  printSelectedVehicles(): void {
    const selectedVehicles = Array.from(this.selectedVehicles.values());

    if (selectedVehicles.length === 0) {
      return;
    }

    this.resetPrintState();
    this.printSelectedVehicleData = selectedVehicles;
    this.printMode = 'multiple';
    this.changeDetectorRef.detectChanges();

    this.loadQRScript().then(() => {
      const elementIds = this.printSelectedVehicleData.map((_, index) => `print-qr-selected-${index}`);

      this.waitForPrintElements(elementIds).then(() => {
        elementIds.forEach((elementId, index) => {
          this.renderQrCode(elementId, this.buildQrText(this.printSelectedVehicleData[index]));
        });

        this.waitForQrRender(elementIds).then(() => {
          this.openPrintArea(() => {
            this.resetPrintState();
          });
        });
      });
    });
  }

  //  Print Truck QR Code Event
  printVehicle(v: VehicleListRow): void {
    this.resetPrintState();
    this.printVehicleData = v;
    this.printMode = 'single';
    this.changeDetectorRef.detectChanges();
    this.loadQRScript().then(() => {
      this.waitForPrintElements(['print-qr']).then(() => {
        this.renderQrCode('print-qr', this.buildQrText(v));

        this.waitForQrRender(['print-qr']).then(() => {
          this.openPrintArea(() => {
            this.resetPrintState();
          });
        });
      });
    });
  }

  //  Load QR Script
  //
  //  This used to load qrcodejs@1.0.0 from a CDN, but that library's
  //  auto type-number selection (_getTypeNumber) estimates capacity from a
  //  hardcoded character-count table instead of the real encoded bit
  //  length, and undercounts multi-byte UTF-8 text (Thai carrier
  //  names/plates) -- so it repeatedly threw "code length overflow" even
  //  at the highest error-correction level, for text nowhere near any
  //  real QR capacity limit. kazuhikoarase/qrcode-generator's `make()`
  //  instead grows the type number by actually measuring the encoded
  //  buffer against each type's real capacity, so it can't hit that same
  //  mismatch. Vendored locally (src/assets/vendor/qrcode-generator)
  //  rather than pulled from a CDN, since its own dist bundle doesn't
  //  expose a documented CDN path the way qrcodejs's did.
  private loadQRScript(): Promise<void> {
    return new Promise((resolve) => {
      if ((window as any)['qrcode']) {
        resolve();
        return;
      }
      const base = document.createElement('script');
      base.src = 'assets/vendor/qrcode-generator/qrcode.js';
      base.onload = () => {
        //  Adds UTF-8 byte counting (qrcode.stringToBytes) on top of the
        //  base script's default -- must load after it, since it patches
        //  the global `qrcode` the base script just created.
        const utf8 = document.createElement('script');
        utf8.src = 'assets/vendor/qrcode-generator/qrcode_UTF8.js';
        utf8.onload = () => resolve();
        document.head.appendChild(utf8);
      };
      document.head.appendChild(base);
    });
  }

  private buildQrText(vehicle: VehicleListRow): string {
    return `${vehicle.carrier_code ?? ''}|${vehicle.license_plate ?? ''}`;
  }

  private renderQrCode(elementId: string, value: string): void {
    const el = document.getElementById(elementId);
    if (!el) return;

    //  Sized in mm-ish units (35mm * ~3.78px/mm * multiply). cellSize is
    //  derived below so the rendered image still comes out at this target
    //  size regardless of which module count the auto-selected type
    //  number ends up needing.
    //  5.6 is close to the safe ceiling for this card layout: header +
    //  footer (both trimmed further, along with .pcard__body's own
    //  padding, to make room here) + this QR (+ its own margin) needs to
    //  stay within .pcard's 95%-of-page height (~1067px on an A4 page
    //  with the @page margin already zeroed out) to avoid spilling onto a
    //  second, mostly-blank page the way the original (much larger) size
    //  did before that was fixed.
    const multiply = 7;
    const targetPx = 35 * 3.78 * multiply;

    el.innerHTML = '';
    const qrcodeFactory = (window as any)['qrcode'];
    //  typeNumber 0 = auto-select the smallest type the data actually
    //  fits in; 'L' (7% error correction) is plenty for a printed label
    //  and keeps that auto-selected type as small as possible.
    const qr = qrcodeFactory(0, 'L');
    qr.addData(value);
    qr.make();

    //  Drawn onto a <canvas> directly (via getModuleCount/isDark) instead
    //  of using the library's own createImgTag/createDataURL -- those
    //  build a hand-rolled GIF encoded into a data: URI, which came back
    //  as a broken image (blank box) in this app's actual print preview.
    //  Canvas is a plain, universally-supported render path with no
    //  intermediate image format to go wrong. Margin matches
    //  createImgTag's own default (cellSize * 4 per side) so the sizing
    //  math -- and the printed result -- stays the same as before.
    const moduleCount = qr.getModuleCount();
    const cellSize = Math.max(1, Math.round(targetPx / (moduleCount + 8)));
    const marginPx = cellSize * 2;
    const canvasSize = moduleCount * cellSize + marginPx * 2;

    const canvas = document.createElement('canvas');
    canvas.width = canvasSize;
    canvas.height = canvasSize;
    const ctx = canvas.getContext('2d');
    if (ctx) {
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, canvasSize, canvasSize);
      ctx.fillStyle = '#000000';
      for (let row = 0; row < moduleCount; row++) {
        for (let col = 0; col < moduleCount; col++) {
          if (qr.isDark(row, col)) {
            ctx.fillRect(marginPx + col * cellSize, marginPx + row * cellSize, cellSize, cellSize);
          }
        }
      }
    }
    el.appendChild(canvas);
  }

  //  If the user navigates away mid-print (before 'afterprint' fires), the
  //  print-area div is still sitting outside its normal spot as a direct
  //  child of <body> -- restore it here so this page's own card never
  //  becomes the next orphan that leaks into someone else's print job.
  ngOnDestroy(): void {
    this.restorePrintAreaToOrigin();
  }

  private resetPrintState(): void {
    this.printVehicleData = null;
    this.printSelectedVehicleData = [];
    this.printMode = null;
    this.changeDetectorRef.detectChanges();
  }

  //  location-management and pallet-management reuse the same #print-area
  //  id and the same body-appendChild-then-afterprint-restore trick (see
  //  `body > *:not(#print-area)` in src/styles.css, which relies on there
  //  being exactly one #print-area at a time). If a print on one of those
  //  pages was interrupted before 'afterprint' fired -- dialog cancelled,
  //  tab closed, user navigated away -- that page's #print-area is left
  //  stranded as a direct child of <body> forever. Since CSS id selectors
  //  match every matching element (unlike getElementById, which only
  //  returns the first), the stray card stays visible and prints alongside
  //  this one. Strip any such leftovers before printing our own.
  private removeStrayPrintAreas(current: HTMLElement): void {
    document.querySelectorAll('#print-area').forEach((el) => {
      if (el !== current && el.parentElement === document.body) {
        el.remove();
      }
    });
  }

  private openPrintArea(onAfterPrint: () => void): void {
    const printArea = document.getElementById('print-area');
    if (!printArea || !printArea.parentNode) return;

    this.removeStrayPrintAreas(printArea);
    this.restorePrintAreaToOrigin();

    const placeholder = document.createElement('div');
    placeholder.id = 'print-area-placeholder';
    printArea.parentNode.insertBefore(placeholder, printArea);
    document.body.appendChild(printArea);

    let isCleanedUp = false;
    const cleanup = () => {
      if (isCleanedUp) return;
      isCleanedUp = true;

      this.restorePrintAreaToOrigin();
      onAfterPrint();
    };

    window.addEventListener(
      'afterprint',
      cleanup,
      { once: true },
    );

    //  NOT followed by an immediate cleanup() call -- that used to run
    //  right here, synchronously, straight after window.print(). Chrome
    //  happens to block script execution while its print dialog is open,
    //  so a single small card got away with it, but that's not a
    //  guarantee -- and printing several selected vehicles' cards takes
    //  visibly longer to lay out, wide enough a window for cleanup() to
    //  fire and yank #print-area back out of <body> (hiding it again)
    //  before the browser had actually captured it for printing, coming
    //  out blank. Left to only the 'afterprint' listener, cleanup now
    //  always runs after the browser is actually done with the content.
    window.print();
  }

  private restorePrintAreaToOrigin(): void {
    const printArea = document.getElementById('print-area');
    const placeholder = document.getElementById('print-area-placeholder');

    if (printArea && placeholder && placeholder.parentNode) {
      placeholder.parentNode.insertBefore(printArea, placeholder);
      placeholder.remove();
    }
  }

  private waitForPrintElements(elementIds: string[]): Promise<void> {
    return this.waitForCondition(() =>
      elementIds.every((elementId) => document.getElementById(elementId)),
    );
  }

  private waitForQrRender(elementIds: string[]): Promise<void> {
    return this.waitForCondition(() =>
      elementIds.every((elementId) => {
        const element = document.getElementById(elementId);
        return element != null && element.childElementCount > 0;
      }),
    );
  }

  private waitForCondition(condition: () => boolean, attempts = 20, delayMs = 50): Promise<void> {
    return new Promise((resolve) => {
      const runCheck = (remainingAttempts: number) => {
        if (condition() || remainingAttempts <= 0) {
          resolve();
          return;
        }

        setTimeout(() => runCheck(remainingAttempts - 1), delayMs);
      };

      runCheck(attempts);
    });
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.clearSelectedVehicles();

    //  Call Load Vehicle
    this.loadVehicleList(); 
  }
}
