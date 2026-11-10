import { Component, inject } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { JobDetail } from '../job-detail/job-detail';

//  WH04 Transfer Warehouse detail (job type 11 'TW'), opened from
//  job-wh-transfer-list. Same page as job-detail -- template, approve,
//  forklift and location flows are inherited -- except the job itself is
//  loaded from GET job/transfer-wh?id={id} (WH04's own API) instead of
//  GET job. That endpoint returns the same shape, pinned to type 11.
@Component({
  selector: 'app-job-wh-transfer-detail',
  standalone: false,
  templateUrl: '../job-detail/job-detail.html',
  styleUrl: '../job-detail/job-detail.css',
})
export class JobWhTransferDetail extends JobDetail {
  private readonly transferWhService = inject(CrudService);

  //  TW source A41/A43 is picked from ct_auto_warehouse
  //  (job-auto-wh-location), not job-wh-location.
  override useAutoWhLocation = true;

  //  Same sky blue TW icon as job-wh-transfer-list.
  override useWhTransferIcon = true;

  override fetchJobData(id: number): Promise<Type.ResponseProcessJobListData> {
    return new Promise((resolve, reject) => {
      this.transferWhService.processGetTransferWhJobDetail(id).subscribe(
        (response: Type.ResponseProcessJobListData) => resolve(response),
        (error) => {
          console.error('Error fetching transfer warehouse job:', error);
          reject(error);
        },
      );
    });
  }
}
