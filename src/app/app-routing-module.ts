import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { AuthService } from './services/auth.service';

//  Component
import { VehicleList } from './components/vehicle-list/vehicle-list';
import { UserList } from './components/user-list/user-list';
import { RoleList } from './components/role-list/role-list';
import { Login } from './components/login/login';
import { JobList } from './components/job-list/job-list';
import { JobWhList } from './components/job-wh-list/job-wh-list';
import { JobWhOutboundList } from './components/job-wh-outbound-list/job-wh-outbound-list';
import { JobWhInternalTransferList } from './components/job-wh-internal-transfer-list/job-wh-internal-transfer-list';
import { JobWhTransferList } from './components/job-wh-transfer-list/job-wh-transfer-list';
import { JobWhTransferDetail } from './components/job-wh-transfer-detail/job-wh-transfer-detail';
import { JobWhInternalTransferDetail } from './components/job-wh-internal-transfer-detail/job-wh-internal-transfer-detail';
import { JobShippingList } from './components/job-shipping-list/job-shipping-list';
import { JobDetail } from './components/job-detail/job-detail';
import { PalletManagement } from './components/pallet-management/pallet-management';
import { LocationManagement } from './components/location-management/location-management';
import { ForkliftManagement } from './components/forklift-management/forklift-management';
import { PalletInformation } from './components/pallet-information/pallet-information';
import { JobSpecialList } from './components/job-special-list/job-special-list';
import { TransactionLog } from './components/transaction-log/transaction-log';
import { WmsInterfaceLog } from './components/wms-interface-log/wms-interface-log';
import { JobSpecialDetail } from './components/job-special-detail/job-special-detail';
import { PalletAdjustment } from './components/pallet-adjustment/pallet-adjustment';

//  Define Route
const routes: Routes = [
  { path: '', component: Login },
  // { path: 'job-list', component: JobList },
  { path: 'job-wh-list', component: JobWhList, canActivate: [AuthService] },
  { path: 'job-wh-outbound-list', component: JobWhOutboundList, canActivate: [AuthService] },
  {
    path: 'job-wh-internal-transfer-list',
    component: JobWhInternalTransferList,
    canActivate: [AuthService],
  },
  {
    path: 'job-wh-internal-transfer-detail/:id',
    component: JobWhInternalTransferDetail,
    canActivate: [AuthService],
  },
  { path: 'job-wh-transfer-list', component: JobWhTransferList, canActivate: [AuthService] },
  { path: 'job-wh-transfer-detail/:id', component: JobWhTransferDetail, canActivate: [AuthService] },
  { path: 'job-shipping-list', component: JobShippingList, canActivate: [AuthService] },
  { path: 'job-detail/:id', component: JobDetail, canActivate: [AuthService] },
  { path: 'vehicle-list', component: VehicleList, canActivate: [AuthService] },
  { path: 'user-list', component: UserList, canActivate: [AuthService] },
  { path: 'role-list', component: RoleList, canActivate: [AuthService] },
  { path: 'pallet-management', component: PalletManagement, canActivate: [AuthService] },
  { path: 'pallet-information/:id', component: PalletInformation, canActivate: [AuthService] },
  { path: 'location-management', component: LocationManagement, canActivate: [AuthService] },
  { path: 'forklift-management', component: ForkliftManagement, canActivate: [AuthService] },
  { path: 'job-special-list', component: JobSpecialList, canActivate: [AuthService] },
  { path: 'pallet-adjustment', component: PalletAdjustment, canActivate: [AuthService] },
  { path: 'job-special-detail/:id', component: JobSpecialDetail, canActivate: [AuthService] },
  { path: 'transaction-log', component: TransactionLog, canActivate: [AuthService] },
  { path: 'wms-interface-log', component: WmsInterfaceLog, canActivate: [AuthService] },
];

@NgModule({
  imports: [RouterModule.forRoot(routes)],
  exports: [RouterModule],
})
export class AppRoutingModule {}
