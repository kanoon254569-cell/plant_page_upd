import { ComponentFixture, TestBed } from '@angular/core/testing';

import { ForkliftManagement } from './forklift-management';

describe('ForkliftManagement', () => {
  let component: ForkliftManagement;
  let fixture: ComponentFixture<ForkliftManagement>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [ForkliftManagement]
    })
    .compileComponents();

    fixture = TestBed.createComponent(ForkliftManagement);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
