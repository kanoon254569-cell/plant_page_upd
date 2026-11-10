import { Component } from '@angular/core';
import { JobList } from '../job-list/job-list';

@Component({
  selector: 'app-job-shipping-list',
  standalone: false,
  templateUrl: '../job-list/job-list.html',
  styleUrls: ['../job-list/job-list.css'],
})
export class JobShippingList extends JobList {
  override readonly typeId = 5;
  override pageCode = 'SP01';
  override pageTitle = 'Job Shipping List';
  override showJobTypeFilter = false;

  override async ngOnInit() {
    this.filter = {
      ...this.filter,
      jobInbound: true,
      jobOutbound: true,
      jobStatuses: [],
      jobType: 5,
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };

    await super.ngOnInit();
  }
}
