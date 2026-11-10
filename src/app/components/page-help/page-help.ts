import {
  AfterViewInit,
  Component,
  ElementRef,
  HostListener,
  Input,
  OnDestroy,
  ViewChild,
} from '@angular/core';
import { PAGE_HELP, PageHelpContent, PageHelpStep } from './page-help.content';

interface TourBox {
  top: number;
  left: number;
  width: number;
  height: number;
}

const SPOTLIGHT_PADDING = 6;
const POPOVER_GAP = 12;
const VIEWPORT_MARGIN = 12;

//  "?" button for a page header -- starts a guided tour of the page: each
//  step dims the page, cuts a spotlight around the elements tagged
//  data-tour="<step.target>" and shows a popover with the step's text.
//  Steps come from PAGE_HELP (page-help.content.ts) by page key.
@Component({
  selector: 'app-page-help',
  standalone: false,
  templateUrl: './page-help.html',
  styleUrl: './page-help.css',
})
export class PageHelp implements AfterViewInit, OnDestroy {
  @Input() page = '';

  @ViewChild('tourRoot') tourRoot!: ElementRef<HTMLElement>;
  @ViewChild('popover') popover?: ElementRef<HTMLElement>;

  active = false;
  steps: PageHelpStep[] = [];
  index = 0;
  spotlight: TourBox | null = null;
  popoverPos = { top: 0, left: 0 };

  private readonly reposition = () => this.updatePosition();

  get content(): PageHelpContent | null {
    return PAGE_HELP[this.page] ?? null;
  }

  get current(): PageHelpStep | null {
    return this.steps[this.index] ?? null;
  }

  get isLast(): boolean {
    return this.index === this.steps.length - 1;
  }

  //  The tour layer is moved to <body> so position: fixed is relative to the
  //  viewport, not to a transformed/clipped ancestor in the page header.
  ngAfterViewInit() {
    document.body.appendChild(this.tourRoot.nativeElement);
  }

  ngOnDestroy() {
    this.end();
    this.tourRoot?.nativeElement.remove();
  }

  @HostListener('document:keydown', ['$event'])
  onKeydown(event: KeyboardEvent) {
    if (!this.active) return;
    if (event.key === 'Escape') this.end();
    else if (event.key === 'ArrowRight') this.next();
    else if (event.key === 'ArrowLeft') this.prev();
  }

  start() {
    if (!this.content) return;
    //  Skip steps whose elements are not on the page right now.
    this.steps = this.content.steps.filter(
      (step) => !step.target || this.targetsOf(step.target).length > 0,
    );
    if (!this.steps.length) return;

    this.index = 0;
    this.active = true;
    window.addEventListener('resize', this.reposition);
    window.addEventListener('scroll', this.reposition, true);
    this.showStep();
  }

  end() {
    if (!this.active) return;
    this.active = false;
    this.spotlight = null;
    window.removeEventListener('resize', this.reposition);
    window.removeEventListener('scroll', this.reposition, true);
  }

  next() {
    if (this.isLast) {
      this.end();
      return;
    }
    this.index++;
    this.showStep();
  }

  prev() {
    if (this.index === 0) return;
    this.index--;
    this.showStep();
  }

  private targetsOf(target: string): HTMLElement[] {
    return Array.from(document.querySelectorAll<HTMLElement>(`[data-tour="${target}"]`)).filter(
      (el) => el.getClientRects().length > 0,
    );
  }

  private showStep() {
    const target = this.current?.target;
    const first = target ? this.targetsOf(target)[0] : null;
    first?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    //  Wait for the popover to render the new text before measuring it.
    setTimeout(() => this.updatePosition());
  }

  private updatePosition() {
    if (!this.active) return;

    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const popoverEl = this.popover?.nativeElement;
    const w = popoverEl?.offsetWidth ?? 740;
    const h = popoverEl?.offsetHeight ?? 240;

    const target = this.current?.target;
    let els = target ? this.targetsOf(target) : [];
    if (this.current?.firstOnly) els = els.slice(0, 1);
    if (!els.length) {
      this.spotlight = null;
      this.popoverPos = { top: (vh - h) / 2, left: (vw - w) / 2 };
      return;
    }

    //  One box around all tagged elements.
    const rects = els.map((el) => el.getBoundingClientRect());
    const top = Math.min(...rects.map((r) => r.top)) - SPOTLIGHT_PADDING;
    const left = Math.min(...rects.map((r) => r.left)) - SPOTLIGHT_PADDING;
    const bottom = Math.max(...rects.map((r) => r.bottom)) + SPOTLIGHT_PADDING;
    const right = Math.max(...rects.map((r) => r.right)) + SPOTLIGHT_PADDING;
    this.spotlight = { top, left, width: right - left, height: bottom - top };

    const clampX = (x: number) => Math.min(Math.max(x, VIEWPORT_MARGIN), vw - w - VIEWPORT_MARGIN);
    const clampY = (y: number) => Math.min(Math.max(y, VIEWPORT_MARGIN), vh - h - VIEWPORT_MARGIN);
    const centerX = clampX(left + (right - left) / 2 - w / 2);
    const centerY = clampY(top + (bottom - top) / 2 - h / 2);

    //  Below, above, right, left of the box; else inside the bottom-right
    //  corner of the viewport (box taller and wider than the free space).
    if (bottom + POPOVER_GAP + h <= vh - VIEWPORT_MARGIN) {
      this.popoverPos = { top: bottom + POPOVER_GAP, left: centerX };
    } else if (top - POPOVER_GAP - h >= VIEWPORT_MARGIN) {
      this.popoverPos = { top: top - POPOVER_GAP - h, left: centerX };
    } else if (right + POPOVER_GAP + w <= vw - VIEWPORT_MARGIN) {
      this.popoverPos = { top: centerY, left: right + POPOVER_GAP };
    } else if (left - POPOVER_GAP - w >= VIEWPORT_MARGIN) {
      this.popoverPos = { top: centerY, left: left - POPOVER_GAP - w };
    } else {
      this.popoverPos = { top: clampY(vh), left: clampX(vw) };
    }
  }
}
