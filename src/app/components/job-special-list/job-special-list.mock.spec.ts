import { Router } from '@angular/router';
import { CrudService } from '../../services/crud.service';
import Notify from '../../shared/notify';
import { JobSpecialList } from './job-special-list';

describe('JobSpecialList form behavior', () => {
  it('sets today on a manual job and does not require the date', () => {
    const crudService = jasmine.createSpyObj<CrudService>('CrudService', ['processGetSpecialJobList']);
    const router = jasmine.createSpyObj<Router>('Router', ['navigate']);
    const component = new JobSpecialList(crudService, router);
    const today = new Date();
    component.addUploadJob();
    const job = component._uploadJobs[0];

    expect(job.dateObj?.getFullYear()).toBe(today.getFullYear());
    expect(job.dateObj?.getMonth()).toBe(today.getMonth());
    expect(job.dateObj?.getDate()).toBe(today.getDate());
    expect(job.dateLocked).toBeTrue();
    expect(component.jobMissingCount(job)).toBe(6);
  });

  it('keeps ton and cart values non-negative and calculates total kilograms', () => {
    const crudService = jasmine.createSpyObj<CrudService>('CrudService', ['processGetSpecialJobList']);
    const router = jasmine.createSpyObj<Router>('Router', ['navigate']);
    const component = new JobSpecialList(crudService, router);
    component.addUploadJob();
    const job = component._uploadJobs[0];

    component.onJobTonInput(job, 1.25);
    component.onJobCartQtyInput(job, 4);

    expect(job.tonPerCart).toBe(1.25);
    expect(job.cartQty).toBe(4);
    expect(component.jobTotalQtyDisplay(job)).toBe('5');

    component.onJobCartQtyInput(job, -2);

    expect(job.cartQty).toBe(0);
    expect(component.jobTotalQtyDisplay(job)).toBe('0');

    component.onJobTonInput(job, -1);
    expect(job.tonPerCart).toBe(0);
    expect(component.jobTotalQtyDisplay(job)).toBe('0');
  });

  it('duplicates a pallet the requested number of times', async () => {
    const crudService = jasmine.createSpyObj<CrudService>('CrudService', ['processGetSpecialJobList']);
    const router = jasmine.createSpyObj<Router>('Router', ['navigate']);
    const component = new JobSpecialList(crudService, router);
    component.addUploadJob();
    component._uploadJobs[0].pallets[0].bags.push({
      grade: 'PP',
      lot: 'LOT-1',
      qty: 100,
      bag: 1,
    });
    const dialog = spyOn(Notify, 'fire').and.resolveTo({
      isConfirmed: true,
      isDismissed: false,
      value: '3',
    });

    await component.duplicateUploadPallet(0, 0);

    expect(component._uploadJobs[0].pallets.length).toBe(4);
    expect(component._uploadJobs[0].pallets[1].bags[0]).toEqual({
      grade: 'PP',
      lot: 'LOT-1',
      qty: 100,
      bag: 1,
    });
    expect(component._uploadJobs[0].pallets[1].bags[0]).not.toBe(
      component._uploadJobs[0].pallets[0].bags[0],
    );
    const inputValidator = dialog.calls.mostRecent().args[0].inputValidator;
    expect(inputValidator?.('0')).toBe('กรุณาระบุจำนวน 1 - 100');
    expect(inputValidator?.('101')).toBe('กรุณาระบุจำนวน 1 - 100');
  });
});
