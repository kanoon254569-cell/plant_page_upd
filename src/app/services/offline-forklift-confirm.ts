import Swal from 'sweetalert2';

export interface OfflineForkliftInfo {
  forkliftName: string | null | undefined;
  whCode?: string | null;
  lastUserName?: string | null;
  jobCount?: number | null;
}

//  Confirm popup shown before an offline forklift is picked (job-detail,
//  job-wh-internal-transfer-detail and job-list's Picking forklift picker).
//  Built on SweetAlert2 (already used across the app) with custom markup;
//  styles are global in src/styles.css under .offline-fl-* because the popup
//  renders under <body>, outside every component's view encapsulation.
//  Resolves true when the user chooses to pick the forklift anyway.
export async function confirmOfflineForklift(info: OfflineForkliftInfo): Promise<boolean> {
  const name = escapeHtml(info.forkliftName || '-');
  const wh = renderWhChips(info.whCode);
  const user = escapeHtml(info.lastUserName || 'ไม่มีผู้ใช้งาน');
  const jobs = info.jobCount ?? 0;

  const result = await Swal.fire({
    html: `
      <div class="offline-fl">
        <div class="offline-fl-icon" aria-hidden="true">
          <span class="material-icons">wifi_off</span>
        </div>
        <h2 class="offline-fl-title">โฟร์คลิฟท์คันนี้ออฟไลน์อยู่</h2>
        <p class="offline-fl-desc">
          ขณะนี้ไม่มีผู้ขับออนไลน์บนโฟร์คลิฟท์คันนี้ งานที่มอบหมายอาจยังไม่ถูกรับจนกว่าผู้ขับจะเข้าสู่ระบบ
        </p>

        <div class="offline-fl-card">
          <img class="offline-fl-card-img" src="assets/images/forklift.png" alt="" />
          <div class="offline-fl-card-body">
            <div class="offline-fl-card-name">
              <span class="offline-fl-card-code">${name}</span>${wh}
            </div>
            <div class="offline-fl-card-meta">
              <span><span class="material-icons">account_circle</span>${user}</span>
              <span><span class="material-icons">assignment</span>คิว: ${jobs} งาน</span>
            </div>
          </div>
          <span class="offline-fl-status">ออฟไลน์</span>
        </div>

        <p class="offline-fl-question">ต้องการเลือกโฟร์คลิฟท์คันนี้หรือไม่?</p>
      </div>`,
    showCancelButton: true,
    confirmButtonText: 'เลือกโฟร์คลิฟท์นี้',
    cancelButtonText: 'ยกเลิก',
    reverseButtons: true,
    focusCancel: true,
    buttonsStyling: false,
    width: 460,
    customClass: {
      popup: 'offline-fl-popup',
      htmlContainer: 'offline-fl-html',
      actions: 'offline-fl-actions',
      confirmButton: 'offline-fl-btn offline-fl-btn--confirm',
      cancelButton: 'offline-fl-btn offline-fl-btn--cancel',
    },
  });

  return result.isConfirmed;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

//  A forklift's whCode is a comma-joined list of every warehouse it serves.
//  Show the first one (callers pass the job's own warehouse first) plus a
//  "+ อีก N" chip whose title lists the rest, instead of one tall chip.
function renderWhChips(whCode: string | null | undefined): string {
  const names = (whCode || '')
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
  if (names.length === 0) return '';

  const [first, ...rest] = names;
  const more = rest.length
    ? `<span class="offline-fl-chip offline-fl-chip--more" title="${escapeHtml(rest.join(', '))}">+ อีก ${rest.length}</span>`
    : '';
  return `<span class="offline-fl-chips"><span class="offline-fl-chip">${escapeHtml(first)}</span>${more}</span>`;
}
