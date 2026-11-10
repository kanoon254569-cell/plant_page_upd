import { Component, ElementRef, OnDestroy, ViewChild } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';
import Swal from 'sweetalert2';
import { Router } from '@angular/router';
import * as XLSX from 'xlsx';
import * as QRCode from 'qrcode';

@Component({
  selector: 'app-forklift-management',
  standalone: false,
  templateUrl: './forklift-management.html',
  styleUrl: './forklift-management.css',
})
export class ForkliftManagement implements OnDestroy {
  //  Direct handle to this instance's own #print-forklift-area node - see
  //  user-list.ts's printUserAreaRef for why this is looked up via ViewChild
  //  rather than document.getElementById (so cleanupOrphanedPrintAreas below
  //  can tell this instance's node apart from an orphaned one left by a
  //  previous instance).
  @ViewChild('printForkliftArea', { static: true }) printForkliftAreaRef!: ElementRef<HTMLDivElement>;
  //  Constructor
  constructor(
    private crudService: CrudService,
    private restService: CrudService,
    private router: Router,
  ) {}

  //  Define Colunm
  displayedColumns: string[] = [
    'select',
    'no',
    'forkliftName',
    'warehouse',
    'section',
    'status',
    'lastForkliftUsed',
    'lastEditForklift',
    'print',
    'edit',
    'delete',
  ];

  _forkliftListTableData: any = [];
  totalCount: number = 0;
  showAddModal = false;
  showEditModal = false;
  isExportingExcel = false;

  //  Skeleton loading -- table shows shimmer rows while the forklift list loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  //  Filter Form
  filter: Type.ForkliftFilter = {
    licensePlate: '',
    forkliftName: '',
    whCodes: [],
    sectionIds: [],
    isActive: '',
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  //  Add Bag Form
  addForkliftForm: any = {
    forkliftName: '',
    licensePlate: '',
    whCodes: [] as string[],
    sections: [] as string[],
    isActive: 'Y',
    remark: '',
    userId: 0,
  };

  optionWarehouse : Type.ResultProcessGetOptionsWh[] = [];

  //  Forklift section (ct_forklift.section_id, stored comma-separated e.g. '1,3')
  readonly optionSection: { id: string; name: string }[] = [
    { id: '1', name: 'Warehouse' },
    { id: '2', name: 'Loading' },
    { id: '3', name: 'Pallet' },
  ];

  //  '1,3' -> ['1', '3'] (unknown ids dropped)
  private parseSections(value: string | null | undefined): string[] {
    const ids = (value ?? '').split(',').map((s) => s.trim());
    return this.optionSection.map((opt) => opt.id).filter((id) => ids.includes(id));
  }

  //  '1,3' -> 'Warehouse, Pallet'
  sectionNames(value: string | null | undefined): string {
    return this.sectionNameList(value).join(', ');
  }

  //  '1,3' -> ['Warehouse', 'Pallet'] -- one chip per section in the table
  sectionNameList(value: string | null | undefined): string[] {
    const ids = this.parseSections(value);
    return this.optionSection.filter((opt) => ids.includes(opt.id)).map((opt) => opt.name);
  }

  //  'WH41, WH42' -> ['WH41', 'WH42'] -- one chip per warehouse in the table
  warehouseList(value: string | null | undefined): string[] {
    return (value ?? '').split(',').map((s) => s.trim()).filter((s) => s && s !== '-');
  }

  //  Label shown on the collapsed Section filter, e.g. "Warehouse, Pallet"
  sectionFilterTriggerText(): string {
    return this.sectionNames((this.filter.sectionIds ?? []).join(','));
  }

  //  Label shown on the collapsed multi-select filter, e.g. "Warehouse A, Warehouse B"
  warehouseFilterTriggerText(): string {
    const codes = this.filter.whCodes ?? [];
    return this.optionWarehouse
      .filter((opt) => codes.includes(opt.wh_code))
      .map((opt) => opt.wh_name)
      .join(', ');
  }

  //  Warehouse dropdown options for the Add Forklift modal, derived from the warehouse codes
  //  already seen in the loaded forklift list (no separate warehouse-options endpoint exists here).
  get warehouseOptions(): string[] {
    const codes = new Set<string>();
    (this._forkliftListTableData || []).forEach((item: any) => {
      if (item.warehouse) codes.add(item.warehouse);
    });
    return Array.from(codes);
  }

  isEditMode: boolean = false;

  _selectedEditItem: any = {
    id: null,
    forkliftName: '',
    licensePlate: '',
    whCodes: [] as string[],
    sections: [] as string[],
    isActive: 'Y',
    remark: '',
  };

  page = 1;
  pageSize = 25;

  printVehicleData: Type.ResultProcessGetVehicle | null = null;
  optionVehicleType: Type.ResultProcessGetOptionsVehicleType[] = [];

  printForkliftData: any = null;

  //  API
  _ResponseProcessForkliftListData!: Type.ResponseProcessForkliftListData;

  //  onOnInit
  async ngOnInit() {
    this.cleanupOrphanedPrintAreas();
    this.fetchProcessGetForklifttList(this.filter);
    this.fetchOptionWarehouse();

    // this.optionVehicleType = (await this.fetchOptionVehicleType()).data;
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;

    this.fetchProcessGetForklifttList(this.filter);
  }

  openAddModal() {
    this.resetAddForkliftForm();
    this.showAddModal = true;
  }
  closeAddModal() {
    this.showAddModal = false;
  }
  openEditModal(element: any) {
    this.onClickEdit(element);
    this.showEditModal = true;
  }
  closeEditModal() {
    this.showEditModal = false;
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = {
      licensePlate: '',
      forkliftName: '',
      whCodes: [],
      sectionIds: [],
      isActive: '',
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };

    this.fetchProcessGetForklifttList(this.filter);
  }

  //  Fetch Pallet List API
  async fetchProcessGetForklifttList(filter: Type.ForkliftFilter) {
    this.isLoading = true;

    await this.restService.processGetForkliftList(
      filter.forkliftName ?? '',
      filter.licensePlate ?? '',
      (filter.whCodes ?? []).join(','),
      filter.isActive ?? '',
      filter.page ?? 1,
      filter.pageSize ?? 25,
      filter.sortBy ?? '',
      filter.sortOrder ?? '',
      (filter.sectionIds ?? []).join(','),
    ).subscribe(
      (data) => {
        this.isLoading = false;
        try {
          if (data != undefined) {
            if (data.status === 'success') {
              this._ResponseProcessForkliftListData = data;

              console.log(this._ResponseProcessForkliftListData);

              //  MAp Total Count
              this.totalCount = data.total_count;
              this.selectedForkliftIds = new Set();

              //  Map Pallet List Table Data
              this._forkliftListTableData = data.data.map((item: any, index: number) => ({
                no: ((filter.page ?? 1) - 1) * (filter.pageSize ?? 25) + index + 1,
                id: item.id,
                forkliftName: item.forklift_name,
                licensePlate: item.license_plate,
                warehouse: item.warehouse_code,
                wmsName: item.wms_name ?? '-',
                sectionId: item.section_id ?? '',
                status: item.forklift_statu ?? '-',
                statusActive: item.status_active ?? 'N',
                remark: item.remark ?? '',
                qty: item.qty ?? 0,
                lastForkliftUsed: item.lasted_used_datetime ?? '-',
                lastEditForklift: item.updated_datetime,
                edit: item.id,
                delete: item.id,
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
        this.isLoading = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      },
    );
  }

  //  Export Excel Button Event -- exports every forklift matching the current
  //  filter (not just the rows on the current page), fetched with the full
  //  result count as the page size.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;

    try {
      const data = await new Promise<Type.ResponseProcessForkliftListData>((resolve, reject) => {
        this.restService
          .processGetForkliftList(
            this.filter.forkliftName ?? '',
            this.filter.licensePlate ?? '',
            (this.filter.whCodes ?? []).join(','),
            this.filter.isActive ?? '',
            1,
            this.totalCount,
            this.filter.sortBy ?? '',
            this.filter.sortOrder ?? '',
            (this.filter.sectionIds ?? []).join(','),
          )
          .subscribe({
            next: (response) => resolve(response),
            error: (error) => reject(error),
          });
      });

      const rows = (data.data || []).map((item: any, index: number) => ({
        '#': index + 1,
        'ชื่อ Forklift': item.forklift_name || '-',
        'Warehouse': item.wms_name || item.warehouse_code || '-',
        'Section': this.sectionNames(item.section_id) || '-',
        'สถานะ': item.status_active === 'Y' ? 'ใช้งาน' : 'ไม่ใช้งาน',
        'วันที่ใช้งานล่าสุด': item.lasted_used_datetime
          ? new Date(item.lasted_used_datetime).toLocaleString('th-TH')
          : '-',
        'วันที่แก้ไขล่าสุด': item.updated_datetime
          ? new Date(item.updated_datetime).toLocaleString('th-TH')
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 20 },
        { wch: 18 },
        { wch: 24 },
        { wch: 12 },
        { wch: 20 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'Forklift List');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `forklift-list_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting forklift list to Excel:', error);
      this.SweetAlert('error', 'ไม่สามารถ Export ข้อมูลได้');
    } finally {
      this.isExportingExcel = false;
    }
  }

  viewPalletInformation(row: any) {
    this.router.navigate(['/pallet-information', row.id]);
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

  resetAddForkliftForm(): void {
    this.addForkliftForm = {
      forkliftName: '',
      licensePlate: '',
      whCodes: [],
      sections: [],
      isActive: 'Y',
      remark: '',
    };
  }

  async onSubmitAddForklift() {
    const payload = {
      forkliftName: this.addForkliftForm.forkliftName,
      licensePlate: this.addForkliftForm.licensePlate,
      whCode: (this.addForkliftForm.whCodes ?? []).join(','),
      sectionId: this.sortSections(this.addForkliftForm.sections).join(','),
      isActive: this.addForkliftForm.isActive,
      remark: (this.addForkliftForm.remark ?? '').trim(),
      userId: 0,
    };

    await this.restService.processInsertForklift(payload).subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.SweetAlert('success', 'เพิ่มถุงสำเร็จ');

          this.closeAddModal();

          this.resetAddForkliftForm();

          this.fetchProcessGetForklifttList(this.filter);
        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      },
    );
  }

  //  Edit Bag Button Event (เซ็ตข้อมูล ไม่เปิด modal เอง — HTML เปิดผ่าน data-bs-toggle)
  onClickEdit(element: any) {
    this.isEditMode = true;

    this._selectedEditItem = {
      id: element.edit,
      forkliftName: element.forkliftName,
      licensePlate: element.licensePlate,
      whCodes: this.resolveWhCodes(element.wmsName, element.warehouse),
      sections: this.parseSections(element.sectionId),
      isActive: element.statusActive ?? 'Y',
      remark: element.remark ?? '',
    };
  }

  //  Save Change Edit Button Event
  onClickSave() {
    const dataRequest = {
      forkliftName: this._selectedEditItem.forkliftName,
      licensePlate: this._selectedEditItem.licensePlate,
      whCode: (this._selectedEditItem.whCodes ?? []).join(','),
      sectionId: this.sortSections(this._selectedEditItem.sections).join(','),
      isActive: this._selectedEditItem.isActive,
      remark: (this._selectedEditItem.remark ?? '').trim(),
      userId: 0,
    };

    this.restService.processUpdateForklift(this._selectedEditItem.id, dataRequest).subscribe(
      (data) => {
        if (data.status === 'success') {
          this.SweetAlert('success', 'บันทึกข้อมูลสำเร็จ');

          this.closeEditModal();

          this.isEditMode = false;
          this.fetchProcessGetForklifttList(this.filter);
        } else {
          this.SweetAlert('error', 'Message : ' + data.message);
        }
      },
      (error) => {
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      },
    );
  }

  //  Pre-select the Edit modal's warehouses. A forklift's warehouses are stored
  //  comma-separated; each wms_name entry may hold either the code or the
  //  display name, so match it against both wh_code and wh_name. Falls back to
  //  the warehouse_code list (ct_storage.storage_name from pProcessGetForkliftList)
  //  when nothing in wms_name matches an option.
  private resolveWhCodes(wmsName: string | null | undefined, warehouseCode: string | null | undefined): string[] {
    const split = (value: string | null | undefined) =>
      (value ?? '').split(',').map((s) => s.trim()).filter((s) => s && s !== '-');

    const match = (tokens: string[]) =>
      tokens
        .map((token) => this.optionWarehouse.find((opt) => opt.wh_code === token || opt.wh_name === token)?.wh_code)
        .filter((code): code is string => !!code);

    const matched = match(split(wmsName));
    return Array.from(new Set(matched.length > 0 ? matched : match(split(warehouseCode))));
  }

  //  Checkbox toggle for the Add/Edit modal warehouse lists
  toggleWhCode(list: string[], code: string, checked: boolean): void {
    const index = list.indexOf(code);
    if (checked && index === -1) list.push(code);
    if (!checked && index !== -1) list.splice(index, 1);
  }

  //  Keep section ids in 1,2,3 order regardless of click order
  private sortSections(list: string[] | null | undefined): string[] {
    return this.optionSection.map((opt) => opt.id).filter((id) => (list ?? []).includes(id));
  }

  //  "เลือกทั้งหมด" checkbox state - true when every warehouse option is selected
  isAllWhSelected(list: string[]): boolean {
    return this.optionWarehouse.length > 0 && this.optionWarehouse.every((opt) => list.includes(opt.wh_code));
  }

  //  "เลือกทั้งหมด" toggle - mutates the list in place so the bound form keeps its reference
  toggleAllWh(list: string[], checked: boolean): void {
    list.splice(0, list.length, ...(checked ? this.optionWarehouse.map((opt) => opt.wh_code) : []));
  }

  fetchOptionWarehouse() {
    this.restService.ProcessGetOptionsLocationWh('ALL').subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.optionWarehouse = data.data || [];
        }
      },
      (error) => {
        console.error('Error fetching warehouse options:', error);
      },
    );
  }

  //  Delete Bag Button Event
  onClickDelete(element: any) {
    Swal.fire({
      title: 'ยืนยันการลบ?',
      text: `ต้องการลบ "${element.forkliftName}" ใช่หรือไม่`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#d33',
      cancelButtonColor: '#6c757d',
      confirmButtonText: 'ลบ',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (result.isConfirmed) {
        this.restService.processDeleteForklift(element.id, 0).subscribe(
          (data) => {
            if (data.status === 'success') {
              this.SweetAlert('success', 'ลบข้อมูลสำเร็จ');
              this.fetchProcessGetForklifttList(this.filter);
            } else {
              this.SweetAlert('error', 'Message : ' + data.message);
            }
          },
          (error) => {
            this.SweetAlert('error', 'Message : Error see in log.');
            console.log(error);
          },
        );
      }
    });
  }

  //  Tracks the placeholder left in the template while #print-forklift-area is
  //  reparented to <body> for printing (see printForklift). Kept as a direct
  //  reference rather than looked up by id, for the same reason as
  //  printForkliftAreaRef above.
  private printAreaPlaceholder: HTMLElement | null = null;

  //  Print Forklift QR Code Event - encodes the forklift's id/name as the QR
  //  data and renders it into the hidden #print-forklift-area before
  //  invoking window.print(). Mirrors user-list.ts's printUserQr.
  async printForklift(row: any): Promise<void> {
    await this.printForklifts([row]);
  }

  //  ─── Multi-select print ───────────────────────────────────────────
  //  Selection covers the current page only and is cleared whenever the
  //  list reloads (search, paging, page-size change), so at most pageSize
  //  cards print in one go.
  selectedForkliftIds = new Set<number>();

  isForkliftSelected(row: any): boolean {
    return this.selectedForkliftIds.has(row.id);
  }

  toggleForkliftSelection(row: any, checked: boolean): void {
    if (checked) this.selectedForkliftIds.add(row.id);
    else this.selectedForkliftIds.delete(row.id);
  }

  get isAllForkliftsSelected(): boolean {
    const rows = this._forkliftListTableData || [];
    return rows.length > 0 && rows.every((row: any) => this.selectedForkliftIds.has(row.id));
  }

  get isSomeForkliftsSelected(): boolean {
    return this.selectedForkliftIds.size > 0 && !this.isAllForkliftsSelected;
  }

  toggleAllForklifts(checked: boolean): void {
    this.selectedForkliftIds = new Set(
      checked ? (this._forkliftListTableData || []).map((row: any) => row.id) : [],
    );
  }

  async printSelectedForklifts(): Promise<void> {
    const rows = (this._forkliftListTableData || []).filter((row: any) => this.selectedForkliftIds.has(row.id));
    if (rows.length === 0) return;
    await this.printForklifts(rows);
  }

  //  One card (page) per forklift, in table order.
  private async printForklifts(rows: any[]): Promise<void> {
    this.printForkliftData = rows;

    let cards: string[];
    try {
      cards = await Promise.all(
        rows.map(async (row) => {
          const qrText = `${row.id ?? ''}|${row.forkliftName ?? ''}`;
          //  Rendered at high resolution because the QR is scaled up to fill
          //  the card body (see .pcard__qr in forklift-management.css).
          const qrDataUrl = await QRCode.toDataURL(qrText, { width: 1200, margin: 1 });
          return this.renderForkliftQrCard(row, qrDataUrl);
        }),
      );
    } catch (error) {
      console.error('Error generating QR code:', error);
      this.SweetAlert('error', 'สร้าง QR Code ไม่สำเร็จ');
      return;
    }

    const printArea = this.printForkliftAreaRef.nativeElement;
    printArea.innerHTML = cards.join('');

    setTimeout(() => {
      if (printArea.parentNode) {
        this.printAreaPlaceholder = document.createElement('div');
        printArea.parentNode.insertBefore(this.printAreaPlaceholder, printArea);
        document.body.appendChild(printArea);
      }

      window.print();

      window.addEventListener('afterprint', this.restorePrintForkliftArea, { once: true });
    }, 50);
  }

  //  Moves #print-forklift-area (reparented to document.body by
  //  printForklift so position:fixed reliably covers the page) back to its
  //  original spot in the template. Also called from ngOnDestroy: if the
  //  user navigates away before the browser fires "afterprint" (e.g. print
  //  dialog cancelled or never resolved), the node would otherwise stay
  //  orphaned under <body> - outliving this component and showing up
  //  unstyled on whatever page loads next, since #print-forklift-area's
  //  "display: none" rule is scoped to this component and goes away once
  //  it's destroyed.
  private restorePrintForkliftArea = (): void => {
    const printArea = this.printForkliftAreaRef?.nativeElement;
    if (printArea && this.printAreaPlaceholder && this.printAreaPlaceholder.parentNode) {
      this.printAreaPlaceholder.parentNode.insertBefore(printArea, this.printAreaPlaceholder);
      this.printAreaPlaceholder.remove();
    }
    this.printAreaPlaceholder = null;
    this.printForkliftData = null;
  };

  ngOnDestroy(): void {
    window.removeEventListener('afterprint', this.restorePrintForkliftArea);
    this.restorePrintForkliftArea();
  }

  //  Self-heal safety net: if an earlier visit ever left #print-forklift-area
  //  orphaned under <body> (the "afterprint" event failed to fire for some
  //  reason), it still carries the same id as this fresh instance's own
  //  node. document.getElementById only ever resolves the first match, so
  //  code addressing the element by id could never reach - and clean up -
  //  the stray duplicate. Sweeping every match by id and dropping whichever
  //  one isn't printForkliftAreaRef removes it the next time this page
  //  loads, with no manual browser refresh required.
  private cleanupOrphanedPrintAreas(): void {
    document
      .querySelectorAll('#print-forklift-area, #print-forklift-area-placeholder')
      .forEach((el) => {
        if (el !== this.printForkliftAreaRef.nativeElement) {
          el.remove();
        }
      });
  }

  private renderForkliftQrCard(row: any, qrDataUrl: string): string {
    //  Same card layout as location-management's printed label (.pcard):
    //  plate header, QR body, "Installation QR Code System" footer.
    const name = row.forkliftName ?? '';
    const plate = this.escapeHtml(name);
    return `
    <div class="pcard-print-page">
      <div class="pcard">
        <header class="pcard__header">
          <div class="pcard__plate">${plate}</div>
        </header>
        <div class="pcard__body">
          <img class="pcard__qr" src="${qrDataUrl}" alt="QR Code" />
        </div>
        <footer class="pcard__footer">Installation QR Code System</footer>
      </div>
    </div>`;
  }

  private escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {
    //  Page size changed -> back to page 1; otherwise go to the requested page.
    //  (Not via onClickSearch(), which always resets filter.page to 1.)
    const pageSizeChanged = event.pageSize !== this.filter.pageSize;
    this.filter.page = pageSizeChanged ? 1 : event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;

    //  Load the chosen page directly -- onClickSearch() resets filter.page to
    //  1, which made every Next/Last/page-size click jump back to page 1.
    this.fetchProcessGetForklifttList(this.filter);
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
