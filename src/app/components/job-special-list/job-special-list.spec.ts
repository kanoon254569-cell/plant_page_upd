import { ComponentFixture, TestBed } from '@angular/core/testing';

import { JobSpecialList } from './job-special-list';

describe('JobSpecialList', () => {
  let component: JobSpecialList;
  let fixture: ComponentFixture<JobSpecialList>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [JobSpecialList]
    })
    .compileComponents();

    fixture = TestBed.createComponent(JobSpecialList);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
