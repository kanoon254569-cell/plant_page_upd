import { AbstractControl } from '@angular/forms';
import { Component, EventEmitter, Input, Output } from '@angular/core';
import Swal, { SweetAlertIcon } from 'sweetalert2';

type LocationControl = AbstractControl<any, any>;

type locationValue = {
  locationId: number | null;
  itemId: number | null;
  locationName: string | null;
  confirmQty: number | null;
  isSelected: boolean | null;
};

@Component({
  selector: 'app-job-wh-location',
  standalone: false,
  templateUrl: './job-wh-location.html',
  styleUrls: ['./job-wh-location.css'],
})
export class JobWhLocation {
  @Input({ required: true }) item!: { id?: number | null; grade?: string | null; lot_no?: string | null };
  @Input() itemQty = 0;
  @Input() stepStyle: { header_text: string; name: string; color: string } | undefined;
  @Input() validationErrors = false;
  @Input() locations: LocationControl[] = [];
  @Input() isEnoughLocations = false;
  @Input() qtyLocations = 0;
  @Input() modalTarget = '#whLocationModal';
  @Input() badgeText = '';
  //  Completed job (job-detail's readOnlyMode) -- disables Add so no new
  //  location can be picked once the job can no longer be approved/saved.
  @Input() readOnly = false;
  //  Non-empty -> Add is disabled and this text is shown as its tooltip
  //  (eg. job-detail's header Cost Center not chosen yet).
  @Input() addDisabledReason = '';
  @Input() qtyUnit: string | null = null;
  //  Bar colour: 'put' green (default), 'get' indigo -- job-detail passes
  //  'get' from its source column, matching the plant GET card.
  @Input() progressStep: 'get' | 'put' = 'put';

  @Output() addLocation = new EventEmitter<number>();
  @Output() editLocation = new EventEmitter<LocationControl>();
  @Output() deleteLocation = new EventEmitter<{
    itemId: number | null;
    location: LocationControl | null;
  }>();

  //  Grade/Lot pills on each location row -- a location picked with stock
  //  carries its own grade/lotNo, but a PUT (destination) location usually
  //  doesn't, so fall back to the Grade & Lot item the panel belongs to.
  locationGrade(location: LocationControl): string {
    return location.value.grade || this.item?.grade || '';
  }

  locationLot(location: LocationControl): string {
    return location.value.lotNo || this.item?.lot_no || '';
  }

  IsLocationComplete(location: LocationControl): boolean {
    return location.value.completeQty >= location.value.totalPallet;
  }

  //  Something already moved through this location -- a pallet put away
  //  (completeQty) or any qty got / put so far (actualQty, from the
  //  *GetPallet / *PutAway procs). Deleting it then would desync the form
  //  from the warehouse, so the delete button swaps for repeat (fit qty).
  //  actualQty covers the GET gap: got but not put away yet.
  IsPalletComplete(location: LocationControl): boolean {
    return location.value.completeQty > 0 || (location.value.actualQty || 0) > 0;
  }

  getPalletProgressWidth(location: LocationControl): number {
    const qty = location.value.qty || 1;
    const actualQty = location.value.actualQty || 0;
    const progressPercentage = (actualQty / qty) * 100;
    return Math.max(0, Math.min(progressPercentage, 100));
  }

  onAddLocation() {
    const itemId = Number(this.item?.id);
    if (!Number.isNaN(itemId)) {
      this.addLocation.emit(itemId);
    }
  }

  onEditLocation(location: LocationControl) {
    this.editLocation.emit(location);
    this.showWhLocationModal();
  }

  onDeleteLocation(location: LocationControl) {
    this.deleteLocation.emit({ itemId: this.item?.id ?? null, location: location ?? null });
  }

  showWhLocationModal() {
    const modalEl = document.getElementById(this.modalTarget.replace('#', ''),);
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  confirmQtyLocations(): number {
    return this.locations
      .filter((location) => location.value.isSelected)
      .reduce((sum, location) => sum + (Number(location.value.confirmQty) || 0), 0);
  }

  findCompleteQtyLocation(locationId: number): number {
    const location = this.locations.find((loc) => loc.value.locationId === locationId);
    return location ? Number(location.value.actualQty) || 0 : 0;
  }

  onFitQtyLocation(location: LocationControl) {
    const remainingQty = this.findCompleteQtyLocation(location.value.locationId) || 0;
    location.patchValue({
      confirmQty: remainingQty,
      qty: remainingQty,
      isChecked: true,
      isSelected: true,
    });
  }

  //  Shows (message) or hides (null) the red error box under the qty input in
  //  the Swal prompt, and rings the input red while it is shown.
  private toggleQtyError(message: string | null) {
    const error = document.getElementById('swal-qty-error');
    const text = document.getElementById('swal-qty-error-text');
    const field = document.getElementById('swal-qty-group');
    if (error) error.style.display = message ? 'flex' : 'none';
    if (text) text.textContent = message ?? '';
    if (field) field.style.boxShadow = message ? '0 0 0 2px rgba(220, 38, 38, 0.45)' : '';
  }

  async onAssignLocationQty(location: LocationControl) {
    const data = location.value as locationValue;
    if (!data) return;

    const unit = this.qtyUnit || 'kg';
    const actualQty = Number(location.value.actualQty) || 0;
    const actualQtyError = `จำนวนต้องไม่น้อยกว่าที่ขนย้ายจริง (${actualQty.toLocaleString('en-US')} ${unit})`;
    const initialValue = data.confirmQty === 0 ? '' : String(data.confirmQty ?? '');

    //  Same prompt layout as select-wh-location: actual moved qty above the
    //  input, red error box below it shown only on Submit.
    Swal.fire({
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (${unit}) : ${data.locationName}</span>`,
      html: `
        <style>
          #swal-qty-input::-webkit-outer-spin-button,
          #swal-qty-input::-webkit-inner-spin-button {
            -webkit-appearance: none;
            margin: 0;
          }
          #swal-qty-input {
            -moz-appearance: textfield;
          }
          #swal-qty-group:focus-within {
            border-color: #1d4ed8;
          }
          #swal-actual-qty-btn:hover {
            background: #e0e7ff;
          }
          #swal-actual-qty-btn:active {
            background: #c7d2fe;
          }
        </style>
        <span style="font-size: 16px;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</span>
        <div
          id="swal-qty-group"
          style="display: flex; align-items: stretch; margin-top: 12px; height: 44px; border: 1px solid #cbd5e1; border-radius: 6px; overflow: hidden; background: #fff; transition: border-color 0.15s ease, box-shadow 0.15s ease;"
        >
          <input
            id="swal-qty-input"
            type="number"
            min="1"
            step="1"
            value="${initialValue}"
            style="flex: 1; min-width: 0; height: 100%; box-sizing: border-box; padding: 0 12px; font-size: 16px; border: none; outline: none; background: transparent;"
          />
          ${
            actualQty > 0
              ? `<button type="button" id="swal-actual-qty-btn" title="ใช้จำนวนที่ขนย้ายจริง" style="display: flex; align-items: center; gap: 6px; margin: 0; padding: 0 16px; border: none; border-left: 1px solid #cbd5e1; border-radius: 0; background: #f1f5f9; color: #1e3a8a; font-size: 14px; line-height: 1; cursor: pointer; white-space: nowrap; transition: background 0.15s ease;"><span style="font-weight: 500; color: #64748b;">ขนย้ายจริง</span><span style="font-weight: 700;">${actualQty.toLocaleString('en-US')} ${unit}</span></button>`
              : ''
          }
        </div>
        <div id="swal-qty-error" role="alert" style="display: none; align-items: center; gap: 8px; margin-top: 10px; padding: 8px 12px; border: 1px solid #fecaca; border-radius: 6px; background: #fef2f2; color: #b91c1c; font-size: 14px; font-weight: 500; line-height: 1.4; text-align: left;"><span style="flex: none; display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; border-radius: 50%; background: #dc2626; color: #fff; font-size: 12px; font-weight: 700;">!</span><span id="swal-qty-error-text"></span></div>
      `,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
      focusConfirm: false,
      didOpen: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        input?.focus();
        //  The actualQty error only shows on Submit (preConfirm); typing clears it.
        input?.addEventListener('input', () => this.toggleQtyError(null));
        //  "ขนย้ายจริง" button: fill the input with the actual moved qty and submit.
        document.getElementById('swal-actual-qty-btn')?.addEventListener('click', () => {
          if (input) input.value = String(actualQty);
          Swal.clickConfirm();
        });
      },
      preConfirm: () => {
        const input = document.getElementById('swal-qty-input') as HTMLInputElement | null;
        const qty = input ? Number(input.value) : NaN;
        if (input?.value && qty < actualQty) {
          this.toggleQtyError(actualQtyError);
          return false;
        }
        return input?.value ?? '';
      },
    }).then((result) => {
      if (result.isConfirmed) {
        const nextConfirmQty = Number(result.value);
        const currentConfirmQty = Number(data.confirmQty) || 0;
        const totalConfirmQty = this.confirmQtyLocations() - currentConfirmQty + nextConfirmQty;

        if (Number.isNaN(nextConfirmQty) || nextConfirmQty < 0) {
          this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
          return;
        }

        if (totalConfirmQty > this.itemQty) {
          this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
          return;
        }

        location.patchValue({
          confirmQty: nextConfirmQty,
          qty: nextConfirmQty,
          isChecked: true,
          isSelected: true,
        });
      }
    });
  }

  SwalAlert(icon: SweetAlertIcon, message: string) {
    const titles = {
      success: 'Success',
      error: 'Error',
      warning: 'Warning',
      info: 'Information',
      question: 'Confirmation',
    };

    Swal.fire({
      position: 'center',
      icon,
      title: `<span style="font-size:22px;font-weight:600;">${titles[icon] ?? 'Notice'}</span>`,
      html: `<span style="font-size:16px;">${message}</span>`,
      showConfirmButton: true,
    });
  }
}
