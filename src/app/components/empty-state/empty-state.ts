import { Component, EventEmitter, Input, Output } from '@angular/core';

export type EmptyStateVariant = 'transfer' | 'job' | 'table';

let nextEmptyStateId = 0;

//  Shared "no data" block for list/table pages -- illustration + title +
//  message + optional primary action. The host page keeps its own wrapper
//  (e.g. .empty-state / .no-job-data) for sizing; this component only
//  centers itself inside whatever space that wrapper gives it.
//
//  variant picks the illustration:
//    transfer -- GET rack -> PUT rack with a moving box (WH03 Internal Transfer)
//    job      -- job sheet + pallet boxes (job-list pages / special job list)
//    table    -- empty data table (management / log pages)
@Component({
  selector: 'app-empty-state',
  standalone: false,
  templateUrl: './empty-state.html',
  styleUrl: './empty-state.css',
})
export class EmptyState {
  @Input() variant: EmptyStateVariant = 'table';
  @Input() title = 'ไม่พบข้อมูล';
  @Input() message = '';
  @Input() actionLabel = '';
  @Input() actionIcon = 'add';
  @Output() action = new EventEmitter<void>();

  //  Unique per instance so two empty states on one page never share the
  //  transfer illustration's <path id> (its <mpath> looks it up by id).
  readonly pathId = `emptyStatePath${nextEmptyStateId++}`;
}
