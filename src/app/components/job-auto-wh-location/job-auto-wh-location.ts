import { AbstractControl } from '@angular/forms';
import { Component, EventEmitter, Input, Output } from '@angular/core';

type LocationControl = AbstractControl<any, any>;

//  Auto warehouse (A41/A43, ct_auto_warehouse) location card -- same card
//  as job-plant-location; the options come from select-auto-wh-location.
@Component({
  selector: 'app-job-auto-wh-location',
  standalone: false,
  templateUrl: './job-auto-wh-location.html',
  styleUrls: ['../job-plant-location/job-plant-location.css'],
})
export class JobAutoWhLocation {
  @Input({ required: true }) item!: { id?: number | null };
  @Input() stepStyle: { header_text: string; name: string; color: string } | undefined;
  @Input() validationErrors = false;
  @Input() locations: LocationControl[] = [];
  @Input() isEmptyLocations = false;
  @Input() canModifyLocation = false;
  @Input() modalTarget = '#autoWhLocationModal';
  @Input() badgeText = 'Auto Warehouse';
  //  Completed job (job-detail's readOnlyMode) -- disables Add.
  @Input() readOnly = false;
  @Input() whCode = '';

  @Output() addLocation = new EventEmitter<number>();
  @Output() deleteLocation = new EventEmitter<{
    itemId: number | null;
    location: LocationControl | null;
  }>();

  onAddLocation() {
    const itemId = Number(this.item?.id);
    if (!Number.isNaN(itemId)) {
      this.addLocation.emit(itemId);
    }
  }

  onDeleteLocation(location: LocationControl) {
    this.deleteLocation.emit({ itemId: this.item?.id ?? null, location: location ?? null });
  }
}
