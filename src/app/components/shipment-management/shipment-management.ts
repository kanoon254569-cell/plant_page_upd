import { Component, OnInit, HostListener, ChangeDetectorRef, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Subject, of } from 'rxjs';
import { catchError, switchMap, tap } from 'rxjs/operators';
import { PageEvent } from '@angular/material/paginator';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';

//  Options for the in-page notice / confirm modal (same names as the
//  SweetAlert options this page used before).
interface NoticeOptions {
  icon?: 'success' | 'error' | 'warning' | 'info' | 'question';
  title?: string;
  text?: string;
  html?: string;
  showCancelButton?: boolean;
  confirmButtonText?: string;
  cancelButtonText?: string;
  confirmButtonColor?: string;
  cancelButtonColor?: string;
  timer?: number;
  showConfirmButton?: boolean;
}

interface StatusOption {
  id: number;
  code: string;
  name: string;
  color: string;
}

const SHIPMENT_STATUSES: StatusOption[] = [
  { id: 1, code: 'CS', name: 'Create Shipment', color: '#94a3b8' },
  { id: 2, code: 'PLN', name: 'Planning', color: '#64748b' },
  { id: 3, code: 'ECI', name: 'Estimate Check in', color: '#3b82f6' },
  { id: 4, code: 'TCI', name: 'Truck Check in', color: '#2563eb' },
  { id: 5, code: 'DCI', name: 'Driver Check in', color: '#1d4ed8' },
  { id: 6, code: 'WPP', name: 'Wait Product Preparing', color: '#eab308' },
  { id: 7, code: 'CPP', name: 'Complete Product Preparing', color: '#10b981' },
  { id: 8, code: 'LC', name: 'Loading Confirm', color: '#059669' },
  { id: 9, code: 'LS', name: 'Loading Start', color: '#0284c7' },
  { id: 10, code: 'QC', name: 'Queue Call', color: '#8b5cf6' },
  { id: 11, code: 'WI', name: 'Weight In', color: '#6366f1' },
  { id: 12, code: 'LBS', name: 'Labor Start', color: '#4f46e5' },
  { id: 13, code: 'LJD', name: 'Labor Job Done', color: '#4338ca' },
  { id: 14, code: 'PL', name: 'Photo Loading', color: '#0d9488' },
  { id: 15, code: 'WO', name: 'Weight Out', color: '#0f766e' },
  { id: 16, code: 'WC', name: 'Weight Crash', color: '#ef4444' },
  { id: 17, code: 'SC', name: 'Shipment Completion', color: '#16a34a' },
];

@Component({
  selector: 'app-shipment-management',
  standalone: false,
  templateUrl: './shipment-management.html',
  styleUrl: './shipment-management.css',
})
export class ShipmentManagement implements OnInit {
  private readonly cdr = inject(ChangeDetectorRef);
  private readonly destroyRef = inject(DestroyRef);
  private readonly crudService = inject(CrudService);

  isLoading = false;
  statusOptions: StatusOption[] = SHIPMENT_STATUSES;

  // Search Filter
  filter: Type.ShipmentManagementFilter = {
    shipmentNo: '',
    doNo: '',
    whCode: '',
    statusId: '',
    dateFrom: null,
    dateTo: null,
    page: 1,
    pageSize: 10,
  };

  // Current page from GET shipment-management (server-side filter + paging)
  allShipments: Type.ShipmentManagementItem[] = [];
  filteredShipments: Type.ShipmentManagementItem[] = [];
  pagedShipments: Type.ShipmentManagementItem[] = [];
  totalCount = 0;

  // Modals state
  isEditDoModalOpen = false;
  isMoveDoModalOpen = false;
  isSplitDoModalOpen = false;
  isCreateShipmentModalOpen = false;

  // "+ DO" picker modal: the shipment it adds to (null = closed), the
  // candidate DOs from GET job/shipment and the ticked ones (by DO no).
  doPickerShipment: Type.ShipmentManagementItem | null = null;
  selectedDoNos = new Map<string, Type.ResultProcessJobShipment>();
  doExpanded = new Set<string>();
  doPage = 1;
  doPageSize = 10;
  doTotalCount = 0;
  doFilter = ShipmentManagement.emptyDoFilter();
  doPlantOptions: Type.ShipmentPlantOption[] = [];
  doWhOptions: Type.ShipmentWhOption[] = [];
  doStatusOptions: Type.ShipmentStatusOption[] = [];
  private doFilterOptionsLoaded = false;
  doOptions: Type.ResultProcessJobShipment[] = [];
  doSearchLoading = false;
  doSearchError = '';
  private readonly doSearch$ = new Subject<void>();

  // Edit DO form
  editDoForm = {
    id: 0,
    shipmentId: 0,
    shipmentNo: '',
    doNo: '',
    grade: '',
    lotNo: '',
    qty: 0,
    unit: 'kg',
    palletQty: 0,
    whCode: 'MWH',
    plantCode: '1100',
    productCc: '',
    remark: '',
  };

  // Move DO modal state
  movingDo: Type.DeliveryOrderItem | null = null;
  // all DOs being moved (one from a row button, several from the bulk button)
  movingDos: Type.DeliveryOrderItem[] = [];
  sourceShipment: Type.ShipmentManagementItem | null = null;
  moveTargetMode: 'existing' | 'new' = 'existing';
  moveTargetShipmentNo = '';
  moveNewShipmentTruck = '';

  // Split DO modal state: the DO being split. The destination DOs are the
  // rows ticked in the shared DO list (selectedDoNos); their qty is split off.
  splittingDo: Type.DeliveryOrderItem | null = null;
  splittingShipment: Type.ShipmentManagementItem | null = null;

  // Merge DO modal state: the DO the ticked DOs are merged into.
  isMergeDoModalOpen = false;
  mergeTargetDo: Type.DeliveryOrderItem | null = null;
  mergeShipment: Type.ShipmentManagementItem | null = null;

  // Create Shipment form
  createShipmentForm = {
    shipmentNo: '',
    licensePlate: '',
    carrierName: '',
    driverName: '',
    whCode: 'MWH',
    plantCode: '1100',
    statusId: 2,
    loadingDate: new Date(),
  };

  ngOnInit(): void {
    this.initDoSearch();
    this.loadShipments();
  }

  @HostListener('document:keydown.escape')
  onEscapePress(): void {
    if (this.notice) {
      this.closeNotice(false);
      return;
    }
    if (this.doPickerShipment) this.closeDoPicker();
    if (this.isEditDoModalOpen) this.closeEditDoModal();
    if (this.isMoveDoModalOpen) this.closeMoveDoModal();
    if (this.isSplitDoModalOpen) this.closeSplitDoModal();
    if (this.isMergeDoModalOpen) this.closeMergeDoModal();
    if (this.isCreateShipmentModalOpen) this.closeCreateShipmentModal();
  }

  // Summary statistics
  get totalDosCount(): number {
    return this.filteredShipments.reduce((sum, s) => sum + (s.dos?.length || 0), 0);
  }

  get totalWeightKg(): number {
    return this.filteredShipments.reduce(
      (sum, s) => sum + (s.dos?.reduce((dSum, d) => dSum + (d.qty || 0), 0) || 0),
      0,
    );
  }

  get completedShipmentsCount(): number {
    return this.filteredShipments.filter((s) => s.statusId === 17).length;
  }

  getStatusOption(statusId: number): StatusOption {
    return (
      this.statusOptions.find((s) => s.id === statusId) || {
        id: statusId,
        code: `S${statusId}`,
        name: 'Unknown',
        color: '#64748b',
      }
    );
  }

  getStatusBadgeClass(statusId: number): string {
    if (statusId === 17) return 'status-badge--success';
    if (statusId >= 6 && statusId <= 8) return 'status-badge--warning';
    if (statusId >= 3 && statusId <= 15) return 'status-badge--info';
    if (statusId === 16) return 'status-badge--danger';
    return 'status-badge--default';
  }

  toggleExpand(shipment: Type.ShipmentManagementItem): void {
    shipment.expanded = !shipment.expanded;
  }

  // Ticked DO rows (by DO id) in the shipment table's DO sub-rows.
  checkedDoIds = new Set<number>();

  toggleDoChecked(doItem: Type.DeliveryOrderItem): void {
    if (this.checkedDoIds.has(doItem.id)) this.checkedDoIds.delete(doItem.id);
    else this.checkedDoIds.add(doItem.id);
    this.cdr.detectChanges();
  }

  isAllShipmentDosChecked(shipment: Type.ShipmentManagementItem): boolean {
    return shipment.dos.length > 0 && shipment.dos.every((d) => this.checkedDoIds.has(d.id));
  }

  isSomeShipmentDosChecked(shipment: Type.ShipmentManagementItem): boolean {
    return !this.isAllShipmentDosChecked(shipment) && shipment.dos.some((d) => this.checkedDoIds.has(d.id));
  }

  toggleAllShipmentDos(shipment: Type.ShipmentManagementItem): void {
    const check = !this.isAllShipmentDosChecked(shipment);
    shipment.dos.forEach((d) => (check ? this.checkedDoIds.add(d.id) : this.checkedDoIds.delete(d.id)));
    this.cdr.detectChanges();
  }

  // Search & Filter
  onClickSearch(): void {
    this.filter.page = 1;
    this.applyFilter();
  }

  resetFilter(): void {
    this.filter = {
      shipmentNo: '',
      doNo: '',
      whCode: '',
      statusId: '',
      dateFrom: null,
      dateTo: null,
      page: 1,
      pageSize: 10,
    };
    this.applyFilter();
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadShipments();
  }

  //  Reload the current page from the API (kept as applyFilter so the action
  //  handlers below can just call it after a save).
  private applyFilter(expandShipmentNos: string[] = []): void {
    this.loadShipments(expandShipmentNos);
  }

  //  GET shipment-management -- shipments of the current page with their DOs.
  //  Expanded rows stay expanded across reloads (by shipment no), plus any
  //  shipment in expandShipmentNos (e.g. the target of a move / add).
  loadShipments(expandShipmentNos: string[] = []): void {
    const expanded = new Set([
      ...this.allShipments.filter((s) => s.expanded).map((s) => s.shipmentNo),
      ...expandShipmentNos,
    ]);
    const status = this.filter.statusId !== '' && this.filter.statusId != null ? Number(this.filter.statusId) : null;

    this.isLoading = true;
    this.cdr.detectChanges();
    this.crudService
      .processGetShipmentMgmtList(
        {
          shipmentNo: (this.filter.shipmentNo || '').trim(),
          doNo: (this.filter.doNo || '').trim(),
          whCode: (this.filter.whCode || '').trim(),
          statusId: status !== null && !isNaN(status) ? status : null,
        },
        this.filter.page || 1,
        this.filter.pageSize || 10,
      )
      .subscribe({
        next: (res) => {
          this.allShipments = (res.data ?? []).map((s) => this.mapShipment(s, expanded));
          this.filteredShipments = this.allShipments;
          this.pagedShipments = this.allShipments;
          this.totalCount = res.total_count ?? 0;
          // drop ticks of DOs that are no longer on the page
          const ids = new Set(this.allShipments.flatMap((s) => s.dos.map((d) => d.id)));
          this.checkedDoIds = new Set([...this.checkedDoIds].filter((id) => ids.has(id)));
          this.isLoading = false;
          this.cdr.detectChanges();
        },
        error: (err) => {
          console.error('Error fetching shipments:', err);
          this.allShipments = [];
          this.filteredShipments = [];
          this.pagedShipments = [];
          this.totalCount = 0;
          this.isLoading = false;
          this.cdr.detectChanges();
          this.notify({ icon: 'error', title: 'โหลดรายการ Shipment ไม่สำเร็จ', text: this.apiErrorText(err) });
        },
      });
  }

  private mapShipment(s: Type.ResultShipmentMgmtShipment, expanded: Set<string>): Type.ShipmentManagementItem {
    return {
      id: s.shipment_id,
      shipmentNo: s.shipment_no,
      statusId: s.status_id ?? 0,
      statusName: s.status_name ?? '',
      loadingDate: s.loading_datetime ?? '',
      licensePlate: s.license_plate ?? '',
      driverName: s.driver_name ?? '',
      carrierName: s.carrier_name ?? '',
      customerName: (s.customer_name ?? '').trim(),
      shipToName: (s.ship_to_name ?? '').trim(),
      whCode: s.wh_code ?? '',
      plantCode: s.cc_code ?? '',
      expanded: expanded.has(s.shipment_no),
      dos: (s.dos ?? []).map((d) => ({
        id: d.delivery_id,
        shipmentId: s.shipment_id,
        shipmentNo: s.shipment_no,
        doNo: d.do_no ?? '',
        grade: d.grade ?? '',
        gradeDesc: d.grade_desc ?? '',
        lotNo: d.lot ?? '',
        qty: Number(d.qty) || 0,
        unit: d.unit ?? 'KG',
        palletQty: d.total_pallet ?? 0,
        whCode: d.wh_code ?? '',
        plantCode: d.cc_code ?? '',
        remark: d.remark ?? '',
        hasPickingJob: !!d.has_picking_job,
        lots: (d.lots ?? []).map((l) => ({
          lotNo: l.lot_no ?? '-',
          qty: Number(l.qty) || 0,
          actualQty: l.actual_qty != null ? Number(l.actual_qty) : null,
        })),
      })),
    };
  }

  //  Message from an API error body ({ status, message }) or the HTTP error.
  private apiErrorText(err: any): string {
    return err?.error?.message || err?.message || 'เกิดข้อผิดพลาด';
  }

  getShipmentTotalQty(shipment: Type.ShipmentManagementItem): number {
    return (shipment.dos || []).reduce((sum, d) => sum + (d.qty || 0), 0);
  }

  getShipmentTotalPallets(shipment: Type.ShipmentManagementItem): number {
    return (shipment.dos || []).reduce((sum, d) => sum + (d.palletQty || 0), 0);
  }

  // -------------------------------------------------------------
  // In-page notice / confirm modal (replaces SweetAlert on this page).
  // notify() takes the same options this page used with Swal.fire() and
  // resolves { isConfirmed } when the user closes it, so callers keep the
  // same .then((result) => result.isConfirmed) flow.
  // -------------------------------------------------------------
  notice: NoticeOptions | null = null;
  private noticeResolve?: (result: { isConfirmed: boolean }) => void;
  private noticeTimer?: ReturnType<typeof setTimeout>;

  notify(options: NoticeOptions): Promise<{ isConfirmed: boolean }> {
    // a newer notice replaces an open one (that one counts as dismissed)
    this.closeNotice(false);
    this.notice = options;
    if (options.timer) {
      this.noticeTimer = setTimeout(() => this.closeNotice(true), options.timer);
    }
    this.cdr.detectChanges();
    return new Promise((resolve) => (this.noticeResolve = resolve));
  }

  closeNotice(confirmed: boolean): void {
    if (this.noticeTimer) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = undefined;
    }
    const resolve = this.noticeResolve;
    this.noticeResolve = undefined;
    if (!this.notice && !resolve) return;
    this.notice = null;
    this.cdr.detectChanges();
    resolve?.({ isConfirmed: confirmed });
  }

  get noticeIcon(): string {
    switch (this.notice?.icon) {
      case 'success':
        return 'check_circle';
      case 'error':
        return 'error';
      case 'warning':
        return 'warning';
      case 'question':
        return 'help';
      default:
        return 'info';
    }
  }

  // -------------------------------------------------------------
  // Add DO
  // -------------------------------------------------------------
  //  Today in Thai time as a local Date -- the picker's default Loading Date.
  private static thaiToday(): Date {
    const [y, m, d] = new Date(Date.now() + 7 * 60 * 60 * 1000).toISOString().split('T')[0].split('-').map(Number);
    return new Date(y, m - 1, d);
  }

  private static toDateParam(d: Date | null): string {
    if (!d) return '';
    const p = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  private static emptyDoFilter() {
    return {
      shipmentNo: '',
      deliveryNo: '',
      plantCodes: [] as string[],
      loadingDate: ShipmentManagement.thaiToday() as Date | null,
      whIds: [] as number[],
      statusIds: [] as number[],
    };
  }

  private resetDoPicker(): void {
    this.doFilter = ShipmentManagement.emptyDoFilter();
    this.doOptions = [];
    this.doSearchError = '';
    this.selectedDoNos = new Map<string, Type.ResultProcessJobShipment>();
    this.doExpanded = new Set<string>();
    this.doTotalCount = 0;
  }

  //  Filter dropdown options (GET job/shipment/plants|storages|statuses),
  //  loaded the first time the picker opens.
  private loadDoFilterOptions(): void {
    if (this.doFilterOptionsLoaded) return;
    this.doFilterOptionsLoaded = true;
    const done = () => this.cdr.detectChanges();
    this.crudService.processGetJobShipmentPlants().subscribe({
      next: (r) => { this.doPlantOptions = r.data ?? []; done(); },
      error: (e) => console.error('Error fetching plant options:', e),
    });
    this.crudService.processGetJobShipmentStorages().subscribe({
      next: (r) => { this.doWhOptions = r.data ?? []; done(); },
      error: (e) => console.error('Error fetching WH options:', e),
    });
    this.crudService.processGetJobShipmentStatuses().subscribe({
      next: (r) => { this.doStatusOptions = r.data ?? []; done(); },
      error: (e) => console.error('Error fetching status options:', e),
    });
  }

  //  DO search (server-side paging); switchMap drops responses from an older search.
  private initDoSearch(): void {
    this.doSearch$
      .pipe(
        tap(() => {
          this.doSearchLoading = true;
          this.doSearchError = '';
          this.cdr.detectChanges();
        }),
        switchMap(() => {
          const f = this.doFilter;
          const date = ShipmentManagement.toDateParam(f.loadingDate);
          return this.crudService
            .processGetJobShipmentList(f.shipmentNo.trim(), f.deliveryNo.trim(), this.doPage, this.doPageSize, {
              loadingFrom: date,
              loadingTo: date,
              plantCodes: f.plantCodes,
              whIds: f.whIds,
              statusIds: f.statusIds,
            })
            .pipe(
              catchError((error) => {
                console.error('Error fetching DO list:', error);
                this.doSearchError = 'โหลดรายการ DO ไม่สำเร็จ';
                return of(null);
              }),
            );
        }),
        takeUntilDestroyed(this.destroyRef),
      )
      .subscribe((response) => {
        this.doSearchLoading = false;
        this.doOptions = response?.data ?? [];
        this.doTotalCount = response?.total_count ?? 0;
        this.doExpanded = new Set<string>();
        this.cdr.detectChanges();
      });
  }

  //  "+ DO": opens the DO picker modal for this shipment (Loading Date =
  //  today), focuses Delivery No and loads the list.
  openDoPicker(shipment: Type.ShipmentManagementItem): void {
    this.doPickerShipment = shipment;
    this.resetDoPicker();
    this.loadDoFilterOptions();
    // render the modal now so its input exists to focus
    this.cdr.detectChanges();
    document.querySelector<HTMLInputElement>('.do-pick-search')?.focus();
    this.searchDoPicker();
  }

  closeDoPicker(): void {
    this.doPickerShipment = null;
    this.resetDoPicker();
  }

  //  New filter -> back to page 1 (ticked DOs are kept).
  searchDoPicker(): void {
    this.doPage = 1;
    this.doSearch$.next();
  }

  //  Text shown in a multi-select box: the picked names, or "ทั้งหมด".
  private static pickedLabel(names: string[]): string {
    if (names.length === 0) return 'ทั้งหมด';
    return names.length <= 2 ? names.join(', ') : `${names.slice(0, 2).join(', ')} +${names.length - 2}`;
  }

  get doPlantLabel(): string {
    return ShipmentManagement.pickedLabel(this.doFilter.plantCodes);
  }

  get doWhLabel(): string {
    const ids = new Set(this.doFilter.whIds);
    return ShipmentManagement.pickedLabel(this.doWhOptions.filter((w) => ids.has(w.id)).map((w) => w.name ?? String(w.id)));
  }

  get doStatusLabel(): string {
    const ids = new Set(this.doFilter.statusIds);
    return ShipmentManagement.pickedLabel(this.doStatusOptions.filter((s) => ids.has(s.id)).map((s) => s.name ?? String(s.id)));
  }

  resetDoFilter(): void {
    this.doFilter = ShipmentManagement.emptyDoFilter();
    this.searchDoPicker();
  }

  onDoPageEvent(event: PageEvent): void {
    this.doPage = event.pageIndex + 1;
    this.doPageSize = event.pageSize;
    this.doSearch$.next();
  }

  //  Rows grouped by consecutive shipmentno, so Shipment No shows once per
  //  block (same as job-list's shipment list).
  get groupedDoOptions(): { shipmentno: string; rows: Type.ResultProcessJobShipment[] }[] {
    const groups: { shipmentno: string; rows: Type.ResultProcessJobShipment[] }[] = [];
    for (const row of this.doOptions) {
      const last = groups[groups.length - 1];
      if (last && last.shipmentno === row.shipmentno) last.rows.push(row);
      else groups.push({ shipmentno: row.shipmentno, rows: [row] });
    }
    return groups;
  }

  trackByDoGroup = (_: number, g: { shipmentno: string; rows: Type.ResultProcessJobShipment[] }) =>
    `${g.shipmentno}:${g.rows[0]?.deliveryno}`;
  trackByDo = (_: number, o: Type.ResultProcessJobShipment) => o.deliveryno;

  get allDosSelected(): boolean {
    const rows = this.doOptions;
    return rows.length > 0 && rows.every((o) => this.selectedDoNos.has(o.deliveryno));
  }

  toggleDo(o: Type.ResultProcessJobShipment): void {
    if (this.selectedDoNos.has(o.deliveryno)) {
      this.selectedDoNos.delete(o.deliveryno);
    } else {
      this.selectedDoNos.set(o.deliveryno, o);
    }
    this.cdr.detectChanges();
  }

  toggleAllDos(): void {
    const rows = this.doOptions;
    if (this.allDosSelected) {
      rows.forEach((o) => this.selectedDoNos.delete(o.deliveryno));
    } else {
      rows.forEach((o) => this.selectedDoNos.set(o.deliveryno, o));
    }
    this.cdr.detectChanges();
  }

  toggleDoExpanded(o: Type.ResultProcessJobShipment): void {
    if (this.doExpanded.has(o.deliveryno)) this.doExpanded.delete(o.deliveryno);
    else this.doExpanded.add(o.deliveryno);
    this.cdr.detectChanges();
  }

  //  Status short code + color -- same mapping as job-list's shipment list.
  private static readonly DO_STATUS_ABBR: Record<number, string> = {
    1: 'CS', 2: 'PLN', 3: 'ECI', 4: 'TCI', 5: 'DCI', 6: 'WPP', 7: 'CPP', 8: 'LC', 9: 'LS',
    10: 'QC', 11: 'WI', 12: 'LBS', 13: 'LJD', 14: 'PL', 15: 'WO', 16: 'WC', 17: 'SC',
  };

  private static readonly DO_STATUS_COLORS: Record<number, string> = {
    1: '#4338ca', 2: '#7c3aed', 3: '#d97706', 4: '#0284c7', 5: '#0891b2', 6: '#ea580c',
    7: '#16a34a', 8: '#1d4ed8', 9: '#0d9488', 10: '#db2777', 11: '#65a30d', 12: '#c026d3',
    13: '#92400e', 14: '#64748b', 15: '#0f172a', 16: '#dc2626', 17: '#047857',
  };

  doStatusAbbr(o: Type.ResultProcessJobShipment): string {
    const abbr = o.current_status_id == null ? null : ShipmentManagement.DO_STATUS_ABBR[o.current_status_id];
    if (abbr) return abbr;
    const name = (o.current_status || o.status || '').trim();
    return name ? name.split(/\s+/).map((w) => w.charAt(0).toUpperCase()).join('') : 'N/A';
  }

  doStatusColor(statusId: number | null | undefined): string | null {
    return statusId == null ? null : ShipmentManagement.DO_STATUS_COLORS[statusId] ?? null;
  }

  //  "เพิ่ม DO": adds every ticked DO to the picker's shipment. A DO that is
  //  already in a shipment on this page is skipped and reported.
  confirmAddSelectedDos(): void {
    const shipment = this.doPickerShipment;
    if (!shipment || this.selectedDoNos.size === 0) return;

    const items: Type.RequestShipmentMgmtAddItem[] = [...this.selectedDoNos.values()].map((src) => ({
      doNo: src.deliveryno,
      grade: src.fpdgradecode ?? null,
      lot: src.pdlotno ?? null,
      qty: src.qty != null ? Number(src.qty) : null,
      unit: src.unit || null,
      totalPallet: src.total_pallet != null ? Number(src.total_pallet) : null,
      ccCode: src.cccode ?? null,
      whCode: src.whcode ?? null,
      remark: src.remark ?? null,
    }));

    //  POST shipment-management/deliveries -- every item is tried; the API
    //  reports which ones were added and why the others were skipped.
    this.crudService.processAddShipmentMgmtDeliveries(shipment.shipmentNo, items).subscribe({
      next: (res) => this.afterAddDos(shipment, res),
      error: (err) => {
        // 400 still carries the per-item results (e.g. every DO already in a shipment)
        if (err?.error?.data) this.afterAddDos(shipment, err.error);
        else this.notify({ icon: 'error', title: 'เพิ่ม DO ไม่สำเร็จ', text: this.apiErrorText(err) });
      },
    });
  }

  private afterAddDos(shipment: Type.ShipmentManagementItem, res: Type.ResponseShipmentMgmtAdd): void {
    const rows = res.data ?? [];
    const added = rows.filter((r) => r.status === 'success').map((r) => r.do_no);
    const failed = rows.filter((r) => r.status !== 'success');

    this.closeDoPicker();
    this.applyFilter([shipment.shipmentNo]);

    this.notify({
      icon: added.length ? (failed.length ? 'warning' : 'success') : 'error',
      title: added.length ? `เพิ่ม ${added.length} DO สำเร็จ` : 'ไม่มี DO ที่เพิ่มได้',
      html:
        (added.length ? `เข้าสู่ Shipment <strong>${shipment.shipmentNo}</strong>` : '') +
        (failed.length ? `<br>ไม่ได้เพิ่ม: ${failed.map((f) => `${f.do_no} (${f.message})`).join(', ')}` : ''),
      timer: failed.length ? undefined : 2000,
      showConfirmButton: failed.length > 0,
    });
  }

  // -------------------------------------------------------------
  // Edit DO
  // -------------------------------------------------------------
  openEditDoModal(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.editDoForm = {
      id: doItem.id,
      shipmentId: shipment.id,
      shipmentNo: shipment.shipmentNo,
      doNo: doItem.doNo,
      grade: doItem.grade,
      lotNo: doItem.lotNo,
      qty: doItem.qty,
      unit: doItem.unit || 'kg',
      palletQty: doItem.palletQty,
      whCode: doItem.whCode || shipment.whCode,
      plantCode: doItem.plantCode || shipment.plantCode,
      productCc: doItem.productCc || '',
      remark: doItem.remark || '',
    };
    this.buildEditOptions();
    this.isEditDoModalOpen = true;
  }

  //  Edit DO dropdowns, built once when the modal opens (a getter returning a
  //  new array each check made mat-select see changed options every cycle).
  //  The DO's current value is always listed, even when it isn't a default.
  editWarehouseOptions: { code: string; name: string }[] = [];
  editPlantOptions: { code: string; name: string }[] = [];

  private buildEditOptions(): void {
    const wh = [
      { code: 'MWH', name: 'Main Warehouse' },
      { code: 'DOCK', name: 'Loading Dock' },
      { code: 'PRE-ZONE', name: 'Prepare Zone' },
    ];
    const plants = ['1100', '1200', '1300', '1600'].map((c) => ({ code: c, name: 'Plant ' + c }));
    const curWh = this.editDoForm.whCode;
    const curPlant = this.editDoForm.plantCode;
    this.editWarehouseOptions = curWh && !wh.some((o) => o.code === curWh) ? [{ code: curWh, name: '' }, ...wh] : wh;
    this.editPlantOptions =
      curPlant && !plants.some((o) => o.code === curPlant) ? [{ code: curPlant, name: '' }, ...plants] : plants;
  }

  closeEditDoModal(): void {
    this.isEditDoModalOpen = false;
  }

  saveEditDo(): void {
    if (!this.editDoForm.doNo.trim()) {
      this.notify({ icon: 'warning', title: 'กรุณาระบุเลขที่ DO' });
      return;
    }
    if (!(Number(this.editDoForm.qty) > 0)) {
      this.notify({ icon: 'warning', title: 'กรุณาระบุจำนวน Qty ที่ถูกต้อง' });
      return;
    }

    const f = this.editDoForm;
    const doNo = f.doNo.trim();
    //  PATCH shipment-management/deliveries/{id}
    this.crudService
      .processUpdateShipmentMgmtDelivery(f.id, {
        doNo,
        grade: f.grade?.trim().toUpperCase() || null,
        lot: f.lotNo?.trim().toUpperCase() || null,
        qty: Number(f.qty),
        totalPallet: f.palletQty != null && String(f.palletQty) !== '' ? Number(f.palletQty) : null,
        ccCode: f.plantCode || null,
        whCode: f.whCode || null,
        remark: f.remark?.trim() || null,
      })
      .subscribe({
        next: () => {
          this.closeEditDoModal();
          this.applyFilter();
          this.notify({
            icon: 'success',
            title: 'แก้ไข DO สำเร็จ',
            text: `อัปเดตข้อมูล ${doNo} เรียบร้อยแล้ว`,
            timer: 1800,
            showConfirmButton: false,
          });
        },
        error: (err) => this.notify({ icon: 'error', title: 'แก้ไข DO ไม่สำเร็จ', text: this.apiErrorText(err) }),
      });
  }

  // -------------------------------------------------------------
  // Move DO (ย้าย DO)
  // -------------------------------------------------------------
  openMoveDoModal(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.openMoveDosModal(shipment, [doItem]);
  }

  //  Bulk "ย้าย": move every ticked DO of this shipment at once.
  openBulkMoveDoModal(shipment: Type.ShipmentManagementItem): void {
    this.openMoveDosModal(shipment, this.checkedDosOf(shipment));
  }

  private openMoveDosModal(shipment: Type.ShipmentManagementItem, dos: Type.DeliveryOrderItem[]): void {
    if (dos.length === 0) return;
    this.movingDos = dos;
    this.movingDo = dos[0];
    this.sourceShipment = shipment;
    this.moveTargetMode = 'existing';
    // destination comes from the same GET job/shipment list as the "+ DO" picker
    this.moveTargetShipmentNo = '';
    this.moveNewShipmentTruck = '';
    this.moveTargetRow = null;
    this.resetDoPicker();
    this.loadDoFilterOptions();
    this.isMoveDoModalOpen = true;
    // render the modal now so its search box exists to focus
    this.cdr.detectChanges();
    document.querySelector<HTMLInputElement>('.do-pick-search')?.focus();
    this.searchDoPicker();
  }

  //  Row of the shared DO list picked as the move destination (its shipmentno).
  moveTargetRow: Type.ResultProcessJobShipment | null = null;

  //  Shared list (doPickerContent): ticks DOs in the "+ DO", Merge DO and
  //  Split DO modals, picks one destination row in the Move DO modal.
  get isPickOneRow(): boolean {
    return this.isMoveDoModalOpen;
  }

  onDoRowClick(o: Type.ResultProcessJobShipment): void {
    if (this.isMoveDoModalOpen) {
      this.moveTargetRow = o;
      this.cdr.detectChanges();
    } else {
      this.toggleDo(o);
    }
  }

  isDoRowPicked(o: Type.ResultProcessJobShipment): boolean {
    return this.isPickOneRow
      ? this.moveTargetRow?.deliveryno === o.deliveryno
      : this.selectedDoNos.has(o.deliveryno);
  }

  doRowIcon(o: Type.ResultProcessJobShipment): string {
    if (this.isPickOneRow) return this.isDoRowPicked(o) ? 'radio_button_checked' : 'radio_button_unchecked';
    return this.isDoRowPicked(o) ? 'check_box' : 'check_box_outline_blank';
  }

  closeMoveDoModal(): void {
    this.isMoveDoModalOpen = false;
    this.movingDo = null;
    this.movingDos = [];
    this.moveTargetRow = null;
    this.resetDoPicker();
    this.sourceShipment = null;
  }

  get movingDoNosText(): string {
    return this.movingDos.map((d) => d.doNo).join(', ');
  }

  get movingQtyTotal(): number {
    return this.movingDos.reduce((sum, d) => sum + (d.qty || 0), 0);
  }

  get movingPalletTotal(): number {
    return this.movingDos.reduce((sum, d) => sum + (d.palletQty || 0), 0);
  }

  otherShipments(): Type.ShipmentManagementItem[] {
    if (!this.sourceShipment) return this.allShipments;
    return this.allShipments.filter((s) => s.id !== this.sourceShipment!.id);
  }

  confirmMoveDo(): void {
    if (this.movingDos.length === 0 || !this.sourceShipment) return;

    const row = this.moveTargetRow;
    if (!row) {
      this.notify({ icon: 'warning', title: 'กรุณาเลือก Shipment ปลายทาง' });
      return;
    }
    if (row.shipmentno === this.sourceShipment.shipmentNo) {
      this.notify({ icon: 'warning', title: 'Shipment ปลายทางเป็น Shipment เดิม', text: 'กรุณาเลือก Shipment อื่น' });
      return;
    }

    const movedDoNo = this.movingDoNosText;
    const fromShipmentNo = this.sourceShipment.shipmentNo;
    const toShipmentNo = row.shipmentno;
    const ids = this.movingDos.map((d) => d.id);

    //  PATCH shipment-management/deliveries/move (all-or-nothing; the API
    //  creates the target shipment when it isn't in QTrack yet)
    this.crudService.processMoveShipmentMgmtDeliveries(ids, toShipmentNo).subscribe({
      next: () => {
        ids.forEach((id) => this.checkedDoIds.delete(id));
        this.closeMoveDoModal();
        this.applyFilter([toShipmentNo]);
        this.notify({
          icon: 'success',
          title: 'ย้าย DO สำเร็จ',
          html: `ย้าย DO <strong>${movedDoNo}</strong><br>จาก <strong>${fromShipmentNo}</strong> ไปยัง <strong>${toShipmentNo}</strong> เรียบร้อยแล้ว`,
        });
      },
      error: (err) => this.notify({ icon: 'error', title: 'ย้าย DO ไม่สำเร็จ', text: this.apiErrorText(err) }),
    });
  }

  // -------------------------------------------------------------
  // Merge DO (รวม DO) -- same layout as the "+ DO" picker: tick DOs in the
  // shared list (GET job/shipment) to merge into the DO the button is on.
  // UI only for now: there is no merge endpoint yet.
  // -------------------------------------------------------------
  openMergeDoModal(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.mergeTargetDo = doItem;
    this.mergeShipment = shipment;
    this.resetDoPicker();
    this.loadDoFilterOptions();
    this.isMergeDoModalOpen = true;
    // render the modal now so its search box exists to focus
    this.cdr.detectChanges();
    document.querySelector<HTMLInputElement>('.do-pick-search')?.focus();
    this.searchDoPicker();
  }

  closeMergeDoModal(): void {
    this.isMergeDoModalOpen = false;
    this.mergeTargetDo = null;
    this.mergeShipment = null;
    this.resetDoPicker();
  }

  //  Ticked DOs to merge, without the DO merged into (it can't merge into itself).
  get mergeSources(): Type.ResultProcessJobShipment[] {
    const doNo = this.mergeTargetDo?.doNo;
    return [...this.selectedDoNos.values()].filter((o) => o.deliveryno !== doNo);
  }

  get mergeQty(): number {
    return this.mergeSources.reduce((sum, o) => sum + (Number(o.qty) || 0), 0);
  }

  //  Qty of the DO merged into after the merge.
  get mergeTotalQty(): number {
    return (this.mergeTargetDo?.qty || 0) + this.mergeQty;
  }

  confirmMergeDo(): void {
    const target = this.mergeTargetDo;
    const shipment = this.mergeShipment;
    if (!target || !shipment) return;

    const picked = this.mergeSources;
    if (picked.length === 0) {
      this.notify({ icon: 'warning', title: 'กรุณาเลือก DO ที่จะรวม', text: `เลือก DO อื่นที่ไม่ใช่ ${target.doNo}` });
      return;
    }

    const qty = this.mergeQty;
    this.notify({
      title: `ยืนยันรวม ${picked.length} DO?`,
      html:
        `รวม ${picked.map((o) => '<strong>' + o.deliveryno + '</strong>').join(', ')}` +
        `<br>เข้า DO <strong>${target.doNo}</strong> (Shipment <strong>${shipment.shipmentNo}</strong>)` +
        `<br>เพิ่มยอด ${qty.toLocaleString()} kg · ยอดรวมหลังรวม <strong>${this.mergeTotalQty.toLocaleString()}</strong> kg`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'รวม DO',
      cancelButtonText: 'ยกเลิก',
      confirmButtonColor: '#0d9488',
    }).then((result) => {
      if (!result.isConfirmed) return;
      this.closeMergeDoModal();
      this.notify({ icon: 'info', title: 'ยังไม่ได้เชื่อมต่อ API', text: 'ปุ่มรวม DO ยังไม่ได้ส่งข้อมูลไปที่ระบบ' });
    });
  }

  // -------------------------------------------------------------
  // Split DO (แยก DO) -- tick one or more DOs in the shared list; the sum of
  // their qty is split off this DO. UI only for now: no split endpoint yet.
  // -------------------------------------------------------------
  openSplitDoModal(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.splittingDo = doItem;
    this.splittingShipment = shipment;
    this.resetDoPicker();
    this.loadDoFilterOptions();
    this.isSplitDoModalOpen = true;
    this.cdr.detectChanges();
    document.querySelector<HTMLInputElement>('.do-pick-search')?.focus();
    this.searchDoPicker();
  }

  closeSplitDoModal(): void {
    this.isSplitDoModalOpen = false;
    this.splittingDo = null;
    this.splittingShipment = null;
    this.resetDoPicker();
  }

  //  Ticked destination DOs, without the DO being split itself.
  get splitTargets(): Type.ResultProcessJobShipment[] {
    const doNo = this.splittingDo?.doNo;
    return [...this.selectedDoNos.values()].filter((o) => o.deliveryno !== doNo);
  }

  //  Qty split off = the sum of the ticked DOs' qty.
  get splitQty(): number {
    return this.splitTargets.reduce((sum, o) => sum + (Number(o.qty) || 0), 0);
  }

  get splitRemainingQty(): number {
    return Math.max(0, (this.splittingDo?.qty || 0) - this.splitQty);
  }

  confirmSplitDo(): void {
    const doItem = this.splittingDo;
    const shipment = this.splittingShipment;
    if (!doItem || !shipment) return;

    const targets = this.splitTargets;
    if (targets.length === 0) {
      this.notify({ icon: 'warning', title: 'กรุณาเลือก DO ปลายทาง', text: `เลือก DO อื่นที่ไม่ใช่ ${doItem.doNo}` });
      return;
    }
    const qty = this.splitQty;
    if (qty <= 0 || qty >= doItem.qty) {
      this.notify({
        icon: 'warning',
        title: 'แยก DO ไม่ได้',
        text: `Qty รวมของ DO ที่เลือก (${qty.toLocaleString()} kg) ต้องมากกว่า 0 และน้อยกว่า ${doItem.qty.toLocaleString()} kg`,
      });
      return;
    }

    this.notify({
      title: `ยืนยันแยก DO ไป ${targets.length} DO?`,
      html:
        `แยก <strong>${qty.toLocaleString()}</strong> kg จาก DO <strong>${doItem.doNo}</strong>` +
        `<br>ไปยัง ${targets
          .map((o) => `<strong>${o.deliveryno}</strong> (${o.shipmentno} · ${(Number(o.qty) || 0).toLocaleString()} kg)`)
          .join(', ')}` +
        `<br>DO เดิมคงเหลือ ${this.splitRemainingQty.toLocaleString()} kg`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'แยก DO',
      cancelButtonText: 'ยกเลิก',
      confirmButtonColor: '#7c3aed',
    }).then((result) => {
      if (!result.isConfirmed) return;
      this.closeSplitDoModal();
      this.notify({ icon: 'info', title: 'ยังไม่ได้เชื่อมต่อ API', text: 'ปุ่มแยก DO ยังไม่ได้ส่งข้อมูลไปที่ระบบ' });
    });
  }

  // -------------------------------------------------------------
  // ส่ง 251 / DO Preparing (per DO)
  // UI only for now: the existing endpoints (WMS251 on job approve,
  // PATCH do-preparing) work on a Picking job item id, which these DOs
  // don't have yet -- so these confirm, then say it isn't connected.
  // -------------------------------------------------------------
  sendDo251(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.notify({
      title: 'ยืนยันส่ง 251?',
      html: `ส่ง FG Issue (251) ของ DO <strong>${doItem.doNo}</strong><br>Shipment <strong>${shipment.shipmentNo}</strong>`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'ส่ง 251',
      cancelButtonText: 'ยกเลิก',
      confirmButtonColor: '#16a34a',
    }).then((result) => {
      if (!result.isConfirmed) return;
      this.notify({ icon: 'info', title: 'ยังไม่ได้เชื่อมต่อ API', text: 'ปุ่มส่ง 251 ยังไม่ได้ส่งข้อมูลไปที่ระบบ' });
    });
  }

  openDoPreparing(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.notify({
      icon: 'info',
      title: 'DO Preparing',
      html: `DO <strong>${doItem.doNo}</strong> · Shipment <strong>${shipment.shipmentNo}</strong><br>ยังไม่ได้เชื่อมต่อ API`,
    });
  }

  // Ticked DOs of one shipment (bulk actions in its DO sub-header).
  checkedDosOf(shipment: Type.ShipmentManagementItem): Type.DeliveryOrderItem[] {
    return shipment.dos.filter((d) => this.checkedDoIds.has(d.id));
  }

  bulkSend251(shipment: Type.ShipmentManagementItem): void {
    const dos = this.checkedDosOf(shipment);
    if (dos.length === 0) return;
    this.notify({
      title: `ยืนยันส่ง 251 ${dos.length} DO?`,
      html: `Shipment <strong>${shipment.shipmentNo}</strong><br>${dos.map((d) => d.doNo).join(', ')}`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'ส่ง 251',
      cancelButtonText: 'ยกเลิก',
      confirmButtonColor: '#16a34a',
    }).then((result) => {
      if (!result.isConfirmed) return;
      this.notify({ icon: 'info', title: 'ยังไม่ได้เชื่อมต่อ API', text: 'ปุ่มส่ง 251 ยังไม่ได้ส่งข้อมูลไปที่ระบบ' });
    });
  }

  bulkDoPreparing(shipment: Type.ShipmentManagementItem): void {
    const dos = this.checkedDosOf(shipment);
    if (dos.length === 0) return;
    this.notify({
      icon: 'info',
      title: `DO Preparing (${dos.length} DO)`,
      html: `${dos.map((d) => d.doNo).join(', ')} · Shipment <strong>${shipment.shipmentNo}</strong><br>ยังไม่ได้เชื่อมต่อ API`,
    });
  }

  bulkDeleteDos(shipment: Type.ShipmentManagementItem): void {
    const dos = this.checkedDosOf(shipment);
    if (dos.length === 0) return;
    this.notify({
      title: `ยืนยันการลบ ${dos.length} DO?`,
      html: `ลบ ${dos.map((d) => '<strong>' + d.doNo + '</strong>').join(', ')}<br>ออกจาก Shipment <strong>${shipment.shipmentNo}</strong> ใช่หรือไม่?`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#dc2626',
      cancelButtonColor: '#64748b',
      confirmButtonText: 'ใช่, ลบรายการ',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (!result.isConfirmed) return;
      this.deleteDos(dos.map((d) => d.id), `ลบ ${dos.length} DO สำเร็จ`);
    });
  }

  // -------------------------------------------------------------
  // Delete DO (ลบ DO)
  // -------------------------------------------------------------
  confirmDeleteDo(shipment: Type.ShipmentManagementItem, doItem: Type.DeliveryOrderItem): void {
    this.notify({
      title: 'ยืนยันการลบ DO?',
      html: `คุณต้องการลบ DO: <strong>${doItem.doNo}</strong> (${doItem.grade} - ${doItem.qty.toLocaleString()} kg)<br>ออกจาก Shipment <strong>${shipment.shipmentNo}</strong> ใช่หรือไม่?`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#dc2626',
      cancelButtonColor: '#64748b',
      confirmButtonText: 'ใช่, ลบรายการ',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (result.isConfirmed) this.deleteDos([doItem.id], 'ลบ DO สำเร็จ', `ลบรายการ ${doItem.doNo} เรียบร้อยแล้ว`);
    });
  }

  //  PATCH shipment-management/deliveries/delete (soft delete, all-or-nothing;
  //  refused when a DO already has a picking job).
  private deleteDos(ids: number[], successTitle: string, successText?: string): void {
    this.crudService.processDeleteShipmentMgmtDeliveries(ids).subscribe({
      next: () => {
        ids.forEach((id) => this.checkedDoIds.delete(id));
        this.applyFilter();
        this.notify({ icon: 'success', title: successTitle, text: successText, timer: 1500, showConfirmButton: false });
      },
      error: (err) => this.notify({ icon: 'error', title: 'ลบ DO ไม่สำเร็จ', text: this.apiErrorText(err) }),
    });
  }

  // -------------------------------------------------------------
  // Create Shipment
  // -------------------------------------------------------------
  openCreateShipmentModal(): void {
    this.createShipmentForm = {
      shipmentNo: `SHP-${Date.now().toString().slice(-8)}`,
      licensePlate: '70-9988 ระยอง',
      carrierName: 'บจก. ไออาร์พีซี โลจิสติกส์',
      driverName: 'สมศักดิ์ ขยันยิ่ง',
      whCode: 'MWH',
      plantCode: '1100',
      statusId: 2,
      loadingDate: new Date(),
    };
    this.isCreateShipmentModalOpen = true;
  }

  closeCreateShipmentModal(): void {
    this.isCreateShipmentModalOpen = false;
  }

  saveCreateShipment(): void {
    const sNo = this.createShipmentForm.shipmentNo.trim();
    if (!sNo) {
      this.notify({ icon: 'warning', title: 'กรุณาระบุเลขที่ Shipment' });
      return;
    }

    const exists = this.allShipments.some((s) => s.shipmentNo.toLowerCase() === sNo.toLowerCase());
    if (exists) {
      this.notify({ icon: 'warning', title: 'เลขที่ Shipment นี้มีอยู่ในระบบแล้ว' });
      return;
    }

    const statusOpt = this.getStatusOption(Number(this.createShipmentForm.statusId));
    const newShipment: Type.ShipmentManagementItem = {
      id: Date.now(),
      shipmentNo: sNo,
      driverName: this.createShipmentForm.driverName.trim(),
      licensePlate: this.createShipmentForm.licensePlate.trim(),
      carrierName: this.createShipmentForm.carrierName.trim(),
      statusId: statusOpt.id,
      statusName: statusOpt.name,
      loadingDate: new Date(this.createShipmentForm.loadingDate).toISOString(),
      whCode: this.createShipmentForm.whCode,
      plantCode: this.createShipmentForm.plantCode,
      dos: [],
      expanded: true,
    };

    this.allShipments.unshift(newShipment);
    this.closeCreateShipmentModal();
    this.applyFilter();

    this.notify({
      icon: 'success',
      title: 'สร้าง Shipment สำเร็จ',
      text: `Shipment: ${newShipment.shipmentNo} พร้อมให้เพิ่มรายการ DO`,
      timer: 1800,
      showConfirmButton: false,
    });
  }
}
