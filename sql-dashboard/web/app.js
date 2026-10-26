/* =========================================================================
   SQL Server Health Dashboard - front end
   One server at a time: pick it at the top, browse its pages on the left.
   Plain JavaScript, no frameworks. Data is always rendered as text.
   ========================================================================= */
(function () {
  'use strict';
  if (window.__unsupportedBrowser) return;

  // ---------------------------------------------------------------------------
  // Constants & icons
  // ---------------------------------------------------------------------------
  const SEV = { none: 0, info: 1, ok: 2, warning: 3, critical: 4, error: 5 };
  const SEV_LABEL = { info: 'Info', ok: 'OK', warning: 'Warning', critical: 'Critical', error: 'Failed' };
  const SEV_ICON = { info: 'info', ok: 'check-circle', warning: 'alert', critical: 'x-circle', error: 'x-circle' };
  const NUMERIC = /^(int|bigint|smallint|tinyint|decimal|numeric|float|real|money|smallmoney)$/i;
  const SQL_VERSIONS = { 17: '2025', 16: '2022', 15: '2019', 14: '2017', 13: '2016', 12: '2014', 11: '2012', 10: '2008' };
  const UNCAPPED_MEMORY = 2147483647;
  const STORE = 'sqldash.';
  const MAX_ROWS = 1000;

  const ICONS = {
    server: '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01"/>',
    database: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    replication: '<path d="M17 2l4 4-4 4"/><path d="M3 11V9a3 3 0 0 1 3-3h15"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v2a3 3 0 0 1-3 3H3"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9"/><path d="M10 13h4"/>',
    disk: '<path d="M22 12H2"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M6 16h.01M10 16h.01"/>',
    activity: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
    file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M8 13h8M8 17h5"/>',
    gauge: '<path d="M12 14l4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>',
    progress: '<path d="M21 12a9 9 0 1 1-9-9"/><path d="M12 7v5l3 3"/>',
    cluster: '<circle cx="12" cy="5" r="3"/><circle cx="5" cy="19" r="3"/><circle cx="19" cy="19" r="3"/><path d="M12 8v3M10.5 13.5l-4 3M13.5 13.5l4 3"/>',
    hourglass: '<path d="M6 2h12M6 22h12"/><path d="M7 2c0 5 10 6 10 10S7 17 7 22M17 2c0 5-10 6-10 10s10 5 10 10"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    memory: '<rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 11v2M10 11v2M14 11v2M18 11v2M6 17v3M10 17v3M14 17v3M18 17v3"/>',
    layers: '<path d="M12 2l10 5-10 5L2 7z"/><path d="M2 17l10 5 10-5M2 12l10 5 10-5"/>',
    play: '<path d="M6 4l14 8-14 8z"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/>',
    moon: '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>',
    check: '<path d="M20 6L9 17l-5-5"/>',
    'check-circle': '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.5l2.5 2.5 4.5-5"/>',
    alert: '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4M12 17h.01"/>',
    'x-circle': '<circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5M12 15V3"/>',
    copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.35-4.35"/>',
    chevron: '<path d="M6 9l6 6 6-6"/>',
    arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
    x: '<path d="M18 6L6 18M6 6l12 12"/>',
    rows: '<path d="M3 6h18M3 12h18M3 18h18"/>',
    message: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>'
  };
  const LOGO = '<svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#1e3a6e"/><ellipse cx="16" cy="9.5" rx="8" ry="3" fill="none" stroke="#fff" stroke-width="2"/><path d="M8 9.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13" fill="none" stroke="#fff" stroke-width="2"/><path d="M8 16c0 1.7 3.6 3 8 3s8-1.3 8-3" fill="none" stroke="#fff" stroke-width="2"/></svg>';

  function svg(name) {
    if (name === 'logo') return LOGO;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      (ICONS[name] || ICONS.database) + '</svg>';
  }

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  const state = {
    cfg: null,
    token: null,
    demo: false,
    fatal: false,
    server: null,          // selected instance id
    page: 'overview',
    inst: {},              // instance id -> { state, latencyMs, version }
    cache: {},             // "server|check" -> { res, at }
    inflight: {},          // "server|check" -> Promise
    tables: {},            // "server|check|set" -> { q, sort, dir }
    view: 'all',           // 'all' | 'issues'
    filter: '',            // global search filter applied to page tables
    pendingFilter: '',
    autoTimer: null,
    tickTimer: null
  };

  // ---------------------------------------------------------------------------
  // DOM helpers
  // ---------------------------------------------------------------------------
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.prototype.slice.call((r || document).querySelectorAll(s));

  function el(tag, props, kids) {
    const e = document.createElement(tag);
    if (props) {
      Object.keys(props).forEach(k => {
        const v = props[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k === 'icon') { e.setAttribute('data-icon', v); e.innerHTML = svg(v); }
        else if (k.indexOf('on') === 0) e.addEventListener(k.slice(2), v);
        else e.setAttribute(k, v === true ? '' : v);
      });
    }
    if (kids !== undefined && kids !== null) {
      [].concat(kids).forEach(c => {
        if (c === null || c === undefined || c === false) return;
        e.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
      });
    }
    return e;
  }
  const icon = (name, cls) => el('span', { icon: name, class: cls });
  const hydrate = root => $$('[data-icon]', root).forEach(n => { if (!n.firstChild) n.innerHTML = svg(n.getAttribute('data-icon')); });

  function pill(sev, text) {
    return el('span', { class: 'pill ' + sev }, [icon(SEV_ICON[sev] || 'info'), text || SEV_LABEL[sev] || sev]);
  }

  function store(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(STORE + key);
      localStorage.setItem(STORE + key, value);
    } catch (e) { /* storage unavailable */ }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  const fmtInt = n => (n === null || n === undefined) ? '–' : Math.round(n).toLocaleString();
  function fmtSizeMB(mb) {
    if (mb === null || mb === undefined || isNaN(mb)) return '–';
    if (mb >= 1048576) return (mb / 1048576).toFixed(2) + ' TB';
    if (mb >= 1024) return (mb / 1024).toFixed(mb >= 102400 ? 0 : 1) + ' GB';
    return Math.round(mb) + ' MB';
  }
  const fmtSizeGB = gb => fmtSizeMB(gb * 1024);
  function fmtUptime(min) {
    if (min === null || min === undefined) return '–';
    const d = Math.floor(min / 1440), h = Math.floor(min / 60) % 24, m = min % 60;
    return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + m + 'm' : m + 'm';
  }
  function fmtAgo(date) {
    const s = Math.max(0, Math.round((Date.now() - date) / 1000));
    if (s < 10) return 'just now';
    if (s < 60) return s + 's ago';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    return Math.floor(s / 3600) + ' h ago';
  }
  const fmtMs = ms => ms >= 1000 ? (ms / 1000).toFixed(1) + ' s' : Math.round(ms) + ' ms';
  function versionName(ver) {
    const major = parseInt(ver, 10);
    return SQL_VERSIONS[major] ? 'SQL Server ' + SQL_VERSIONS[major] : 'SQL Server ' + (ver || '');
  }
  const shortEdition = e => String(e || '').replace(/ \(64-bit\)/, '').replace(/ Edition/, '');
  function humanize(name) {
    return String(name).replace(/_/g, ' ')
      .replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
      .replace(/\bPct\b/g, '%').replace(/\bSec\b/g, '(s)').replace(/\bMin\b/g, '(min)')
      .replace(/\b(KB|MB|GB)\b/g, '($1)').trim();
  }

  // ---------------------------------------------------------------------------
  // API
  // ---------------------------------------------------------------------------
  class ApiError extends Error {
    constructor(message, kind) { super(message); this.kind = kind; }
  }

  async function api(path, body) {
    if (state.demo) return window.SqlDashDemo.handle(path, body);
    let res;
    try {
      res = await fetch(path, {
        method: body ? 'POST' : 'GET',
        headers: { 'X-Dashboard-Token': state.token || '', 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
        cache: 'no-store'
      });
    } catch (e) {
      throw new ApiError('Cannot reach the dashboard service. Is the dashboard console window still open?', 'network');
    }
    let data = null;
    try { data = await res.json(); } catch (e) { /* not JSON */ }
    if (res.status === 401) throw new ApiError((data && data.error) || 'Session expired.', 'auth');
    if (!res.ok) throw new ApiError((data && data.error) || ('HTTP ' + res.status), 'http');
    return data;
  }

  function fatal(err) {
    if (err.kind === 'auth') {
      state.fatal = true;
      banner('error', 'Your session key is no longer valid (the dashboard service was restarted). Re-open the dashboard with the address shown in its console window.');
      stopAuto();
      return true;
    }
    if (err.kind === 'network') { banner('error', err.message); return true; }
    return false;
  }

  function readToken() {
    const m = /[#&]t=([A-Za-z0-9]+)/.exec(location.hash);
    if (m) {
      try { sessionStorage.setItem(STORE + 'token', m[1]); } catch (e) { /* ignore */ }
      history.replaceState(null, '', location.pathname + location.search);
      return m[1];
    }
    try { return sessionStorage.getItem(STORE + 'token'); } catch (e) { return null; }
  }

  async function runPool(items, limit, worker) {
    const q = items.slice();
    const workers = [];
    for (let i = 0; i < Math.min(limit, q.length); i++) workers.push((async () => { while (q.length) await worker(q.shift()); })());
    await Promise.all(workers);
  }

  // ---------------------------------------------------------------------------
  // Data loading with an in-memory cache (per server + check)
  // ---------------------------------------------------------------------------
  const cacheKey = (server, check) => server + '|' + check;
  const cached = (check, server) => state.cache[cacheKey(server || state.server, check)];
  const isStale = entry => !entry || (Date.now() - entry.at) / 1000 > (state.cfg.ui.cacheSeconds || 120);

  function load(check, force, server) {
    server = server || state.server;
    const key = cacheKey(server, check);
    if (state.inflight[key]) return state.inflight[key];
    if (!force && !isStale(state.cache[key])) return Promise.resolve(state.cache[key]);
    const p = api('/api/run', { instanceId: server, checkId: check })
      .then(res => analyze(res))
      .catch(e => {
        if (fatal(e)) throw e;
        return analyze({ ok: false, error: e.message, durationMs: 0, resultSets: [], messages: [] });
      })
      .then(res => {
        const entry = { res: res, at: Date.now() };
        state.cache[key] = entry;
        delete state.inflight[key];
        if (res.ok) markReachable(server, res);
        else if (/network-related|could not open a connection|server was not found|timeout expired|login failed/i.test(res.error || '')) {
          state.inst[server] = Object.assign({}, state.inst[server], { state: 'offline', error: res.error });
          renderPicker();
        }
        if (check === 'summary' && server === state.server) { renderRail(); renderPicker(); }
        return entry;
      }, e => { delete state.inflight[key]; throw e; });
    state.inflight[key] = p;
    return p;
  }

  function markReachable(server, res) {
    const cur = state.inst[server] || {};
    if (cur.state !== 'online') {
      state.inst[server] = Object.assign({}, cur, { state: 'online', latencyMs: cur.latencyMs || res.durationMs, error: null });
      renderPicker();
    }
  }

  function analyze(res) {
    res.counts = { critical: 0, warning: 0, info: 0, ok: 0, rows: 0 };
    (res.resultSets || []).forEach(set => {
      set.statusIdx = set.columns.findIndex(c => /^status$/i.test(c.name));
      set.counts = { critical: 0, warning: 0, info: 0, ok: 0 };
      res.counts.rows += set.rows.length;
      if (set.statusIdx < 0) return;
      set.rows.forEach(r => { const s = normSev(r[set.statusIdx]); if (s) set.counts[s]++; });
      ['critical', 'warning', 'info', 'ok'].forEach(k => { res.counts[k] += set.counts[k]; });
    });
    return res;
  }

  function normSev(v) {
    const s = String(v === null || v === undefined ? '' : v).toLowerCase();
    if (s === 'ok') return 'ok';
    if (s === 'warning') return 'warning';
    if (s === 'critical' || s === 'error') return 'critical';
    if (s === 'info') return 'info';
    return null;
  }

  function asObjects(set) {
    if (!set) return [];
    return set.rows.map(r => { const o = {}; set.columns.forEach((c, i) => { o[c.name] = r[i]; }); return o; });
  }

  // ---------------------------------------------------------------------------
  // Chrome: banner, toasts, tooltip
  // ---------------------------------------------------------------------------
  function banner(kind, text) {
    const b = $('#banner');
    b.className = 'banner' + (kind === 'error' ? ' error' : '');
    b.textContent = '';
    b.appendChild(icon(kind === 'error' ? 'x-circle' : 'info'));
    b.appendChild(el('span', { text: text }));
    b.hidden = false;
  }

  function toast(kind, text) {
    const t = el('div', { class: 'toast ' + kind, role: 'status' }, [icon(kind === 'ok' ? 'check-circle' : kind === 'error' ? 'x-circle' : 'info'), el('div', { text: text })]);
    $('#toasts').appendChild(t);
    setTimeout(() => { t.classList.add('leaving'); setTimeout(() => t.remove(), 300); }, 3800);
  }


  // ---------------------------------------------------------------------------
  // Server picker
  // ---------------------------------------------------------------------------
  const instById = id => state.cfg.instances.find(i => i.id === id);
  const checkById = id => state.cfg.checks.find(c => c.id === id);
  const pageById = id => state.cfg.pages.find(p => p.id === id);

  function instSubtitle(inst) {
    const st = state.inst[inst.id] || {};
    const sum = cached('summary', inst.id);
    if (sum && sum.res.ok) {
      const s = asObjects(sum.res.resultSets[0])[0] || {};
      return versionName(s.ProductVersion) + ' · ' + shortEdition(s.Edition);
    }
    if (st.version) return st.version;
    if (st.state === 'offline') return 'Unreachable';
    return inst.server;
  }

  function renderPicker() {
    if (!state.cfg) return;
    const inst = state.server ? instById(state.server) : null;
    const st = inst ? (state.inst[inst.id] || {}) : {};
    $('#picker-name').textContent = inst ? inst.name : 'Select a server';
    $('#picker-dot').className = 'dot ' + (st.state || '');
    $('#picker-btn').title = inst ? inst.server : '';

    const list = $('#picker-list');
    if ($('#picker-pop').hidden) return;
    const q = $('#picker-filter').value.trim().toLowerCase();
    list.textContent = '';
    let group = null, shown = 0;
    state.cfg.instances.forEach(i => {
      if (q && [i.name, i.server, i.group, i.role].join(' ').toLowerCase().indexOf(q) < 0) return;
      if (i.group !== group) { list.appendChild(el('div', { class: 'pop-group', text: i.group })); group = i.group; }
      shown++;
      const s = state.inst[i.id] || {};
      list.appendChild(el('button', {
        class: 'opt', type: 'button', role: 'option', 'aria-selected': i.id === state.server ? 'true' : 'false',
        onclick: () => { closePicker(); selectServer(i.id); }
      }, [
        el('span', { class: 'dot ' + (s.state || '') }),
        el('span', { class: 'opt-main' }, [el('span', { class: 'opt-name', text: i.name }), el('span', { class: 'opt-sub', text: instSubtitle(i) })]),
        i.role ? el('span', { class: 'tag', text: i.role }) : null,
        el('span', { class: 'opt-side', text: s.state === 'online' && s.latencyMs ? fmtMs(s.latencyMs) : '' })
      ]));
    });
    if (!shown) list.appendChild(el('div', { class: 'pop-empty', text: 'No server matches.' }));
  }

  function openPicker() {
    $('#picker-pop').hidden = false;
    $('#picker-btn').setAttribute('aria-expanded', 'true');
    $('#picker-search-wrap').hidden = state.cfg.instances.length < 7;
    $('#picker-filter').value = '';
    renderPicker();
    if (!$('#picker-search-wrap').hidden) $('#picker-filter').focus();
  }
  function closePicker() {
    $('#picker-pop').hidden = true;
    $('#picker-btn').setAttribute('aria-expanded', 'false');
  }

  async function pingAll() {
    const ids = state.cfg.instances.map(i => i.id);
    ids.forEach(id => { if (!state.inst[id]) state.inst[id] = { state: 'checking' }; });
    renderPicker();
    try {
      await runPool(ids, state.cfg.ui.concurrency || 6, async id => {
        try {
          const r = await api('/api/run', { instanceId: id, checkId: '__ping' });
          if (r.ok) {
            const row = asObjects(r.resultSets[0])[0] || {};
            state.inst[id] = { state: 'online', latencyMs: r.durationMs, version: versionName(row.ProductVersion) + ' · ' + shortEdition(row.Edition) };
          } else {
            state.inst[id] = { state: 'offline', error: r.error };
          }
        } catch (e) {
          if (fatal(e)) throw e;
          state.inst[id] = { state: 'offline', error: e.message };
        }
        renderPicker();
      });
    } catch (e) { /* reported */ }
  }

  function selectServer(id) {
    if (!instById(id)) return;
    state.server = id;
    state.filter = '';
    store('server', id);
    renderPicker();
    renderRail();
    load('summary').then(() => { if (state.page === 'overview') renderPage(); }).catch(() => {});
    renderPage();
  }

  // ---------------------------------------------------------------------------
  // Rail (menu)
  // ---------------------------------------------------------------------------
  function badgeFor(page) {
    if (!page.badge || !state.server) return null;
    const sum = cached('summary');
    if (!sum || !sum.res.ok) return null;
    const s = asObjects(sum.res.resultSets[0])[0] || {};
    const n = s[page.badge];
    if (n === null || n === undefined) return null;
    const cls = { BackupsMissing7d: n ? 'crit' : '', FailedJobs24h: n ? 'crit' : '', RunningBackups: n ? 'live' : '', ActiveRequests: s.BlockedRequests ? 'warn' : n ? 'live' : '' }[page.badge] || '';
    if (!n && page.badge !== 'UserDatabases') return null;
    return el('span', { class: 'badge ' + cls, text: fmtInt(n) });
  }

  function renderRail() {
    const rail = $('#rail');
    rail.textContent = '';
    let group = null;
    state.cfg.pages.forEach(p => {
      if (p.group && p.group !== group) { rail.appendChild(el('div', { class: 'rail-group', text: p.group })); group = p.group; }
      rail.appendChild(el('a', {
        class: 'nav' + (p.id === state.page ? ' is-active' : ''), href: '#/' + p.id, title: p.title,
        'aria-current': p.id === state.page ? 'page' : null
      }, [icon(p.icon), el('span', { class: 'nav-label', text: p.title }), badgeFor(p)]));
    });
  }

  function go(pageId, filter) {
    state.pendingFilter = filter || '';
    if (('#/' + pageId) === location.hash) route();
    else location.hash = '#/' + pageId;
  }

  function route() {
    const id = (location.hash.match(/^#\/([\w-]+)/) || [])[1];
    state.page = pageById(id) ? id : (state.cfg.pages[0] && state.cfg.pages[0].id);
    state.filter = state.pendingFilter || '';   // a filter only survives navigation started by search
    state.pendingFilter = '';
    renderRail();
    renderPage();
    $('#main').scrollTop = 0;
    window.scrollTo(0, 0);
  }

  // ---------------------------------------------------------------------------
  // Pages
  // ---------------------------------------------------------------------------
  function renderPage() {
    const main = $('#main');
    if (!state.cfg) return;
    const page = pageById(state.page);
    main.textContent = '';
    if (!state.server) { main.appendChild(welcome()); return; }
    if (!page) return;
    if (page.view === 'overview') renderOverview(main, page);
    else renderTablePage(main, page);
  }

  function welcome() {
    return el('div', { class: 'card welcome fade-in' }, [
      el('div', { class: 'page-icon' }, icon('server')),
      el('h1', { text: 'Pick a SQL Server to begin' }),
      el('p', { text: 'Choose a server from the menu at the top. You will see its health at a glance, then dig into databases, backups, running queries and replication from the menu on the left.' }),
      el('div', { class: 'hero-chips', style: null }, [])
    ]);
  }

  function refreshButton(onClick, busy) {
    return el('button', { class: 'btn', type: 'button', disabled: busy, onclick: onClick },
      [icon('refresh', busy ? 'spin' : null), busy ? 'Refreshing' : 'Refresh']);
  }

  function errorCard(title, msg, retry) {
    return el('div', { class: 'card errorcard fade-in' }, [
      el('div', { class: 'empty-icon' }, icon('x-circle')),
      el('h3', { text: title }),
      el('pre', { text: msg || 'Unknown error' }),
      el('p', { class: 'sub', text: 'Check the server name and port, firewall rules, and that your account has the permissions listed in the README.' }),
      el('div', null, el('button', { class: 'btn primary', type: 'button', onclick: retry }, [icon('refresh'), 'Try again']))
    ]);
  }

  // ----- Overview --------------------------------------------------------------
  function renderOverview(main, page) {
    const key = cacheKey(state.server, 'summary');
    const entry = state.cache[key];
    const busy = !!state.inflight[key];
    const refresh = () => { load('summary', true).then(() => renderPage()).catch(() => {}); renderPage(); };

    if (!entry) {
      main.appendChild(skeletonOverview());
      if (!busy) load('summary').then(() => renderPage()).catch(() => {});
      return;
    }
    if (isStale(entry) && !busy) load('summary', true).then(() => renderPage()).catch(() => {});

    const res = entry.res;
    const inst = instById(state.server);
    if (!res.ok) { main.appendChild(errorCard('Could not reach ' + inst.name, res.error, refresh)); return; }

    const s = asObjects(res.resultSets[0])[0] || {};
    const disks = asObjects(res.resultSets[1]);
    const dbs = asObjects(res.resultSets[2]);
    const lat = (state.inst[state.server] || {}).latencyMs;

    const grid = el('div', { class: 'ov' });

    // Hero
    const chips = [
      el('span', { class: 'chip' }, [icon('layers'), versionName(s.ProductVersion) + ' ' + [s.ProductLevel, s.UpdateLevel].filter(Boolean).join(' ')]),
      el('span', { class: 'chip' }, [icon('shield'), shortEdition(s.Edition) + ' edition']),
      s.HostPlatform ? el('span', { class: 'chip' }, [icon('server'), s.HostPlatform]) : null,
      el('span', { class: 'chip' }, [icon('clock'), 'Up ' + fmtUptime(s.UptimeMinutes)]),
      s.IsHadrEnabled ? el('span', { class: 'chip' }, [icon('cluster'), 'Always On']) : null,
      s.IsClustered ? el('span', { class: 'chip' }, [icon('cluster'), 'Failover cluster']) : null
    ];
    grid.appendChild(el('section', { class: 'card hero span-12 fade-in' }, [
      el('div', { style: null }, [
        el('div', { class: 'hero-kicker' }, [el('span', { class: 'dot online' }), 'Online' + (lat ? ' · ' + fmtMs(lat) : '') + (inst.role ? ' · ' + inst.role : '') + (inst.group ? ' · ' + inst.group : '')]),
        el('h1', { text: inst.name }),
        el('div', { class: 'sub', text: (s.ServerName && s.ServerName !== inst.name ? s.ServerName + ' · ' : '') + inst.server + (s.InstanceName && s.InstanceName !== 'MSSQLSERVER' ? ' · instance ' + s.InstanceName : '') }),
        el('div', { class: 'hero-chips' }, chips)
      ]),
      el('div', { class: 'hero-side' }, [
        refreshButton(refresh, busy),
        el('div', { class: 'hero-meta' }, [el('span', { class: 'stamp', 'data-at': entry.at }, [icon('clock'), 'Updated ' + fmtAgo(entry.at)])])
      ])
    ]));

    // Key numbers - plain values, no charts
    const freeDisk = disks.reduce((a, d) => a + (d.FreeGB || 0), 0);
    const capped = s.MaxServerMemoryMB && s.MaxServerMemoryMB < UNCAPPED_MEMORY;
    const offline = (s.DatabaseCount || 0) - (s.OnlineDatabases || 0);
    const cpuSev = s.SqlCpuPct >= 90 ? 'critical' : s.SqlCpuPct >= 75 ? 'warning' : null;
    const lowDisk = disks.some(d => d.FreePct < 20);
    const has = v => v !== null && v !== undefined;

    grid.appendChild(statCard('cpu', 'CPU', cpuSev, has(s.SqlCpuPct) ? s.SqlCpuPct + '%' : '–', 'SQL Server CPU usage', [
      ['Logical CPUs', fmtInt(s.LogicalCpus)],
      ['MAXDOP', s.MaxDop === 0 ? '0 (unlimited)' : fmtInt(s.MaxDop)]
    ]));
    grid.appendChild(statCard('memory', 'Memory', capped ? null : 'warning', fmtSizeMB(s.PhysicalMemoryMB), 'Server RAM', [
      ['Max server memory', capped ? fmtSizeMB(s.MaxServerMemoryMB) : 'Not set'],
      ['Used by SQL Server', fmtSizeMB(s.TotalServerMemoryMB)]
    ]));
    grid.appendChild(statCard('database', 'Databases', offline ? 'warning' : null, fmtInt(s.DatabaseCount), 'Databases on this server', [
      ['User / system', fmtInt(s.UserDatabases) + ' / ' + fmtInt((s.DatabaseCount || 0) - (s.UserDatabases || 0))],
      ['Online', offline ? fmtInt(s.OnlineDatabases) + ' of ' + fmtInt(s.DatabaseCount) : 'All online']
    ]));
    grid.appendChild(statCard('disk', 'Storage', lowDisk ? 'warning' : null, fmtSizeMB((s.DataSizeMB || 0) + (s.LogSizeMB || 0)), 'Total size of all databases', [
      ['Data / log', fmtSizeMB(s.DataSizeMB) + ' / ' + fmtSizeMB(s.LogSizeMB)],
      ['Free disk space', disks.length ? fmtSizeGB(freeDisk) : '–']
    ]));

    // Attention tiles
    const tiles = el('div', { class: 'tiles span-12' });
    tiles.appendChild(tile(s.BackupsMissing7d ? 'critical' : 'ok', 'archive', s.BackupsMissing7d,
      s.BackupsMissing7d ? 'Missing full backups' : 'Full backups current',
      s.BackupsMissing7d ? 'No full backup in the last 7 days' : 'Every database backed up within 7 days', 'backup-missing'));
    tiles.appendChild(tile(s.RunningBackups ? 'info' : 'none', 'progress', s.RunningBackups,
      s.RunningBackups ? 'Backups running' : 'No backups running', s.RunningBackups ? 'See progress & ETA' : 'Recent backups and restores', 'running-backups'));
    tiles.appendChild(tile(s.BlockedRequests ? 'warning' : 'none', 'activity', s.ActiveRequests,
      'Active queries', s.BlockedRequests ? plural(s.BlockedRequests, 'blocked request') : fmtInt(s.UserSessions) + ' user sessions', 'queries'));
    tiles.appendChild(tile(s.FailedJobs24h ? 'critical' : 'ok', 'clock', s.FailedJobs24h,
      s.FailedJobs24h ? 'Failed Agent jobs' : 'No failed jobs', 'In the last 24 hours', 'jobs'));
    grid.appendChild(tiles);

    // Disks
    const diskCard = el('section', { class: 'card span-7 fade-in' }, [
      el('div', { class: 'card-head pad' }, [el('div', { class: 'card-title' }, [icon('disk'), 'Disks']), el('span', { class: 'sub', text: disks.length ? plural(disks.length, 'drive') + ' with database files' : '' })])
    ]);
    if (!disks.length) diskCard.appendChild(el('div', { class: 'sub pad', text: 'Disk information is not available (VIEW SERVER STATE required).' }));
    else diskCard.appendChild(miniTable(['Drive', 'Label', 'Total', 'Used', 'Free', 'Free %'], [false, false, true, true, true, true], disks.map((d, i) => {
      const sev = d.FreePct < 10 ? 'critical' : d.FreePct < 20 ? 'warning' : null;
      return [el('b', { text: d.Volume || ('Volume ' + (i + 1)) }), d.Label || '–', fmtSizeGB(d.TotalGB), fmtSizeGB(d.TotalGB - d.FreeGB), fmtSizeGB(d.FreeGB),
        sev ? pill(sev, d.FreePct + '%') : d.FreePct + '%'];
    })));
    grid.appendChild(diskCard);

    // Largest databases
    const top = dbs.slice(0, 8);
    const dbCard = el('section', { class: 'card span-5 fade-in' }, [
      el('div', { class: 'card-head pad' }, [el('div', { class: 'card-title' }, [icon('database'), 'Largest databases']),
        el('button', { class: 'link', type: 'button', onclick: () => go('databases') }, 'View all ' + dbs.length)])
    ]);
    const dbTable = miniTable(['Database', 'Data', 'Log', 'Total'], [false, true, true, true],
      top.map(d => [el('b', { text: d.DatabaseName }), fmtSizeMB(d.DataMB), fmtSizeMB(d.LogMB), fmtSizeMB((d.DataMB || 0) + (d.LogMB || 0))]));
    $$('tbody tr', dbTable).forEach((tr, i) => {
      tr.classList.add('clickable');
      tr.title = 'Show ' + top[i].DatabaseName + ' in Databases';
      tr.addEventListener('click', () => go('databases', top[i].DatabaseName));
    });
    dbCard.appendChild(dbTable);
    grid.appendChild(dbCard);

    // Details
    const kv = [
      ['Product version', s.ProductVersion], ['Level / update', [s.ProductLevel, s.UpdateLevel].filter(Boolean).join(' / ')],
      ['Edition', s.Edition], ['Host OS', s.HostPlatform], ['Machine', s.MachineName], ['Instance', s.InstanceName],
      ['Collation', s.Collation], ['Started', s.StartTime], ['Server time', s.ServerTime],
      ['Cost threshold', s.CostThreshold], ['Page life expectancy', has(s.PageLifeExpectancy) ? fmtInt(s.PageLifeExpectancy) + ' s' : null], ['User sessions', s.UserSessions]
    ];
    grid.appendChild(el('section', { class: 'card card-pad span-12 fade-in' }, [
      el('div', { class: 'card-head' }, [el('div', { class: 'card-title' }, [icon('info'), 'Server details'])]),
      el('dl', { class: 'kv' }, kv.map(p => el('div', null, [el('dt', { text: p[0] }), el('dd', { text: p[1] === null || p[1] === undefined || p[1] === '' ? '–' : String(p[1]), title: p[1] === null || p[1] === undefined ? null : String(p[1]) })])))
    ]));

    if (res.messages && res.messages.length) {
      grid.appendChild(el('div', { class: 'messages span-12' }, [icon('message'), el('div', { text: res.messages.join(' ') })]));
    }
    main.appendChild(grid);
  }

  function statCard(iconName, label, sev, value, caption, rows) {
    return el('section', { class: 'card stat-card span-3 fade-in' }, [
      el('div', { class: 'stat-top' }, [el('span', { class: 'stat-label' }, [icon(iconName), label]), sev ? pill(sev) : null]),
      el('div', { class: 'stat-value', text: value }),
      el('div', { class: 'sub', text: caption }),
      el('dl', { class: 'stat-rows' }, rows.map(r => el('div', null, [el('dt', { text: r[0] }), el('dd', { text: r[1] })])))
    ]);
  }

  function miniTable(headers, numeric, rows) {
    return el('div', { class: 'mini-wrap' }, el('table', { class: 'grid mini' }, [
      el('thead', null, el('tr', null, headers.map((h, i) => el('th', { class: numeric[i] ? 'num' : null, text: h })))),
      el('tbody', null, rows.map(r => el('tr', null, r.map((c, i) => el('td', { class: numeric[i] ? 'num' : null }, c)))))
    ]));
  }

  function tile(sev, iconName, n, label, sub, pageId) {
    return el('button', { class: 'tile ' + sev + ' fade-in', type: 'button', onclick: () => go(pageId) }, [
      el('span', { class: 'tile-icon' }, icon(sev === 'ok' ? 'check-circle' : iconName)),
      el('span', { class: 'tile-text' }, [
        el('span', { class: 'tile-num', text: n === null || n === undefined ? '–' : fmtInt(n) }),
        el('span', { class: 'tile-label', text: label }),
        el('span', { class: 'tile-sub', text: sub })
      ]),
      icon('arrow', 'tile-go')
    ]);
  }

  function skeletonOverview() {
    const g = el('div', { class: 'ov' });
    const sk = (cls, h) => { const n = el('div', { class: 'sk ' + cls }); n.style.height = h + 'px'; return n; };
    g.appendChild(sk('span-12', 170));
    for (let i = 0; i < 4; i++) g.appendChild(sk('span-3', 190));
    g.appendChild(sk('span-12', 80));
    g.appendChild(sk('span-7', 240));
    g.appendChild(sk('span-5', 240));
    return g;
  }

  // ----- Table pages -------------------------------------------------------------
  function renderTablePage(main, page) {
    const entries = page.checks.map(id => state.cache[cacheKey(state.server, id)]);
    const busy = page.checks.some(id => state.inflight[cacheKey(state.server, id)]);
    const doRefresh = force => {
      Promise.all(page.checks.map(id => load(id, force))).then(() => { if (state.page === page.id) renderPage(); }).catch(() => {});
    };
    if (entries.some(e => !e) || entries.some(isStale)) { if (!busy) { doRefresh(false); return renderTablePage(main, page); } }

    const at = entries.filter(Boolean).reduce((a, e) => Math.min(a, e.at), Infinity);
    main.appendChild(el('div', { class: 'page-head fade-in' }, [
      el('div', { class: 'page-title' }, [
        el('div', { class: 'page-icon' }, icon(page.icon)),
        el('div', null, [el('h1', { text: page.title }), el('p', { text: page.description })])
      ]),
      el('div', { class: 'page-tools' }, [
        at !== Infinity ? el('span', { class: 'stamp', 'data-at': at }, [icon('clock'), 'Updated ' + fmtAgo(at)]) : null,
        segmented(),
        refreshButton(() => { doRefresh(true); renderPage(); }, busy)
      ])
    ]));

    if (state.filter) {
      main.appendChild(el('div', { class: 'filter-chip' }, ['Filtered by “' + state.filter + '”',
        el('button', { type: 'button', 'aria-label': 'Clear filter', onclick: () => { state.filter = ''; $('#search-input').value = ''; renderPage(); } }, icon('x'))]));
    }

    if (entries.some(e => !e)) {
      const sk = el('div', { class: 'card panel fade-in' });
      sk.style.padding = '18px';
      for (let i = 0; i < 6; i++) { const r = el('div', { class: 'sk' }); r.style.height = '34px'; r.style.marginBottom = '10px'; sk.appendChild(r); }
      main.appendChild(sk);
      return;
    }

    // Summary stats
    let crit = 0, warn = 0, ok = 0, rows = 0, hasStatus = false;
    entries.forEach(e => { if (!e.res.ok) return; crit += e.res.counts.critical; warn += e.res.counts.warning; ok += e.res.counts.ok; rows += e.res.counts.rows; hasStatus = hasStatus || e.res.resultSets.some(s => s.statusIdx >= 0); });
    const stats = el('div', { class: 'summary-row fade-in' });
    if (hasStatus) {
      stats.appendChild(stat('critical', 'x-circle', crit, 'Critical'));
      stats.appendChild(stat('warning', 'alert', warn, 'Warnings'));
      stats.appendChild(stat('ok', 'check-circle', ok, 'Healthy'));
    }
    stats.appendChild(stat('rows', 'rows', rows, plural(rows, 'row').replace(/^\d+ /, '')));
    main.appendChild(stats);

    page.checks.forEach(id => {
      const e = state.cache[cacheKey(state.server, id)];
      const check = checkById(id);
      if (!e.res.ok) {
        main.appendChild(errorCard(check.title + ' could not run', e.res.error, () => { load(id, true).then(() => renderPage()); renderPage(); }));
        return;
      }
      if (e.res.messages && e.res.messages.length) {
        main.appendChild(el('div', { class: 'messages fade-in' }, [icon('message'), e.res.messages.length === 1 ? el('div', { text: e.res.messages[0] }) : el('ul', null, e.res.messages.map(m => el('li', { text: m })))]));
        main.lastChild.style.margin = '0 0 16px';
      }
      e.res.resultSets.forEach((set, i) => main.appendChild(panel(check, set, i)));
    });
  }

  function stat(cls, iconName, n, label) {
    return el('div', { class: 'stat ' + cls }, [el('span', { class: 'ico' }, icon(iconName)), el('span', { class: 'stat-n', text: fmtInt(n) }), el('span', { class: 'stat-l', text: label })]);
  }

  function segmented() {
    const mk = (v, t) => el('button', { type: 'button', class: state.view === v ? 'is-active' : '', 'aria-pressed': state.view === v ? 'true' : 'false',
      onclick: () => { state.view = v; renderPage(); } }, t);
    return el('div', { class: 'segmented', role: 'group', 'aria-label': 'Rows to show' }, [mk('all', 'All rows'), mk('issues', 'Issues only')]);
  }

  function panel(check, set, idx) {
    const key = state.server + '|' + check.id + '|' + idx;
    const ui = state.tables[key] || (state.tables[key] = { q: '', sort: -1, dir: 1 });
    const title = (check.resultTitles && check.resultTitles[idx]) || ('Result ' + (idx + 1));
    const wrap = el('div', { class: 'twrap' });

    const head = el('div', { class: 'panel-head' }, [
      el('div', { class: 'panel-title' }, [title,
        el('span', { class: 'badge', text: fmtInt(set.rows.length) }),
        set.counts.critical ? pill('critical', set.counts.critical + ' critical') : null,
        set.counts.warning ? pill('warning', set.counts.warning + ' warning') : null])
    ]);
    if (set.rows.length) {
      const input = el('input', { type: 'search', placeholder: 'Filter', 'aria-label': 'Filter ' + title, value: ui.q });
      input.addEventListener('input', () => { ui.q = input.value; drawTable(wrap, set, ui); });
      head.appendChild(el('div', { class: 'panel-tools' }, [
        el('label', { class: 'tfilter' }, [icon('search'), input]),
        el('button', { class: 'icon-btn sm', type: 'button', title: 'Copy (paste into Excel or e-mail)', 'aria-label': 'Copy ' + title, onclick: () => copySet(set) }, icon('copy')),
        el('button', { class: 'icon-btn sm', type: 'button', title: 'Download CSV', 'aria-label': 'Download ' + title, onclick: () => downloadCsv(set, check, title) }, icon('download'))
      ]));
    }

    const card = el('section', { class: 'card panel fade-in' }, [head]);
    if (!set.rows.length) {
      const msg = (check.emptyMessages && check.emptyMessages[idx]) || 'Nothing to report here.';
      card.appendChild(el('div', { class: 'empty' }, [el('div', { class: 'empty-icon' }, icon('check-circle')), el('h4', { text: 'All clear' }), el('p', { text: msg })]));
    } else {
      card.appendChild(wrap);
      drawTable(wrap, set, ui);
    }
    if (set.truncated) card.appendChild(el('div', { class: 'tnote', text: 'Only the first ' + set.rows.length + ' rows were returned (maxRowsPerResultSet).' }));
    return card;
  }

  function drawTable(wrap, set, ui) {
    const cols = set.columns;
    let rows = set.rows;
    let hidden = 0;
    if (state.view === 'issues' && set.statusIdx >= 0) {
      const n = rows.length;
      rows = rows.filter(r => { const s = normSev(r[set.statusIdx]); return s === 'warning' || s === 'critical'; });
      hidden = n - rows.length;
    }
    const terms = [state.filter, ui.q].map(t => (t || '').trim().toLowerCase()).filter(Boolean);
    terms.forEach(q => { rows = rows.filter(r => r.some(v => v !== null && String(v).toLowerCase().indexOf(q) >= 0)); });
    if (ui.sort >= 0) {
      const i = ui.sort, dir = ui.dir, isStatus = i === set.statusIdx;
      rows = rows.slice().sort((a, b) => {
        let x = a[i], y = b[i];
        if (x === null || x === undefined) return 1;
        if (y === null || y === undefined) return -1;
        if (isStatus) { x = SEV[normSev(x)] || 0; y = SEV[normSev(y)] || 0; }
        if (typeof x === 'number' && typeof y === 'number') return (x - y) * dir;
        return String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: 'base' }) * dir;
      });
    }

    wrap.textContent = '';
    if (!rows.length) {
      wrap.appendChild(el('div', { class: 'empty' }, [el('div', { class: 'empty-icon' }, icon(hidden ? 'check-circle' : 'search')),
        el('h4', { text: hidden ? 'No issues' : 'No matches' }),
        el('p', { text: hidden ? plural(hidden, 'healthy row') + ' hidden.' : 'No rows match the filter.' })]));
      return;
    }

    const numeric = cols.map(c => NUMERIC.test(c.type));
    const thead = el('tr', null, cols.map((c, i) => {
      const sorted = ui.sort === i;
      return el('th', {
        class: (numeric[i] ? 'num' : '') + (sorted ? ' sorted' : ''), scope: 'col', title: 'Sort by ' + c.name,
        'aria-sort': sorted ? (ui.dir > 0 ? 'ascending' : 'descending') : 'none',
        onclick: () => { if (ui.sort === i) ui.dir = -ui.dir; else { ui.sort = i; ui.dir = i === set.statusIdx || numeric[i] ? -1 : 1; } drawTable(wrap, set, ui); }
      }, [i === set.statusIdx ? 'Status' : humanize(c.name), el('span', { class: 's', text: sorted ? (ui.dir > 0 ? '▲' : '▼') : '↕' })]);
    }));
    const firstText = cols.findIndex((c, i) => i !== set.statusIdx && !numeric[i]);
    const tbody = el('tbody');
    rows.slice(0, MAX_ROWS).forEach(r => {
      const sev = set.statusIdx >= 0 ? normSev(r[set.statusIdx]) : null;
      tbody.appendChild(el('tr', { class: sev === 'critical' || sev === 'warning' ? 'row-' + sev : null },
        r.map((v, i) => cell(v, cols[i], numeric[i], i === set.statusIdx, i === firstText))));
    });
    wrap.appendChild(el('table', { class: 'grid' }, [el('thead', null, thead), tbody]));
    if (rows.length > MAX_ROWS) wrap.appendChild(el('div', { class: 'tnote', text: 'Showing ' + MAX_ROWS + ' of ' + rows.length + ' rows - filter or download the CSV for everything.' }));
  }

  // Percent columns: [warn, crit, higherIsBad] thresholds colour the value
  const PCT_COLUMNS = { LogUsedPct: [75, 90, true], FreePct: [20, 10, false], PercentComplete: null, WaitPct: null, SignalPct: null };

  function cell(v, col, isNum, isStatus, isFirst) {
    if (isStatus) {
      const s = normSev(v);
      return el('td', null, s ? pill(s) : String(v === null ? '' : v));
    }
    if (v === null || v === undefined) return el('td', { class: 'null', text: '—' });
    if (typeof v === 'boolean') return el('td', null, el('span', { class: v ? 'yes' : 'no', text: v ? 'Yes' : 'No' }));
    if (typeof v === 'number' && Object.prototype.hasOwnProperty.call(PCT_COLUMNS, col.name)) {
      const t = PCT_COLUMNS[col.name];
      let sev = null;
      if (t) sev = t[2] ? (v >= t[1] ? 'critical' : v >= t[0] ? 'warning' : null) : (v < t[1] ? 'critical' : v < t[0] ? 'warning' : null);
      return el('td', { class: 'num' }, sev ? pill(sev, v.toFixed(1) + '%') : v.toFixed(1) + '%');
    }
    if (typeof v === 'number' && isNum) {
      return el('td', { class: 'num', text: Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumFractionDigits: 2 }) });
    }
    const s = String(v);
    const isCode = /sql|statement/i.test(col.name);
    if (s.length > 90 || s.indexOf('\n') >= 0 || isCode) {
      const td = el('td', { class: 'clamp' + (isCode ? ' code' : ''), title: s.length > 600 ? null : s }, el('div', { text: s }));
      td.addEventListener('click', () => td.classList.toggle('open'));
      return td;
    }
    return el('td', { class: isFirst ? 'strong' : null, text: s });
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------
  const cellText = v => v === null || v === undefined ? '' : String(v);

  function downloadCsv(set, check, title) {
    const esc = v => { const s = cellText(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const lines = [set.columns.map(c => esc(c.name)).join(',')].concat(set.rows.map(r => r.map(esc).join(',')));
    const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
    const name = [instById(state.server).name, check.id, title, stamp].join('_').replace(/[^A-Za-z0-9._-]+/g, '-') + '.csv';
    const a = el('a', { href: URL.createObjectURL(blob), download: name });
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
    toast('ok', 'Downloaded ' + name);
  }

  function copySet(set) {
    const tsv = [set.columns.map(c => c.name).join('\t')]
      .concat(set.rows.map(r => r.map(v => cellText(v).replace(/[\t\r\n]+/g, ' ')).join('\t'))).join('\r\n');
    const done = () => toast('ok', 'Copied ' + plural(set.rows.length, 'row') + ' to the clipboard.');
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(tsv).then(done, () => fallbackCopy(tsv, done));
    else fallbackCopy(tsv, done);
  }

  function fallbackCopy(text, done) {
    const ta = el('textarea', { 'aria-hidden': 'true' });
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); done(); } catch (e) { toast('error', 'Copy failed.'); }
    ta.remove();
  }

  // ---------------------------------------------------------------------------
  // Global search: databases, pages, servers
  // ---------------------------------------------------------------------------
  let searchItems = [];
  let searchIdx = -1;

  function highlight(text, q) {
    const i = text.toLowerCase().indexOf(q);
    if (!q || i < 0) return [text];
    return [text.slice(0, i), el('mark', { text: text.slice(i, i + q.length) }), text.slice(i + q.length)];
  }

  function renderSearch() {
    const input = $('#search-input');
    const pop = $('#search-pop');
    const q = input.value.trim().toLowerCase();
    searchItems = [];
    pop.textContent = '';
    if (!q) { pop.hidden = true; return; }

    const groups = [];
    const sum = state.server ? cached('summary') : null;
    if (sum && sum.res.ok) {
      const dbs = asObjects(sum.res.resultSets[2]).filter(d => d.DatabaseName.toLowerCase().indexOf(q) >= 0).slice(0, 6);
      if (dbs.length) groups.push(['Databases on ' + instById(state.server).name, dbs.map(d => ({
        icon: 'database', name: d.DatabaseName, sub: fmtSizeMB((d.DataMB || 0) + (d.LogMB || 0)) + ' · ' + d.State + ' · ' + d.RecoveryModel,
        run: () => go('databases', d.DatabaseName)
      }))]);
    }
    const pages = state.cfg.pages.filter(p => (p.title + ' ' + p.description).toLowerCase().indexOf(q) >= 0).slice(0, 5);
    if (pages.length) groups.push(['Pages', pages.map(p => ({ icon: p.icon, name: p.title, sub: p.description, run: () => go(p.id) }))]);
    const servers = state.cfg.instances.filter(i => [i.name, i.server, i.role, i.group].join(' ').toLowerCase().indexOf(q) >= 0).slice(0, 5);
    if (servers.length) groups.push(['Servers', servers.map(i => ({ icon: 'server', name: i.name, sub: instSubtitle(i), run: () => selectServer(i.id) }))]);
    if (state.server && pageById(state.page).view !== 'overview') {
      groups.push(['Filter', [{ icon: 'search', name: 'Filter “' + input.value.trim() + '” on this page', sub: 'Show only rows containing this text', run: () => { state.filter = input.value.trim(); renderPage(); } }]]);
    }

    groups.forEach(g => {
      pop.appendChild(el('div', { class: 'pop-group', text: g[0] }));
      g[1].forEach(item => {
        const idx = searchItems.length;
        searchItems.push(item);
        pop.appendChild(el('button', {
          class: 'opt' + (idx === searchIdx ? ' is-active' : ''), type: 'button', role: 'option',
          onmousedown: e => { e.preventDefault(); chooseSearch(idx); }
        }, [el('span', { class: 'opt-icon' }, icon(item.icon)),
          el('span', { class: 'opt-main' }, [el('span', { class: 'opt-name' }, highlight(item.name, q)), el('span', { class: 'opt-sub', text: item.sub })])]));
      });
    });
    if (!searchItems.length) pop.appendChild(el('div', { class: 'pop-empty', text: 'Nothing matches “' + input.value.trim() + '”.' }));
    pop.hidden = false;
  }

  function chooseSearch(idx) {
    const item = searchItems[idx];
    if (!item) return;
    const input = $('#search-input');
    $('#search-pop').hidden = true;
    input.value = '';
    input.blur();
    item.run();
  }

  // ---------------------------------------------------------------------------
  // Auto refresh & "updated x ago" ticker
  // ---------------------------------------------------------------------------
  function stopAuto() { if (state.autoTimer) clearInterval(state.autoTimer); state.autoTimer = null; }

  function setAuto(min) {
    stopAuto();
    store('auto', String(min));
    if (min > 0) {
      state.autoTimer = setInterval(() => {
        if (state.fatal || !state.server) return;
        const page = pageById(state.page);
        const ids = page.checks.indexOf('summary') < 0 ? page.checks.concat('summary') : page.checks;
        Promise.all(ids.map(id => load(id, true))).then(() => renderPage()).catch(() => {});
      }, min * 60000);
    }
  }

  function tick() {
    $$('.stamp[data-at]').forEach(n => {
      const t = n.lastChild;
      if (t && t.nodeType === 3) t.textContent = 'Updated ' + fmtAgo(Number(n.getAttribute('data-at')));
    });
  }

  // ---------------------------------------------------------------------------
  // Start-up
  // ---------------------------------------------------------------------------
  function bind() {
    $('#picker-btn').addEventListener('click', e => { e.stopPropagation(); if ($('#picker-pop').hidden) openPicker(); else closePicker(); });
    $('#picker-filter').addEventListener('input', renderPicker);
    $('#picker-pop').addEventListener('click', e => e.stopPropagation());
    document.addEventListener('click', () => closePicker());

    const input = $('#search-input');
    input.addEventListener('input', () => { searchIdx = 0; renderSearch(); });
    input.addEventListener('focus', () => { if (input.value) renderSearch(); });
    input.addEventListener('blur', () => setTimeout(() => { $('#search-pop').hidden = true; }, 120));
    input.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        if (!searchItems.length) return;
        searchIdx = (searchIdx + (e.key === 'ArrowDown' ? 1 : -1) + searchItems.length) % searchItems.length;
        renderSearch();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        chooseSearch(Math.max(0, searchIdx));
      } else if (e.key === 'Escape') {
        input.value = ''; renderSearch(); input.blur();
      }
    });
    document.addEventListener('keydown', e => {
      const tag = (document.activeElement && document.activeElement.tagName) || '';
      if ((e.key === '/' || (e.key === 'k' && (e.ctrlKey || e.metaKey))) && !/INPUT|TEXTAREA|SELECT/.test(tag)) { e.preventDefault(); input.focus(); }
      if (e.key === 'Escape') closePicker();
    });

    $('#auto-refresh').addEventListener('change', e => setAuto(Number(e.target.value)));
    window.addEventListener('hashchange', route);
  }

  async function init() {
    hydrate(document);
    bind();

    const demo = location.protocol === 'file:' || /(^|[#&?])demo\b/.test(location.hash + location.search);
    state.token = demo ? null : readToken();
    state.demo = demo && !!window.SqlDashDemo;
    if (!state.demo && !state.token) {
      state.fatal = true;
      banner('error', 'No session key found. Open the dashboard with the full address printed in the dashboard console window (it ends with #t=…).');
      return;
    }
    try {
      state.cfg = await api('/api/config');
    } catch (e) {
      if (!fatal(e)) banner('error', 'Could not load the configuration: ' + e.message);
      return;
    }
    const cfg = state.cfg;
    cfg.ui = cfg.ui || {};
    cfg.pages = cfg.pages || [];
    if (state.demo) {
      banner('info', 'Demo mode - sample data only, no SQL Server connections are made. Start the dashboard with Start-Dashboard.cmd for live data.');
      if (/demo/.test(location.hash)) history.replaceState(null, '', location.pathname + location.search);
    }

    $('#app-title').textContent = cfg.title;
    document.title = cfg.title;
    if (cfg.environment) {
      const b = $('#env-badge');
      b.textContent = cfg.environment;
      b.classList.toggle('nonprod', !/prod/i.test(cfg.environment));
      b.hidden = false;
    }

    const saved = store('server');
    state.server = instById(saved) ? saved : (cfg.instances[0] && cfg.instances[0].id);
    const auto = Number(store('auto') || cfg.ui.defaultAutoRefresh || 0);
    $('#auto-refresh').value = String([0, 1, 5, 15].indexOf(auto) >= 0 ? auto : 0);
    setAuto(Number($('#auto-refresh').value));

    route();
    if (state.server) load('summary').then(() => renderPage()).catch(() => {});
    if (cfg.ui.pingOnLoad !== false) pingAll();
    state.tickTimer = setInterval(tick, 15000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
