import { Component } from '@angular/core';
import { MatPaginatorIntl } from '@angular/material/paginator';
import { JobList, JobListPaginatorIntl } from '../job-list/job-list';

@Component({
  selector: 'app-job-wh-list',
  standalone: false,
  templateUrl: '../job-list/job-list.html',
  styleUrls: ['../job-list/job-list.css'],
  providers: [{ provide: MatPaginatorIntl, useClass: JobListPaginatorIntl }],
})
export class JobWhList extends JobList {
  override readonly typeId = 5;
  override useProductCcFilter = true;
  override showToCcFilter = false;
  override useToWhFilter = true;

  override async ngOnInit() {
    this.filter = {
      ...this.filter,
      jobInbound: true,
      jobOutbound: false,
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
