import { Component, HostListener } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';

function defaultFilter(): Type.WmsInterfaceLogFilter {
  return {
    mode: '',
    keyword: '',
    status: '',
    page: 1,
    pageSize: 25,
  };
}

function emptySummary(): Type.ResultProcessWmsInterfaceLogSummary {
  return {
    total_round: 0,
    success_round: 0,
    error_round: 0,
    pending_round: 0,
    total_qr: 0,
    success_qr: 0,
  };
}

function startOfToday(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

interface QrGroup {
  pallet_no: number;
  items: Type.ResultProcessWmsInterfaceLogQr[];
}

//  tr_wms_interface_log viewer: every call this system made to WMS
//  (FR001 InsertPalletConfirm / FR002 ConfirmLocation / FR004 CheckTotalPallet)
//  with the QR (= bag) count of each round. Searching a transfer slip no.
//  shows how many bags WMS accepted for it.
@Component({
  selector: 'app-wms-interface-log',
  standalone: false,
  templateUrl: './wms-interface-log.html',
  styleUrls: ['../transaction-log/transaction-log.css', './wms-interface-log.css'],
})
export class WmsInterfaceLog {
  constructor(private crudService: CrudService) {}

  displayedColumns: string[] = [
    'expand',
    'no',
    'sentDate',
    'mode',
    'trTranNo',
    'gradeLot',
    'pallet',
    'qrCount',
    'qty',
    'status',
    'message',
    'duration',
  ];

  //  Detail modal: opened by clicking a row, detail fetched on open and
  //  cached by id.
  selectedRow: Type.ResultProcessWmsInterfaceLogData | null = null;
  detailCache = new Map<number, Type.ResponseProcessWmsInterfaceLogDetail>();
  detailLoadingId: number | null = null;

  //  Skeleton loading -- summary numbers + table rows while the log list
  //  loads, info strip / tabs / pallet rows while a detail loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });
  readonly skeletonDetailCells = Array.from({ length: 5 });
  readonly skeletonDetailTabs = Array.from({ length: 3 });
  readonly skeletonDetailRows = Array.from({ length: 4 });
  detailError = '';
  activeTab: 'pallet' | 'qr' | 'json' = 'pallet';
  qrGroupCache = new WeakMap<Type.ResponseProcessWmsInterfaceLogDetail, QrGroup[]>();
  readonly bagsPerPallet = 40;

  optionsMode = [
    { value: '', label: 'ทั้งหมด' },
    { value: 'FR001', label: 'FR001 - InsertPalletConfirm' },
    { value: 'FR002', label: 'FR002 - ConfirmLocation' },
    { value: 'FR004', label: 'FR004 - CheckTotalPallet' },
  ];

  optionsStatus = [
    { value: '', label: 'ทั้งหมด' },
    { value: 'success', label: 'Success' },
    { value: 'error', label: 'Error' },
    { value: 'pending', label: 'Pending' },
  ];

  logList: Type.ResultProcessWmsInterfaceLogData[] = [];
  totalCount = 0;
  summary: Type.ResultProcessWmsInterfaceLogSummary = emptySummary();
  //  Shown instead of the "no data" state when the API call itself fails
  //  (e.g. the API in environment.baseAPIURL has no wms-interface-log yet).
  loadError = '';

  filter: Type.WmsInterfaceLogFilter = defaultFilter();
  //  Date range on create_datetime, today by default (and after Clear).
  //  Only a start date picked = that day only.
  dateFrom: Date | null = startOfToday();
  dateTo: Date | null = startOfToday();

  async ngOnInit() {
    await this.loadLog();
  }

  //  Same date handling as Transaction Log: the real backend returns
  //  d/m/yyyy HH:mm:ss with a Buddhist-Era year, which the date pipe can't parse.
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

  toDateText(value: Date | null): string {
    if (!value) return '';

    const date = new Date(value);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');

    return `${year}-${month}-${day}`;
  }

  async loadLog() {
    this.isLoading = true;
    try {
      const result = await firstValueFrom(
        this.crudService.processGetWmsInterfaceLog(
          this.filter.mode || '',
          this.filter.keyword || '',
          this.filter.status || '',
          this.toDateText(this.dateFrom),
          this.toDateText(this.dateTo ?? this.dateFrom),
          this.filter.page || 1,
          this.filter.pageSize || 25,
        ),
      );
      this.logList = result.data ?? [];
      this.totalCount = result.total_count ?? 0;
      //  SUM() over no rows comes back NULL (error/pending cards showed a
      //  blank number) -- fall back to 0 per field.
      const s: Partial<Type.ResultProcessWmsInterfaceLogSummary> = result.summary?.[0] ?? {};
      this.summary = {
        total_round: s.total_round ?? 0,
        success_round: s.success_round ?? 0,
        error_round: s.error_round ?? 0,
        pending_round: s.pending_round ?? 0,
        total_qr: s.total_qr ?? 0,
        success_qr: s.success_qr ?? 0,
      };
      this.loadError = '';
      this.selectedRow = null;
    } catch (error: any) {
      console.error('Error fetching WMS interface log:', error);
      this.loadError = `โหลดข้อมูลไม่สำเร็จ (HTTP ${error?.status ?? '-'}) ${error?.error?.message ?? ''}`.trim();
      this.logList = [];
      this.totalCount = 0;
      this.summary = emptySummary();
    } finally {
      this.isLoading = false;
    }
  }

  onClickSearch() {
    this.filter.page = 1;
    this.loadLog();
  }

  resetFilter() {
    this.filter = defaultFilter();
    this.dateFrom = startOfToday();
    this.dateTo = startOfToday();
    this.loadLog();
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadLog();
  }

  statusClass(status: string): string {
    switch (status) {
      case 'success':
        return 'status-chip status-chip--success';
      case 'error':
        return 'status-chip status-chip--error';
      default:
        return 'status-chip status-chip--pending';
    }
  }

  @HostListener('document:keydown.escape')
  closeDetail() {
    this.selectedRow = null;
  }

  async openDetail(row: Type.ResultProcessWmsInterfaceLogData) {
    this.selectedRow = row;
    this.activeTab = 'pallet';
    this.detailError = '';
    if (this.detailCache.has(row.id)) return;

    this.detailLoadingId = row.id;
    try {
      const result = await firstValueFrom(this.crudService.processGetWmsInterfaceLogDetail(row.id));
      this.detailCache.set(row.id, result);
    } catch (error: any) {
      console.error('Error fetching WMS interface log detail:', error);
      this.detailError = `โหลดรายละเอียดไม่สำเร็จ (HTTP ${error?.status ?? '-'})`;
    } finally {
      this.detailLoadingId = null;
    }
  }

  get expandedDetail(): Type.ResponseProcessWmsInterfaceLogDetail | undefined {
    return this.selectedRow ? this.detailCache.get(this.selectedRow.id) : undefined;
  }

  //  QR tab shows one line per pallet with only the bag numbers, which reads
  //  far easier than 200 "P89-18" chips. Grouped once per detail.
  qrGroups(detail: Type.ResponseProcessWmsInterfaceLogDetail): QrGroup[] {
    let groups = this.qrGroupCache.get(detail);
    if (!groups) {
      const byPallet = new Map<number, Type.ResultProcessWmsInterfaceLogQr[]>();
      for (const q of detail.qr_list ?? []) {
        const list = byPallet.get(q.pallet_no) ?? [];
        list.push(q);
        byPallet.set(q.pallet_no, list);
      }
      groups = [...byPallet.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([pallet_no, items]) => ({ pallet_no, items }));
      this.qrGroupCache.set(detail, groups);
    }
    return groups;
  }

  //  Grade/Lot column in the pallet table only when pallets differ --
  //  a single grade/lot is already shown in the modal header tags.
  mixedGradeLot(detail: Type.ResponseProcessWmsInterfaceLogDetail): boolean {
    const keys = new Set((detail.pallets ?? []).map((p) => `${p.grade}|${p.lot}`));
    return keys.size > 1;
  }

  //  Width of the pallet fill bar, 40 bags = one full pallet.
  palletFill(p: Type.ResultProcessWmsInterfaceLogPallet): number {
    return Math.min(100, Math.round((p.qr_count / this.bagsPerPallet) * 100));
  }

  resentCount(detail: Type.ResponseProcessWmsInterfaceLogDetail): number {
    return (detail.qr_list ?? []).filter((q) => q.sent_before_id !== null).length;
  }

  missingTotal(detail: Type.ResponseProcessWmsInterfaceLogDetail): number {
    return (detail.pallets ?? []).reduce((sum, p) => sum + (p.missing_bag ?? 0), 0);
  }

  palletRange(row: Type.ResultProcessWmsInterfaceLogData): string {
    if (row.pallet_from === null || row.pallet_from === undefined) return '-';
    return row.pallet_from === row.pallet_to
      ? String(row.pallet_from)
      : `${row.pallet_from} - ${row.pallet_to}`;
  }

  prettyJson(value: string | null | undefined): string {
    if (!value) return '-';
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return value;
    }
  }

  copyText(value: string | null | undefined) {
    if (!value) return;
    navigator.clipboard?.writeText(this.prettyJson(value)).catch(() => {});
  }

  formatDuration(ms: number | null | undefined): string {
    if (ms === null || ms === undefined) return '-';
    return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(2)} s`;
  }
}
