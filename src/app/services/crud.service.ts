import { Injectable } from '@angular/core';
import { HttpClient, HttpEvent, HttpHeaders, HttpRequest } from '@angular/common/http';
import { Observable, throwError, interval } from 'rxjs';
import * as Type from '../../../src/models/variables-type';
import { environment } from '../../../src/environments/environment';
import { JwtTokenService } from './jwt-token.service';

@Injectable({
  providedIn: 'root',
})
export class CrudService {
  // Define API
  url_ = 'assets/store.json';

  // Api configurations
  private headers = new HttpHeaders({ 'Content-Type': 'application/json' });
  private hostURL = environment.baseAPIURL;
  private apiURL = `${this.hostURL}/api/v1`;

  // Sub api
  private authUrl = `${this.apiURL}/auth/`;
  private processUrl = `${this.apiURL}/process/`;
  private masterUrl = `${this.apiURL}/master/`;
  private processCbUrl = `${this.apiURL}/process-cb/`;
  http: any;

  constructor(
    private httpClient: HttpClient,
    private jwtTokenService: JwtTokenService,
  ) {}

  // Http Options
  httpOptions = {
    headers: new HttpHeaders({
      'Content-Type': 'application/json',
    }),
  };

  private getAuthHeaders() {
    const token = this.jwtTokenService.getAccessToken();

    return new HttpHeaders({
      'Content-Type': 'application/json',
      Authorization: token ? `Bearer ${token}` : '',
    });
  }

  /*------------------ Auth ---------------------*/
  Login(data: any): Observable<Type.ResponseLogin> {
    return this.httpClient.post<Type.ResponseLogin>(`${this.authUrl + 'login'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  /*------------------ Master ---------------------*/

  processGetForkliftList(
    forkliftName: string,
    licensePlate: string,
    whCodes: string,
    isActive: string,
    page: number,
    pageSize: number,
    sortBy: string,
    sortOrder: string,
    sectionIds: string = '',
  ): Observable<Type.ResponseProcessForkliftListData> {
    // this.GetToken();
    return this.httpClient.get<Type.ResponseProcessForkliftListData>(
      `${
        this.masterUrl + 'forklift'
      }?forkliftName=${forkliftName}&licensePlate=${licensePlate}&whCodes=${whCodes}&isActive=${isActive}&page=${page}&pageSize=${pageSize}&sortBy=${sortBy}&sortOrder=${sortOrder}&sectionIds=${sectionIds}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processInsertForklift(data: any): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.masterUrl + 'forklift'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  processUpdateForklift(
    id: number,
    data: {
      forkliftName: string;
      licensePlate: string;
      whCode: string;
      userId: number;
    },
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(
      `${this.masterUrl + 'forklift'}/${id}`,
      data,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  processDeleteForklift(id: number, userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.delete<Type.ResponseStandard>(`${this.masterUrl + 'forklift'}/${id}`, {
      headers: this.getAuthHeaders(),
      body: { id, userId },
    });
  }

  processGetForkliftAvailable(
    whCodes: string,
    flName: string,
    currentUser: string,
    isInnerWh: string = 'N',
    //  comma list of section ids (1=Warehouse, 2=Loading, 3=Pallet); '' = all
    sectionIds: string = '',
  ): Observable<Type.ResponseProcessForkliftAvailable> {
    return this.httpClient.get<Type.ResponseProcessForkliftAvailable>(
      `${this.masterUrl + 'forklift/available'}?whCodes=${whCodes}&flName=${flName}&currentUser=${currentUser}&isInnerWh=${isInnerWh}&sectionIds=${sectionIds}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetWhLocation(
    wh: string,
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
  ): Observable<Type.ResponseProcessWhLocation> {
    return this.httpClient.get<Type.ResponseProcessWhLocation>(
      `${this.masterUrl + 'location/wh'}/${wh}?whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}&locationCode=${locationCode}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Location Management page - always pulls live from WMS+ (see LocationController.GetWhLocationAsync).
  //  wh is fixed to 'MWH' for the Boardman warehouse, matching the convention used across the app
  //  (see select-wh-location.ts default warehouseCode). "ชื่อ Location" searches by location_desc,
  //  not location_code (filtered in-memory on the backend since WMS+ has no locationDesc param).
  processGetLocationManagementList(
    wh: string,
    whCode: string,
    locationDesc: string,
    priorityName: string,
    statusId: number,
    page: number,
    pageSize: number,
  ): Observable<Type.ResponseProcessWhLocation> {
    return this.httpClient.get<Type.ResponseProcessWhLocation>(
      `${
        this.masterUrl + 'location/wh'
      }/${wh}?whCode=${whCode}&locationDesc=${locationDesc}&priorityName=${priorityName}&page=${page}&pageSize=${pageSize}&statusId=${statusId}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Location Management page - edit modal (priority only) and Active/Inactive toggle both go
  //  through this same endpoint; the caller decides which fields to send.
  processUpdateLocation(
    id: number,
    data: Type.RequestUpdateLocation,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(
      `${this.masterUrl + 'location'}/${id}`,
      data,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  //  locationDesc/isActive/page/pageSize are all optional so existing callers
  //  (select-pre-zone-location.ts) that never pass them keep the exact same behavior - full
  //  matching set, active-only (backend defaults @is_active to 'Y', @page_size to 1000).
  //  isActive: '' explicitly requests both active and inactive rows (see LocationController.cs).
  processGetPrezoneLocation(
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
    page?: number,
    pageSize?: number,
    locationDesc?: string,
    isActive?: string,
  ): Observable<Type.ResponseProcessPreZoneLocation> {
    let url = `${this.masterUrl + 'location/pre-zone'}?whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}&locationCode=${locationCode}`;
    if (page != null) url += `&page=${page}`;
    if (pageSize != null) url += `&pageSize=${pageSize}`;
    if (locationDesc != null) url += `&locationDesc=${locationDesc}`;
    if (isActive != null) url += `&isActive=${isActive}`;

    return this.httpClient.get<Type.ResponseProcessPreZoneLocation>(url, {
      headers: this.getAuthHeaders(),
    });
  }

  //  locationDesc/isActive/page/pageSize are all optional so existing callers
  //  (select-dock-location.ts) that never pass them keep the exact same behavior - full matching
  //  set, active-only (backend defaults @is_active to 'Y', @page_size to 1000). isActive: ''
  //  explicitly requests both active and inactive rows (see LocationController.cs).
  processGetDockLocation(
    whCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
    page?: number,
    pageSize?: number,
    locationDesc?: string,
    isActive?: string,
  ): Observable<Type.ResponseProcessDockLocation> {
    let url = `${this.masterUrl + 'location/dock'}?whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}&locationCode=${locationCode}`;
    if (page != null) url += `&page=${page}`;
    if (pageSize != null) url += `&pageSize=${pageSize}`;
    if (locationDesc != null) url += `&locationDesc=${locationDesc}`;
    if (isActive != null) url += `&isActive=${isActive}`;

    return this.httpClient.get<Type.ResponseProcessDockLocation>(url, {
      headers: this.getAuthHeaders(),
    });
  }

  processGetStockInquiry(
    whType: string,
    grade: string,
    lotNo: string,
    costCenter: string,
    invDate: string,
    prodType: string,
    isBag: string = 'N'
  ): Observable<Type.ResponseProcessGetStockInquiry> {
    return this.httpClient.get<Type.ResponseProcessGetStockInquiry>(
      `${this.masterUrl + 'location/stock-inquiry'}?whType=${whType}&grade=${grade}&lotNo=${lotNo}&costCenter=${costCenter}&invDate=${invDate}&prodType=${prodType}&isBag=${isBag}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetAllStockInquiry(
    whType: string,
    grade: string,
    lotNo: string,
    costCenter: string,
    sapCostCenter: string,
    invDate: string,
    prodType: string,
    isBag: string = 'N'
  ): Observable<Type.ResponseProcessGetAllStockInquiry> {
    return this.httpClient.get<Type.ResponseProcessGetAllStockInquiry>(
      `${this.masterUrl + 'location/all-stock'}?whType=${whType}&grade=${grade}&lotNo=${lotNo}&costCenter=${costCenter}&sapCostCenter=${sapCostCenter}&invDate=${invDate}&prodType=${prodType}&isBag=${isBag}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetBgPlantLocation(bgPlantCode: string): Observable<Type.ResponseProcessBgPlantLocation> {
    return this.httpClient.get<Type.ResponseProcessBgPlantLocation>(
      `${this.masterUrl + 'location/bg-plant'}/${bgPlantCode}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetAutoWhLocation(whCode: string): Observable<Type.ResponseProcessAutoWhLocation> {
    return this.httpClient.get<Type.ResponseProcessAutoWhLocation>(
      `${this.masterUrl + 'location/auto-wh'}/${encodeURIComponent(whCode)}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetRqPlantLocation(rqPlantCode: string): Observable<Type.ResponseProcessRqPlantLocation> {
    return this.httpClient.get<Type.ResponseProcessRqPlantLocation>(
      `${this.masterUrl + 'location/rq-plant'}/${rqPlantCode}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetSpecialLocation(spcCode: string): Observable<Type.ResponseProcessSpecialLocation> {
    return this.httpClient.get<Type.ResponseProcessSpecialLocation>(
      `${this.masterUrl + 'location/special-zone'}?spcCode=${spcCode}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetReplaceLocation(rpzCode: string): Observable<Type.ResponseProcessReplaceLocation> {
    return this.httpClient.get<Type.ResponseProcessReplaceLocation>(
      `${this.masterUrl + 'location/replace-zone'}?rpzCode=${rpzCode}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processApproveJob(id: number, data: any): Observable<Type.ResponseStandard> {
    return this.httpClient.patch<Type.ResponseStandard>(
      `${this.processUrl + 'job'}/${id}/approve`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processMapDo(data: any): Observable<Type.ResponseStandard> {
    return this.httpClient.patch<Type.ResponseStandard>(
      `${this.processUrl + 'job'}/map-shipment-do`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetGradeWithSapCcCode(
    grade: string,
    ccCode: string,
    prodType?: string,
  ): Observable<Type.ResponseProcessGetGradeWithSapCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetGradeWithSapCcCode>(
      `${this.masterUrl + 'grade-with-sap-cc-code'}?grade=${grade}&ccCode=${ccCode}&prodType=${prodType}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET api/v1/master/grade (GradeController.GetMasterGrade) -- searches
  //  the WMS+ master grade list by any combination of code/desc/type/group/
  //  cost center. Used to look up a grade's unit_ratio/unit_pallet (package
  //  ratio) rather than the single-grade grade-with-sap-cc-code lookup above.
  processGetMasterGrade(
    gradeCode: string,
    gradeDesc: string,
    prodType: string,
    prodGroup: string,
    costCenter: string,
    page: number = 1,
    pageSize: number = 10,
  ): Observable<Type.ResponseProcessGetMasterGrade> {
    return this.httpClient.get<Type.ResponseProcessGetMasterGrade>(
      `${
        this.masterUrl + 'grade'
      }?gradeCode=${gradeCode}&gradeDesc=${gradeDesc}&prodType=${prodType}&prodGroup=${prodGroup}&costCenter=${costCenter}&page=${page}&pageSize=${pageSize}`,
      { headers: this.getAuthHeaders() },
    );
  }

  /*------------------ Process CB ---------------------*/

  ProcessGetOptionsVehicleType(): Observable<Type.ResponseProcessGetOptionsVehicleType> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsVehicleType>(
      `${this.processCbUrl + 'vehicle-type'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsLocationType(): Observable<Type.ResponseProcessGetOptionsLocationType> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsLocationType>(
      `${this.processCbUrl + 'location-type'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetFindLocation(
    locationType: string,
    locationName: string
  ): Observable<Type.ResponseProcessFindLocation> {
    return this.httpClient.get<Type.ResponseProcessFindLocation>(
      `${this.processCbUrl + 'find-location'}?locationType=${locationType}&locationName=${locationName}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsDepartment(): Observable<Type.ResponseProcessGetOptionsDepartment> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsDepartment>(
      `${this.processCbUrl + 'department'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsRole(): Observable<Type.ResponseProcessGetOptionsRole> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsRole>(
      `${this.processCbUrl + 'role'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsWmsCcCode(wh: string): Observable<Type.ResponseProcessGetOptionsWmsCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWmsCcCode>(
      `${this.processCbUrl + 'wms-cc-code'}?wh=${wh}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  //  WH Prod CC options for one TS / RC / RQ job, same list as WMS+'s
  //  "WH Prod CC" select (empty for other job types).
  ProcessGetOptionsWmsProdCcByJob(jobMainId: number): Observable<Type.ResponseProcessGetOptionsWmsCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWmsCcCode>(
      `${this.processCbUrl + 'wms-prod-cc-by-job'}?jobMainId=${jobMainId}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  //  WH Prod CC options for WH02 Internal Transfer, same list as WMS+'s
  //  Transfer WH form (ct_transfer_wh_convert_sap_wms for the warehouse).
  ProcessGetOptionsWmsProdCcTransferWh(wh: string): Observable<Type.ResponseProcessGetOptionsWmsCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWmsCcCode>(
      `${this.processCbUrl + 'wms-prod-cc-transfer-wh'}?wh=${wh}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationWh(wh: string): Observable<Type.ResponseProcessGetOptionsWh> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWh>(
      `${this.processCbUrl + 'location-wh'}?wh=${wh}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationArea(
    wh: string,
    whCode: string,
    areaCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsArea> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsArea>(
      `${this.processCbUrl + 'location-area'}?wh=${wh}&whCode=${whCode}&areaCode=${areaCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationLevel(
    wh: string,
    whCode: string,
    areaCode: string,
    levelCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsLevel> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsLevel>(
      `${this.processCbUrl + 'location-level'}?wh=${wh}&whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationPreZoneWh(): Observable<Type.ResponseProcessGetOptionsWh> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWh>(
      `${this.processCbUrl + 'location-pre-zone-wh'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationPreZoneArea(
    whCode: string,
    areaCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsArea> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsArea>(
      `${this.processCbUrl + 'location-pre-zone-area'}?whCode=${whCode}&areaCode=${areaCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationPreZoneLevel(
    whCode: string,
    areaCode: string,
    levelCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsLevel> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsLevel>(
      `${this.processCbUrl + 'location-pre-zone-level'}?whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationDockWh(): Observable<Type.ResponseProcessGetOptionsWh> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWh>(
      `${this.processCbUrl + 'location-dock-wh'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationDockArea(
    whCode: string,
    areaCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsArea> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsArea>(
      `${this.processCbUrl + 'location-dock-area'}?whCode=${whCode}&areaCode=${areaCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsLocationDockLevel(
    whCode: string,
    areaCode: string,
    levelCode?: string,
  ): Observable<Type.ResponseProcessGetOptionsLevel> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsLevel>(
      `${this.processCbUrl + 'location-dock-level'}?whCode=${whCode}&areaCode=${areaCode}&levelCode=${levelCode}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsJobStatus(
    userType: number,
  ): Observable<Type.ResponseProcessGetOptionsJobStatus> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsJobStatus>(
      `${this.processCbUrl + 'job-status'}?userType=${userType}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsJobLocation(): Observable<Type.ResponseProcessGetOptionsJobLocation> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsJobLocation>(
      `${this.processCbUrl + 'job-location'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsJobType(): Observable<Type.ResponseProcessGetOptionsJobType> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsJobType>(
      `${this.processCbUrl + 'job-type'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsBgPlant(): Observable<Type.ResponseProcessGetOptionsBgPlant> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsBgPlant>(
      `${this.processCbUrl + 'bg-plant'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsWhCcCode(): Observable<Type.ResponseProcessGetOptionsWhCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsWhCcCode>(
      `${this.processCbUrl + 'wh-cc-code'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsSapCcCode(): Observable<Type.ResponseProcessGetOptionsSapCcCode> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsSapCcCode>(
      `${this.processCbUrl + 'sap-cc-code'}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  ProcessGetOptionsProductType(): Observable<Type.ResponseProcessGetOptionsProductType> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsProductType>(
      `${this.processCbUrl + 'product-type'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsCodePallet(): Observable<Type.ResponseProcessGetOptionsCodePallet> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsCodePallet>(
      `${this.processCbUrl + 'code-pallet'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetOptionsSpecialPackageType(): Observable<Type.ResponseProcessGetOptionsSpecialPackageType> {
    return this.httpClient.get<Type.ResponseProcessGetOptionsSpecialPackageType>(
      `${this.processCbUrl + 'special-package-type'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  /*------------------ Process ---------------------*/
  processGetJobList(
    id: number,
    systemNo: string,
    fromCcCode: string,
    toCcCode: string,
    jobStatus: number,
    jobType: number,
    topicName: string,
    page: number,
    pageSize: number,
    sortBy: string,
    sortOrder: string,
    //  WH01 Inbound "ปลายทาง (Product CC)" filter -> tr_job_main.product_cc.
    productCc: string = '',
    //  WH01 Inbound "To Warehouse" filter -> ct_location.wh_code of MWH to-locations.
    toWhCode: string = '',
    //  WH02 Outbound "From / To Location" filters (key null = whole location type).
    fromLocation: Type.JobLocationFilter | null = null,
    toLocation: Type.JobLocationFilter | null = null,
    //  job-list date range + multi-select filters -- only non-empty ones are
    //  sent, so callers that don't use them hit GET job exactly as before.
    multi: Type.JobListMultiFilter | null = null,
  ): Observable<Type.ResponseProcessJobListData> {
    // this.GetToken();
    const multiParams = [
      ['dateFrom', multi?.dateFrom ?? ''],
      ['dateTo', multi?.dateTo ?? ''],
      ['fromCcCodes', (multi?.fromCcCodes ?? []).join(',')],
      ['toCcCodes', (multi?.toCcCodes ?? []).join(',')],
      ['toWhCodes', (multi?.toWhCodes ?? []).join(',')],
      ['statusIds', (multi?.statusIds ?? []).join(',')],
      ['fromLocations', multi?.fromLocations?.length ? JSON.stringify(multi.fromLocations) : ''],
      ['toLocations', multi?.toLocations?.length ? JSON.stringify(multi.toLocations) : ''],
      ['productCcs', (multi?.productCcs ?? []).join(',')],
      ['typeIds', (multi?.typeIds ?? []).join(',')],
    ]
      .filter(([, value]) => !!value)
      .map(([key, value]) => `&${key}=${encodeURIComponent(value)}`)
      .join('');
    return this.httpClient.get<Type.ResponseProcessJobListData>(
      `${
        this.processUrl + 'job'
      }?id=${id}&systemNo=${systemNo}&fromCcCode=${fromCcCode}&toCcCode=${toCcCode}&jobStatus=${jobStatus}&jobType=${jobType}&topicName=${topicName}&page=${page}&pageSize=${pageSize}&sortBy=${sortBy}&sortOrder=${sortOrder}&productCc=${encodeURIComponent(productCc)}&toWhCode=${encodeURIComponent(toWhCode)}&fromLocationType=${encodeURIComponent(fromLocation?.type ?? '')}&fromLocationKey=${encodeURIComponent(fromLocation?.key ?? '')}&toLocationType=${encodeURIComponent(toLocation?.type ?? '')}&toLocationKey=${encodeURIComponent(toLocation?.key ?? '')}${multiParams}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET api/v1/process/job/wms-plus-log?jobMainIds=101,102 -- 1 batch call
  //  per job-list page load (not 1 per row) for the WMS+ put-away sync
  //  status badge.
  processGetWmsPlusLogStatus(
    jobMainIds: string,
  ): Observable<Type.ResponseProcessWmsPlusLogStatus> {
    return this.httpClient.get<Type.ResponseProcessWmsPlusLogStatus>(
      `${this.processUrl + 'job/wms-plus-log'}?jobMainIds=${jobMainIds}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET api/v1/process/job/total-pallet/source-changed?jobMainIds=101,102 --
  //  1 batch call per page, same as processGetWmsPlusLogStatus, for the
  //  "source changed" badge (total_pallet needs a re-approve).
  processGetTotalPalletSourceChanged(
    jobMainIds: string,
  ): Observable<Type.ResponseProcessTotalPalletSourceChanged> {
    return this.httpClient.get<Type.ResponseProcessTotalPalletSourceChanged>(
      `${this.processUrl + 'job/total-pallet/source-changed'}?jobMainIds=${jobMainIds}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  PATCH api/v1/process/job/{jobId}/wms-plus/resend -- re-sends the WMS+
  //  confirm-location notification for a job whose last attempt failed (see
  //  job-list.html's WMS+ status badge resend button).
  processResendWmsPlus(jobId: number): Observable<Type.ResponseProcessResendWmsPlus> {
    return this.httpClient.patch<Type.ResponseProcessResendWmsPlus>(
      `${this.processUrl + 'job'}/${jobId}/wms-plus/resend`,
      {},
      { headers: this.getAuthHeaders() },
    );
  }

  processGetTransactionLog(
    topic: string,
    activity: string,
    editor: number,
    detail: string,
    modifieddate: string,
    page: number,
    pageSize: number,
  ): Observable<Type.ResponseProcessTransactionLogData> {
    return this.httpClient.get<Type.ResponseProcessTransactionLogData>(
      `${
        this.processUrl + 'transaction-log'
      }?topic=${topic}&activity=${activity}&editor=${editor}&modifieddate=${modifieddate}&page=${page}&pageSize=${pageSize}&detail=${detail}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetWmsInterfaceLog(
    mode: string,
    keyword: string,
    status: string,
    datefrom: string,
    dateto: string,
    page: number,
    pageSize: number,
  ): Observable<Type.ResponseProcessWmsInterfaceLogData> {
    return this.httpClient.get<Type.ResponseProcessWmsInterfaceLogData>(
      `${this.processUrl + 'wms-interface-log'}`,
      {
        headers: this.getAuthHeaders(),
        params: { mode, keyword, status, datefrom, dateto, page, pageSize },
      },
    );
  }

  processGetWmsInterfaceLogDetail(id: number): Observable<Type.ResponseProcessWmsInterfaceLogDetail> {
    return this.httpClient.get<Type.ResponseProcessWmsInterfaceLogDetail>(
      `${this.processUrl + 'wms-interface-log'}/${id}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetVehicle(filter?: Type.VehicleFilter): Observable<Type.ResponseProcessGetVehicle> {
    let params: any = {};
    if (filter) {
      if (filter.licensePlate) params['licensePlate'] = filter.licensePlate.trim();
      if (filter.carrierName) params['carrierName'] = filter.carrierName.trim();
      if (filter.vehicleType) params['vehicleType'] = filter.vehicleType;
      if (filter.isActive) params['isActive'] = filter.isActive;
      if (filter.page && filter.page > 0) params['page'] = filter.page;
      if (filter.pageSize && filter.pageSize > 0) params['pageSize'] = filter.pageSize;
      if (filter.sortBy) params['sortBy'] = filter.sortBy;
      if (filter.sortOrder) params['sortOrder'] = filter.sortOrder;
    }
    return this.httpClient.get<Type.ResponseProcessGetVehicle>(`${this.masterUrl + 'vehicle'}`, {
      headers: this.getAuthHeaders(),
      params,
    });
  }

  ProcessGetUser(filter?: Type.UserFilter): Observable<Type.ResponseProcessGetUser> {
    let params: any = {};
    if (filter) {
      if (filter.userName) params['userName'] = filter.userName.trim();
      if (filter.thaiName) params['thaiName'] = filter.thaiName.trim();
      if (filter.engName) params['engName'] = filter.engName.trim();
      if (filter.departmentId) params['departmentId'] = filter.departmentId;
      if (filter.roleId) params['roleId'] = filter.roleId;
      if (filter.page && filter.page > 0) params['page'] = filter.page;
      if (filter.pageSize && filter.pageSize > 0) params['pageSize'] = filter.pageSize;
      if (filter.sortBy) params['sortBy'] = filter.sortBy;
      if (filter.sortOrder) params['sortOrder'] = filter.sortOrder;
    }
    return this.httpClient.get<Type.ResponseProcessGetUser>(`${this.masterUrl + 'user'}`, {
      headers: this.getAuthHeaders(),
      params,
    });
  }

  ProcessInsertUser(data: Type.RequestInsertUpdateDeleteUser): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.masterUrl + 'user'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessUpdateUser(
    id: number,
    data: Type.RequestInsertUpdateDeleteUser,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(`${this.masterUrl + 'user'}/${id}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessDeleteUser(
    id: number,
    data: Type.RequestInsertUpdateDeleteUser,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.delete<Type.ResponseStandard>(`${this.masterUrl + 'user'}/${id}`, {
      headers: this.getAuthHeaders(),
      body: data,
    });
  }

  //  Role Management
  ProcessGetRole(filter?: Type.RoleFilter): Observable<Type.ResponseProcessGetRole> {
    let params: any = {};
    if (filter) {
      if (filter.roleName) params['roleName'] = filter.roleName.trim();
      if (filter.details) params['details'] = filter.details.trim();
      if (filter.isActive) params['isActive'] = filter.isActive;
      if (filter.page && filter.page > 0) params['page'] = filter.page;
      if (filter.pageSize && filter.pageSize > 0) params['pageSize'] = filter.pageSize;
      if (filter.sortBy) params['sortBy'] = filter.sortBy;
      if (filter.sortOrder) params['sortOrder'] = filter.sortOrder;
    }
    return this.httpClient.get<Type.ResponseProcessGetRole>(`${this.masterUrl + 'role'}`, {
      headers: this.getAuthHeaders(),
      params,
    });
  }

  ProcessInsertRole(data: Type.RequestInsertUpdateDeleteRole): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.masterUrl + 'role'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessUpdateRole(
    id: number,
    data: Type.RequestInsertUpdateDeleteRole,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(`${this.masterUrl + 'role'}/${id}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessDeleteRole(
    id: number,
    data: Type.RequestInsertUpdateDeleteRole,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.delete<Type.ResponseStandard>(`${this.masterUrl + 'role'}/${id}`, {
      headers: this.getAuthHeaders(),
      body: data,
    });
  }

  //  Permission keys of the logged-in user (their role in their department),
  //  read live from ct_role_permission -- see permission.service.ts.
  ProcessGetMyPermission(): Observable<Type.ResponseProcessGetMyPermission> {
    return this.httpClient.get<Type.ResponseProcessGetMyPermission>(
      `${this.masterUrl + 'me/permission'}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetRolePermission(roleId: number): Observable<Type.ResponseProcessGetRolePermission> {
    return this.httpClient.get<Type.ResponseProcessGetRolePermission>(
      `${this.masterUrl + 'role'}/${roleId}/permission`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessSaveRolePermission(
    roleId: number,
    data: Type.RequestSaveRolePermission,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(
      `${this.masterUrl + 'role'}/${roleId}/permission`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetPalletList(
    palletNo: string,
    grade: string,
    lot: string,
    locationType: string,
    locationId: number,
    page: number = 1,
    pageSize: number = 10,
    qrCode: string = '',
    sortBy: string = '',
    sortOrder: string = '',
  ): Observable<Type.ResponseProcessPalletListData> {
    // this.GetToken();
    return this.httpClient.get<Type.ResponseProcessPalletListData>(
      `${
        this.processUrl + 'pallet'
      }?palletNo=${palletNo}&grade=${grade}&lot=${lot}&locationType=${locationType}&locationId=${locationId}&page=${page}&pageSize=${pageSize}&qrCode=${encodeURIComponent(qrCode)}&sortBy=${sortBy}&sortOrder=${sortOrder}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processMovePalletsToBagging(palletIds: number[], userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-management/move-to-bagging`,
      { palletIds, userId },
      { headers: this.getAuthHeaders() },
    );
  }

  processGetDummyPalletList(
    palletNo: string,
    locationType: string,
    page: number = 1,
    pageSize: number = 25,
  ): Observable<Type.ResponseProcessDummyPalletList> {
    return this.httpClient.get<Type.ResponseProcessDummyPalletList>(
      `${this.processUrl}pallet-management/dummy?palletNo=${encodeURIComponent(palletNo)}&locationType=${locationType}&page=${page}&pageSize=${pageSize}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processCreateDummyPallet(qty: number, userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-management/dummy`,
      { qty, userId },
      { headers: this.getAuthHeaders() },
    );
  }

  processClearDummyPallets(palletIds: number[], userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-management/dummy/clear`,
      { palletIds, userId },
      { headers: this.getAuthHeaders() },
    );
  }

  processGetPalletListByLocation(
    locationId: number,
    locationType: string = 'MWH',
    page: number = 1,
    pageSize: number = 1000,
  ): Observable<Type.ResponseProcessPalletListByLocation> {
    // this.GetToken();
    return this.httpClient.get<Type.ResponseProcessPalletListByLocation>(
      `${
        this.processUrl + 'pallet/by-location'
      }?locationId=${locationId}&locationType=${locationType}&page=${page}&pageSize=${pageSize}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetBagList(
    pllaetId: string,
    page: number,
    pageSize: number,
  ): Observable<Type.ResponseProcessBagListData> {
    // this.GetToken();
    return this.httpClient.get<Type.ResponseProcessBagListData>(
      `${this.processUrl + 'bag'}?palletId=${pllaetId}&page=${page}&pageSize=${pageSize}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetPalletHistory(palletId: string): Observable<Type.ResponseProcessPalletHistory> {
    return this.httpClient.get<Type.ResponseProcessPalletHistory>(
      `${this.processUrl + 'pallet/history'}?palletId=${palletId}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processInsertBag(data: any): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.processUrl + 'bag'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  processUpdateBag(
    id: number,
    data: {
      grade: string;
      lot: string;
      runningNumber: string;
      qty: number;
      userId: number;
    },
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(`${this.processUrl + 'bag'}/${id}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  processDeleteBag(id: number, userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.delete<Type.ResponseStandard>(`${this.processUrl + 'bag'}/${id}`, {
      headers: this.getAuthHeaders(),
      body: { id, userId },
    });
  }

  processImportJobShipment(
    data: Type.RequestImportJobShipmentItem[],
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}job/shipment/import`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET job/shipment -- job-list.ts's shipment-list modal (opened via the
  //  header "Shipment" button). Optional filters (statusIds /
  //  loadingFrom / loadingTo, dates as yyyy-MM-dd) are only sent when set.
  processGetJobShipmentList(
    shipmentNo: string,
    deliveryNo: string,
    page: number,
    pageSize: number,
    filters: { statusIds?: number[]; loadingFrom?: string; loadingTo?: string } = {},
  ): Observable<Type.ResponseProcessJobShipmentListData> {
    let url = `${this.processUrl + 'job/shipment'}?shipmentNo=${encodeURIComponent(shipmentNo)}&deliveryNo=${encodeURIComponent(deliveryNo)}&page=${page}&pageSize=${pageSize}`;
    if (filters.statusIds?.length) url += `&statusIds=${filters.statusIds.join(',')}`;
    if (filters.loadingFrom) url += `&loadingFrom=${filters.loadingFrom}`;
    if (filters.loadingTo) url += `&loadingTo=${filters.loadingTo}`;
    return this.httpClient.get<Type.ResponseProcessJobShipmentListData>(url, {
      headers: this.getAuthHeaders(),
    });
  }

  //  PATCH job/map-shipment-special -- shipment-list's "Map DO Special" action.
  processMapShipmentSpecial(
    data: Type.RequestMapShipmentSpecial,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.patch<Type.ResponseStandard>(
      `${this.processUrl}job/map-shipment-special`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  POST job/picking -- shipment-list's "สร้างงาน Picking" action.
  processCreatePickingJob(
    data: Type.RequestCreatePickingJobItem,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.processUrl}job/picking`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  processCreateInternalTransferJob(
    data: Type.RequestCreateInternalTransferJobItem,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}job/internal-transfer`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET job/internal-transfer -- job-wh-internal-transfer-list's own list
  //  (separate from GET job/special's pattern, same idea: a job type not
  //  covered by the unified pProcessGetJobList view gets its own list SP).
  processGetInternalTransferJobList(
    systemNo: string,
    dateFrom: string,
    dateTo: string,
    jobStatus: number,
    page: number,
    pageSize: number,
    id: number = 0,
    //  Multi-select filters
    //  (scratch_16_alter_pProcessGetInternalTransferJobList_multi_filter.sql),
    //  sent comma-separated; empty = not filtered.
    multi?: {
      statusIds?: number[];
      fromWhCodes?: string[];
      toWhCodes?: string[];
      productCcs?: string[];
      sortBy?: string;
      sortOrder?: string;
    },
  ): Observable<Type.ResponseProcessInternalTransferJobListData> {
    const statusIds = (multi?.statusIds ?? []).join(',');
    const fromWhCodes = (multi?.fromWhCodes ?? []).join(',');
    const toWhCodes = (multi?.toWhCodes ?? []).join(',');
    const productCcs = (multi?.productCcs ?? []).join(',');
    const sortBy = multi?.sortBy ?? '';
    const sortOrder = multi?.sortOrder ?? '';
    return this.httpClient.get<Type.ResponseProcessInternalTransferJobListData>(
      `${
        this.processUrl + 'job/internal-transfer'
      }?id=${id}&systemNo=${encodeURIComponent(systemNo)}&dateFrom=${dateFrom}&dateTo=${dateTo}&jobStatus=${jobStatus}&statusIds=${encodeURIComponent(statusIds)}&fromWhCodes=${encodeURIComponent(fromWhCodes)}&toWhCodes=${encodeURIComponent(toWhCodes)}&productCcs=${encodeURIComponent(productCcs)}&page=${page}&pageSize=${pageSize}&sortBy=${sortBy}&sortOrder=${sortOrder}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET job/transfer-wh -- WH04 Transfer Warehouse (job type 11) own API,
  //  same response shape as GET job (pProcessGetTransferWhJobList, sql/50).
  processGetTransferWhJobList(
    systemNo: string,
    date: string,
    jobStatus: number,
    page: number,
    pageSize: number,
    id: number = 0,
    //  WH ต้นทาง / ปลายทาง (VTransferWhForm.source / wh_code, sql/51).
    fromWhCode: string = '',
    toWhCode: string = '',
    //  Multi-select filters (sql/pProcessGetTransferWhJobList_multi_filter.sql),
    //  sent comma-separated; empty = not filtered.
    //  dateTo: create-date range end ('date' = start), yyyy-MM-dd.
    multi?: {
      statusIds?: number[];
      fromWhCodes?: string[];
      toWhCodes?: string[];
      productCcs?: string[];
      dateTo?: string;
    },
  ): Observable<Type.ResponseProcessTransferWhJobListData> {
    const dateTo = multi?.dateTo ?? '';
    const statusIds = (multi?.statusIds ?? []).join(',');
    const fromWhCodes = (multi?.fromWhCodes ?? []).join(',');
    const toWhCodes = (multi?.toWhCodes ?? []).join(',');
    const productCcs = (multi?.productCcs ?? []).join(',');
    return this.httpClient.get<Type.ResponseProcessTransferWhJobListData>(
      `${
        this.processUrl + 'job/transfer-wh'
      }?id=${id}&systemNo=${encodeURIComponent(systemNo)}&date=${date}&jobStatus=${jobStatus}&fromWhCode=${encodeURIComponent(fromWhCode)}&toWhCode=${encodeURIComponent(toWhCode)}&statusIds=${encodeURIComponent(statusIds)}&fromWhCodes=${encodeURIComponent(fromWhCodes)}&toWhCodes=${encodeURIComponent(toWhCodes)}&productCcs=${encodeURIComponent(productCcs)}&dateTo=${dateTo}&page=${page}&pageSize=${pageSize}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET job/transfer-wh?id={id} -- one TW job for job-wh-transfer-detail,
  //  in the same shape GET job returns for job-detail.
  processGetTransferWhJobDetail(id: number): Observable<Type.ResponseProcessJobListData> {
    return this.httpClient.get<Type.ResponseProcessJobListData>(
      `${this.processUrl + 'job/transfer-wh'}?id=${id}&page=1&pageSize=1`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  GET job/internal-transfer/{jobId} -- job-wh-internal-transfer-list's
  //  Edit action, to pre-fill the same create-form/pickers used to create it.
  processGetInternalTransferJobDetail(
    jobId: number,
  ): Observable<Type.ResponseProcessInternalTransferJobDetailData> {
    return this.httpClient.get<Type.ResponseProcessInternalTransferJobDetailData>(
      `${this.processUrl}job/internal-transfer/${jobId}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processUpdateInternalTransferJob(
    jobId: number,
    data: Type.RequestCreateInternalTransferJobItem,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(
      `${this.processUrl}job/internal-transfer/${jobId}`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  /*------------------ Process - Pallet Adjustment ---------------------*/
  //  NOTE: Backend endpoints below do not exist yet -- these are stubs
  //  drafted alongside the pallet-adjustment component/API spec so the
  //  screen can be wired up as soon as the corresponding controllers are
  //  implemented. See conversation for the suggested API spec + SP draft.

  processGetPalletAdjustmentOverview(
    filter: Type.PalletAdjustmentFilter,
  ): Observable<Type.ResponseProcessPalletAdjustmentOverview> {
    return this.httpClient.get<Type.ResponseProcessPalletAdjustmentOverview>(
      `${this.processUrl + 'pallet-adjustment/overview'}?printDateFrom=${filter.printDateFrom ?? ''}&printDateTo=${filter.printDateTo ?? ''}&ccCode=${filter.ccCode ?? ''}&grade=${filter.grade ?? ''}&lot=${filter.lot ?? ''}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processGetPalletAdjustmentBagList(
    palletId: number,
  ): Observable<Type.ResponseProcessPalletAdjustmentBagList> {
    return this.httpClient.get<Type.ResponseProcessPalletAdjustmentBagList>(
      `${this.processUrl + 'pallet-adjustment/bag'}?palletId=${palletId}`,
      { headers: this.getAuthHeaders() },
    );
  }

  processShiftMissingBag(
    data: Type.RequestPalletAdjustmentShiftMissingBag,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/shift-missing`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processPullBagOut(
    data: Type.RequestPalletAdjustmentPullBagOut,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/pull-out`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processAddBagIn(
    data: Type.RequestPalletAdjustmentAddBagIn,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/add-in`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  processReorderPallet(
    data: Type.RequestPalletAdjustmentReorderPallet,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/reorder`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Quick Actions -- จบพาเลท (dbo.sp_PalletAdjustment_FinishPallet, sets
  //  pallet_status_id = 3 CONFIRMED)
  processFinishPallet(
    data: Type.RequestPalletAdjustmentFinishPallet,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/finish`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Orphan Bag "สร้างพาเลทใหม่" -- pop-up ดึง ct_grade_package_ratio ของ grade
  processGetGradeRatio(grade: string): Observable<Type.ResponsePalletAdjustmentGradeRatio> {
    return this.httpClient.get<Type.ResponsePalletAdjustmentGradeRatio>(
      `${this.processUrl}pallet-adjustment/grade-ratio?grade=${encodeURIComponent(grade)}`,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Orphan Bag "สร้างพาเลทใหม่" -- dbo.sp_PalletAdjustment_CreatePallet
  processCreatePallet(
    data: Type.RequestPalletAdjustmentCreatePallet,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/create-pallet`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Quick Actions -- ถุง Reject (dbo.pProcessUpdateBagRejectStatus @reject=1)
  processRejectBag(
    data: Type.RequestPalletAdjustmentRejectBag,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/reject-bag`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Quick Actions -- เพิ่มข้อมูล (dbo.sp_PalletAdjustment_AddMissingBag)
  processAddMissingBag(
    data: Type.RequestPalletAdjustmentAddMissingBag,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/add-missing-bag`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  //  Rejected Bags "คืนค่า" -- dbo.pProcessUpdateBagRejectStatus @reject=0
  processUnrejectBag(
    data: Type.RequestPalletAdjustmentUnrejectBag,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(
      `${this.processUrl}pallet-adjustment/unreject-bag`,
      data,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessGetDo(doNo: string, grade: string): Observable<Type.ResponseProcessGetDo> {
    return this.httpClient.get<Type.ResponseProcessGetDo>(
      `${this.processUrl + 'do'}?doNo=${doNo}&grade=${grade}`,
      {
        headers: this.getAuthHeaders(),
      },
    );
  }

  //  filters: job-list's Map DO Shipment filter bar (search / grades /
  //  loadingFrom / loadingTo as yyyy-MM-dd), only sent when set.
  ProcessGetDoFromExcel(
    doNo: string,
    grade: string,
    filters: { search?: string; grades?: string[]; loadingFrom?: string; loadingTo?: string } = {},
  ): Observable<Type.ResponseProcessGetDoFromExcel> {
    let url = `${this.processUrl + 'do-from-excel'}?doNo=${doNo}&grade=${grade}`;
    if (filters.search) url += `&search=${encodeURIComponent(filters.search)}`;
    if (filters.grades?.length) url += `&grades=${encodeURIComponent(filters.grades.join(','))}`;
    if (filters.loadingFrom) url += `&loadingFrom=${filters.loadingFrom}`;
    if (filters.loadingTo) url += `&loadingTo=${filters.loadingTo}`;
    return this.httpClient.get<Type.ResponseProcessGetDoFromExcel>(url, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessUpdateDo(data: any): Observable<Type.ResponseStandard> {
    return this.httpClient.patch<Type.ResponseStandard>(`${this.processUrl + 'do'}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  ProcessGetDoPreparing(itemId: number): Observable<Type.ResponseProcessGetDoPreparing> {
    return this.httpClient.get<Type.ResponseProcessGetDoPreparing>(
      `${this.processUrl}do-preparing?item_id=${itemId}`,
      { headers: this.getAuthHeaders() },
    );
  }

  ProcessUpdateDoPreparing(data: Type.RequestProcessUpdateDoPreparing): Observable<Type.ResponseStandard> {
    return this.httpClient.patch<Type.ResponseStandard>(`${this.processUrl}do-preparing`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  /*------------------ Special Job ---------------------*/

  //  isApprove filters by tr_special_detail.is_approve ('Y'/'N') -- pass ''
  //  to leave it unfiltered. Used by the Map DO Special picker
  //  (job-list.ts's fetchSpecialJobCandidates) to show only approved
  //  pallets; job-special-list.ts/job-special-detail.ts pass '' since they
  //  list everything regardless of approval status.
  processGetSpecialJobList(
    id: number,
    docNo: string,
    dateFrom: string,
    dateTo: string,
    jobStatus: number,
    jobType: number,
    page: number,
    pageSize: number,
    sortBy: string,
    sortOrder: string,
    isApprove: string = '',
    //  job-list Map DO Special Grade filter (sql/101), only sent when set.
    grades: string[] = [],
  ): Observable<Type.ResponseProcessSpecialJobListData> {
    return this.httpClient.get<Type.ResponseProcessSpecialJobListData>(
      `${
        this.processUrl + 'job/special'
      }?id=${id}&docNo=${docNo}&dateFrom=${dateFrom}&dateTo=${dateTo}&jobStatus=${jobStatus}&jobType=${jobType}&page=${page}&pageSize=${pageSize}&sortBy=${sortBy}&sortOrder=${sortOrder}&isApprove=${isApprove}` +
        (grades.length ? `&grades=${encodeURIComponent(grades.join(','))}` : ''),
      { headers: this.getAuthHeaders() },
    );
  }

  processCreateSpecialJob(
    data: Type.RequestCreateSpecialJobItem[],
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.post<Type.ResponseStandard>(`${this.processUrl}job/special`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  //  Saves edits made in the Inspect modal (job-special-list.ts's
  //  onSaveInspectJob) back to tr_special_header/tr_special_detail.
  processUpdateSpecialJob(
    id: number,
    data: Type.RequestUpdateSpecialJobItem,
  ): Observable<Type.ResponseStandard> {
    return this.httpClient.put<Type.ResponseStandard>(`${this.processUrl}job/special/${id}`, data, {
      headers: this.getAuthHeaders(),
    });
  }

  processDeleteSpecialJob(id: number, userId: number): Observable<Type.ResponseStandard> {
    return this.httpClient.delete<Type.ResponseStandard>(`${this.processUrl}job/special/${id}`, {
      headers: this.getAuthHeaders(),
      body: { id, userId },
    });
  }
}
