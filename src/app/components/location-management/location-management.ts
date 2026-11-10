import { ChangeDetectorRef, Component } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { PageEvent } from '@angular/material/paginator';
import { MatSlideToggleChange } from '@angular/material/slide-toggle';
import Swal from 'sweetalert2';
import * as XLSX from 'xlsx';
import { forkJoin } from 'rxjs';

interface LocationManagementRow {
  no: number;
  id: number | null;
  locationId: number;
  locationName: string;
  titleLocation: string;
  whCode: string;
  //  Code actually embedded in the QR value - normally same as whCode, but mock rows can
  //  display one warehouse code (eg. "WH38") while the QR still encodes the real one ("M38").
  qrWhCode: string;
  areaCode: string;
  levelCode: string;
  locationCode: string;
  priorityId: number | null;
  priorityName: string | null;
  status: string;
  updatedDatetime: string | null | undefined;
  updatedDateDisplay: string | null;
  updatedTimeDisplay: string | null;
  isActive: boolean;
}

//  Dock / Pre-Zone rows - those two location types only expose
//  {id, wh_code, area_code, level_code, location_code, location_desc, is_active} from WMS+ (see
//  processGetDockLocation / processGetPrezoneLocation), with no priority/status/updated fields
//  and no edit/sync actions, so they get a lighter read-only row shape than LocationManagementRow.
interface SimpleLocationRow {
  no: number;
  id: number;
  locationName: string;
  titleLocation: string;
  whCode: string;
  //  Code actually embedded in the QR value - see buildSimpleLocationRow. Dock's wh_code now
  //  comes back "WH"-prefixed (eg. "WH38") for display, but the physical QR/barcode still needs
  //  the bare code (eg. "38D01", not "WH38D01").
  qrWhCode: string;
  areaCode: string;
  levelCode: string;
  locationCode: string;
  isActive: boolean;
}

type LocationType = 'MWH' | 'DOCK' | 'PRE-ZONE' | 'PLANT';

interface PlantRow {
  no: number;
  id: number;
  plantCode: string;
  plantLocation: string;
}

//  Selection/print (checkboxes, Print Selected) is shared across the MWH table and the
//  Dock/Pre-Zone table - both row shapes carry the {id, locationName, titleLocation} that
//  selection/printing actually need, so one Map/one set of helpers covers either table.
type AnyLocationRow = LocationManagementRow | SimpleLocationRow;

@Component({
  selector: 'app-location-management',
  standalone: false,
  templateUrl: './location-management.html',
  styleUrl: './location-management.css',
})
export class LocationManagement {
  //  Location Management always looks at the Boardman main warehouse (MWH) - same convention
  //  used everywhere else in this app (see select-wh-location.ts default warehouseCode).
  private readonly wh = 'MWH';

  constructor(
    private restService: CrudService,
    private changeDetectorRef: ChangeDetectorRef,
  ) {}

  //  Define Column
  displayedColumns: string[] = [
    'select',
    'no',
    'locationName',
    'whCode',
    'priority',
    'status',
    'isActive',
    'updatedDatetime',
    'action',
    'edit'
  ];

  //  Filter Form
  filter: Type.LocationManagementFilter = {
    locationDesc: '',
    whCode: 'M35',
    priorityName: '',
    statusId: 0,
    page: 1,
    pageSize: 25,
  };

  _printLocation = '';
  _printLocationName = '';
  _locationListTableData: LocationManagementRow[] = [];
  printSelectedLocationsData: { qrValue: string; displayTitle: string }[] = [];
  printMode: 'single' | 'multiple' | null = null;
  totalCount = 0;
  //  Skeleton loading -- the MWH / Dock / Pre-Zone table shows shimmer rows
  //  while its location list loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });
  isSelectingAllLocations = false;
  isExportingExcel = false;

  //  Keyed by row, holding the full row (not just the key) so Print Selected
  //  works on locations picked via "select all" from pages that aren't the
  //  currently loaded one -- mirrors vehicle-list.ts's selectedVehicles. Shared between the
  //  MWH table and the Dock/Pre-Zone table (see AnyLocationRow).
  private selectedLocations = new Map<number, AnyLocationRow>();
  isSelectingAllDockPreZoneLocations = false;

  optionWarehouse: Type.ResultProcessGetOptionsWh[] = []; 
  printVehicleData: Type.ResponseProcessGetOptionsWh | null = null;

  //  Priority filter / edit options. There is no dedicated CB endpoint for priority yet, so the
  //  list is built from whatever {priority_id, priority_name} pairs show up in the loaded data -
  //  this avoids guessing IDs for Fast/Medium/Slow.
  priorityOptions: { id: number; name: string }[] = [];

  statusOptions: { id: number; label: string }[] = [
    { id: 1, label: 'เปิดใช้งาน' },
    { id: 2, label: 'ปิดใช้งาน' },
  ];

  isEditMode = false;
  showEditModal = false;
  _selectedEditItem: any = {
    id: null,
    locationName: '',
    priorityId: null,
    isActive: true,
  };

  //  Location Type tabs - MWH keeps the existing full-featured table above; Dock / Pre-Zone
  //  show a lighter read-only table since their API still doesn't return priority/status/updated
  //  (is_active is now available - see pILogistic_ProcessGetDockLocation/PreZoneLocation.sql).
  locationType: LocationType = 'MWH';
  dockPreZoneDisplayedColumns: string[] = ['select', 'no', 'locationName', 'whCode', 'isActive', 'action'];
  dockPreZoneFilter = { whCode: '', areaCode: '', levelCode: '', locationDesc: '' };
  optionDockPreZoneWh: Type.ResultProcessGetOptionsWh[] = [];
  optionDockPreZoneArea: Type.ResultProcessGetOptionsArea[] = [];
  optionDockPreZoneLevel: Type.ResultProcessGetOptionsLevel[] = [];
  _dockPreZoneListTableData: SimpleLocationRow[] = [];
  //  Separate pagination state from the MWH tab's filter.page/pageSize/totalCount, since both
  //  tabs' paginators are independent (see pILogistic_ProcessGetDockLocation/PreZoneLocation.sql).
  dockPreZonePage = 1;
  dockPreZonePageSize = 25;
  dockPreZoneTotalCount = 0;

  // Plant options populate the filter; the table itself is loaded from
  // GET master/location/bg-plant/{plantCode} ({ id, plant_code, plant_location }).
  plantDisplayedColumns: string[] = ['select', 'no', 'plantCode', 'plantLocation', 'action'];
  plantFilter = { plantCode: '', plantLocation: '' };
  optionPlant: Type.ResultProcessGetOptionsBgPlant[] = [];
  private plantRows: PlantRow[] = [];
  _plantListTableData: PlantRow[] = [];
  plantPage = 1;
  plantPageSize = 25;
  plantTotalCount = 0;
  private selectedPlantRows = new Map<number, PlantRow>();

  get selectedPlantCount(): number {
    return this.selectedPlantRows.size;
  }

  isPlantSelected(row: PlantRow): boolean {
    return this.selectedPlantRows.has(row.id);
  }

  togglePlantSelection(row: PlantRow, selected: boolean): void {
    if (selected) this.selectedPlantRows.set(row.id, row);
    else this.selectedPlantRows.delete(row.id);
  }

  isAllCurrentPlantsSelected(): boolean {
    return this._plantListTableData.length > 0 && this._plantListTableData.every((row) => this.isPlantSelected(row));
  }

  isSomeCurrentPlantsSelected(): boolean {
    return this._plantListTableData.some((row) => this.isPlantSelected(row)) && !this.isAllCurrentPlantsSelected();
  }

  toggleSelectAllPlants(selected: boolean): void {
    this._plantListTableData.forEach((row) => this.togglePlantSelection(row, selected));
  }

  clearSelectedPlants(): void {
    this.selectedPlantRows.clear();
  }

  async ngOnInit() {
    this.fetchOptionWarehouse();

    this.fetchLocationList();
  }

  //  Warehouse Option (whCode list under the fixed MWH warehouse type)
  fetchOptionWarehouse() {
    this.restService.ProcessGetOptionsLocationWh(this.wh).subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.optionWarehouse = data.data || [];
        }
      },
      (error) => {
        console.error('Error fetching warehouse options:', error);
      },
    );
  }

  //  Location Type tab switch - MWH re-runs the existing paginated fetch; Dock / Pre-Zone
  //  load the full list right away (Warehouse/Area/Level are optional, independent narrowing
  //  filters, not required/cascading steps - see fetchDockPreZoneLocationList below).
  onSelectLocationType(type: LocationType) {
    if (this.locationType === type) return;

    this.locationType = type;
    this.resetDockPreZoneFilter();

    if (type === 'MWH') {
      this.fetchLocationList();
    } else if (type === 'PLANT') {
      this.resetPlantFilter();
      this.fetchPlantOptions();
    } else {
      this.fetchOptionDockPreZoneWh();
      this.fetchOptionDockPreZoneArea();
      this.fetchOptionDockPreZoneLevel();
      this.fetchDockPreZoneLocationList();
    }
  }

  private resetDockPreZoneFilter() {
    this.dockPreZoneFilter = { whCode: '', areaCode: '', levelCode: '', locationDesc: '' };
    this.optionDockPreZoneWh = [];
    this.optionDockPreZoneArea = [];
    this.optionDockPreZoneLevel = [];
    this._dockPreZoneListTableData = [];
    this.dockPreZonePage = 1;
    this.dockPreZoneTotalCount = 0;
  }

  private resetPlantFilter(): void {
    this.plantFilter = { plantCode: '', plantLocation: '' };
    this.plantRows = [];
    this._plantListTableData = [];
    this.plantPage = 1;
    this.plantTotalCount = 0;
    this.clearSelectedPlants();
  }

  private fetchPlantOptions(): void {
    this.restService.ProcessGetOptionsBgPlant().subscribe({
      next: (data) => (this.optionPlant = data?.status === 'success' ? data.data || [] : []),
      error: (error) => {
        this.optionPlant = [];
        console.error('Error fetching plant options:', error);
      },
    });
  }

  onClickSearchPlant(): void {
    this.clearSelectedPlants();
    this.plantPage = 1;
    const code = this.plantFilter.plantCode.trim();
    const plantCodes = code ? [code] : this.optionPlant.map((plant) => plant.bg_plant_code);
    if (plantCodes.length === 0) {
      this.plantRows = [];
      this.applyPlantFilter();
      return;
    }

    this.isLoading = true;
    forkJoin(plantCodes.map((plantCode) => this.restService.processGetBgPlantLocation(plantCode))).subscribe({
      next: (responses) => {
        this.isLoading = false;
        this.plantRows = responses
          .filter((response) => response?.status === 'success')
          .flatMap((response) => response.data || [])
          .map((plant, index) => ({ no: index + 1, id: plant.id, plantCode: plant.plant_code, plantLocation: plant.plant_location }));
        this.applyPlantFilter();
      },
      error: (error) => {
        this.isLoading = false;
        this.plantRows = [];
        this.applyPlantFilter();
        this.SweetAlert('error', 'Message : Error see in log.');
        console.error('Error fetching plant locations:', error);
      },
    });
  }

  onClickClearPlantFilter(): void {
    this.resetPlantFilter();
  }

  onPlantPageEvent(event: PageEvent): void {
    this.clearSelectedPlants();
    this.plantPage = event.pageIndex + 1;
    this.plantPageSize = event.pageSize;
    this.applyPlantFilter();
  }

  private applyPlantFilter(): void {
    const location = this.plantFilter.plantLocation.trim().toLowerCase();
    const rows = this.plantRows.filter((row) => !location || row.plantLocation.toLowerCase().includes(location));
    this.plantTotalCount = rows.length;
    const start = (this.plantPage - 1) * this.plantPageSize;
    this._plantListTableData = rows.slice(start, start + this.plantPageSize).map((row, index) => ({ ...row, no: start + index + 1 }));
  }

  //  Clear Button Event (Dock / Pre-Zone tab) - resets wh/area/level/locationDesc and re-fetches
  //  the full list, same as resetFilter() does for the MWH tab. Re-fetches all three option lists
  //  too since resetDockPreZoneFilter also clears them. Also clears any selected checkboxes,
  //  same as fetchLocationList() already does for the MWH tab's Clear/Search.
  onClickClearDockPreZoneFilter() {
    this.clearSelections();
    this.resetDockPreZoneFilter();
    this.fetchOptionDockPreZoneWh();
    this.fetchOptionDockPreZoneArea();
    this.fetchOptionDockPreZoneLevel();
    this.fetchDockPreZoneLocationList();
  }

  //  Search Button Event (Dock / Pre-Zone tab) - "ชื่อ Location" (locationDesc) is the only
  //  free-text filter; wh/area/level stay as whatever the cascading dropdowns currently hold.
  //  Also clears any selected checkboxes, same as fetchLocationList() already does for the MWH
  //  tab's Clear/Search.
  onClickSearchDockPreZone() {
    this.clearSelections();
    this.dockPreZonePage = 1;
    this.fetchDockPreZoneLocationList();
  }

  //  Warehouse Option for Dock / Pre-Zone - unlike MWH, these two have no `wh` param (they're
  //  each their own fixed location type on the backend, see location-dock-wh / location-pre-zone-wh).
  fetchOptionDockPreZoneWh() {
    const call =
      this.locationType === 'DOCK'
        ? this.restService.ProcessGetOptionsLocationDockWh()
        : this.restService.ProcessGetOptionsLocationPreZoneWh();

    call.subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.optionDockPreZoneWh = data.data || [];
        }
      },
      (error) => {
        console.error('Error fetching dock/pre-zone warehouse options:', error);
      },
    );
  }

  //  Area Option for Dock / Pre-Zone - fetched independent of whCode (empty string -> the
  //  backend's @wh_code IS NULL OR... branch -> every area, confirmed against
  //  pILogistic_ProcessCBGetDockArea/PreZoneArea), so Warehouse/Area/Level never gate each
  //  other; each dropdown always lists everything and only narrows the location list itself.
  //  The backend's DISTINCT is over the full (wh_code, area_code) row, not area_code alone, so
  //  fetching every warehouse's areas together produces the same area_code repeated once per
  //  warehouse it appears under - dedupe by careacode here so the dropdown lists each area once.
  fetchOptionDockPreZoneArea() {
    const call =
      this.locationType === 'DOCK'
        ? this.restService.ProcessGetOptionsLocationDockArea('', '')
        : this.restService.ProcessGetOptionsLocationPreZoneArea('', '');

    call.subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.optionDockPreZoneArea = this.dedupeByKey(data.data || [], (option) => option.careacode);
        }
      },
      (error) => {
        console.error('Error fetching dock/pre-zone area options:', error);
      },
    );
  }

  //  Level Option for Dock / Pre-Zone - same independence + dedupe reasoning as
  //  fetchOptionDockPreZoneArea above. Dock levels are especially repetitive since docks have no
  //  real "level" concept - pILogistic_ProcessCBGetDockLevel hardcodes level_code to '-' for
  //  every row, so without deduping this would list "-" once per warehouse+area combination.
  fetchOptionDockPreZoneLevel() {
    const call =
      this.locationType === 'DOCK'
        ? this.restService.ProcessGetOptionsLocationDockLevel('', '', '')
        : this.restService.ProcessGetOptionsLocationPreZoneLevel('', '', '');

    call.subscribe(
      (data) => {
        if (data && data.status === 'success') {
          this.optionDockPreZoneLevel = this.dedupeByKey(data.data || [], (option) => option.clevelcode);
        }
      },
      (error) => {
        console.error('Error fetching dock/pre-zone level options:', error);
      },
    );
  }

  private dedupeByKey<T>(items: T[], keyOf: (item: T) => string | number): T[] {
    const seen = new Set<string | number>();
    return items.filter((item) => {
      const key = keyOf(item);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  //  Warehouse/Area/Level are independent of each other - each dropdown's own option list is
  //  fetched once (see fetchOptionDockPreZone*) and never re-filtered by a sibling's selection.
  //  Picking one only updates dockPreZoneFilter/resets to page 1 - it does NOT re-fetch the
  //  location list on its own; the user has to press Search (onClickSearchDockPreZone) first,
  //  same as "ชื่อ Location" is a plain text field that doesn't search on every keystroke.
  onSelectDockPreZoneWh() {
    this.dockPreZonePage = 1;
  }

  onSelectDockPreZoneArea() {
    this.dockPreZonePage = 1;
  }

  onSelectDockPreZoneLevel() {
    this.dockPreZonePage = 1;
  }

  //  mat-paginator Event for the Dock / Pre-Zone tab (separate from onPageEvent, which drives
  //  the MWH tab's own paginator/filter.page).
  onDockPreZonePageEvent(event: PageEvent): void {
    this.clearSelections();
    this.dockPreZonePage = event.pageIndex + 1;
    this.dockPreZonePageSize = event.pageSize;
    this.fetchDockPreZoneLocationList();
  }

  //  Loads the Dock / Pre-Zone list - with no filter picked yet this fires with every field
  //  empty, which the API treats as "no filter" and returns everything (mirrors how the MWH tab
  //  shows data immediately without requiring a warehouse to be picked first). Now paginated
  //  server-side via pILogistic_ProcessGetDockLocation/PreZoneLocation's @page/@page_size.
  fetchDockPreZoneLocationList() {
    const { whCode, areaCode, levelCode, locationDesc } = this.dockPreZoneFilter;

    this.isLoading = true;
    //  isActive: '' asks the backend for both active and inactive rows (its default when omitted
    //  is active-only) - Location Management is an admin screen, so it should show everything.
    const call =
      this.locationType === 'DOCK'
        ? this.restService.processGetDockLocation(
            whCode,
            areaCode,
            levelCode,
            '',
            this.dockPreZonePage,
            this.dockPreZonePageSize,
            locationDesc,
            '',
          )
        : this.restService.processGetPrezoneLocation(
            whCode,
            areaCode,
            levelCode,
            '',
            this.dockPreZonePage,
            this.dockPreZonePageSize,
            locationDesc,
            '',
          );

    call.subscribe(
      (data) => {
        this.isLoading = false;
        if (data && data.status === 'success') {
          const pageOffset = (this.dockPreZonePage - 1) * this.dockPreZonePageSize;
          this._dockPreZoneListTableData = (data.data || []).map((item, index) =>
            this.buildSimpleLocationRow(item, pageOffset + index + 1),
          );
          this.dockPreZoneTotalCount = data.total_count ?? this._dockPreZoneListTableData.length;
        } else {
          this._dockPreZoneListTableData = [];
          this.dockPreZoneTotalCount = 0;
          this.SweetAlert('error', 'Message : ' + data.message);
        }
      },
      (error) => {
        this.isLoading = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.error(error);
      },
    );
  }

  private buildSimpleLocationRow(
    item: Type.ResultProcessDockLocation | Type.ResultProcessPreZoneLocation,
    no: number,
  ): SimpleLocationRow {
    //  wh_code as returned by the API is now derived differently per location type for display
    //  (pILogistic_ProcessGetDockLocation prefixes "WH" onto the bare code, eg. "38" -> "WH38";
    //  pILogistic_ProcessGetPreZoneLocation both drops a character AND prefixes "WH", eg.
    //  "W41" -> "WH41") - guessing/stripping a fixed prefix breaks depending on which. The
    //  physical dock/zone signage and QR have to match location_desc exactly (the raw,
    //  unmodified dock_name/zone_name), so derive the true wh code from there instead: strip the
    //  already-correctly-parsed area+level+location suffix off its end, leaving whatever's left.
    const areaCode = item.area_code || '';
    const levelCode = item.level_code == '-' ? '' : item.level_code || '';
    const locationCode = item.location_code || '';
    const fullCode = this.stripLocationChars(item.location_desc);
    const suffixLength = this.stripLocationChars(`${areaCode}${levelCode}${locationCode}`).length;
    const qrWhCode = fullCode.slice(0, fullCode.length - suffixLength);

    return {
      no,
      id: item.id,
      locationName: fullCode,
      titleLocation: fullCode,
      whCode: item.wh_code,
      qrWhCode,
      areaCode: item.area_code,
      levelCode: item.level_code,
      locationCode: item.location_code,
      isActive: item.is_active,
    };
  }

  //  Fetch Location List - always pulled live from WMS+ (see crud.service.ts)
  fetchLocationList() {
    this.clearSelections();

    // Filter wh code
    if (this.filter.whCode === null || this.filter.whCode === '') {
      this.SweetAlert('warning', 'Message : กรูณาเลือก WAREHOUSE ที่ต้องการ');
      return;
    }

    this.isLoading = true;
    this.restService
      .processGetLocationManagementList(
        this.wh,
        this.filter.whCode || '',
        this.filter.locationDesc || '',
        this.filter.priorityName || '',
        this.filter.statusId || 0,
        this.filter.page || 1,
        this.filter.pageSize || 25,
      )
      .subscribe(
        (data) => {
          this.isLoading = false;
          try {
            if (data && data.status === 'success') {
              this.totalCount = data.total_count || 0;

              const pageOffset = ((this.filter.page || 1) - 1) * (this.filter.pageSize || 25);
              this._locationListTableData = (data.data || []).map((item, index) =>
                this.buildLocationRow(item, pageOffset + index + 1),
              );

              //  Mockup rows (no backing WMS+ record yet) requested for the demo layout.
              // const mockRows = [
              //   this.buildMockLocationRow(this._locationListTableData.length + 1, 'WH38', 'M38', 'C', '-', '05'),
              //   this.buildMockLocationRow(this._locationListTableData.length + 2, 'WH38', 'M38', 'F', '-', '05'),

              //   this.buildMockLocationRow(this._locationListTableData.length + 3, 'WH38', 'M38', 'K', '-', '26'),
              //   this.buildMockLocationRow(this._locationListTableData.length + 4, 'WH38', 'M38', 'K', '-', '27'),
              //   this.buildMockLocationRow(this._locationListTableData.length + 5, 'WH38', 'M38', 'K', '-', '19'),
              //   this.buildMockLocationRow(this._locationListTableData.length + 6, 'WH38', 'M38', 'K', '-', '12'),
              //   this.buildMockLocationRow(this._locationListTableData.length + 7, 'WH38', 'M38', 'K', '-', '05'),
              // ];
              // this._locationListTableData = [...this._locationListTableData, ...mockRows];

              this.updatePriorityOptions(data.data || []);
            } else {
              this._locationListTableData = [];
              this.totalCount = 0;
              this.SweetAlert('error', 'Message : ' + data.message);
            }
          } catch (error) {
            console.error(error);
          }
        },
        (error) => {
          this.isLoading = false;
          this.SweetAlert('error', 'Message : Error see in log.');
          console.error(error);
        },
      );
  }

  private buildLocationRow(item: Type.ResultProcessWhLocation, no: number): LocationManagementRow {
    const updatedDatetime = this.formatUpdatedDatetime(item.updated_datetime);

    return {
      no,
      id: item.id,
      locationId: item.location_id,
      //  "ชื่อ Location" comes from location_desc, not location_code.
      locationName: this.stripLocationChars(`${item.wh_code || ''}${item.area_code || ''}${item.level_code == '-' ? '' : item.level_code || ''}${item.location_code || ''}`),
      titleLocation: this.stripLocationChars(item.location_desc),
      whCode: item.wh_code,
      qrWhCode: item.wh_code,
      areaCode: item.area_code,
      levelCode: item.level_code,
      locationCode: item.location_code,
      priorityId: item.priority_id,
      priorityName: item.priority_name,
      status: item.status || 'Available',
      updatedDatetime: item.updated_datetime,
      updatedDateDisplay: updatedDatetime.date,
      updatedTimeDisplay: updatedDatetime.time,
      isActive: item.is_active ?? true,
    };
  }

  //  Mockup row builder (no backing WMS+ record) - id stays null so it behaves like an
  //  un-synced row (edit/toggle actions already prompt "กรุณากด Sync ก่อน" for id == null).
  //  displayWhCode is what the table/plate shows (eg. "WH38"); qrWhCode is what actually gets
  //  encoded into the QR value (eg. "M38") - they can differ, unlike real synced rows.
  private buildMockLocationRow(
    no: number,
    displayWhCode: string,
    qrWhCode: string,
    areaCode: string,
    levelCode: string,
    locationCode: string,
  ): LocationManagementRow {
    const levelPart = levelCode === '-' ? '' : levelCode;
    const locationName = this.stripLocationChars(`${qrWhCode}${areaCode}${levelPart}${locationCode}`);
    const titleLocation = this.stripLocationChars(`${displayWhCode}${areaCode}${levelPart}${locationCode}`);

    return {
      no,
      id: null,
      locationId: 0,
      locationName,
      titleLocation,
      whCode: displayWhCode,
      qrWhCode,
      areaCode,
      levelCode,
      locationCode,
      priorityId: null,
      priorityName: null,
      status: 'Available',
      updatedDatetime: null,
      updatedDateDisplay: null,
      updatedTimeDisplay: null,
      isActive: true,
    };
  }

  //  "Select all" selects every location matching the current filter, not just the rows on the
  //  current page -- _locationListTableData only ever holds one page's worth of data, so
  //  covering every page means re-fetching with the full result count as the page size. Goes
  //  straight through the REST call (not fetchLocationList) since that clears selections on
  //  every call.
  private fetchAllMatchingLocations(): Promise<LocationManagementRow[]> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetLocationManagementList(
          this.wh,
          this.filter.whCode || '',
          this.filter.locationDesc || '',
          this.filter.priorityName || '',
          this.filter.statusId || 0,
          1,
          this.totalCount || this._locationListTableData.length,
        )
        .subscribe({
          next: (data) => {
            if (data && data.status === 'success') {
              resolve((data.data || []).map((item, index) => this.buildLocationRow(item, index + 1)));
            } else {
              resolve([]);
            }
          },
          error: (error) => reject(error),
        });
    });
  }

  //  Same idea as fetchAllMatchingLocations above, but for the Dock/Pre-Zone table - goes
  //  straight through the REST call (not fetchDockPreZoneLocationList, which resets
  //  dockPreZonePage/dockPreZoneTotalCount) so the currently-viewed page isn't disturbed.
  //  isActive: '' matches fetchDockPreZoneLocationList's own "show both" request.
  private fetchAllMatchingDockPreZoneLocations(): Promise<SimpleLocationRow[]> {
    return new Promise((resolve, reject) => {
      const { whCode, areaCode, levelCode, locationDesc } = this.dockPreZoneFilter;
      const pageSize = this.dockPreZoneTotalCount || this._dockPreZoneListTableData.length;

      const call =
        this.locationType === 'DOCK'
          ? this.restService.processGetDockLocation(whCode, areaCode, levelCode, '', 1, pageSize, locationDesc, '')
          : this.restService.processGetPrezoneLocation(
              whCode,
              areaCode,
              levelCode,
              '',
              1,
              pageSize,
              locationDesc,
              '',
            );

      call.subscribe({
        next: (data) => {
          if (data && data.status === 'success') {
            resolve((data.data || []).map((item, index) => this.buildSimpleLocationRow(item, index + 1)));
          } else {
            resolve([]);
          }
        },
        error: (error) => reject(error),
      });
    });
  }

  //  Fixed display order for the Priority dropdown/filter: Slow, Medium, Fast (regardless of the
  //  order priorities happen to appear in the fetched location data). Names not in this map (if
  //  any) are sorted to the end.
  private readonly priorityOrder: Record<string, number> = {
    slow: 1,
    medium: 2,
    fast: 3,
  };

  private priorityRank(name: string): number {
    return this.priorityOrder[name.trim().toLowerCase()] ?? 99;
  }

  private updatePriorityOptions(rows: Type.ResultProcessWhLocation[]) {
    rows.forEach((row) => {
      if (
        row.priority_id != null &&
        row.priority_name &&
        !this.priorityOptions.some((p) => p.id === row.priority_id)
      ) {
        this.priorityOptions.push({ id: row.priority_id, name: row.priority_name });
      }
    });

    this.priorityOptions.sort((a, b) => this.priorityRank(a.name) - this.priorityRank(b.name));
  }

  //  Print plate text has no spaces to wrap on (see stripLocationChars), so long names would
  //  otherwise overflow the fixed-size plate and get clipped - shrink the font instead.
  getPlateFontSize(text: string | null | undefined): number {
    const length = (text || '').length;
    if (length <= 8) return 150;
    if (length <= 12) return 110;
    if (length <= 16) return 85;
    if (length <= 20) return 65;
    return 50;
  }

  priorityDotClass(priorityName: string | null): string {
    if (!priorityName) return '';
    return 'priority-dot-' + priorityName.trim().toLowerCase();
  }

  //  MWH table's Warehouse badge - WMS+ returns sub-warehouse codes "WH"-prefixed (eg. "WH35"),
  //  but this app's own convention elsewhere (filter.whCode default 'M35', optionWarehouse
  //  values) is "M35" - anchored to the start so it only strips a genuine "WH" prefix, unlike a
  //  plain .replace('WH','M') which would also corrupt the unrelated "MWH" warehouse-type
  //  constant into "MM" (it contains "WH" starting at index 1, not just as a prefix).
  formatWhCode(whCode: string | null | undefined): string {
    return (whCode || '').replace(/^WH/i, 'M');
  }

  get selectedLocationCount(): number {
    return this.selectedLocations.size;
  }

  isRowSelected(row: AnyLocationRow): boolean {
    return this.selectedLocations.has(this.getRowKey(row));
  }

  toggleRowSelection(row: AnyLocationRow, checked: boolean): void {
    const rowKey = this.getRowKey(row);

    if (checked) {
      this.selectedLocations.set(rowKey, row);
      return;
    }

    this.selectedLocations.delete(rowKey);
  }

  //  Selects the rows on the current page only, so one Print Selected prints at most
  //  pageSize labels (same rule as user-list / forklift-management). The selection is
  //  cleared whenever the list reloads (search, paging, page-size change).
  toggleSelectAllCurrentPage(checked: boolean): void {
    this.selectedLocations.clear();
    if (checked) {
      this._locationListTableData.forEach((row) => this.selectedLocations.set(this.getRowKey(row), row));
    }
    this.changeDetectorRef.detectChanges();
  }

  //  Same as toggleSelectAllCurrentPage above, for the Dock/Pre-Zone table.
  toggleSelectAllDockPreZone(checked: boolean): void {
    this.selectedLocations.clear();
    if (checked) {
      this._dockPreZoneListTableData.forEach((row) => this.selectedLocations.set(this.getRowKey(row), row));
    }
    this.changeDetectorRef.detectChanges();
  }

  clearSelectedLocations(): void {
    this.clearSelections();
  }

  //  Export Excel Button Event -- exports every location matching the current filter/tab,
  //  across every page (not just the rows on the current page), reusing the same
  //  fetchAllMatchingLocations/fetchAllMatchingDockPreZoneLocations helpers "select all" uses.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel) return;

    if (this.locationType === 'MWH') {
      if (this.totalCount === 0) return;
      this.isExportingExcel = true;
      try {
        const rows = await this.fetchAllMatchingLocations();
        this.writeLocationWorkbook(
          rows.map((row, index) => ({
            '#': index + 1,
            'ชื่อ Location': row.titleLocation || '-',
            'Warehouse': this.formatWhCode(row.whCode) || '-',
            'Priority': row.priorityName || '-',
            'สถานะ': row.status || '-',
            'ใช้งาน': row.isActive ? 'ใช้งาน' : 'ไม่ใช้งาน',
            'วันที่แก้ไขล่าสุด': [row.updatedDateDisplay, row.updatedTimeDisplay].filter(Boolean).join(' ') || '-',
          })),
          [{ wch: 5 }, { wch: 20 }, { wch: 14 }, { wch: 12 }, { wch: 14 }, { wch: 12 }, { wch: 20 }],
        );
      } catch (error) {
        console.error('Error exporting location list to Excel:', error);
        this.SweetAlert('error', 'ไม่สามารถ Export ข้อมูลได้');
      } finally {
        this.isExportingExcel = false;
      }
      return;
    }

    if (this.dockPreZoneTotalCount === 0) return;
    this.isExportingExcel = true;
    try {
      const rows = await this.fetchAllMatchingDockPreZoneLocations();
      this.writeLocationWorkbook(
        rows.map((row, index) => ({
          '#': index + 1,
          'ชื่อ Location': row.titleLocation || '-',
          'Warehouse': row.whCode || '-',
          'ใช้งาน': row.isActive ? 'ใช้งาน' : 'ไม่ใช้งาน',
        })),
        [{ wch: 5 }, { wch: 20 }, { wch: 14 }, { wch: 12 }],
      );
    } catch (error) {
      console.error('Error exporting location list to Excel:', error);
      this.SweetAlert('error', 'ไม่สามารถ Export ข้อมูลได้');
    } finally {
      this.isExportingExcel = false;
    }
  }

  private writeLocationWorkbook(rows: Record<string, any>[], colWidths: { wch: number }[]): void {
    const worksheet = XLSX.utils.json_to_sheet(rows);
    worksheet['!cols'] = colWidths;

    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, 'Location List');

    const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
    XLSX.writeFile(workbook, `location-list_${timestamp}.xlsx`);
  }

  isAllCurrentPageSelected(): boolean {
    return (
      this._locationListTableData.length > 0 &&
      this._locationListTableData.every((row) => this.selectedLocations.has(this.getRowKey(row)))
    );
  }

  isAllDockPreZoneCurrentPageSelected(): boolean {
    return (
      this._dockPreZoneListTableData.length > 0 &&
      this._dockPreZoneListTableData.every((row) => this.selectedLocations.has(this.getRowKey(row)))
    );
  }

  isSomeDockPreZoneCurrentPageSelected(): boolean {
    return (
      this._dockPreZoneListTableData.some((row) => this.selectedLocations.has(this.getRowKey(row))) &&
      !this.isAllDockPreZoneCurrentPageSelected()
    );
  }

  isSomeCurrentPageSelected(): boolean {
    return (
      this._locationListTableData.some((row) => this.selectedLocations.has(this.getRowKey(row))) &&
      !this.isAllCurrentPageSelected()
    );
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;
    this.fetchLocationList();
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = {
      locationDesc: '',
      whCode: 'M35',
      priorityName: '',
      statusId: 0,
      page: 1,
      pageSize: 25,
    };
    this.fetchLocationList();
  }

  //  Sync Button Event - data is always pulled live from WMS+, so Sync simply re-fetches
  //  the latest list from WMS+ instead of a cached/local copy.
  onClickSync() {
    this.fetchLocationList();
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.fetchLocationList();
  }

  //  Edit Button Event (priority only)
  onClickEdit(row: any) {
    if (row.id == null) {
      this.SweetAlert('info', 'ตำแหน่งนี้ยังไม่มีข้อมูลในระบบ กรุณากด Sync ก่อนแก้ไข');
      return;
    }

    this.isEditMode = true;
    this._selectedEditItem = {
      id: row.id,
      locationName: row.locationName,
      priorityId: row.priorityId,
      isActive: row.isActive,
    };
  }

  openEditModal(row: any) { this.onClickEdit(row); this.showEditModal = true; }
  closeEditModal() { this.showEditModal = false; }

  //  Save Change Edit Button Event
  onClickSave() {
    if (this._selectedEditItem.id == null) return;

    this.restService
      .processUpdateLocation(this._selectedEditItem.id, {
        locationName: this._selectedEditItem.locationName,
        priorityId: this._selectedEditItem.priorityId,
        isActive: this._selectedEditItem.isActive,
        updateBy: 0,
      })
      .subscribe(
        (data) => {
          if (data.status === 'success') {
            this.SweetAlert('success', 'บันทึกข้อมูลสำเร็จ');

            this.closeEditModal();

            this.isEditMode = false;
            this.fetchLocationList();
          } else {
            this.SweetAlert('error', 'Message : ' + data.message);
          }
        },
        (error) => {
          this.SweetAlert('error', 'Message : Error see in log.');
          console.error(error);
        },
      );
  }

  //  Active / Inactive Toggle Event
  onToggleActive(row: any, event: MatSlideToggleChange) {
    const nextValue = event.checked;

    if (row.id == null) {
      event.source.checked = row.isActive;
      this.SweetAlert('info', 'ตำแหน่งนี้ยังไม่มีข้อมูลในระบบ กรุณากด Sync ก่อน');
      return;
    }

    this.restService.processUpdateLocation(row.id, { isActive: nextValue, updateBy: 0 }).subscribe(
      (data) => {
        if (data.status === 'success') {
          row.isActive = nextValue;
        } else {
          event.source.checked = row.isActive;
          this.SweetAlert('error', 'Message : ' + data.message);
        }
      },
      (error) => {
        event.source.checked = row.isActive;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.error(error);
      },
    );
  }

  printSelectedLocations(): void {
    const selectedLocations = Array.from(this.selectedLocations.values()).map((row) => ({
      qrValue: this.normalizeLocationName(row.locationName),
      displayTitle: this.normalizeLocationName(row.titleLocation),
    }));

    if (selectedLocations.length === 0) {
      this.SweetAlert('warning', 'Message : กรุณาเลือกรายการ Location ที่ต้องการพิมพ์');
      return;
    }

    this.resetPrintState();
    this.printSelectedLocationsData = selectedLocations;
    this.printMode = 'multiple';
    this.changeDetectorRef.detectChanges();

    this.loadQRScript().then(() => {
      setTimeout(() => {
        this.printSelectedLocationsData.forEach((location, index) => {
          this.renderQrCode(`print-qr-selected-${index}`, location.qrValue);
        });

        setTimeout(() => {
          this.openPrintArea(() => {
            this.resetPrintState();
          });
        }, 200);
      }, 50);
    });
  }

  // Plant labels encode the plant/cost-center code; their title shows the
  // corresponding plant location. This mirrors the single-row print action
  // available for Dock and Prepare Zone rows.
  printPlant(plant: PlantRow): void {
    this.resetPrintState();
    this._printLocation = plant.plantCode;
    this._printLocationName = plant.plantLocation || plant.plantCode;
    this.printMode = 'single';
    this.changeDetectorRef.detectChanges();

    this.loadQRScript().then(() => {
      setTimeout(() => {
        this.renderQrCode('print-qr-single', this._printLocation);
        setTimeout(() => this.openPrintArea(() => this.resetPrintState()), 200);
      }, 50);
    });
  }

  //  Print Truck QR Code Event
  printLocation(v: any): void { 
    this.resetPrintState();
    this._printLocation = this.normalizeLocationName(this.stripLocationChars(`${(v.qrWhCode || v.whCode) || ''}${v.areaCode == '-' ? '' : v.areaCode || ''}${v.levelCode == '-' ? '' : v.levelCode || ''}${v.locationCode == '-' ? '' : v.locationCode || ''}`));
    this._printLocationName = this.stripLocationChars(v.titleLocation);
    console.log(v);
    this.printMode = 'single';
    this.changeDetectorRef.detectChanges();

    this.loadQRScript().then(() => {
      setTimeout(() => {
        this.renderQrCode('print-qr-single', this._printLocation);
        setTimeout(() => {
          this.openPrintArea(() => {
            this.resetPrintState();
          });
        }, 200);
      }, 50);
    });
  }
  
  //  Load QR Script
  private loadQRScript(): Promise<void> {
    return new Promise((resolve) => {
      if ((window as any)['QRCode']) {
        resolve();
        return;
      }
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js';
      s.onload = () => resolve();
      document.head.appendChild(s);
    });
  }

  private clearSelections(): void {
    this.selectedLocations.clear();
  }

  private getRowKey(row: AnyLocationRow): number {
    //  LocationManagementRow.id can be null for an un-synced MWH row (falls back to
    //  locationId); SimpleLocationRow.id is always present, and has no locationId to fall
    //  back to.
    return 'locationId' in row ? row.id ?? row.locationId : row.id;
  }

  private normalizeLocationName(value: string | null | undefined): string {
    const normalizedValue = value?.trim();
    return normalizedValue ? normalizedValue : '-';
  }

  //  Location codes may carry stray '-' / ' ' characters (eg. "WH40-ON PALLET"); strip them
  //  so the displayed/printed/QR location text stays a clean, unbroken code.
  private stripLocationChars(value: string): string {
    return (value || '').replace(/[-\s]/g, '');
  }

  private formatUpdatedDatetime(value: string | null | undefined): {
    date: string | null;
    time: string | null;
  } {
    if (!value) {
      return { date: null, time: null };
    }

    const trimmedValue = value.trim();
    const dateTimeParts = trimmedValue.split(/\s+/);
    const rawDate = dateTimeParts[0] || '';
    const rawTime = dateTimeParts[1] || null;
    const dateParts = rawDate.split('/');

    if (dateParts.length === 3) {
      const day = dateParts[0].padStart(2, '0');
      const month = dateParts[1].padStart(2, '0');
      const year = dateParts[2];

      return {
        date: `${day}/${month}/${year}`,
        time: rawTime,
      };
    }

    return {
      date: trimmedValue,
      time: null,
    };
  }

  private renderQrCode(elementId: string, value: string): void {
    const el = document.getElementById(elementId);
    if (!el) return;

    const multiply = 5.2;
    el.innerHTML = '';
    new (window as any)['QRCode'](el, {
      text: value,
      width: 35 * 3.78 * multiply,
      height: 35 * 3.78 * multiply,
      colorDark: '#000000',
      colorLight: '#ffffff',
    });
  }

  private resetPrintState(): void {
    this._printLocation = '';
    this.printSelectedLocationsData = [];
    this.printMode = null;
    this.printVehicleData = null;
    this.changeDetectorRef.detectChanges();
  }

  private openPrintArea(onAfterPrint: () => void): void {
    const printArea = document.getElementById('print-area');
    if (!printArea || !printArea.parentNode) return;

    const placeholder = document.createElement('div');
    placeholder.id = 'print-area-placeholder';
    printArea.parentNode.insertBefore(placeholder, printArea);
    document.body.appendChild(printArea);

    //  'afterprint' alone isn't reliable enough to move #print-area back - when it doesn't fire
    //  (browser/print-flow dependent), #print-area was left permanently appended to <body>: still
    //  visible on screen (outside the print media query) and, since it now sits outside Angular's
    //  router-managed tree, stuck showing on every route the user navigates to afterwards.
    //  Cleanup now runs from whichever of these three signals fires first, and only once.
    let cleaned = false;
    const cleanup = () => {
      if (cleaned) return;
      cleaned = true;

      window.removeEventListener('afterprint', cleanup);
      mediaQueryList.removeEventListener('change', onMediaChange);
      clearTimeout(fallbackTimer);

      const printAreaElement = document.getElementById('print-area');
      const placeholderElement = document.getElementById('print-area-placeholder');

      if (printAreaElement && placeholderElement && placeholderElement.parentNode) {
        placeholderElement.parentNode.insertBefore(printAreaElement, placeholderElement);
        placeholderElement.remove();
      }

      onAfterPrint();
    };

    //  window.matchMedia('print') firing 'not matches' is the cross-browser-reliable signal that
    //  the print flow ended, even in cases where 'afterprint' itself gets missed.
    const mediaQueryList = window.matchMedia('print');
    const onMediaChange = (mql: MediaQueryListEvent) => {
      if (!mql.matches) cleanup();
    };
    mediaQueryList.addEventListener('change', onMediaChange);

    //  Last-resort safety net so #print-area can never stay stuck indefinitely.
    const fallbackTimer = setTimeout(cleanup, 10000);

    window.print();
    window.addEventListener('afterprint', cleanup, { once: true });
  }

  //  Sweet Alert
  SweetAlert(iconn: any, alert_message: string) {
    Swal.fire({
      position: 'center',
      icon: iconn,
      title: 'ข้อความจากระบบ',
      text: alert_message,
      showConfirmButton: true,
    });
  }
}
