import { Component } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';

interface LoadingListFilter {
  shipmentNo: string;
  doNo: string;
  dateFrom: Date | null;
  dateTo: Date | null;
  docks: string[];
  statusIds: number[];
  page: number;
  pageSize: number;
}

function defaultFilter(): LoadingListFilter {
  return { shipmentNo: '', doNo: '',dateFrom: null, dateTo: null, docks: [],statusIds: [], page: 1, pageSize: 25 };
}

//  SP02 - Loading List. Own page and own API (GET process/job/loading?wh=,
//  pProcessGetLoadingJobs list mode -- sql/119), separate from SP01
//  (job-shipping-list = JobList + pProcessGetJobList). Looks like the job
//  list: it reuses job-list.css and the same card markup.
//  The API returns every Loading job with status 2/4/5 (called without wh);
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
    this.expandedJobId = null;
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
  expandedJobId: number | null = null;

  isLoading = false;
  readonly skeletonRows = Array.from({ length: 6 });

  async ngOnInit() {
    this.loadDockOptions();
    this.loadStatusOptions();
    await this.loadJobs();
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
    const shipmentNo = this.filter.shipmentNo.trim().toLowerCase();
    const doNo = this.filter.doNo.trim().toLowerCase();
    const has = (value: string | null | undefined, text: string) =>
      !!value && value.toLowerCase().includes(text);
    const statuses = this.filter.statusIds;
    const docks = this.filter.docks;
    const from = this.startOfDay(this.filter.dateFrom);
    const to = this.startOfDay(this.filter.dateTo ?? this.filter.dateFrom);
    this.filteredJobs = this.allJobs.filter((job) => {
      if (statuses.length && !statuses.includes(job.status_id)) return false;
      if (docks.length && !docks.includes(this.dockName(job))) return false;
      if (from !== null && to !== null) {
        const created = this.startOfDay(this.parseJobDate(job.create_datetime));
        if (created === null || created < from || created > to) return false;
      }
      if (shipmentNo && !has(job.system_no, shipmentNo)) return false;
      if (doNo && !job.items.some((i) => has(i.do_no, doNo))) return false;
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
    this.expandedJobId = null;
    this.loadJobs();
  }

  resetFilter() {
    this.filter = defaultFilter();
    this.expandedJobId = null;
    this.loadJobs();
  }

  onPageEvent(event: PageEvent) {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.expandedJobId = null;
    this.slicePage();
  }

  toggleExpand(job: Type.LoadingJob) {
    this.expandedJobId = this.expandedJobId === job.id ? null : job.id;
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

  doNumbers(job: Type.LoadingJob): string {
    const list = Array.from(new Set(job.items.map((i) => i.do_no).filter(Boolean)));
    return list.length ? list.join(', ') : '-';
  }

  //  Dock / vehicle names sit on the item locations (from = DOCK, to = VEHICLE).
  dockName(job: Type.LoadingJob): string {
    return this.firstLocationName(job, 'from_locations') || job.from_location_cc_code || '-';
  }

  vehicleName(job: Type.LoadingJob): string {
    return this.firstLocationName(job, 'to_locations') || job.to_vehicle_desc || '-';
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
