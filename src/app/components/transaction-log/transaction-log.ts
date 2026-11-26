import { Component } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import * as XLSX from 'xlsx';

function defaultFilter(): Type.TransactionLogFilter {
  return {
    topic: '',
    activity: '',
    editor: 0,
    detail: '',
    modifiedDate: '',
    page: 1,
    pageSize: 25,
  };
}

@Component({
  selector: 'app-transaction-log',
  standalone: false,
  templateUrl: './transaction-log.html',
  styleUrl: './transaction-log.css',
})
export class TransactionLog {
  //  Constructor
  constructor(
    private crudService: CrudService,
    private sanitizer: DomSanitizer,
  ) {}

  //  Define Column
  displayedColumns: string[] = ['no', 'topic', 'activity', 'detail', 'editor', 'modifiedDate'];

  //  API dates come back either as ISO (local/mock backend) or as
  //  d/m/yyyy HH:mm:ss with a Buddhist-Era year (real qas-qtrack backend,
  //  e.g. "28/8/2569 7:52:16" for 2026-08-28) -- Angular's `date` pipe
  //  can't parse the latter and throws NG02100, which is why row.create_datetime
  //  renders as '-'/crashes only once deployed against the real API.
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

  transactionLogList: Type.ResultProcessTransactionLogData[] = [];
  totalCount = 0;
  isExportingExcel = false;

  //  Skeleton loading -- table shows shimmer rows while the log list loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  //  Filter Form
  filter: Type.TransactionLogFilter = defaultFilter();

  //  Modified Date (bound to the mat-datepicker; converted to a yyyy-MM-dd
  //  string in `modifiedDateText` before being sent to the API).
  modifiedDate: Date | null = null;

  optionsEditor: Type.ResultProcessGetUser[] = [];

  //  ngOnInit
  async ngOnInit() {
    await this.loadTransactionLog();

    this.optionsEditor = (await this.fetchOptionEditor()).data;
  }

  get modifiedDateText(): string {
    if (!this.modifiedDate) return '';

    const date = new Date(this.modifiedDate);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');

    return `${year}-${month}-${day}`;
  }

  //  Load Transaction Log List
  async loadTransactionLog() {
    this.isLoading = true;
    try {
      const result = await this.fetchTransactionLog();
      this.transactionLogList = result.data;
      this.totalCount = result.total_count;
    } finally {
      this.isLoading = false;
    }
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;
    this.loadTransactionLog();
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = defaultFilter();
    this.modifiedDate = null;
    this.loadTransactionLog();
  }

  //  Export Excel Button Event -- exports every log matching the current filter (not just the
  //  rows on the current page), fetched with the full result count as the page size.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;

    try {
      const result = await firstValueFrom(
        this.crudService.processGetTransactionLog(
          this.filter.topic || '',
          this.filter.activity || '',
          this.filter.editor || 0,
          this.filter.detail || '',
          this.modifiedDateText,
          1,
          this.totalCount,
        ),
      );

      const rows = result.data.map((log, index) => ({
        '#': index + 1,
        'Topic': log.topic || '-',
        'Activity': this.shortActivity(log) || '-',
        'Detail': (log.detail || '-').replace(/\*(.+?)\*/g, '$1'),
        'Editor': log.create_user_name || '-',
        'Modified Date': log.create_datetime
          ? (this.parseJobDate(log.create_datetime)?.toLocaleString('th-TH') ?? log.create_datetime)
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 18 },
        { wch: 16 },
        { wch: 50 },
        { wch: 18 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'Transaction Log');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `transaction-log_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting transaction log to Excel:', error);
    } finally {
      this.isExportingExcel = false;
    }
  }

  //  Fetch Transaction Log List API
  fetchTransactionLog(): Promise<Type.ResponseProcessTransactionLogData> {
    return firstValueFrom(
      this.crudService.processGetTransactionLog(
        this.filter.topic || '',
        this.filter.activity || '',
        this.filter.editor || 0,
        this.filter.detail || '',
        this.modifiedDateText,
        this.filter.page || 1,
        this.filter.pageSize || 25,
      ),
    ).catch((error) => {
      console.error('Error fetching transaction log:', error);
      throw error;
    });
  }

  //  Load Editor Dropdown (reuses the existing user list endpoint)
  fetchOptionEditor(): Promise<Type.ResponseProcessGetUser> {
    return firstValueFrom(this.crudService.ProcessGetUser({ page: 1, pageSize: 1000 })).catch(
      (error) => {
        console.error('Error fetching editor options:', error);
        throw error;
      },
    );
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;

    //  Call Load Transaction Log
    this.loadTransactionLog();
  }

  //  Some activities repeat their topic (e.g. topic "Internal Transfer" +
  //  activity "Create Internal Transfer Job") -- drop the topic words so the
  //  column reads "Create Job".
  shortActivity(row: { topic?: string | null; activity?: string | null }): string {
    const activity = row.activity || '';
    if (!row.topic) return activity;

    const short = activity.replace(row.topic, '').replace(/\s+/g, ' ').trim();
    return short || activity;
  }

  //  Only plain Create/Update/Delete master-data activities get a colored chip;
  //  multi-word activities (Create Pallet, Move Bag, ...) render as plain text.
  //  The old `'activity-badge--' + activity` binding split "Create Pallet" into
  //  the classes "activity-badge--create" + "pallet" and colored it green.
  activityBadgeClass(activity: string | null | undefined): string {
    const key = (activity || '').trim().toLowerCase();
    return /^(create|insert|update|edit|delete)$/.test(key)
      ? `activity-badge activity-badge--${key}`
      : '';
  }

  //  The API wraps emphasized parts of a log message in *asterisks* (e.g. "changed
  //  *Grade* from A to B"). Escape the raw text first (it can embed user-entered
  //  values like grade/lot codes) before turning *...* into <strong>, so nothing
  //  else in the message can inject markup.
  formatDetail(detail: string | null | undefined): SafeHtml {
    if (!detail) return this.sanitizer.bypassSecurityTrustHtml('-');

    const escaped = detail
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');

    const withBold = escaped.replace(/\*(.+?)\*/g, '<strong>$1</strong>');

    return this.sanitizer.bypassSecurityTrustHtml(withBold);
  }
}
