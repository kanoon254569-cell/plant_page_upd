import { Component } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';

interface LoadingListFilter {
  systemNo: string;
  dateFrom: Date | null;
  dateTo: Date | null;
  docks: string[];
  vehicle: string;
  statusIds: number[];
  page: number;
  pageSize: number;
}

//  Date range starts on today (both ends), so the page opens on today's jobs.
function defaultFilter(): LoadingListFilter {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return { systemNo: '', dateFrom: today, dateTo: new Date(today), docks: [], vehicle: '', statusIds: [], page: 1, pageSize: 25 };
}

//  SP02 - Loading List. Own page and own API (GET process/job/loading?wh=,
//  pProcessGetLoadingJobs list mode -- sql/119), separate from SP01
//  (job-shipping-list = JobList + pProcessGetJobList). Looks like the job
//  list: it reuses job-list.css and the same card markup.
//  The API returns every Loading job with status 1/2/4/5 (called without wh);
//  search / date / dock / status / paging run here on the client.
@Component({
  selector: 'app-job-loading-list',
  standalone: false,
  templateUrl: './job-loading-list.html',
  styleUrls: ['../job-list/job-list.css', './job-loading-list.css'],
})
export class JobLoadingList {
  constructor(private crudService: CrudService) {}

  //  Same status list as job-list on SP01: GET process-cb/job-status with
  //  userType 5 (pProcessCBGetJobStatus, ct_job_status, Thai names).
  statusOptions: Type.ResultProcessGetOptionsJobStatus[] = [];

  filter: LoadingListFilter = defaultFilter();

  //  "เรียงตาม" -- same options as job-list, sorted here on the client.
  //  '' = default: urgent first, then newest job (the API's id DESC).
  readonly sortOptions: { value: string; label: string }[] = [
    { value: '', label: 'ค่าเริ่มต้น' },
    { value: 'create_datetime:DESC', label: 'วันที่สร้าง ใหม่ - เก่า' },
    { value: 'create_datetime:ASC', label: 'วันที่สร้าง เก่า - ใหม่' },
    { value: 'system_no:ASC', label: 'เลขที่ใบงาน A - Z' },
    { value: 'system_no:DESC', label: 'เลขที่ใบงาน Z - A' },
    { value: 'status_id:ASC', label: 'สถานะ เริ่มต้น - เสร็จสิ้น' },
    { value: 'status_id:DESC', label: 'สถานะ เสร็จสิ้น - เริ่มต้น' },
  ];
  sortValue = '';

  get sortLabel(): string {
    return this.sortOptions.find((option) => option.value === this.sortValue)?.label ?? '';
  }

  onSelectSort(value: string) {
    this.sortValue = value;
    this.filter.page = 1;
    this.saveFilter();
    this.applyFilter();
  }

  private compareJobs(a: Type.LoadingJob, b: Type.LoadingJob): number {
    const [key, order] = this.sortValue.split(':');
    const dir = order === 'ASC' ? 1 : -1;
    switch (key) {
      case 'create_datetime': {
        const ta = this.parseJobDate(a.create_datetime)?.getTime() ?? 0;
        const tb = this.parseJobDate(b.create_datetime)?.getTime() ?? 0;
        return (ta - tb) * dir || (a.id - b.id) * dir;
      }
      case 'system_no':
        return (a.system_no || '').localeCompare(b.system_no || '') * dir || b.id - a.id;
      case 'status_id':
        return (a.status_id - b.status_id) * dir || b.id - a.id;
      default: {
        const ua = a.is_urgent === 'Y' ? 0 : 1;
        const ub = b.is_urgent === 'Y' ? 0 : 1;
        return ua - ub || b.id - a.id;
      }
    }
  }

  //  Dock names (eg. 38D01) from master/location/dock -- the same
  //  IRPC.dbo.ct_strorage_dock the Loading job's GET location points to.
  dockOptions: string[] = [];

  private allJobs: Type.LoadingJob[] = [];
  filteredJobs: Type.LoadingJob[] = [];
  pagedJobs: Type.LoadingJob[] = [];
  //  Job whose DO items show in #loadingJobItemsModal ("+ อีก N รายการ").
  selectedJob: Type.LoadingJob | null = null;

  isLoading = false;
  readonly skeletonRows = Array.from({ length: 6 });

  async ngOnInit() {
    this.restoreFilter();
    this.loadDockOptions();
    this.loadStatusOptions();
    await this.loadJobs();
  }

  //  Saved filter -- the last searched filter is kept in sessionStorage and
  //  restored on the next visit (same as job-wh-transfer-list.ts).
  private readonly filterStorageKey = 'job-loading-list-filter';

  private saveFilter() {
    const saved = {
      systemNo: this.filter.systemNo ?? '',
      dateFrom: this.formatFilterDate(this.filter.dateFrom),
      dateTo: this.formatFilterDate(this.filter.dateTo),
      docks: this.filter.docks ?? [],
      vehicle: this.filter.vehicle ?? '',
      statusIds: this.filter.statusIds ?? [],
      sortValue: this.sortValue,
      pageSize: this.filter.pageSize ?? 25,
    };
    try {
      sessionStorage.setItem(this.filterStorageKey, JSON.stringify(saved));
    } catch {
      //  Storage blocked/full -- the filter just isn't remembered.
    }
  }

  private restoreFilter() {
    let saved: any = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(this.filterStorageKey) || 'null');
    } catch {
      saved = null;
    }
    if (!saved || typeof saved !== 'object') return;

    const strings = (value: unknown): string[] =>
      Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];

    this.filter = {
      ...this.filter,
      systemNo: typeof saved.systemNo === 'string' ? saved.systemNo : '',
      //  '' = searched without that date; a missing key keeps today.
      dateFrom: saved.dateFrom === '' ? null : (this.fromFilterDate(saved.dateFrom) ?? this.filter.dateFrom),
      dateTo: saved.dateTo === '' ? null : (this.fromFilterDate(saved.dateTo) ?? this.filter.dateTo),
      docks: strings(saved.docks),
      vehicle: typeof saved.vehicle === 'string' ? saved.vehicle : '',
      statusIds: Array.isArray(saved.statusIds)
        ? saved.statusIds.filter((id: unknown): id is number => typeof id === 'number')
        : [],
      page: 1,
      pageSize: typeof saved.pageSize === 'number' && saved.pageSize > 0 ? saved.pageSize : this.filter.pageSize,
    };
    if (typeof saved.sortValue === 'string' && this.sortOptions.some((o) => o.value === saved.sortValue)) {
      this.sortValue = saved.sortValue;
    }
  }

  //  yyyy-MM-dd in local time ('' = no date).
  private formatFilterDate(value: Date | null | undefined): string {
    if (!value) return '';
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`;
  }

  private fromFilterDate(value: unknown): Date | null {
    if (typeof value !== 'string') return null;
    const m = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!m) return null;
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    return isNaN(d.getTime()) ? null : d;
  }

  private async loadStatusOptions() {
    try {
      const result = await firstValueFrom(this.crudService.ProcessGetOptionsJobStatus(5));
      this.statusOptions = result?.data ?? [];
    } catch (error) {
      console.error('Error fetching job status options:', error);
      this.statusOptions = [];
    }
  }

  private async loadDockOptions() {
    try {
      const result = await firstValueFrom(this.crudService.processGetDockLocation('', '', '', ''));
      const names = (result?.data ?? []).map((d) => d.location_desc).filter(Boolean);
      this.dockOptions = Array.from(new Set(names)).sort();
    } catch (error) {
      console.error('Error fetching dock options:', error);
      this.dockOptions = [];
    }
  }

  async loadJobs() {
    this.isLoading = true;
    this.saveFilter();
    try {
      const result = await firstValueFrom(this.crudService.processGetLoadingJobList(''));
      this.allJobs = result?.data ?? [];
    } catch (error) {
      //  The API answers 404 when the proc reports no success -- show empty.
      console.error('Error loading loading-job list:', error);
      this.allJobs = [];
    } finally {
      this.isLoading = false;
      this.applyFilter();
    }
  }

  applyFilter() {
    const systemNo = this.filter.systemNo.trim().toLowerCase();
    const has = (value: string | null | undefined, text: string) =>
      !!value && value.toLowerCase().includes(text);
    const statuses = this.filter.statusIds;
    const docks = this.filter.docks;
    const vehicle = this.filter.vehicle.trim().toLowerCase();
    const from = this.startOfDay(this.filter.dateFrom);
    const to = this.startOfDay(this.filter.dateTo ?? this.filter.dateFrom);
    this.filteredJobs = this.allJobs.filter((job) => {
      if (statuses.length && !statuses.includes(job.status_id)) return false;
      //  Dock: the job matches when any of its GET docks is picked.
      if (docks.length && !this.dockNames(job).some((d) => docks.includes(d))) return false;
      //  Vehicle: the full plate (716677รย) or the PUT location name
      //  (111355|716677); a job with no vehicle yet drops out while filled.
      if (
        vehicle &&
        !has(job.to_vehicle_plate, vehicle) &&
        !has(this.firstLocationName(job, 'to_locations'), vehicle)
      )
        return false;
      if (from !== null && to !== null) {
        const created = this.startOfDay(this.parseJobDate(job.create_datetime));
        if (created === null || created < from || created > to) return false;
      }
      if (systemNo && !has(job.system_no, systemNo)) return false;
      return true;
    });
    this.filteredJobs.sort((a, b) => this.compareJobs(a, b));
    this.slicePage();
  }

  private slicePage() {
    const maxPage = Math.max(1, Math.ceil(this.filteredJobs.length / this.filter.pageSize));
    if (this.filter.page > maxPage) this.filter.page = maxPage;
    const start = (this.filter.page - 1) * this.filter.pageSize;
    this.pagedJobs = this.filteredJobs.slice(start, start + this.filter.pageSize);
  }

  onClickSearch() {
    this.filter.page = 1;
    this.loadJobs();
  }

  resetFilter() {
    this.filter = defaultFilter();
    this.loadJobs();
  }

  onPageEvent(event: PageEvent) {
    this.filter.page = event.pageIndex + 1;
    if (this.filter.pageSize !== event.pageSize) {
      this.filter.pageSize = event.pageSize;
      this.saveFilter();
    }
    this.slicePage();
  }

  private startOfDay(value: Date | null | undefined): number | null {
    if (!value) return null;
    return new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
  }

  statusLabels(): string[] {
    return this.statusOptions
      .filter((o) => this.filter.statusIds.includes(o.id))
      .map((o) => o.name_th || o.name);
  }

  //  Same classes as JobList.jobStatusClass (job-list.css status colors).
  jobStatusClass(statusId?: number | null): string {
    switch (statusId) {
      case 1: return 'pending';
      case 2: return 'wh-approved';
      case 3: return 'sp-approve';
      case 4: return 'in-progress';
      case 5: return 'complete';
      case 6: return 'mapping-do';
      default: return '';
    }
  }

  //  Lots of a DO item: its own lot_no, else the distinct lots on its GET
  //  docks (from_locations[].addon_lot). null when there are none.
  itemLots(item: Type.LoadingJobItem | null | undefined): string[] | null {
    if (!item) return null;
    if (item.lot_no) return [item.lot_no];
    const lots = new Set<string>();
    for (const loc of item.locations?.from_locations ?? []) {
      for (const a of loc?.addon_lot ?? []) {
        if (a?.lot) lots.add(String(a.lot));
      }
    }
    return lots.size ? Array.from(lots) : null;
  }

  //  Non-empty values joined with " · " (shipment strip under the card).
  joinText(values: (string | null | undefined)[]): string {
    return values.map((v) => (v ?? '').trim()).filter(Boolean).join(' · ');
  }

  //  Dock / vehicle names sit on the item locations (from = DOCK, to = VEHICLE).
  //  Every GET dock of the job (a DO can be split over several docks, eg.
  //  38D01 + 38D02), distinct, in item order. The card shows the first +N.
  dockNames(job: Type.LoadingJob): string[] {
    const names = new Set<string>();
    for (const item of job.items) {
      for (const loc of item.locations?.from_locations ?? []) {
        const name = loc?.location_name ?? loc?.name;
        if (name) names.add(String(name));
      }
    }
    if (!names.size && job.from_location_cc_code) names.add(job.from_location_cc_code);
    return Array.from(names);
  }

  dockName(job: Type.LoadingJob): string {
    return this.dockNames(job)[0] || '-';
  }

  //  Full plate (to_vehicle_plate, eg. 716677รย), else the PUT location
  //  name (111355|716677) from an API without sql/133. '' = no vehicle yet
  //  (the card then shows "ยังไม่มีรถ", like SPC01's "ยังไม่สแกน location").
  vehicleName(job: Type.LoadingJob): string {
    return (job.to_vehicle_plate ?? '').trim() || this.firstLocationName(job, 'to_locations');
  }

  private firstLocationName(job: Type.LoadingJob, key: 'from_locations' | 'to_locations'): string {
    for (const item of job.items) {
      for (const loc of item.locations?.[key] ?? []) {
        const name = loc?.location_name ?? loc?.name;
        if (name) return String(name);
      }
    }
    return '';
  }

  receivePercent(job: Type.LoadingJob): number {
    if (!job.total_qty) return 0;
    return Math.min(100, (job.receive_qty / job.total_qty) * 100);
  }

  completePercent(job: Type.LoadingJob): number {
    if (!job.total_qty) return 0;
    return Math.min(100, (job.complete_qty / job.total_qty) * 100);
  }

  //  Same output as JobList.formatDateEnd / formatDuration.
  formatDateEnd(dateStart?: string | null, dateEnd?: string | null): string {
    if (!dateStart && !dateEnd) return '-';
    if (dateStart && !dateEnd) return 'Now';
    const endDate = this.parseJobDate(dateEnd);
    if (!endDate) return '-';
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${pad(endDate.getDate())}/${pad(endDate.getMonth() + 1)}/${endDate.getFullYear()} ${pad(endDate.getHours())}:${pad(endDate.getMinutes())}:${pad(endDate.getSeconds())}`;
  }

  formatDuration(start?: string | null, end?: string | null): string {
    if (!start) return '-';
    const startDate = this.parseJobDate(start);
    const endDate = end ? this.parseJobDate(end) : new Date();
    if (!startDate || !endDate) return '-';
    const diff = endDate.getTime() - startDate.getTime();
    if (diff < 0) return '-';

    const totalSeconds = Math.floor(diff / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const parts: string[] = [];
    if (hours > 0) parts.push(`${hours} ชม.`);
    if (minutes > 0 || hours > 0) parts.push(`${minutes} นาที`);
    parts.push(`${totalSeconds % 60} วินาที`);
    return parts.join(' ');
  }

  //  API dates: ISO, or d/m/yyyy HH:mm:ss with a Buddhist-Era year (same
  //  parser as job-list / transaction-log).
  parseJobDate(value?: string | Date | null): Date | null {
    if (!value) return null;
    if (value instanceof Date) return isNaN(value.getTime()) ? null : value;

    const trimmed = value.trim();
    const m = trimmed.match(
      /^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/,
    );
    if (m) {
      let year = parseInt(m[3], 10);
      if (year < 100) year += 2000;
      if (year > 2400) year -= 543;
      const d = new Date(
        year,
        parseInt(m[2], 10) - 1,
        parseInt(m[1], 10),
        m[4] ? parseInt(m[4], 10) : 0,
        m[5] ? parseInt(m[5], 10) : 0,
        m[6] ? parseInt(m[6], 10) : 0,
      );
      return isNaN(d.getTime()) ? null : d;
    }

    const iso = new Date(trimmed);
    return isNaN(iso.getTime()) ? null : iso;
  }
}
