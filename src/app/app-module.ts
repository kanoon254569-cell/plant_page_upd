import { NgModule, provideBrowserGlobalErrorListeners } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { provideHttpClient } from '@angular/common/http';

import { AppRoutingModule } from './app-routing-module';
import { App } from './app';
import { HttpClientModule } from '@angular/common/http';

//  Components
import { VehicleList } from './components/vehicle-list/vehicle-list';
import { UserList } from './components/user-list/user-list';
import { Header } from './components/header/header';
import { Sidebar } from './components/sidebar/sidebar';
import { Login } from './components/login/login';
import { Dialogloading } from './components/dialogloading/dialogloading';
import { JobList } from './components/job-list/job-list';
import { JobDetail } from './components/job-detail/job-detail';
import { JobWhList } from './components/job-wh-list/job-wh-list';
import { JobWhOutboundList } from './components/job-wh-outbound-list/job-wh-outbound-list';
import { JobWhInternalTransferList } from './components/job-wh-internal-transfer-list/job-wh-internal-transfer-list';
import { JobWhInternalTransferDetail } from './components/job-wh-internal-transfer-detail/job-wh-internal-transfer-detail';
import { JobWhTransferList } from './components/job-wh-transfer-list/job-wh-transfer-list';
import { JobWhTransferDetail } from './components/job-wh-transfer-detail/job-wh-transfer-detail';
import { JobShippingList } from './components/job-shipping-list/job-shipping-list';
import { JobWhLocation } from './components/job-wh-location/job-wh-location';
import { JobPlantLocation } from './components/job-plant-location/job-plant-location';
import { JobAutoWhLocation } from './components/job-auto-wh-location/job-auto-wh-location';
import { JobPreZoneLocation } from './components/job-pre-zone-location/job-pre-zone-location';
import { JobSpecialZoneLocation } from './components/job-special-zone-location/job-special-zone-location';
import { JobReplaceZoneLocation } from './components/job-replace-zone-location/job-replace-zone-location';
import { SelectBgPlantLocation } from './components/select-bg-plant-location/select-bg-plant-location';
import { SelectAutoWhLocation } from './components/select-auto-wh-location/select-auto-wh-location';
import { SelectRqPlantLocation } from './components/select-rq-plant-location/select-rq-plant-location';
import { SelectDockLocation } from './components/select-dock-location/select-dock-location';
import { JobDockLocation } from './components/job-dock-location/job-dock-location';
import { SelectWhLocation } from './components/select-wh-location/select-wh-location';
import { SelectInternalTransferLocation } from './components/select-internal-transfer-location/select-internal-transfer-location';
import { SelectPreZoneLocation } from './components/select-pre-zone-location/select-pre-zone-location';
import { SelectSpecialZoneLocation } from './components/select-special-zone-location/select-special-zone-location';
import { SelectReplaceZoneLocation } from './components/select-replace-zone-location/select-replace-zone-location';
import { PalletManagement } from './components/pallet-management/pallet-management';
import { LocationManagement } from './components/location-management/location-management';
import { ForkliftManagement } from './components/forklift-management/forklift-management';
import { PalletInformation } from './components/pallet-information/pallet-information';

//  Angular Material
import { MatCardModule } from '@angular/material/card';
import { MatSidenavModule } from '@angular/material/sidenav';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatIconModule } from '@angular/material/icon';
import { MatListModule } from '@angular/material/list';
import { MatTableModule } from '@angular/material/table';
import { MatSelectModule } from '@angular/material/select';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatMenuModule } from '@angular/material/menu';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatBottomSheetModule } from '@angular/material/bottom-sheet';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { FormsModule, ReactiveFormsModule } from '@angular/forms';
import { MatDialogModule } from '@angular/material/dialog';
import { MatDatepickerModule } from '@angular/material/datepicker';
import { MAT_DATE_LOCALE, MatNativeDateModule } from '@angular/material/core';
import { MatExpansionModule } from '@angular/material/expansion';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatTimepickerModule } from '@angular/material/timepicker';
import { MatPaginatorModule } from '@angular/material/paginator';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { TransactionLog } from './components/transaction-log/transaction-log';
import { WmsInterfaceLog } from './components/wms-interface-log/wms-interface-log';
import { JobSpecialList } from './components/job-special-list/job-special-list';
import { JobSpecialDetail } from './components/job-special-detail/job-special-detail';
import { RoleList } from './components/role-list/role-list';
import { PalletAdjustment } from './components/pallet-adjustment/pallet-adjustment';
import { EmptyState } from './components/empty-state/empty-state';
import { PageHelp } from './components/page-help/page-help';
import { HasPermissionDirective } from './services/has-permission.directive';
import { SkeletonWidthsFromDirective, SkeletonWidthsToDirective } from './services/skeleton-column-widths.directive';

@NgModule({
  declarations: [
    App,
    VehicleList,
    UserList,
    Header,
    Sidebar,
    Login,
    Dialogloading,
    JobList,
    JobDetail,
    JobWhList,
    JobWhOutboundList,
    JobWhInternalTransferList,
    JobWhInternalTransferDetail,
    JobWhTransferList,
    JobWhTransferDetail,
    JobShippingList,
    JobWhLocation,
    JobPlantLocation,
    JobAutoWhLocation,
    JobPreZoneLocation,
    JobSpecialZoneLocation,
    JobReplaceZoneLocation,
    JobDockLocation,
    SelectBgPlantLocation,
    SelectAutoWhLocation,
    SelectRqPlantLocation,
    SelectWhLocation,
    SelectInternalTransferLocation,
    SelectPreZoneLocation,
    SelectSpecialZoneLocation,
    SelectReplaceZoneLocation,
    SelectDockLocation,
    PalletManagement,
    LocationManagement,
    ForkliftManagement,
    PalletInformation,
    TransactionLog,
    WmsInterfaceLog,
    JobSpecialList,
    JobSpecialDetail,
    RoleList,
    PalletAdjustment,
    EmptyState,
    PageHelp,
    HasPermissionDirective,
    SkeletonWidthsFromDirective,
    SkeletonWidthsToDirective,
  ],
  imports: [
    BrowserModule,
    AppRoutingModule,
    MatCardModule,
    MatSidenavModule,
    MatToolbarModule,
    MatIconModule,
    MatListModule,
    MatTableModule,
    MatSelectModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule,
    MatMenuModule,
    MatCheckboxModule,
    MatSlideToggleModule,
    MatBottomSheetModule,
    MatProgressSpinnerModule,
    FormsModule,
    ReactiveFormsModule,
    MatDialogModule,
    MatDatepickerModule,
    MatNativeDateModule,
    MatExpansionModule,
    MatTooltipModule,
    MatTimepickerModule,
    MatPaginatorModule,
    MatAutocompleteModule,
    HttpClientModule,
  ],
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideHttpClient(),
    { provide: MAT_DATE_LOCALE, useValue: 'en-GB' },
  ],
  bootstrap: [App],
})
export class AppModule {}
