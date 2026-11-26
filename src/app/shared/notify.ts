//  App-wide replacement for sweetalert2.
//
//  Notify.fire(options) keeps the subset of the Swal.fire() options this app
//  used, so call sites only swap the import:
//    - plain messages (no cancel button, no input, no preConfirm) become a
//      toast in the top-right corner that closes by itself; fire() resolves
//      straight away with isConfirmed = true.
//    - confirms / prompts (showCancelButton, input or preConfirm) open a small
//      modal dialog and resolve when the user answers.
//
//  Everything renders under <body>, outside component view encapsulation, so
//  the styles live in src/styles.css under .nt-*.

export type NotifyIcon = 'success' | 'error' | 'warning' | 'info' | 'question';

export interface NotifyOptions {
  icon?: NotifyIcon;
  title?: string;
  text?: string;
  html?: string;

  //  toast only
  timer?: number;

  //  dialog
  showCancelButton?: boolean;
  confirmButtonText?: string;
  cancelButtonText?: string;
  confirmButtonColor?: string;
  cancelButtonColor?: string;
  reverseButtons?: boolean;
  focusCancel?: boolean;
  focusConfirm?: boolean;
  buttonsStyling?: boolean;
  width?: number | string;
  customClass?: {
    popup?: string;
    htmlContainer?: string;
    actions?: string;
    confirmButton?: string;
    cancelButton?: string;
  };
  input?: 'text' | 'number' | 'textarea' | 'email' | 'password';
  inputValue?: string | number | null;
  inputLabel?: string;
  inputPlaceholder?: string;
  inputAttributes?: Record<string, string>;
  inputValidator?: (value: string) => string | null | undefined | void | Promise<string | null | undefined | void>;
  preConfirm?: (value?: string) => any;
  didOpen?: (popup: HTMLElement) => void;
  //  Element to render the dialog in (default <body>). Callers pass the open
  //  Bootstrap modal's content so its focus trap doesn't block the input.
  target?: HTMLElement | string;
  //  false = no dimmed backdrop (eg. when shown over a Bootstrap modal).
  backdrop?: boolean;
  //  false = don't refocus the previously focused element on close.
  returnFocus?: boolean;

  //  Swal-only options still passed by some call sites; ignored.
  [key: string]: any;
}

export interface NotifyResult<T = any> {
  isConfirmed: boolean;
  isDismissed: boolean;
  value?: T;
}

const ICONS: Record<NotifyIcon, string> = {
  success: 'check_circle',
  error: 'error',
  warning: 'warning',
  info: 'info',
  question: 'help',
};

//  Titles that only say "message from the system" add nothing to a toast.
const GENERIC_TITLES = ['ข้อความจากระบบ', 'Notice'];

interface ActiveDialog {
  popup: HTMLElement;
  confirm: () => void;
  showValidation: (message: string) => void;
}

let activeDialog: ActiveDialog | null = null;

function fire<T = any>(options: NotifyOptions): Promise<NotifyResult<T>> {
  const isDialog = !!(options.showCancelButton || options.input || options.preConfirm);
  if (!isDialog) {
    showToast(options);
    return Promise.resolve({ isConfirmed: true, isDismissed: false });
  }
  return openDialog<T>(options);
}

// ── Toast ──────────────────────────────────────────────────────────────

function toastContainer(): HTMLElement {
  let container = document.getElementById('nt-toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'nt-toast-container';
    container.className = 'nt-toast-container';
    container.setAttribute('aria-live', 'polite');
    document.body.appendChild(container);
  }
  return container;
}

function showToast(options: NotifyOptions): void {
  const icon: NotifyIcon = options.icon ?? 'info';
  const toast = document.createElement('div');
  toast.className = `nt-toast nt-toast--${icon}`;
  toast.setAttribute('role', icon === 'error' ? 'alert' : 'status');

  const iconEl = document.createElement('span');
  iconEl.className = 'material-icons nt-toast-icon';
  iconEl.textContent = ICONS[icon];
  toast.appendChild(iconEl);

  const body = document.createElement('div');
  body.className = 'nt-toast-body';

  const title = stripTags(options.title ?? '').trim();
  const hasMessage = !!(options.html || options.text);
  if (title && (!hasMessage || !GENERIC_TITLES.includes(title))) {
    const titleEl = document.createElement('div');
    titleEl.className = 'nt-toast-title';
    titleEl.textContent = title;
    body.appendChild(titleEl);
  }
  if (hasMessage) {
    const messageEl = document.createElement('div');
    messageEl.className = 'nt-toast-message';
    if (options.html) messageEl.innerHTML = options.html;
    else messageEl.textContent = options.text ?? '';
    body.appendChild(messageEl);
  }
  toast.appendChild(body);

  const closeButton = document.createElement('button');
  closeButton.type = 'button';
  closeButton.className = 'nt-toast-close';
  closeButton.setAttribute('aria-label', 'ปิด');
  closeButton.innerHTML = '<span class="material-icons">close</span>';
  toast.appendChild(closeButton);

  const container = toastContainer();
  container.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('nt-toast--show'));

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    toast.classList.remove('nt-toast--show');
    setTimeout(() => toast.remove(), 200);
  };

  const duration = options.timer ?? (icon === 'error' || icon === 'warning' ? 5000 : 3000);
  let timer = setTimeout(close, duration);
  toast.addEventListener('mouseenter', () => clearTimeout(timer));
  toast.addEventListener('mouseleave', () => (timer = setTimeout(close, 1500)));
  closeButton.addEventListener('click', close);
}

// ── Dialog ─────────────────────────────────────────────────────────────

function openDialog<T>(options: NotifyOptions): Promise<NotifyResult<T>> {
  //  One dialog at a time, like Swal: a new one cancels the previous.
  if (activeDialog) {
    activeDialog.popup.dispatchEvent(new CustomEvent('nt-dismiss'));
  }

  return new Promise<NotifyResult<T>>((resolve) => {
    const previousFocus = document.activeElement as HTMLElement | null;
    const custom = options.customClass ?? {};
    const styled = options.buttonsStyling !== false;

    const overlay = document.createElement('div');
    overlay.className = options.backdrop === false ? 'nt-overlay nt-overlay--clear' : 'nt-overlay';
    const target =
      (typeof options.target === 'string' ? document.querySelector<HTMLElement>(options.target) : options.target) ??
      document.body;

    const popup = document.createElement('div');
    popup.className = `nt-dialog ${custom.popup ?? ''}`.trim();
    popup.setAttribute('role', 'dialog');
    popup.setAttribute('aria-modal', 'true');
    if (options.width != null) {
      popup.style.width = typeof options.width === 'number' ? `${options.width}px` : options.width;
    }

    if (options.icon) {
      const iconEl = document.createElement('div');
      iconEl.className = `nt-dialog-icon nt-dialog-icon--${options.icon}`;
      iconEl.innerHTML = `<span class="material-icons">${ICONS[options.icon]}</span>`;
      popup.appendChild(iconEl);
    }

    if (options.title) {
      const titleEl = document.createElement('h2');
      titleEl.className = 'nt-dialog-title';
      titleEl.innerHTML = options.title;
      popup.appendChild(titleEl);
    }

    if (options.html || options.text) {
      const content = document.createElement('div');
      content.className = `nt-dialog-content ${custom.htmlContainer ?? ''}`.trim();
      if (options.html) content.innerHTML = options.html;
      else content.textContent = options.text ?? '';
      popup.appendChild(content);
    }

    let inputEl: HTMLInputElement | HTMLTextAreaElement | null = null;
    if (options.input) {
      if (options.inputLabel) {
        const label = document.createElement('label');
        label.className = 'nt-dialog-label';
        label.htmlFor = 'nt-dialog-input';
        label.textContent = options.inputLabel;
        popup.appendChild(label);
      }
      inputEl = document.createElement(options.input === 'textarea' ? 'textarea' : 'input');
      if (inputEl instanceof HTMLInputElement) inputEl.type = options.input;
      inputEl.id = 'nt-dialog-input';
      inputEl.className = 'nt-input';
      if (options.inputPlaceholder) inputEl.placeholder = options.inputPlaceholder;
      Object.entries(options.inputAttributes ?? {}).forEach(([key, value]) => inputEl!.setAttribute(key, value));
      if (options.inputValue != null) inputEl.value = String(options.inputValue);
      popup.appendChild(inputEl);
    }

    const validation = document.createElement('div');
    validation.className = 'nt-dialog-validation';
    validation.hidden = true;
    popup.appendChild(validation);

    const actions = document.createElement('div');
    actions.className = `nt-dialog-actions ${custom.actions ?? ''}`.trim();

    const confirmButton = document.createElement('button');
    confirmButton.type = 'button';
    confirmButton.className = `${styled ? 'nt-btn nt-btn--confirm' : ''} ${custom.confirmButton ?? ''}`.trim();
    confirmButton.textContent = options.confirmButtonText ?? 'ตกลง';
    if (options.confirmButtonColor) confirmButton.style.background = options.confirmButtonColor;

    const cancelButton = document.createElement('button');
    cancelButton.type = 'button';
    cancelButton.className = `${styled ? 'nt-btn nt-btn--cancel' : ''} ${custom.cancelButton ?? ''}`.trim();
    cancelButton.textContent = options.cancelButtonText ?? 'ยกเลิก';
    if (options.cancelButtonColor) {
      cancelButton.style.background = options.cancelButtonColor;
      cancelButton.style.color = '#fff';
    }

    //  Default order: cancel on the left, confirm on the right.
    const buttons = options.showCancelButton ? [cancelButton, confirmButton] : [confirmButton];
    if (options.reverseButtons) buttons.reverse();
    buttons.forEach((button) => actions.appendChild(button));
    popup.appendChild(actions);

    overlay.appendChild(popup);
    target.appendChild(overlay);
    document.body.classList.add('nt-dialog-open');
    requestAnimationFrame(() => overlay.classList.add('nt-overlay--show'));

    let done = false;
    let busy = false;

    const finish = (result: NotifyResult<T>) => {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKeydown, true);
      overlay.classList.remove('nt-overlay--show');
      setTimeout(() => {
        overlay.remove();
        if (!document.querySelector('.nt-overlay')) document.body.classList.remove('nt-dialog-open');
      }, 150);
      if (activeDialog?.popup === popup) activeDialog = null;
      if (options.returnFocus !== false) previousFocus?.focus?.();
      resolve(result);
    };

    const showValidation = (message: string) => {
      validation.textContent = message;
      validation.hidden = false;
    };

    const confirm = async () => {
      if (busy || done) return;
      validation.hidden = true;
      const inputValue = inputEl?.value;
      busy = true;
      confirmButton.disabled = true;
      try {
        if (options.inputValidator) {
          const error = await options.inputValidator(inputValue ?? '');
          if (error) {
            showValidation(error);
            return;
          }
        }
        let value: any = inputEl ? inputValue : true;
        if (options.preConfirm) {
          const preValue = await options.preConfirm(inputValue);
          if (preValue === false) return;
          if (preValue !== undefined) value = preValue;
        }
        finish({ isConfirmed: true, isDismissed: false, value });
      } finally {
        busy = false;
        confirmButton.disabled = false;
      }
    };

    const dismiss = () => finish({ isConfirmed: false, isDismissed: true });

    const onKeydown = (event: KeyboardEvent) => {
      if (activeDialog?.popup !== popup) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        dismiss();
      } else if (event.key === 'Enter' && event.target === inputEl && options.input !== 'textarea') {
        event.preventDefault();
        confirm();
      }
    };

    confirmButton.addEventListener('click', confirm);
    cancelButton.addEventListener('click', dismiss);
    overlay.addEventListener('mousedown', (event) => {
      if (event.target === overlay) dismiss();
    });
    popup.addEventListener('nt-dismiss', dismiss);
    document.addEventListener('keydown', onKeydown, true);

    activeDialog = { popup, confirm, showValidation };

    if (inputEl) inputEl.focus();
    else if (options.focusCancel && options.showCancelButton) cancelButton.focus();
    else if (options.focusConfirm !== false) confirmButton.focus();

    options.didOpen?.(popup);
  });
}

function stripTags(value: string): string {
  const div = document.createElement('div');
  div.innerHTML = value;
  return div.textContent ?? '';
}

export const Notify = {
  fire,
  //  Same as pressing the confirm button of the open dialog.
  clickConfirm(): void {
    activeDialog?.confirm();
  },
  //  Shows a message under the open dialog's content (eg. from preConfirm).
  showValidationMessage(message: string): void {
    activeDialog?.showValidation(message);
  },
};

export default Notify;
