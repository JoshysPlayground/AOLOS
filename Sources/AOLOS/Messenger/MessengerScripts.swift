import Foundation

extension Scripts {
    /// Reads contacts, presence and messages out of Facebook's Messenger web client at facebook.com/messages and
    /// posts them over `aolos`. Native code calls back into `window.__aolosMessenger`.
    ///
    /// Facebook has no public API for personal messages. The client keeps its inbox in a local database exposed as
    /// the `LSDatabaseSingleton` module, with `contacts`, `threads`, `participants`, `messages` and `attachments`
    /// tables. End-to-end encrypted chats are decrypted into the same tables. Presence comes from the
    /// `FBPresenceUnifiedClientSingleton` module. IDs and timestamps in the tables are `I64` values. Module and table
    /// names come from the running client and can change with any Facebook release.
    ///
    /// Every ID posted to native code carries the `fb:` prefix so it cannot collide with a Discord or Slack ID.
    static let messengerBridge = #"""
    (() => {
      if (window.__aolosMessenger || !/(^|\.)facebook\.com$/.test(location.hostname)) return;
      const post = (m) => { try { window.webkit.messageHandlers.aolos.postMessage(m); } catch (e) {} };
      const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

      // AOL-OS plays its own sounds, so Messenger's notification sounds stay silent. Calls use streams and still play.
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        const src = this.currentSrc || this.src || '';
        if (!this.srcObject && /^https:\/\/[^/]*(fbcdn\.net|facebook\.com)\/.*\.(mp3|ogg|wav)(\?|$)/i.test(src)) {
          return Promise.resolve();
        }
        return play.apply(this, arguments);
      };

      const PREFIX = 'fb:';
      const wrap = (id) => PREFIX + id;
      const raw = (id) => { const s = String(id || ''); return s.startsWith(PREFIX) ? s.slice(PREFIX.length) : s; };
      const mod = (name) => { try { return window.require(name); } catch (e) { return null; } };

      let db = null;
      let I64 = null;
      let presence = null;
      let meID = '';
      let meName = '';

      const str = (v) => { if (v === null || v === undefined) return ''; try { return I64.to_string(v); } catch (e) { return String(v); } };
      const num = (v) => { if (v === null || v === undefined) return 0; try { return I64.to_float(v); } catch (e) { return Number(v) || 0; } };

      // Table iterators are async and yield [primaryKey, row] pairs.
      const rows = async (table) => {
        const t = db.tables[table];
        if (!t) return [];
        const it = t.entries();
        const out = [];
        let r = await it.next();
        while (!r.done) { out.push(Array.isArray(r.value) ? r.value[1] : r.value); r = await it.next(); }
        return out;
      };

      // LSThreadType values seen in the client: 1 and 2 are plain one-to-one and group chats, 15 and 16 are the
      // end-to-end encrypted ones.
      const ONE = [1, 15];
      const GROUP = [2, 16];
      const ENCRYPTED = [15, 16];

      const cache = { contacts: new Map(), threads: new Map(), members: new Map(), userThread: new Map() };

      const refresh = async () => {
        const contacts = new Map();
        for (const c of await rows('contacts')) contacts.set(str(c.id), c);
        const threads = new Map();
        for (const t of await rows('threads')) threads.set(str(t.threadKey), t);
        const members = new Map();
        for (const p of await rows('participants')) {
          const key = str(p.threadKey);
          if (!members.has(key)) members.set(key, []);
          members.get(key).push(str(p.contactId));
        }
        cache.contacts = contacts;
        cache.threads = threads;
        cache.members = members;
      };

      // Active is presenceStatus 2. Someone seen in the last 15 minutes shows as idle, like AIM's away.
      const IDLE_SECONDS = 15 * 60;
      const status = (id) => {
        let p = null;
        try { p = presence && presence.getPresenceMap().get(String(id)); } catch (e) {}
        if (!p) return 'offline';
        if (Number(p.presenceStatus) === 2) return 'online';
        const ago = Date.now() / 1000 - Number(p.lastActiveTimeSeconds || 0);
        return ago < IDLE_SECONDS ? 'idle' : 'offline';
      };

      const contactName = (id) => {
        const c = cache.contacts.get(String(id));
        return (c && (c.name || c.firstName)) || '';
      };

      const buddy = (id) => {
        const c = cache.contacts.get(String(id)) || {};
        return { id: wrap(id), name: contactName(id) || String(id), username: String(c.username || ''),
                 avatar: String(c.profilePictureUrl || ''), status: status(id) };
      };

      const others = (key) => (cache.members.get(key) || []).filter((id) => id !== meID);
      const typeOf = (t) => num(t && t.threadType);
      // Encrypted threads are flagged isHidden in this table because another part of the client draws them, so
      // only the folder decides what is in the inbox.
      const inInbox = (t) => t.folderName === 'inbox';
      const byActivity = (a, b) => num(b.lastActivityTimestampMs) - num(a.lastActivityTimestampMs);

      const group = (t) => {
        const key = str(t.threadKey);
        const ids = others(key);
        const name = t.threadName || ids.map(contactName).filter(Boolean).join(', ') || 'Group Chat';
        return { id: wrap(key), name: String(name), members: ids.map(buddy) };
      };

      // Friends are contacts with friendshipStatus ARE_FRIENDS (1) and contactType USER (1).
      const friends = () => [...cache.contacts.values()]
        .filter((c) => num(c.friendshipStatus) === 1 && num(c.contactType) === 1 && str(c.id) !== meID)
        .map((c) => buddy(str(c.id)));

      // One-to-one partners, most recent conversation first. Remembers each partner's thread for sending.
      const recent = () => {
        const list = [...cache.threads.values()].filter((t) => ONE.includes(typeOf(t)) && inInbox(t)).sort(byActivity);
        const seen = new Set();
        const out = [];
        for (const t of list) {
          const key = str(t.threadKey);
          const id = others(key)[0] || (typeOf(t) === 1 ? key : '');
          if (!id || seen.has(id)) continue;
          seen.add(id);
          if (!cache.userThread.has(id)) cache.userThread.set(id, key);
          if (out.length < 60) out.push(buddy(id));
        }
        return out;
      };

      // A group moved to end-to-end encryption keeps its old thread, so groups with the same people show once.
      const groups = () => {
        const seen = new Set();
        return [...cache.threads.values()]
          .filter((t) => GROUP.includes(typeOf(t)) && inInbox(t)).sort(byActivity)
          .filter((t) => {
            const people = others(str(t.threadKey)).slice().sort().join(',');
            if (people && seen.has(people)) return false;
            seen.add(people);
            return true;
          })
          .slice(0, 30).map(group);
      };

      let last = '';
      const snapshot = (force) => {
        const me = cache.contacts.get(meID) || {};
        const body = {
          me: { id: wrap(meID), name: meName, avatar: String(me.profilePictureUrl || '') },
          friends: friends(),
          recent: recent(),
          groups: groups(),
        };
        const json = JSON.stringify(body);
        if (!force && json === last) return;
        last = json;
        post(Object.assign({ type: 'messenger.friends' }, body));
      };

      const https = (u) => (typeof u === 'string' && /^https:\/\//.test(u) ? u : '');

      const attachmentsByMessage = async () => {
        const map = new Map();
        for (const a of await rows('attachments')) {
          const id = String(a.messageId || '');
          if (!map.has(id)) map.set(id, []);
          map.get(id).push(a);
        }
        return map;
      };

      // Encrypted chats keep their text sealed with a local key in the table, wrapped in the same "digits##digits"
      // marker at both ends. The page decrypts it only to draw the chat, so the readable text is taken from the
      // drawn messages and matched to rows by minute and order.
      const SEALED_NOTE = '[encrypted message, open in Messenger to read]';
      const sealed = (t) => { const m = /^(\d+##\d+)/.exec(String(t || '')); return !!m && String(t).endsWith(m[1]); };
      const revealed = new Map();

      // Each drawn message carries a label like "At October 9, 2026, 6:22 AM, Pat: hello". Recent ones drop the
      // date ("At 6:22 AM, Pat: hi") or name the weekday ("At Monday 6:22 AM, Pat: hi").
      const LABEL = /^At (.*?)(\d{1,2}:\d{2})\s?([AP]M), ([^:]+?)(?:: ([\s\S]*))?$/;
      const WEEKDAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
      const labelTime = (prefix, clock, half) => {
        const day = prefix.replace(/[,\s]+$/, '').trim();
        if (/\d{4}$/.test(day)) return Date.parse(`${day} ${clock} ${half}`);
        const [h, min] = clock.split(':').map(Number);
        const d = new Date();
        const weekday = WEEKDAYS.indexOf(day.toLowerCase());
        if (weekday >= 0) d.setDate(d.getDate() - ((d.getDay() - weekday + 7) % 7));
        else if (/^yesterday$/i.test(day)) d.setDate(d.getDate() - 1);
        else if (day) return Date.parse(`${day}, ${d.getFullYear()} ${clock} ${half}`);
        d.setHours((h % 12) + (half === 'PM' ? 12 : 0), min, 0, 0);
        return d.getTime();
      };
      const drawn = () => {
        const out = [];
        for (const el of document.querySelectorAll('[aria-label^="At "]')) {
          const m = LABEL.exec(el.getAttribute('aria-label') || '');
          const when = m ? labelTime(m[1], m[2], m[3]) : NaN;
          if (!m || isNaN(when)) continue;
          out.push({ minute: Math.floor(when / 60000), sender: m[4].trim(), text: (m[5] || '').trim() });
        }
        return out;
      };

      // Pairs the drawn messages with the thread's rows minute by minute, in order.
      const reveal = async (key) => {
        if (currentKey() !== key) return 0;
        const list = await messagesIn(key);
        const shown = drawn();
        const byMinute = (items, minute) => items.reduce((map, item) => {
          const k = minute(item);
          if (!map.has(k)) map.set(k, []);
          map.get(k).push(item);
          return map;
        }, new Map());
        const rowsBy = byMinute(list, (m) => Math.floor(num(m.timestampMs) / 60000));
        const shownBy = byMinute(shown, (d) => d.minute);
        let found = 0;
        for (const [minute, group] of rowsBy) {
          const texts = shownBy.get(minute) || [];
          if (texts.length !== group.length) continue;
          group.forEach((m, i) => {
            if (sealed(m.text) && texts[i].text) { revealed.set(String(m.messageId), texts[i].text); found += 1; }
          });
        }
        return found;
      };

      // Waits for the chat to finish drawing, then reads it.
      const revealOpen = async (key) => {
        let count = -1;
        await waitFor(() => { const n = drawn().length; const settled = n > 0 && n === count; count = n; return settled; }, 4000);
        return reveal(key);
      };

      // Encrypted media has no https URL in the table. The client decrypts it into blob URLs, so it shows as a note.
      const message = (m, atts) => {
        const images = [];
        const files = [];
        const notes = [];
        for (const a of atts.get(String(m.messageId)) || []) {
          const mime = String(a.previewUrlMimeType || a.playableUrlMimeType || '');
          const preview = https(a.previewUrl) || https(a.imageUrl);
          const playable = https(a.playableUrl);
          if (preview && (mime.startsWith('image/') || num(a.attachmentType) === 2)) {
            images.push({ url: preview, name: String(a.filename || ''), width: num(a.previewWidth), height: num(a.previewHeight) });
          } else if (playable || (preview && a.filename)) {
            files.push({ url: playable || preview, name: String(a.filename || 'file') });
          } else if (a.titleText) {
            notes.push(String(a.titleText));
          } else {
            notes.push(num(a.attachmentType) === 2 ? '[photo]' : '[attachment]');
          }
        }
        let text = String(m.text || '');
        if (sealed(text)) text = revealed.get(String(m.messageId)) || SEALED_NOTE;
        if (!text && notes.length) text = notes.join(' ');
        const sender = str(m.senderId);
        return { id: String(m.messageId), channelID: wrap(str(m.threadKey)), authorID: wrap(sender),
                 authorName: sender === meID ? meName : contactName(sender), text, time: num(m.timestampMs), images, files };
      };

      // Plain chats use mid. IDs and encrypted chats use numeric ones. An optimistic send uses its offline
      // threading ID until the server confirms it, so those rows are left out along with admin lines.
      const real = (m) => {
        const id = String(m.messageId || '');
        if (!id || m.isAdminMessage || m.isUnsent) return false;
        const otid = str(m.offlineThreadingId);
        return !otid || id !== otid;
      };
      const byTime = (a, b) => num(a.timestampMs) - num(b.timestampMs);

      const seen = new Set();
      let baselined = false;
      const started = Date.now();

      // New messages since the bridge started. Older ones that arrive later are history the client loaded.
      const scan = async () => {
        const fresh = [];
        for (const m of await rows('messages')) {
          const id = String(m.messageId || '');
          if (!id || seen.has(id)) continue;
          seen.add(id);
          if (baselined && real(m) && num(m.timestampMs) >= started - 5000) fresh.push(m);
        }
        baselined = true;
        if (!fresh.length) return;
        fresh.sort(byTime);
        const hidden = fresh.filter((m) => sealed(m.text) && !revealed.has(String(m.messageId)));
        if (!hidden.length) { await deliver(fresh); return; }
        // Opening the chat in the Messenger window draws the new messages so their text can be read.
        serial(async () => {
          for (const key of new Set(hidden.map((m) => str(m.threadKey)))) {
            try {
              if (currentKey() !== key) await open({ channelId: key });
              await revealOpen(key);
            } catch (e) {}
          }
          await deliver(fresh);
        });
      };

      const deliver = async (list) => {
        const atts = await attachmentsByMessage();
        for (const m of list) {
          const key = str(m.threadKey);
          const t = cache.threads.get(key);
          if (!t) continue;
          const type = typeOf(t);
          if (GROUP.includes(type)) {
            post({ type: 'messenger.groupMessage', group: group(t), message: message(m, atts) });
          } else if (ONE.includes(type)) {
            const id = others(key)[0] || key;
            cache.userThread.set(id, key);
            post({ type: 'messenger.message', userId: wrap(id), buddy: buddy(id), message: message(m, atts) });
          }
        }
      };

      let running = false;
      let again = false;
      let pending = null;
      const update = async () => {
        if (running) { again = true; return; }
        running = true;
        try {
          await refresh();
          snapshot(false);
          await scan();
        } catch (e) {}
        running = false;
        if (again) { again = false; schedule(); }
      };
      const schedule = () => {
        if (pending) return;
        pending = setTimeout(() => { pending = null; update(); }, 400);
      };

      // Sends and history loads drive the Messenger window, so they run one at a time.
      let chain = Promise.resolve();
      const serial = (fn) => {
        const run = chain.then(fn, fn);
        chain = run.catch(() => {});
        return run;
      };

      const currentKey = () => {
        const m = location.pathname.match(/\/messages\/(?:e2ee\/)?t\/(\d+)/);
        return m ? m[1] : '';
      };
      const samePath = (a, b) => a.replace(/\/+$/, '') === b.replace(/\/+$/, '');

      // A sidebar link is the client's own navigation. Without one, a popstate makes its router read the new URL.
      const go = (path) => {
        if (samePath(location.pathname, path)) return;
        const link = [...document.querySelectorAll('a[href]')].find((a) => samePath(a.getAttribute('href') || '', path));
        if (link) { link.click(); return; }
        history.pushState({}, '', path);
        window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
      };

      const waitFor = async (test, ms) => {
        const end = Date.now() + ms;
        while (Date.now() < end) {
          const v = await test();
          if (v) return v;
          await sleep(250);
        }
        return null;
      };

      const pathFor = (key) => {
        const t = cache.threads.get(key);
        return (ENCRYPTED.includes(typeOf(t)) ? '/messages/e2ee/t/' : '/messages/t/') + key + '/';
      };

      // A target is a wrapped user ID for a one-to-one chat or { channelId } for a group chat.
      const threadFor = (target) => {
        if (target && typeof target === 'object' && target.channelId) {
          const key = raw(target.channelId);
          return { key, path: pathFor(key) };
        }
        const id = raw(target);
        const key = cache.userThread.get(id);
        if (key) return { key, path: pathFor(key) };
        // Facebook redirects a new conversation to the encrypted thread when there is one.
        return { key: '', path: '/messages/t/' + id + '/' };
      };

      const loaded = new Set();
      const messagesIn = async (key) => (await rows('messages')).filter((m) => str(m.threadKey) === key && real(m)).sort(byTime);

      const open = async (target) => {
        let { key, path } = threadFor(target);
        go(path);
        if (!key) {
          key = await waitFor(() => currentKey(), 8000) || '';
          if (!key) throw new Error('Messenger did not open this conversation.');
          if (typeof target === 'string') cache.userThread.set(raw(target), key);
        } else {
          await waitFor(() => currentKey() === key, 8000);
        }
        return key;
      };

      // The table only holds threads the client has opened, so the first load opens the thread in the Messenger
      // window and waits for its messages.
      const history = (target, limit) => serial(async () => {
        let { key } = threadFor(target);
        let list = key ? await messagesIn(key) : [];
        if (!key || (list.length < limit && !loaded.has(key))) {
          const before = list.length;
          key = await open(target);
          loaded.add(key);
          await waitFor(async () => (await messagesIn(key)).length > before, 6000);
          await sleep(400);
          list = await messagesIn(key);
        }
        const recent = list.slice(-limit);
        if (recent.some((m) => sealed(m.text) && !revealed.has(String(m.messageId)))) {
          if (currentKey() !== key) await open(target);
          await revealOpen(key);
        }
        const atts = await attachmentsByMessage();
        return recent.map((m) => message(m, atts));
      });

      const composer = () => [...document.querySelectorAll('[role="textbox"][contenteditable="true"]')]
        .find((e) => !/search/i.test(e.getAttribute('aria-label') || '')) || null;

      const clear = (box) => {
        const L = mod('Lexical');
        const editor = box && box.__lexicalEditor;
        if (L && editor) { try { editor.update(() => L.$getRoot().clear()); } catch (e) {} }
      };

      // The composer is a Lexical editor. Text goes in through Lexical so the client's own state sees it.
      const type = async (box, text) => {
        box.focus();
        const L = mod('Lexical');
        const editor = box.__lexicalEditor;
        if (L && editor && typeof L.$getRoot === 'function') {
          await Promise.race([
            new Promise((resolve) => editor.update(() => {
              const root = L.$getRoot();
              root.clear();
              const p = L.$createParagraphNode();
              text.split('\n').forEach((line, i) => {
                if (i > 0) p.append(L.$createLineBreakNode());
                if (line) p.append(L.$createTextNode(line));
              });
              root.append(p);
              p.selectEnd();
            }, { onUpdate: resolve })),
            sleep(500),
          ]);
          return;
        }
        const dt = new DataTransfer();
        dt.setData('text/plain', text);
        box.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
      };

      const submit = async (box) => {
        await sleep(200);
        const button = [...document.querySelectorAll('[role="button"][aria-label], button[aria-label]')]
          .find((b) => /^(press enter to send|send)$/i.test((b.getAttribute('aria-label') || '').trim()));
        if (button) { button.click(); return; }
        const enter = () => new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                                                          bubbles: true, cancelable: true });
        const L = mod('Lexical');
        const editor = box.__lexicalEditor;
        if (L && editor && L.KEY_ENTER_COMMAND && editor.dispatchCommand(L.KEY_ENTER_COMMAND, enter())) return;
        box.dispatchEvent(enter());
      };

      const empty = (box) => !box.isConnected || box.innerText.trim() === '';

      const send = (target, text) => serial(async () => {
        await open(target);
        const box = await waitFor(() => composer(), 8000);
        if (!box) throw new Error('Messenger did not show a message box for this conversation.');
        await sleep(300);
        await type(box, text);
        if (empty(box)) throw new Error('Messenger did not accept the text.');
        await submit(box);
        if (!(await waitFor(() => empty(box), 4000))) {
          clear(box);
          throw new Error('Messenger did not send the message.');
        }
        return true;
      });

      window.__aolosMessenger = {
        snapshot: () => { snapshot(true); return true; },
        history: (target, limit) => history(target, limit),
        latest: (target, limit) => history(target, limit),
        send: (target, text) => send(target, String(text || '')),
        open: (target) => serial(() => open(target)).then(() => true),
      };

      let tries = 0;
      let reported = false;
      let signedOff = false;
      const boot = async () => {
        tries += 1;
        if (typeof window.require !== 'function') return false;
        const user = mod('CurrentUserInitialData');
        if (!user || !user.USER_ID || String(user.USER_ID) === '0') {
          if (user && !signedOff) { signedOff = true; post({ type: 'messenger.signedOff' }); }
          return false;
        }
        I64 = mod('I64');
        const single = mod('LSDatabaseSingleton');
        const missing = [];
        if (!I64) missing.push('I64');
        if (!single) missing.push('LSDatabaseSingleton');
        if (missing.length) {
          if (tries >= 40 && !reported && /^\/messages/.test(location.pathname)) {
            reported = true;
            post({ type: 'messenger.unavailable', missing });
          }
          return false;
        }
        db = await single.LSDatabaseSingleton;
        if (!db || !db.tables || !db.tables.messages || !db.tables.contacts) return false;
        const pres = mod('FBPresenceUnifiedClientSingleton');
        presence = pres && pres.FBPresenceUnifiedClientSingleton;
        meID = String(user.USER_ID);
        meName = String(user.NAME || user.SHORT_NAME || '');
        await refresh();
        await scan();
        db.subscribeToCommit(schedule);
        try { if (presence) presence.registerListener(schedule); } catch (e) {}
        // Presence also changes without a commit, and idle times move with the clock.
        setInterval(schedule, 15000);
        post({ type: 'messenger.ready', missing: presence ? [] : ['FBPresenceUnifiedClientSingleton'] });
        snapshot(true);
        return true;
      };
      let booting = false;
      const timer = setInterval(async () => {
        if (booting) return;
        booting = true;
        try { if (await boot()) clearInterval(timer); } catch (e) {}
        booting = false;
      }, 1500);
    })();
    """#
}
