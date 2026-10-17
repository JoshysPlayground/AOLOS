import WebKit

enum Scripts {
    /// Autofill runs in its own content world so page scripts cannot call into it or read its globals.
    @MainActor static let autofillWorld = WKContentWorld.world(name: "AOLOSAutofill")
    /// Navigation input runs in its own world. It only reads key and click events.
    @MainActor static let browserWorld = WKContentWorld.world(name: "AOLOSBrowser")

    /// Cmd or Option with Left and Right go back and forward outside text fields. Middle click opens a link in a new window.
    /// Talks to native code over `aolosBrowser`. Both handlers skip events the page already handled.
    static let browserInput = #"""
    (() => {
      const post = (m) => { try { webkit.messageHandlers.aolosBrowser.postMessage(m); } catch (e) {} };
      const editable = (el) => !!el && (el.isContentEditable || /^(input|textarea|select)$/i.test(el.tagName || ''));

      window.addEventListener('keydown', (e) => {
        if (e.defaultPrevented || e.ctrlKey || e.shiftKey || e.metaKey === e.altKey) return;
        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
        if (editable(e.target) || editable(document.activeElement)) return;
        e.preventDefault();
        post({ type: 'navigate', direction: e.key === 'ArrowLeft' ? 'back' : 'forward' });
      });

      document.addEventListener('auxclick', (e) => {
        if (e.button !== 1 || e.defaultPrevented) return;
        const link = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!link || !/^https?:/i.test(link.href)) return;
        e.preventDefault();
        post({ type: 'openLink', url: link.href });
      });
    })();
    """#

    /// Replaces the page's Notification API so web notifications become AOL-OS sounds.
    /// Runs in the page world because it must shadow the page's own `Notification`.
    static let notificationShim = #"""
    (() => {
      if (window.__aolosNotify) return;
      window.__aolosNotify = true;
      const post = (m) => { try { window.webkit.messageHandlers.aolos.postMessage(m); } catch (e) {} };

      class AOLNotification extends EventTarget {
        constructor(title, options = {}) {
          super();
          this.title = String(title);
          this.body = options.body || '';
          this.tag = options.tag || '';
          this.icon = options.icon || '';
          this.data = options.data;
          this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
          post({ type: 'notification', title: this.title, body: this.body });
          setTimeout(() => {
            const e = new Event('show');
            this.dispatchEvent(e);
            if (typeof this.onshow === 'function') this.onshow(e);
          }, 0);
        }
        close() {
          const e = new Event('close');
          this.dispatchEvent(e);
          if (typeof this.onclose === 'function') this.onclose(e);
        }
        static get permission() { return 'granted'; }
        static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
        static get maxActions() { return 0; }
      }

      try {
        Object.defineProperty(window, 'Notification', { value: AOLNotification, writable: true, configurable: true });
      } catch (e) {
        window.Notification = AOLNotification;
      }

      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options = {}) {
          post({ type: 'notification', title: String(title), body: options.body || '' });
          return Promise.resolve();
        };
      }

      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (d) => (d && d.name === 'notifications')
          ? Promise.resolve({ state: 'granted', status: 'granted', onchange: null,
                              addEventListener() {}, removeEventListener() {} })
          : query(d);
      }
    })();
    """#

    /// Captures submitted logins and fills saved ones. Talks to native code over `aolosAuth`.
    static let autofill = #"""
    (() => {
      const post = (m) => { try { webkit.messageHandlers.aolosAuth.postMessage(m); } catch (e) {} };
      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const passwordField = (root) =>
        Array.from((root || document).querySelectorAll('input[type=password]')).find(visible) || null;

      const userField = (pw) => {
        const scope = pw.form || document;
        const inputs = Array.from(scope.querySelectorAll('input'))
          .filter((i) => visible(i) && /^(text|email|tel|)$/i.test(i.type || ''));
        let best = null;
        for (const i of inputs) {
          if (i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) best = i;
        }
        return best || inputs[0] || null;
      };

      const capture = (pw) => {
        if (!pw || !pw.value) return;
        const u = userField(pw);
        post({ type: 'credential', username: u ? u.value : '', password: pw.value });
      };

      document.addEventListener('submit', (e) => capture(passwordField(e.target)), true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.type === 'password') capture(e.target);
      }, true);
      document.addEventListener('click', (e) => {
        const b = e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
        if (!b) return;
        const pw = passwordField(b.form || document);
        if (pw) capture(pw);
      }, true);

      const setValue = (el, v) => {
        const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        d.set.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };

      window.__aolosFill = (u, p) => {
        const pw = passwordField();
        if (!pw || pw.value) return;
        const uf = userField(pw);
        if (uf && !uf.value && u) setValue(uf, u);
        setValue(pw, p);
      };

      // The visibility test forces layout, so DOM changes are batched and the cheap selector test runs first.
      let asked = false;
      let queued = false;
      const check = () => {
        queued = false;
        if (asked || !document.querySelector('input[type=password]') || !passwordField()) return;
        asked = true;
        observer.disconnect();
        post({ type: 'needCredentials' });
      };
      const observer = new MutationObserver(() => {
        if (asked || queued) return;
        queued = true;
        setTimeout(check, 300);
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      check();
    })();
    """#
}
