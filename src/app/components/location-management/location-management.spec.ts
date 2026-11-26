import { ComponentFixture, TestBed } from '@angular/core/testing';

import { LocationManagement } from './location-management';

describe('LocationManagement', () => {
  let component: LocationManagement;
  let fixture: ComponentFixture<LocationManagement>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [LocationManagement]
    })
    .compileComponents();

    fixture = TestBed.createComponent(LocationManagement);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
