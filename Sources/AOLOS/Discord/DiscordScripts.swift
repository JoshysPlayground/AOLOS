import Foundation

extension Scripts {
    /// Reads friends, presence and direct messages out of the Discord web app and posts them over `aolos`.
    /// Native code calls back into `window.__aolosDiscord`. Discord has no public API for this, so the
    /// script finds the client's own Flux stores through its webpack chunk array, `webpackChunkdiscord_app`.
    /// Store and action names come from the running client and can change with any Discord release.
    static let discordBridge = #"""
    (() => {
      if (window.__aolosDiscord || !/(^|\.)discord\.com$/.test(location.hostname)) return;
      const post = (m) => { try { window.webkit.messageHandlers.aolos.postMessage(m); } catch (e) {} };
      const S = {};
      let req = null;

      const webpack = () => {
        if (req) return req;
        const chunk = window.webpackChunkdiscord_app;
        if (!chunk || typeof chunk.push !== 'function') return null;
        // Each webpack runtime on the page forwards the push to the one before it, so the callback runs once
        // per runtime. The main client is the runtime with the largest module cache.
        const found = [];
        try {
          chunk.push([[Symbol('aolos')], {}, (r) => { found.push(r); }]);
          chunk.pop();
        } catch (e) { return null; }
        const size = (r) => (r && r.c ? Object.keys(r.c).length : 0);
        const best = found.sort((a, b) => size(b) - size(a))[0];
        if (size(best) > 0) req = best;
        return req;
      };

      const candidates = function* () {
        const r = webpack();
        if (!r) return;
        for (const id of Object.keys(r.c)) {
          let e;
          try { e = r.c[id] && r.c[id].exports; } catch (err) { continue; }
          if (!e || e === window) continue;
          yield e;
          if (typeof e !== 'object') continue;
          let keys = [];
          // Some exports are proxies whose key lookup throws.
          try { keys = Object.keys(e); } catch (err) { continue; }
          for (const k of keys) {
            let v;
            try { v = e[k]; } catch (err) { continue; }
            if (v && v !== e && (typeof v === 'object' || typeof v === 'function')) yield v;
          }
        }
      };

      // Some exports are proxies that answer every property with a function. Skip them.
      const isProxy = (e) => { try { return e.__aolosNoSuchKey !== undefined; } catch (err) { return true; } };
      const find = (test) => {
        for (const e of candidates()) {
          try { if (!isProxy(e) && test(e)) return e; } catch (err) {}
        }
        return null;
      };

      const storeName = (e) => {
        if (typeof e.getName === 'function') return e.getName();
        return e.constructor && e.constructor.displayName;
      };
      const store = (name) => find((e) => typeof e.addChangeListener === 'function' && storeName(e) === name);

      const wanted = {
        presence: () => store('PresenceStore'),
        relationships: () => store('RelationshipStore'),
        users: () => store('UserStore'),
        channels: () => store('ChannelStore'),
        messages: () => store('MessageStore'),
        dispatcher: () => find((e) => typeof e.dispatch === 'function' && typeof e.subscribe === 'function'
                                     && typeof e.unsubscribe === 'function'),
        actions: () => find((e) => typeof e.sendMessage === 'function' && typeof e.fetchMessages === 'function'),
        privates: () => find((e) => typeof e.openPrivateChannel === 'function'),
        // The REST wrapper the client sends uploads through. It takes `attachments` and `fields` options.
        http: () => find((e) => typeof e.get === 'function' && typeof e.post === 'function' && typeof e.put === 'function'
                              && typeof e.patch === 'function' && typeof e.del === 'function' && !e.Request),
      };
      const required = ['presence', 'relationships', 'users', 'dispatcher'];
      const missing = (keys) => keys.filter((k) => !S[k]);

      const need = (k) => {
        if (!S[k]) {
          req = null;
          try { S[k] = wanted[k](); } catch (e) {}
        }
        if (!S[k]) throw new Error(`AOL-OS could not find Discord's ${k} module.`);
        return S[k];
      };

      const avatar = (u, id) => {
        if (u && u.avatar) return `https://cdn.discordapp.com/avatars/${id}/${u.avatar}.png?size=64`;
        let index = 0;
        try {
          index = u && u.discriminator && u.discriminator !== '0'
            ? Number(u.discriminator) % 5 : Number((BigInt(id) >> 22n) % 6n);
        } catch (e) {}
        return `https://cdn.discordapp.com/embed/avatars/${index}.png`;
      };

      const displayName = (id) => {
        const u = S.users.getUser(id);
        const nick = typeof S.relationships.getNickname === 'function' ? S.relationships.getNickname(id) : null;
        return nick || (u && (u.globalName || u.global_name || u.username)) || id;
      };

      const activity = (id) => {
        let list = [];
        try { list = S.presence.getActivities(id) || []; } catch (e) {}
        const custom = list.find((a) => a.type === 4 && a.state);
        if (custom) return custom.state;
        const verbs = { 0: 'Playing', 1: 'Streaming', 2: 'Listening to', 3: 'Watching', 5: 'Competing in' };
        const a = list.find((x) => x.type in verbs && x.name);
        return a ? `${verbs[a.type]} ${a.name}` : '';
      };

      const friendIDs = () => {
        if (typeof S.relationships.getFriendIDs === 'function') return S.relationships.getFriendIDs();
        const all = typeof S.relationships.getRelationships === 'function' ? S.relationships.getRelationships() : {};
        return Object.keys(all).filter((id) => all[id] === 1);
      };

      const clientStatus = (id) => {
        try {
          const state = S.presence.getState();
          return (state.clientStatuses && state.clientStatuses[id]) || {};
        } catch (e) { return {}; }
      };

      const friend = (id) => {
        const u = S.users.getUser(id);
        const cs = clientStatus(id);
        return {
          id,
          name: displayName(id),
          username: (u && u.username) || '',
          avatar: avatar(u, id),
          status: S.presence.getStatus(id) || 'offline',
          desktop: cs.desktop || '', mobile: cs.mobile || '', web: cs.web || '',
          activity: activity(id),
        };
      };

      const snowflake = (v) => { try { return BigInt(v || 0); } catch (e) { return 0n; } };

      // Direct message partners, most recent conversation first.
      const recentDMs = () => {
        if (!S.channels || typeof S.channels.getMutablePrivateChannels !== 'function') return [];
        let list = [];
        try { list = Object.values(S.channels.getMutablePrivateChannels() || {}); } catch (e) { return []; }
        return list
          .filter((c) => c && c.type === 1 && c.lastMessageId)
          .sort((a, b) => {
            const x = snowflake(a.lastMessageId), y = snowflake(b.lastMessageId);
            return x === y ? 0 : (x > y ? -1 : 1);
          })
          .slice(0, 60)
          .map(recipient)
          .filter(Boolean)
          .map(friend);
      };

      let last = '';
      let pending = null;
      const snapshot = (force) => {
        const me = S.users.getCurrentUser();
        if (!me) return;
        const body = {
          me: { id: me.id, name: me.globalName || me.global_name || me.username, avatar: avatar(me, me.id) },
          friends: friendIDs().map(friend),
          recent: recentDMs(),
        };
        const json = JSON.stringify(body);
        if (!force && json === last) return;
        last = json;
        post(Object.assign({ type: 'discord.friends' }, body));
      };
      const schedule = () => {
        if (pending) return;
        pending = setTimeout(() => { pending = null; try { snapshot(false); } catch (e) {} }, 300);
      };

      const text = (m) => {
        let s = String(m.content || '');
        s = s.replace(/<@!?(\d+)>/g, (_, id) => '@' + displayName(id));
        s = s.replace(/<a?(:\w+:)\d+>/g, '$1');
        const files = (m.attachments || []).map((a) => a.filename || a.url).filter(Boolean);
        if (files.length) s += (s ? '\n' : '') + files.map((f) => `[${f}]`).join(' ');
        if (!s && (m.sticker_items || m.stickerItems || []).length) s = '[sticker]';
        if (!s && (m.embeds || []).length) s = '[embed]';
        return s;
      };

      const message = (m) => {
        let time = Date.now();
        try {
          const t = new Date(m.timestamp && m.timestamp.valueOf ? m.timestamp.valueOf() : m.timestamp).getTime();
          if (!isNaN(t)) time = t;
        } catch (e) {}
        const author = m.author || {};
        return { id: String(m.id), authorID: String(author.id || ''), text: text(m), time };
      };

      const recipient = (channel) => {
        if (!channel || channel.type !== 1) return null;
        if (typeof channel.getRecipientId === 'function') return channel.getRecipientId();
        const r = channel.recipients || channel.rawRecipients || [];
        const first = r[0];
        return first && typeof first === 'object' ? first.id : first;
      };

      const channelFor = async (userId) => {
        let cid = need('channels').getDMFromUserId(userId);
        if (cid) return cid;
        if (S.privates && typeof S.privates.ensurePrivateChannel === 'function') {
          cid = await S.privates.ensurePrivateChannel(userId);
          if (cid) return cid;
        }
        if (S.privates && typeof S.privates.openPrivateChannel === 'function') {
          S.privates.openPrivateChannel(userId);
          for (let i = 0; i < 20 && !cid; i++) {
            await new Promise((resolve) => setTimeout(resolve, 250));
            cid = S.channels.getDMFromUserId(userId);
          }
          if (cid) return cid;
        }
        throw new Error('Discord has no direct message channel with this buddy yet.');
      };

      const loaded = (cid) => {
        const list = need('messages').getMessages(cid);
        if (!list) return [];
        if (typeof list.toArray === 'function') return list.toArray();
        return list._array || [];
      };

      const subscribe = () => {
        [S.presence, S.relationships, S.users, S.channels].forEach((s) => { if (s) s.addChangeListener(schedule); });
        S.dispatcher.subscribe('MESSAGE_CREATE', (a) => {
          if (!a || a.optimistic || !a.message) return;
          if (!S.channels) return;
          const channel = S.channels.getChannel(a.channelId);
          const userId = recipient(channel);
          if (!userId) return;
          post({ type: 'discord.message', userId, buddy: friend(userId), message: message(a.message) });
        });
        S.dispatcher.subscribe('CONNECTION_OPEN', () => setTimeout(() => snapshot(true), 1500));
        S.dispatcher.subscribe('LOGOUT', () => { last = ''; post({ type: 'discord.signedOff' }); });
      };

      window.__aolosDiscord = {
        snapshot: () => snapshot(true),
        history: async (userId, limit) => {
          const cid = await channelFor(userId);
          if (loaded(cid).length < limit && S.actions && typeof S.actions.fetchMessages === 'function') {
            try { await S.actions.fetchMessages({ channelId: cid, limit: Math.max(limit, 25) }); } catch (e) {}
          }
          return loaded(cid).slice(-limit).map(message);
        },
        send: async (userId, content) => {
          const cid = await channelFor(userId);
          await need('actions').sendMessage(cid, { content, tts: false, invalidEmojis: [], validNonShortcutEmojis: [] },
                                      undefined, {});
          return true;
        },
        upload: async (userId, content, files) => {
          const cid = await channelFor(userId);
          const attachments = files.map((f, i) => {
            const bin = atob(f.data);
            const bytes = new Uint8Array(bin.length);
            for (let j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
            const file = new File([bytes], f.name, { type: f.type || 'application/octet-stream' });
            return { name: `files[${i}]`, file, filename: f.name };
          });
          const payload = { content: content || '', attachments: files.map((f, i) => ({ id: i, filename: f.name })) };
          await need('http').post({ url: `/channels/${cid}/messages`, attachments,
                                    fields: [{ name: 'payload_json', value: JSON.stringify(payload) }] });
          return true;
        },
        open: (userId) => { need('privates').openPrivateChannel(userId); return true; },
      };

      let tries = 0;
      let reported = false;
      let lastError = '';
      const boot = () => {
        tries += 1;
        if (!webpack()) return false;
        for (const k of missing(Object.keys(wanted))) {
          try { S[k] = wanted[k](); } catch (e) { lastError = String(e); }
        }
        const gaps = missing(required);
        if (gaps.length) {
          // The page can load a small webpack runtime before the full client, so look it up again next time.
          if (tries >= 40 && !reported) {
            reported = true;
            post({ type: 'discord.unavailable', missing: gaps, modules: Object.keys(req.c).length, error: lastError });
          }
          req = null;
          return false;
        }
        if (!S.users.getCurrentUser()) return false;
        subscribe();
        post({ type: 'discord.ready', missing: missing(Object.keys(wanted)) });
        snapshot(true);
        return true;
      };
      const timer = setInterval(() => { if (boot()) clearInterval(timer); }, 1500);
    })();
    """#
}
