import { ComponentFixture, TestBed } from '@angular/core/testing';

import { PalletAdjustment } from './pallet-adjustment';

describe('PalletAdjustment', () => {
  let component: PalletAdjustment;
  let fixture: ComponentFixture<PalletAdjustment>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [PalletAdjustment],
    }).compileComponents();

    fixture = TestBed.createComponent(PalletAdjustment);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
