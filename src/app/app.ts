import { Component, OnDestroy, OnInit, signal } from '@angular/core';
import { NavigationEnd, Router } from '@angular/router';
import { Subscription } from 'rxjs';
import { filter } from 'rxjs/operators';

@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  standalone: false,
  styleUrl: './app.css'
})
export class App implements OnInit, OnDestroy {
  constructor(public router: Router) {}
  protected readonly title = signal('IRPC_QRCODE_SYSTEM_WEB');

  private routerSub?: Subscription;

  //  Several pages (job-special-detail, user-list, forklift-management)
  //  reparent their own hidden #print-*-area node to document.body right
  //  before window.print() so it isn't clipped by a modal, then move it back
  //  once printing finishes. If that restore never runs (afterprint never
  //  fires, or the page is torn down before its placeholder can be found),
  //  the node is left stuck directly under <body> -- outside Angular's
  //  component tree entirely, so it survives every later route change and
  //  shows up, unstyled, on whatever page loads next (e.g. job-wh-list,
  //  job-shipping-list). Each of those pages already sweeps its OWN id on
  //  its own next visit, but that only catches the leak if the user happens
  //  to come back to that same print-capable page; sweeping every known
  //  print-area id here, on every navigation, catches it regardless of
  //  which page it leaked from or which page the user lands on next.
  private readonly orphanedPrintAreaIds = [
    'print-special-area',
    'print-user-area',
    'print-forklift-area',
  ];

  ngOnInit() {
    this.routerSub = this.router.events
      .pipe(filter((event) => event instanceof NavigationEnd))
      .subscribe(() => this.cleanupOrphanedPrintAreas());
  }

  ngOnDestroy() {
    this.routerSub?.unsubscribe();
  }

  //  Only removes a match that's actually sitting directly under <body> --
  //  the live copy inside whichever print-capable page is currently mounted
  //  stays untouched, since it lives inside that component's own template.
  private cleanupOrphanedPrintAreas() {
    for (const id of this.orphanedPrintAreaIds) {
      document.querySelectorAll(`#${id}, #${id}-placeholder`).forEach((el) => {
        if (el.parentElement === document.body) {
          el.remove();
        }
      });
    }
  }
}
