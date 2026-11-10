import { Component } from '@angular/core';
import { JobList } from '../job-list/job-list';

@Component({
  selector: 'app-job-wh-outbound-list',
  standalone: false,
  templateUrl: '../job-list/job-list.html',
  styleUrls: ['../job-list/job-list.css'],
})
export class JobWhOutboundList extends JobList {
  override readonly typeId = 5;
  override pageCode = 'WH02';
  override useProductCcFilter = true;
  override showFromCcFilter = false;
  override showToCcFilter = false;
  override useLocationFilter = true;

  override async ngOnInit() {
    this.filter = {
      ...this.filter,
      jobInbound: false,
      jobOutbound: true,
      jobStatuses: [],
      jobType: 0,
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };

    await super.ngOnInit();
  }
}
