import { Component } from '@angular/core';
import { Location } from '@angular/common';
import { ActivatedRoute } from '@angular/router';
import { CrudService } from '../../services/crud.service';
import { JwtTokenService } from '../../services/jwt-token.service';
import * as Type from '../../../models/variables-type';
import Swal from 'sweetalert2';
import { PageEvent } from '@angular/material/paginator';
import { catchError, forkJoin, of } from 'rxjs';

@Component({
  selector: 'app-pallet-information',
  standalone: false,
  templateUrl: './pallet-information.html',
  styleUrl: './pallet-information.css',
})

export class PalletInformation {

  //  Constructor
  constructor(
    private route: ActivatedRoute,
    private restService: CrudService,
    private location: Location,
    private jwtService: JwtTokenService
  ) { }

  //  Back button -- browser history back, same as job-detail's goBack, so it
  //  returns to whichever page opened this one (pallet-management or
  //  forklift-management).
  goBack() {
    this.location.back();
  }

  //  Define Colunm
  displayedColumns: string[] = [
    'no',
    'bagNumber',
    'costCenter',
    'runningNo',
    'grade',
    'lot',
    'mode',
    'createDateTime',
    // 'action'
  ];

  //  Add Bag Form
  addBagForm: any = {
    grade: '',
    lot: '',
    runningNumber: '',
    qty: 0,
    userId: 0
  };

  isEditMode: boolean = false;

  _selectedEditItem: any = {
    id: null,
    grade: '',
    lot: '',
    runningNumber: '',
    qty: 0,
  };


  //  Header card -- filled from the pallet-management row passed in as
  //  router state (see ngOnInit), or from the bag list as a fallback when
  //  the page is opened directly. process/pallet is no longer called here.
  _palletCardData: any[] = [];

  //  Skeleton loading -- Bag List rows (and the header card when it has no
  //  router state yet) show shimmer bars while process/bag loads
  isBagListLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  //  API
  _ResponseProcessBagListData!: Type.ResponseProcessBagListData;

  _bagListTableData: any = [];
  //  Every slot of the pallet (bags + empty slots) -- the paginator pages this list
  _bagSlots: any[] = [];
  isCreatingMissingBags = false;
  //  Header card QTY came from the previous page -- recount it after adding bags
  private refreshCardQty = false;
  //  QR being saved right now -- those rows show the spinner
  creatingMissingQrs = new Set<string>();
  _totalCount: number = 0;
  showAddModal = false;
  showEditModal = false;

  _palletId = '';
  _bagListData: any;

  page = 1;
  pageSize = 50;

  //  Bag List / Pallet History tabs
  activeTab: 'bags' | 'history' = 'bags';

  //  Pallet History (loaded the first time the tab is opened)
  _historyData: Type.ResultProcessPalletHistory[] = [];
  //  _historyData under one header per day (newest first)
  _historyDays: Type.PalletHistoryDay[] = [];
  _historyTotalCount = 0;
  historyLoaded = false;
  historyLoading = false;

  //  Location Type badge icon by ct_location_type.code -- same set as pallet-management
  readonly locationTypeIcon: Partial<Record<string, string>> = {
    'BG-PLANT': 'shopping_bag',
    'MWH': 'warehouse',
    'RQ-PLANT': 'business',
    'PRE-ZONE': 'inventory_2',
    'SPC-ZONE': 'star',
    'DOCK': 'local_shipping',
    'VEHICLE': 'directions_car',
  };

  //  Process icon by ct_process.id (color comes from .ph-step--p<id>)
  readonly processIcon: Partial<Record<number, string>> = {
    1: 'file_upload',
    2: 'file_download',
    3: 'inventory',
    4: 'move_to_inbox',
  };

  //  Job type icon by ct_job_type.short_name
  readonly jobTypeIcon: Partial<Record<string, string>> = {
    TS: 'swap_horiz',
    RC: 'move_to_inbox',
    RQ: 'outbox',
    PK: 'shopping_cart',
    SP: 'local_shipping',
    BK: 'build',
    SPC: 'star',
    LD: 'upload',
    IT: 'sync_alt',
    TW: 'compare_arrows',
  };

  //  Component Build Up Event!
  ngOnInit(): void {
    this._palletId =
      this.route.snapshot.paramMap.get('id') ?? '';

    const pallet = history.state?.pallet;
    if (pallet) {
      this._palletCardData = [
        {
          palletNumber: pallet.palletNumber,
          grade: pallet.grade,
          unitRatio: pallet.unitRatio ?? null,
          unitPallet: pallet.unitPallet ?? null,
          lot: pallet.lot,
          qty: pallet.qty ?? 0,
          palletType: pallet.palletType ?? '-',
          palletLocation: pallet.palletLocation ?? '-'
        }
      ];
    }

    this.fetchProcessGetBagtList(this.page, this.pageSize);
    //  Load history up front too, so the Pallet History tab shows its count on first open
    this.fetchPalletHistory();
  }

  //  QTY of a pallet with empty slots = bags x unit_ratio (same as pProcessGetPalletList). Also kept
  //  in history.state, otherwise a browser refresh shows the old QTY again.
  private updateCardQty(bags: Type.ResultProcessBagListData[]) {
    const card = this._palletCardData[0];
    if (!this.refreshCardQty || !card) return;
    this.refreshCardQty = false;

    card.qty = bags.length * (card.unitRatio ?? bags[0]?.unit_ratio ?? 0);
    if (history.state?.pallet) {
      history.replaceState({ ...history.state, pallet: { ...history.state.pallet, qty: card.qty } }, '');
    }
  }

  //  Fallback header card (page opened directly / from forklift-management)
  //  -- only what the bag rows carry: pallet_no, distinct grades/lots, ratio.
  private buildPalletCardFromBags(bags: Type.ResultProcessBagListData[]) {
    if (this._palletCardData.length > 0 || bags.length === 0) return;

    const distinct = (values: string[]) =>
      Array.from(new Set(values.filter((v) => !!v))).join(', ');

    this._palletCardData = [
      {
        palletNumber: bags[0].pallet_no,
        grade: distinct(bags.map((b) => b.grade)),
        unitRatio: bags[0].unit_ratio ?? null,
        unitPallet: null,
        lot: distinct(bags.map((b) => b.lot)),
        qty: null,
        palletType: null,
        palletLocation: null
      }
    ];
  }

  //  Dummy pallet (PLD...) has no tr_pallet.unit_ratio, so the bag rows carry no ratio and QTY
  //  stays empty when the page wasn't opened from the Dummy tab (direct link, forklift-management,
  //  or a card without the ratio). Fill ratio / QTY = bags x grade package ratio from
  //  pallet-management/dummy (pProcessGetDummyPalletList, sql/107_). Runs once per load.
  private dummyCardFilled = false;

  private fillDummyPalletCard() {
    const card = this._palletCardData[0];
    if (this.dummyCardFilled || !card || !String(card.palletNumber ?? '').startsWith('PLD')) return;
    if (card.unitRatio != null && card.qty) return;
    this.dummyCardFilled = true;

    this.restService.processGetDummyPalletList(card.palletNumber, '', 1, 1).subscribe({
      next: (response) => {
        const dummy = (response?.data ?? []).find((d) => d.pallet_no === card.palletNumber);
        if (!dummy) return;

        card.grade = card.grade || dummy.grade;
        card.lot = card.lot || dummy.lot;
        card.unitRatio = dummy.unit_ratio ?? null;
        card.qty = dummy.qty ?? 0;
        card.palletType = 'Dummy';
        card.palletLocation = card.palletLocation && card.palletLocation !== '-' ? card.palletLocation : dummy.current_location;
        if (history.state?.pallet) {
          history.replaceState(
            { ...history.state, pallet: { ...history.state.pallet, unitRatio: card.unitRatio, qty: card.qty } },
            '',
          );
        }
      },
      error: (error) => console.log(error),
    });
  }

  //  Order the pallet by slot, with empty slots (no print data) kept in place -- same rule as
  //  bagSlots of pallet-adjustment: slot = bag no. in the QR only when every bag is still on its
  //  own ton and none was shifted by a reject, otherwise bag_no with the empty slots at the end.
  private buildBagSlots(bags: any[], adjustment: Type.ResponseProcessPalletAdjustmentBagList | null): any[] {
    const adjBags = new Map((adjustment?.data ?? []).map((b) => [b.id, b]));
    bags = bags.map((b) => ({ ...b, isManualAdded: !!adjBags.get(b.id)?.is_manual_added }));

    const missing = [...(adjustment?.missing_slots ?? [])].sort((a, b) => a.planned_pos - b.planned_pos);
    if (missing.length === 0) return bags;

    const qrPart = (qr: string, index: number) => Number(String(qr ?? '').split('|')[index]) || null;
    const unitPallet = bags.length + missing.length;
    const qrNos = bags.map((b) => qrPart(b.bagNumber, 3));
    const useQrSlot =
      new Set(bags.map((b) => qrPart(b.bagNumber, 4))).size === 1 &&
      bags.every((b) => {
        const adj = adjBags.get(b.id);
        return adj != null && !adj.reject_before && adj.ton_no != null && adj.ton_no === qrPart(b.bagNumber, 4);
      }) &&
      qrNos.every((n) => n != null && n >= 1 && n <= unitPallet) &&
      new Set(qrNos).size === qrNos.length;

    const rows = bags.map((b, i) => ({ ...b, no: useQrSlot ? qrNos[i] : b.no }));
    const used = new Set(rows.map((r) => r.no));
    let slotNo = 0;
    missing.forEach((m) => {
      do {
        slotNo++;
      } while (used.has(slotNo));
      const parts = m.qr_text_data.split('|');
      rows.push({
        no: slotNo,
        isMissing: true,
        bagNumber: m.qr_text_data,
        costCenter: parts[0],
        grade: parts[1],
        lot: parts[2],
        bagRunning: parts[3],
        tonNo: null,
        modeId: null,
        createDateTime: null,
      });
    });
    return rows.sort((a, b) => (a.no ?? Number.MAX_SAFE_INTEGER) - (b.no ?? Number.MAX_SAFE_INTEGER));
  }

  private applyBagPage(): void {
    const lastPage = Math.max(1, Math.ceil(this._bagSlots.length / this.pageSize));
    this.page = Math.min(this.page, lastPage);
    const start = (this.page - 1) * this.pageSize;
    this._bagListTableData = this._bagSlots.slice(start, start + this.pageSize);
  }

  //  Create the tr_bag row of an empty slot -- same action as "เพิ่มข้อมูล" of pallet-adjustment
  async onClickCreateMissingBag(row: any) {
    await this.createMissingBags([row.bagNumber], `ต้องการเพิ่มข้อมูลถุง ${row.bagNumber} หรือไม่?`);
  }

  //  QR of every empty slot of the pallet (all pages, not just the rows on screen)
  get missingBagQrs(): string[] {
    return this._bagSlots.filter((s) => s.isMissing).map((s) => s.bagNumber);
  }

  async onClickCreateAllMissingBags() {
    const qrs = this.missingBagQrs;
    await this.createMissingBags(qrs, `ต้องการเพิ่มข้อมูลถุงที่ขาดทั้งหมด ${qrs.length} ถุง หรือไม่?`);
  }

  private async createMissingBags(qrs: string[], confirmText: string) {
    if (qrs.length === 0 || this.isCreatingMissingBags) return;

    const { isConfirmed } = await Swal.fire({
      icon: 'question',
      title: 'ยืนยันการเพิ่มข้อมูลถุง',
      text: confirmText,
      showCancelButton: true,
      confirmButtonText: 'ยืนยันเพิ่มข้อมูล',
      cancelButtonText: 'ยกเลิก',
    });
    if (!isConfirmed) return;

    this.isCreatingMissingBags = true;
    this.creatingMissingQrs = new Set(qrs);
    this.restService
      .processAddMissingBag({
        palletId: Number(this._palletId),
        missingQrs: qrs,
        userId: Number(this.jwtService.getUserId() ?? 0),
      })
      .subscribe({
        next: (response) => {
          this.refreshCardQty = true;
          this.isCreatingMissingBags = false;
          this.creatingMissingQrs.clear();
          this.SweetAlert(response.status === 'success' ? 'success' : 'warning', response.message || 'เพิ่มข้อมูลสำเร็จ');
          this.fetchProcessGetBagtList();
        },
        error: (error) => {
          this.refreshCardQty = true;
          this.isCreatingMissingBags = false;
          this.creatingMissingQrs.clear();
          console.log(error);
          this.SweetAlert('error', error?.error?.message || 'เพิ่มข้อมูลไม่สำเร็จ');
          //  Some slots may already be saved before the error
          this.fetchProcessGetBagtList();
        },
      });
  }

  //  Fetch Bag List API
  async fetchProcessGetBagtList(page: number = this.page, pageSize: number = this.pageSize) {
    this.isBagListLoading = true;

    //  All bags of the pallet at once: empty slots sit between bags, so paging is done here.
    //  pallet-adjustment/bag needs data.pallet_management -- without it (or before sql/98_) the
    //  list is just the bags in bag_no order, with no empty slots.
    forkJoin({
      data: this.restService.processGetBagList(this._palletId, 1, 1000),
      adjustment: this.restService
        .processGetPalletAdjustmentBagList(Number(this._palletId))
        .pipe(catchError(() => of(null))),
    }).subscribe(
      ({ data, adjustment }) => {
        this.isBagListLoading = false;
        try {
          if (data != undefined) {
            if (data.status === 'success') {

              this._ResponseProcessBagListData = data;

              //  Map Pallet List Table Data
              const bags = data.data.map(
                (item: any, index: number) => ({
                  id: item.id,
                  no: item.bag_no,
                  bagNumber: item.qr_text_data,
                  costCenter: item.cost_center,
                  //  Bag running = 4th part of the bag QR (cost_center|grade|lot|running|ton)
                  bagRunning: String(item.qr_text_data ?? '').split('|')[3]?.trim() || null,
                  tonNo: item.ton_no ?? null,
                  modeId: item.mode_id ?? null,
                  grade: item.grade,
                  lot: item.lot,
                  qty: item.qty,
                  createDateTime: item.create_datetime,
                  edit: item.id,
                  delete: item.id,
                  action: item.id
                })
              );

              this._bagSlots = this.buildBagSlots(bags, adjustment);
              this._totalCount = this._bagSlots.length;
              this.applyBagPage();

              this.buildPalletCardFromBags(data.data);
              this.updateCardQty(data.data);
              this.fillDummyPalletCard();

            } else {
              this.SweetAlert('error', 'Message : ' + data.message);
            }
          }
        } catch (error) {
          console.log(error);
        }
      },
      (error) => {
        this.isBagListLoading = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      }
    );
  }

  selectTab(tab: 'bags' | 'history'): void {
    this.activeTab = tab;
    if (tab === 'history' && !this.historyLoaded && !this.historyLoading) this.fetchPalletHistory();
  }

  //  Fetch Pallet History API (whole timeline, not paginated)
  fetchPalletHistory(): void {
    this.historyLoading = true;
    this.restService.processGetPalletHistory(this._palletId).subscribe(
      (data) => {
        this.historyLoading = false;
        if (data?.status === 'success') {
          this._historyData = data.data ?? [];
          this._historyDays = this.groupHistoryByDay(this._historyData);
          this._historyTotalCount = data.total_count ?? 0;
          this.historyLoaded = true;
        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this.historyLoading = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      }
    );
  }

  //  Timeline rows grouped under one header per day; rows stay newest first
  //  as the SP returns them. Each row is one step with its own operator and
  //  forklift (Get and Put can be done by different people).
  private groupHistoryByDay(events: Type.ResultProcessPalletHistory[]): Type.PalletHistoryDay[] {
    const days: Type.PalletHistoryDay[] = [];
    for (const e of events) {
      const d = new Date(e.event_datetime);
      const key = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
      const day = days[days.length - 1];
      if (day && day.key === key) day.items.push(e);
      else days.push({ key, date: e.event_datetime, items: [e] });
    }
    return days;
  }

  //  Name only (Thai, else English, else the employee code) -- the code is shown on its own line
  historyUserDisplayName(item: Type.ResultProcessPalletHistory): string | null {
    return (item.create_user_thai_name || item.create_user_eng_name || item.create_user_name || '').trim() || null;
  }

  //  Header summary: number of jobs, first and latest movement
  get historyJobCount(): number {
    return new Set(this._historyData.filter((e) => e.job_main_id != null).map((e) => e.job_main_id)).size;
  }

  get historyFirstDatetime(): string | null {
    return this._historyData.length ? this._historyData[this._historyData.length - 1].event_datetime : null;
  }

  get historyLastDatetime(): string | null {
    return this._historyData.length ? this._historyData[0].event_datetime : null;
  }

  resetAddBagForm(): void {
    this.addBagForm = {
      grade: '',
      lot: '',
      runningNumber: '',
      qty: 0,
      userId: 0
    };
  }

  openAddModal() { this.resetAddBagForm(); this.showAddModal = true; }
  closeAddModal() { this.showAddModal = false; }
  openEditModal(element: any) { this.onClickEdit(element); this.showEditModal = true; }
  closeEditModal() { this.showEditModal = false; }

  async onSubmitAddBag() {
    const payload = {
      grade: this.addBagForm.grade,
      lot: this.addBagForm.lot,
      runningNumber: this.addBagForm.runningNumber,
      qty: this.addBagForm.qty,
      userId: 0   
    };

    await this.restService.processInsertBag(payload).subscribe(
      (data) => {
        if (data && data.status === 'success') {

          this.SweetAlert('success', 'เพิ่มถุงสำเร็จ');

          this.closeAddModal();

          this.resetAddBagForm();

          this.fetchProcessGetBagtList(this.page, this.pageSize);

        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      }
    );
  }

  //  Edit Bag Button Event (เซ็ตข้อมูล ไม่เปิด modal เอง — HTML เปิดผ่าน data-bs-toggle)
  onClickEdit(element: any) {
    this.isEditMode = true;

    this._selectedEditItem = {
      id: element.edit,         //  id ถูกซ่อนไว้ในคีย์ edit จาก mapping เดิม
      grade: element.grade,
      lot: element.lot,
      runningNumber: '',        //  mapping เดิมไม่มี runningNumber ต้องพิมพ์ใหม่
      qty: element.qty,
    };
  }

  //  Save Change Edit Button Event
  onClickSave() {
    const dataRequest = {
      grade: this._selectedEditItem.grade,
      lot: this._selectedEditItem.lot,
      runningNumber: this._selectedEditItem.runningNumber,
      qty: Number(this._selectedEditItem.qty),
      userId: 0,   
    };

    this.restService.processUpdateBag(this._selectedEditItem.id, dataRequest).subscribe(
      (data) => {
        if (data.status === 'success') {

          this.SweetAlert('success', 'บันทึกข้อมูลสำเร็จ');

          this.closeEditModal();

          this.isEditMode = false;
          this.fetchProcessGetBagtList(this.page, this.pageSize);

        } else {
          this.SweetAlert('error', 'Message : ' + data.message);
        }
      },
      (error) => {
        this.SweetAlert('error', 'Message : Error see in log.');
        console.log(error);
      }
    );
  }

  //  Delete Bag Button Event
  //  tr_bag.mode_id has no master table -- labels agreed with the team
  readonly bagModeLabels: Partial<Record<number, string>> = { 1: 'Auto', 2: 'Manual', 3: 'Test' };

  //  Copy Bag Number (QR text) -- icon turns to a check for 1.5s
  copiedBagNumber: string | null = null;
  private copiedTimeout: any;

  async copyBagNumber(text: string) {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      //  clipboard API blocked (e.g. http) -> fallback via hidden textarea
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
    }

    this.copiedBagNumber = text;
    clearTimeout(this.copiedTimeout);
    this.copiedTimeout = setTimeout(() => (this.copiedBagNumber = null), 1500);
  }

  onClickDelete(element: any) {
    Swal.fire({
      title: 'ยืนยันการลบ?',
      text: `ต้องการลบถุง "${element.bagNumber}" ใช่หรือไม่`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#d33',
      cancelButtonColor: '#6c757d',
      confirmButtonText: 'ลบ',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (result.isConfirmed) {
        this.restService.processDeleteBag(element.delete, 0).subscribe(
          (data) => {
            if (data.status === 'success') {
              this.SweetAlert('success', 'ลบข้อมูลสำเร็จ');
              this.fetchProcessGetBagtList(this.page, this.pageSize);
            } else {
              this.SweetAlert('error', 'Message : ' + data.message);
            }
          },
          (error) => {
            this.SweetAlert('error', 'Message : Error see in log.');
            console.log(error);
          }
        );
      }
    });
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {

    this.page = event.pageIndex + 1;
    this.pageSize = event.pageSize;

    this.applyBagPage();

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
