import { AfterViewInit, Directive, ElementRef, Input, OnDestroy } from '@angular/core';

//  Keeps a skeleton table's columns the same width as the real table's.
//  The real mat-table sizes its columns from the data (auto layout), so the
//  skeleton cannot know them up front. The real table records its header
//  widths while it is on screen; the skeleton (same key) applies them the
//  next time the page loads:
//    <table mat-table skeletonWidthsFrom="user-list"> ... (real table)
//    <table class="adm-skel-table" skeletonWidthsTo="user-list"> ... (skeleton)
//  Columns are matched by their mat-column-* class, so every skeleton <th>
//  carries the same mat-column-* class as the real column. Widths are kept
//  in localStorage, so they survive a page refresh; before the real table
//  has been shown once, the skeleton falls back to auto layout.

interface ColumnWidths {
  table: number;
  //  true when the real table fit its container (w-100, no horizontal
  //  scroll) -- the skeleton then uses percentages so it still fits after a
  //  window resize; otherwise it uses the same pixel widths and scrolls too.
  fits: boolean;
  columns: Record<string, number>;
}

const STORAGE_PREFIX = 'skeleton-widths:';
const memoryCache = new Map<string, ColumnWidths>();

function columnName(th: Element): string | null {
  const cls = Array.from(th.classList).find((c) => c.startsWith('mat-column-'));
  return cls ? cls.substring('mat-column-'.length) : null;
}

function headerCells(table: HTMLElement): HTMLElement[] {
  const row = table.querySelector('thead tr, tr.mat-mdc-header-row');
  return row ? (Array.from(row.querySelectorAll('th')) as HTMLElement[]) : [];
}

function saveWidths(key: string, widths: ColumnWidths): void {
  memoryCache.set(key, widths);
  try {
    localStorage.setItem(STORAGE_PREFIX + key, JSON.stringify(widths));
  } catch {
    //  storage blocked (private window etc.) -- the in-memory copy still works
  }
}

function loadWidths(key: string): ColumnWidths | null {
  const cached = memoryCache.get(key);
  if (cached) return cached;
  try {
    const raw = localStorage.getItem(STORAGE_PREFIX + key);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as ColumnWidths;
    memoryCache.set(key, parsed);
    return parsed;
  } catch {
    return null;
  }
}

//  Real table: records its header widths whenever they change (data loaded,
//  window resized).
@Directive({
  selector: '[skeletonWidthsFrom]',
  standalone: false,
})
export class SkeletonWidthsFromDirective implements AfterViewInit, OnDestroy {
  @Input() skeletonWidthsFrom = '';

  private observer?: ResizeObserver;
  private observed = new Set<Element>();

  constructor(private el: ElementRef<HTMLElement>) {}

  ngAfterViewInit(): void {
    if (typeof ResizeObserver === 'undefined') return;

    //  mat-table renders its header row after this hook, so the first
    //  callback (table grows when rows render) also picks up the <th>s.
    this.observer = new ResizeObserver(() => this.record());
    this.observer.observe(this.el.nativeElement);
  }

  ngOnDestroy(): void {
    this.observer?.disconnect();
  }

  private record(): void {
    const table = this.el.nativeElement;
    const cells = headerCells(table);
    if (!this.skeletonWidthsFrom || cells.length === 0) return;

    const columns: Record<string, number> = {};
    for (const th of cells) {
      if (!this.observed.has(th)) {
        this.observer?.observe(th);
        this.observed.add(th);
      }
      const name = columnName(th);
      const width = th.getBoundingClientRect().width;
      if (name && width > 0) columns[name] = Math.round(width);
    }
    if (Object.keys(columns).length === 0) return;

    const tableWidth = Math.round(table.getBoundingClientRect().width);
    const containerWidth = table.parentElement?.clientWidth ?? tableWidth;
    saveWidths(this.skeletonWidthsFrom, {
      table: tableWidth,
      fits: tableWidth <= containerWidth + 1,
      columns,
    });
  }
}

//  Skeleton table: fixed layout with the recorded widths.
@Directive({
  selector: '[skeletonWidthsTo]',
  standalone: false,
})
export class SkeletonWidthsToDirective implements AfterViewInit {
  @Input() skeletonWidthsTo = '';

  constructor(private el: ElementRef<HTMLElement>) {}

  ngAfterViewInit(): void {
    const widths = this.skeletonWidthsTo ? loadWidths(this.skeletonWidthsTo) : null;
    if (!widths) return;

    const table = this.el.nativeElement;
    const cells = headerCells(table);
    if (!cells.every((th) => widths.columns[columnName(th) ?? ''] !== undefined)) return;

    for (const th of cells) {
      const width = widths.columns[columnName(th)!];
      th.style.boxSizing = 'border-box';
      th.style.width = widths.fits ? `${(width / widths.table) * 100}%` : `${width}px`;
    }
    table.style.tableLayout = 'fixed';
    table.style.width = widths.fits ? '100%' : `${widths.table}px`;
  }
}
