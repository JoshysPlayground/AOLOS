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

      // AOL-OS plays its own sounds, so Discord's notification sounds stay silent. They are audio elements
      // loaded from the client's /assets/ folder. Calls and videos use streams or CDN URLs and still play.
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        const src = this.currentSrc || this.src || '';
        if (!this.srcObject && /^https:\/\/[^/]*discord\.com\/assets\/[^/]+\.(mp3|ogg|wav)(\?|$)/i.test(src)) {
          return Promise.resolve();
        }
        return play.apply(this, arguments);
      };

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
        guilds: () => store('GuildStore'),
        sortedGuilds: () => store('SortedGuildStore'),
        guildChannels: () => store('GuildChannelStore'),
        readState: () => store('ReadStateStore'),
        voiceStates: () => store('VoiceStateStore'),
        selectedChannels: () => store('SelectedChannelStore'),
        voiceActions: () => find((e) => typeof e.selectVoiceChannel === 'function'),
        guildMembers: () => store('GuildMemberStore'),
        guildRoles: () => store('GuildRoleStore'),
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

      // The server nickname, then the friend nickname, then the display name. Empty when Discord has not loaded the user.
      const knownName = (id, guildId) => {
        if (guildId) {
          try { const m = need('guildMembers').getMember(guildId, id); if (m && m.nick) return String(m.nick); } catch (e) {}
        }
        const u = S.users.getUser(id);
        const nick = typeof S.relationships.getNickname === 'function' ? S.relationships.getNickname(id) : null;
        return nick || (u && (u.globalName || u.global_name || u.username)) || '';
      };
      const displayName = (id) => knownName(id) || id;

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

      const members = (channel) => {
        const r = channel.recipients || channel.rawRecipients || [];
        return r.map((x) => (x && typeof x === 'object' ? x.id : x)).filter(Boolean);
      };

      const group = (channel) => {
        const ids = members(channel);
        const name = channel.name || ids.map(displayName).join(', ') || 'Group Chat';
        return { id: String(channel.id), name, members: ids.map(friend) };
      };

      // Group direct messages, most recent first.
      const groupDMs = () => {
        if (!S.channels || typeof S.channels.getMutablePrivateChannels !== 'function') return [];
        let list = [];
        try { list = Object.values(S.channels.getMutablePrivateChannels() || {}); } catch (e) { return []; }
        return list
          .filter((c) => c && c.type === 3)
          .sort((a, b) => {
            const x = snowflake(a.lastMessageId || a.id), y = snowflake(b.lastMessageId || b.id);
            return x === y ? 0 : (x > y ? -1 : 1);
          })
          .slice(0, 30)
          .map(group);
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
          groups: groupDMs(),
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

      const guildOf = (m, channelID) => {
        if (m.guild_id || m.guildId) return String(m.guild_id || m.guildId);
        try { const c = S.channels.getChannel(channelID); return c && c.guild_id ? String(c.guild_id) : ''; } catch (e) { return ''; }
      };

      const roleName = (guildId, id) => {
        try {
          const r = need('guildRoles').getRole(guildId, id);
          if (r && r.name) return String(r.name);
        } catch (e) {}
        try {
          const g = need('guilds').getGuild(guildId);
          const r = g && g.roles && g.roles[id];
          if (r && r.name) return String(r.name);
        } catch (e) {}
        return 'role';
      };

      // Webhooks and bots often post only rich embeds, so their text is the embed's author, title, description and fields.
      const embedText = (m) => (m.embeds || [])
        .filter((e) => e && e.type !== 'image' && e.type !== 'gifv')
        .map((e) => {
          const author = e.author && e.author.name;
          const footer = e.footer && e.footer.text;
          const lines = [author, e.title || e.rawTitle, e.description || e.rawDescription];
          for (const f of e.fields || []) {
            const name = f.name || f.rawName, value = f.value || f.rawValue;
            lines.push(name && value ? `${name}: ${value}` : (name || value));
          }
          lines.push(footer);
          return lines.filter(Boolean).map(String).join('\n');
        })
        .filter(Boolean)
        .join('\n\n');

      const text = (m, guildId) => {
        const mentioned = {};
        for (const u of m.mentions || []) {
          if (u && typeof u === 'object' && u.id) mentioned[String(u.id)] = u.global_name || u.globalName || u.username;
        }
        let s = String(m.content || '');
        s = s.replace(/<@!?(\d+)>/g, (_, id) => '@' + (knownName(id, guildId) || mentioned[id] || 'unknown-user'));
        s = s.replace(/<@&(\d+)>/g, (_, id) => '@' + roleName(guildId, id));
        s = s.replace(/<#(\d+)>/g, (_, id) => {
          try { const c = S.channels.getChannel(id); if (c && c.name) return '#' + c.name; } catch (e) {}
          return '#channel';
        });
        s = s.replace(/<a?(:\w+:)\d+>/g, '$1');
        const embeds = embedText(m);
        if (embeds) s = s ? `${s}\n${embeds}` : embeds;
        if (!s && (m.sticker_items || m.stickerItems || []).length) s = '[sticker]';
        return s;
      };

      // Raw gateway events use snake_case and store records use camelCase, so read both spellings.
      const media = (m) => {
        const images = [];
        const files = [];
        for (const a of m.attachments || []) {
          const type = a.content_type || a.contentType || '';
          const url = a.proxy_url || a.proxyURL || a.url;
          if (!url) continue;
          const item = { url, name: a.filename || 'file', width: a.width || 0, height: a.height || 0 };
          (/^image\//.test(type) || /\.(png|jpe?g|gif|webp)$/i.test(item.name) ? images : files).push(item);
        }
        for (const e of m.embeds || []) {
          if (e.type !== 'image' && e.type !== 'gifv') continue;
          const img = e.image || e.thumbnail;
          const url = img && (img.proxy_url || img.proxyURL || img.url);
          if (url) images.push({ url, name: '', width: img.width || 0, height: img.height || 0 });
        }
        return { images, files };
      };

      const message = (m) => {
        let time = Date.now();
        try {
          const t = new Date(m.timestamp && m.timestamp.valueOf ? m.timestamp.valueOf() : m.timestamp).getTime();
          if (!isNaN(t)) time = t;
        } catch (e) {}
        const { images, files } = media(m);
        const author = m.author || {};
        const authorID = String(author.id || '');
        const channelID = String(m.channel_id || m.channelId || '');
        const guildId = guildOf(m, channelID);
        return { id: String(m.id), channelID, authorID, authorName: authorName(m, guildId), text: text(m, guildId), time, images, files,
                 reply: reply(m, channelID, guildId), reactions: (m.reactions || []).map(reaction) };
      };

      // A webhook names itself on each message, so its name is never looked up.
      const authorName = (m, guildId) => {
        const author = m.author || {};
        const id = String(author.id || '');
        const own = String(author.global_name || author.globalName || author.username || '');
        if (m.webhook_id || m.webhookId || !id) return own;
        let name = '';
        try { name = knownName(id, guildId); } catch (e) {}
        return name || own || id;
      };

      // The quoted message a reply points at. Gateway events embed it and stored messages reference it by ID.
      const reply = (m, channelID, guildId) => {
        const ref = m.message_reference || m.messageReference;
        const refID = ref && (ref.message_id || ref.messageId);
        let original = m.referenced_message || m.referencedMessage || null;
        if (!original && refID) {
          try { original = need('messages').getMessage(channelID, refID); } catch (e) {}
        }
        if (original) {
          return { id: String(original.id), authorName: authorName(original, guildId), text: text(original, guildId).slice(0, 140) };
        }
        return refID ? { id: String(refID), authorName: '', text: 'Original message not loaded' } : null;
      };

      const reaction = (r) => {
        const e = r.emoji || {};
        const name = e.id ? `:${e.name}:` : (e.name || '?');
        const count = r.count || (r.count_details ? (r.count_details.normal || 0) + (r.count_details.burst || 0) : 1);
        return { name, count, me: !!(r.me || r.me_burst) };
      };

      const recipient = (channel) => {
        if (!channel || channel.type !== 1) return null;
        if (typeof channel.getRecipientId === 'function') return channel.getRecipientId();
        const r = channel.recipients || channel.rawRecipients || [];
        const first = r[0];
        return first && typeof first === 'object' ? first.id : first;
      };

      // A conversation target is a user ID for a direct message or { channelId } for a group.
      const channelFor = async (target) => {
        if (target && typeof target === 'object' && target.channelId) return String(target.channelId);
        const userId = target;
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
          if (channel && channel.type === 3) {
            post({ type: 'discord.groupMessage', group: group(channel), message: message(a.message) });
            return;
          }
          if (channel && channel.guild_id && mentionsMe(a.message, channel)) {
            post(Object.assign(roomInfo(channel), { type: 'discord.mention', message: message(a.message) }));
            return;
          }
          if (watched.has(String(a.channelId))) {
            post({ type: 'discord.roomMessage', channelId: String(a.channelId), message: message(a.message) });
            return;
          }
          if (channel && channel.guild_id) {
            post(Object.assign(roomInfo(channel), { type: 'discord.roomActivity', message: message(a.message) }));
            return;
          }
          const userId = recipient(channel);
          if (!userId) return;
          post({ type: 'discord.message', userId, buddy: friend(userId), message: message(a.message) });
        });
        const reactions = (a) => setTimeout(() => {
          try {
            const cid = String(a.channelId || '');
            const channel = S.channels && S.channels.getChannel(cid);
            if (!channel || !(channel.type === 1 || channel.type === 3 || watched.has(cid))) return;
            const m = need('messages').getMessage(cid, a.messageId);
            if (!m) return;
            post({ type: 'discord.reactions', channelId: cid, messageId: String(a.messageId),
                   reactions: (m.reactions || []).map(reaction) });
          } catch (e) {}
        }, 60);
        let voiceTimer = null;
        S.dispatcher.subscribe('VOICE_STATE_UPDATES', () => {
          if (voiceTimer) return;
          voiceTimer = setTimeout(() => { voiceTimer = null; post({ type: 'discord.voice' }); }, 500);
        });
        ['MESSAGE_REACTION_ADD', 'MESSAGE_REACTION_REMOVE', 'MESSAGE_REACTION_REMOVE_ALL', 'MESSAGE_REACTION_REMOVE_EMOJI']
          .forEach((t) => S.dispatcher.subscribe(t, reactions));
        S.dispatcher.subscribe('CONNECTION_OPEN', () => setTimeout(() => snapshot(true), 1500));
        S.dispatcher.subscribe('LOGOUT', () => { last = ''; post({ type: 'discord.signedOff' }); });
      };

      // The server and room a server channel message belongs to.
      const roomInfo = (channel) => {
        let serverName = '';
        try { const g = optional('guilds'); serverName = String((g && g.getGuild(channel.guild_id) || {}).name || ''); } catch (e) {}
        let categoryName = '';
        try {
          const parent = channel.parent_id && S.channels.getChannel(channel.parent_id);
          categoryName = parent ? String(parent.name || '') : '';
        } catch (e) {}
        return { channelId: String(channel.id), guildId: String(channel.guild_id), roomName: String(channel.name || ''),
                 serverName, categoryId: channel.parent_id ? String(channel.parent_id) : '', categoryName };
      };

      // A server message that names you directly or one of your roles. @everyone and @here are left out.
      const mentionsMe = (m, channel) => {
        const me = S.users.getCurrentUser();
        if (!me || !m.author || String(m.author.id) === String(me.id)) return false;
        if ((m.mentions || []).some((u) => String(u && typeof u === 'object' ? u.id : u) === String(me.id))) return true;
        const roles = m.mention_roles || m.mentionRoles || [];
        if (!roles.length) return false;
        try {
          const member = optional('guildMembers').getMember(channel.guild_id, me.id);
          return !!member && (member.roles || []).some((r) => roles.includes(r));
        } catch (e) { return false; }
      };

      // Server channels with an open chat room window. Only these forward live messages.
      const watched = new Set();
      const optional = (k) => { try { return need(k); } catch (e) { return null; } };

      const servers = () => {
        const gs = need('guilds');
        const all = gs.getGuilds ? gs.getGuilds() : {};
        const list = Array.isArray(all) ? all : Object.values(all || {});
        let order = [];
        try {
          const sorted = optional('sortedGuilds');
          if (sorted && typeof sorted.getFlattenedGuildIds === 'function') order = sorted.getFlattenedGuildIds();
        } catch (e) {}
        const rank = new Map(order.map((id, i) => [String(id), i]));
        const pos = (id) => (rank.has(id) ? rank.get(id) : 1e9);
        return list
          .map((g) => ({ id: String(g.id), name: String(g.name || g.id),
                         icon: g.icon ? `https://cdn.discordapp.com/icons/${g.id}/${g.icon}.png?size=64` : '' }))
          .sort((a, b) => pos(a.id) - pos(b.id) || a.name.localeCompare(b.name));
      };

      // Text and announcement channels the account can see, in the server's sidebar order.
      const rooms = (guildId) => {
        let list = [];
        const gc = optional('guildChannels');
        try {
          const r = gc && typeof gc.getChannels === 'function' ? gc.getChannels(guildId) : null;
          if (r && Array.isArray(r.SELECTABLE)) list = r.SELECTABLE.map((x) => x.channel || x);
        } catch (e) {}
        if (!list.length) {
          try {
            const all = need('channels').getMutableGuildChannelsForGuild(guildId);
            list = Object.values(all || {}).sort((a, b) => (a.position || 0) - (b.position || 0));
          } catch (e) {}
        }
        if (gc && typeof gc.getChannels === 'function') {
          try {
            const r = gc.getChannels(guildId);
            if (r && Array.isArray(r.VOCAL)) {
              const vocal = r.VOCAL.map((x) => x.channel || x);
              const known = new Set(list.map((c) => c && c.id));
              list = list.concat(vocal.filter((c) => c && !known.has(c.id)));
            }
          } catch (e) {}
        }
        const rs = optional('readState');
        const vs = optional('voiceStates');
        const sel = optional('selectedChannels');
        let joined = null;
        try { joined = sel && typeof sel.getVoiceChannelId === 'function' ? sel.getVoiceChannelId() : null; } catch (e) {}
        const people = (cid) => {
          try {
            const states = vs.getVoiceStatesForChannel(cid);
            const list = Array.isArray(states) ? states : Object.values(states || {});
            return list.map((s) => displayName(String(s.userId || s.user_id || (s.user && s.user.id) || ''))).filter(Boolean);
          } catch (e) { return []; }
        };
        return list
          .filter((c) => c && (c.type === 0 || c.type === 5 || c.type === 2 || c.type === 13))
          .map((c) => {
            const voice = c.type === 2 || c.type === 13;
            let category = '';
            try {
              const parent = c.parent_id && S.channels.getChannel(c.parent_id);
              category = parent ? String(parent.name || '') : '';
            } catch (e) {}
            let unread = false;
            try { unread = !!(rs && typeof rs.hasUnread === 'function' && rs.hasUnread(c.id)); } catch (e) {}
            return { id: String(c.id), name: String(c.name || c.id), category,
                     categoryId: c.parent_id ? String(c.parent_id) : '', unread: !voice && unread, voice,
                     people: voice ? people(c.id) : [], joined: voice && String(joined) === String(c.id) };
          });
      };

      window.__aolosDiscord = {
        snapshot: () => snapshot(true),
        servers: () => servers(),
        rooms: (guildId) => rooms(String(guildId)),
        // Every room in every server, for Quick Launch.
        allRooms: () => {
          const out = [];
          for (const s of servers()) {
            let list = [];
            try { list = rooms(s.id); } catch (e) {}
            for (const r of list) out.push({ id: r.id, name: r.name, voice: r.voice, serverName: s.name });
          }
          return out;
        },
        // People the client knows (friends, DM partners, server members it has loaded) whose name matches,
        // so Quick Launch can start an IM with someone who is not on the Buddy List.
        searchUsers: (query, limit) => {
          const q = String(query || '').toLowerCase();
          if (!q) return [];
          const me = S.users.getCurrentUser();
          let all = [];
          try {
            const users = typeof S.users.getUsers === 'function' ? S.users.getUsers() : {};
            all = Array.isArray(users) ? users : Object.values(users || {});
          } catch (e) { return []; }
          const out = [];
          for (const u of all) {
            if (!u || u.bot || u.system || (me && String(u.id) === String(me.id))) continue;
            const id = String(u.id);
            const names = [displayName(id), u.username, u.globalName || u.global_name].filter(Boolean);
            if (!names.some((n) => String(n).toLowerCase().includes(q))) continue;
            out.push(friend(id));
            if (out.length >= limit) break;
          }
          return out;
        },
        watch: (channelId) => { watched.add(String(channelId)); return true; },
        unwatch: (channelId) => { watched.delete(String(channelId)); return true; },
        history: async (userId, limit) => {
          const cid = await channelFor(userId);
          if (loaded(cid).length < limit && S.actions && typeof S.actions.fetchMessages === 'function') {
            try { await S.actions.fetchMessages({ channelId: cid, limit: Math.max(limit, 25) }); } catch (e) {}
          }
          return loaded(cid).slice(-limit).map(message);
        },
        send: async (userId, content, replyTo) => {
          const cid = await channelFor(userId);
          // Sends go over the REST wrapper. The client's own sendMessage can wait forever on a server channel
          // the client has not opened.
          const http = optional('http');
          if (http) {
            const body = { content, nonce: String((BigInt(Date.now()) - 1420070400000n) << 22n) };
            if (replyTo) body.message_reference = { message_id: String(replyTo) };
            await http.post({ url: `/channels/${cid}/messages`, body });
            return true;
          }
          await need('actions').sendMessage(cid, { content, tts: false, invalidEmojis: [], validNonShortcutEmojis: [] },
                                            undefined, {});
          return true;
        },
        upload: async (userId, content, files, replyTo) => {
          const cid = await channelFor(userId);
          const attachments = files.map((f, i) => {
            const bin = atob(f.data);
            const bytes = new Uint8Array(bin.length);
            for (let j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
            const file = new File([bytes], f.name, { type: f.type || 'application/octet-stream' });
            return { name: `files[${i}]`, file, filename: f.name };
          });
          const payload = { content: content || '', attachments: files.map((f, i) => ({ id: i, filename: f.name })) };
          if (replyTo) payload.message_reference = { message_id: String(replyTo) };
          await need('http').post({ url: `/channels/${cid}/messages`, attachments,
                                    fields: [{ name: 'payload_json', value: JSON.stringify(payload) }] });
          return true;
        },
        // The latest messages straight from Discord's API, used to catch anything the live events missed.
        latest: async (target, limit) => {
          const cid = await channelFor(target);
          const res = await need('http').get({ url: `/channels/${cid}/messages`, query: { limit } });
          return (Array.isArray(res && res.body) ? res.body : []).slice().reverse().map(message);
        },
        joinVoice: (channelId) => { need('voiceActions').selectVoiceChannel(channelId ? String(channelId) : null); return true; },
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
