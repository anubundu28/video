/* =========================================================================
   SQL Server Health Dashboard - front end
   Plain JavaScript, no frameworks, no network access beyond the local
   dashboard service. All data is rendered with textContent (never as HTML).
   ========================================================================= */
(function () {
  'use strict';
  if (window.__unsupportedBrowser) return;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  const SEV = { none: 0, info: 1, ok: 2, warning: 3, critical: 4, error: 5 };
  const SEV_LABEL = { none: 'Done', info: 'Info', ok: 'Healthy', warning: 'Warning', critical: 'Critical', error: 'Failed', running: 'Running', queued: 'Queued' };
  const SEV_ICON = { none: 'check-circle', info: 'info', ok: 'check-circle', warning: 'alert', critical: 'x-circle', error: 'x-circle', queued: 'clock' };
  const NUMERIC_TYPES = /^(int|bigint|smallint|tinyint|decimal|numeric|float|real|money|smallmoney)$/i;
  const SQL_VERSIONS = { 17: '2025', 16: '2022', 15: '2019', 14: '2017', 13: '2016', 12: '2014', 11: '2012', 10: '2008' };
  const STORE = 'sqldash.';

  const ICONS = {
    server: '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01"/>',
    database: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    replication: '<path d="M17 2l4 4-4 4"/><path d="M3 11V9a3 3 0 0 1 3-3h15"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v2a3 3 0 0 1-3 3H3"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9"/><path d="M10 13h4"/>',
    disk: '<path d="M22 12H2"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M6 16h.01M10 16h.01"/>',
    lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    activity: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
    pulse: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
    file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M8 13h8M8 17h5"/>',
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
    trash: '<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
    x: '<path d="M18 6L6 18M6 6l12 12"/>',
    plug: '<path d="M9 2v6M15 2v6M6 8h12v4a6 6 0 0 1-12 0z"/><path d="M12 18v4"/>',
    message: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>'
  };
  const LOGO = '<svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#3d5afe"/><ellipse cx="16" cy="9.5" rx="8" ry="3" fill="none" stroke="#fff" stroke-width="2"/><path d="M8 9.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13" fill="none" stroke="#fff" stroke-width="2"/><path d="M11 18h3l1.5-3 2 6 1.5-3h2" fill="none" stroke="#7cf0b4" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

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
    selected: new Set(),
    inst: {},              // instanceId -> { state, latencyMs, version, error }
    runs: [],              // newest first
    running: new Set(),    // checkIds currently running
    view: 'all',
    autoTimer: null,
    lastRunAt: null,
    lastRunLabel: '',
    fatal: false
  };

  // ---------------------------------------------------------------------------
  // DOM helpers
  // ---------------------------------------------------------------------------
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.prototype.slice.call((root || document).querySelectorAll(sel));

  function el(tag, props, children) {
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
    if (children !== undefined && children !== null) {
      [].concat(children).forEach(c => {
        if (c === null || c === undefined || c === false) return;
        e.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
      });
    }
    return e;
  }
  const icon = (name, cls) => el('span', { icon: name, class: cls });

  function hydrateIcons(root) {
    $$('[data-icon]', root).forEach(n => { if (!n.firstChild) n.innerHTML = svg(n.getAttribute('data-icon')); });
  }

  function pill(sev, text, big) {
    const cls = 'pill pill-' + sev + (big ? ' pill-lg' : '');
    if (sev === 'running') return el('span', { class: cls }, [el('span', { class: 'spinner' }), text || SEV_LABEL.running]);
    return el('span', { class: cls }, [icon(SEV_ICON[sev] || 'info'), text || SEV_LABEL[sev] || sev]);
  }

  function store(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(STORE + key);
      localStorage.setItem(STORE + key, value);
    } catch (e) { /* storage may be unavailable */ }
    return null;
  }

  function fmtTime(d) { return d ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '–'; }
  function fmtMs(ms) { return ms >= 1000 ? (ms / 1000).toFixed(1) + ' s' : Math.round(ms) + ' ms'; }
  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }

  function humanize(name) {
    return String(name)
      .replace(/_/g, ' ')
      .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
      .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
      .replace(/\bPct\b/g, '%')
      .replace(/\bSec\b/g, '(s)')
      .replace(/\bMin\b/g, '(min)')
      .replace(/\bMs\b/g, '(ms)')
      .replace(/\b(KB|MB|GB)\b/g, '($1)')
      .trim();
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
        cache: 'no-store',
        credentials: 'same-origin'
      });
    } catch (e) {
      throw new ApiError('Cannot reach the dashboard service. Is the dashboard console window still open?', 'network');
    }
    let data = null;
    try { data = await res.json(); } catch (e) { /* non-JSON */ }
    if (res.status === 401) throw new ApiError((data && data.error) || 'Session expired.', 'auth');
    if (!res.ok) throw new ApiError((data && data.error) || ('HTTP ' + res.status), 'http');
    return data;
  }

  function handleFatal(err) {
    if (err.kind === 'auth') {
      state.fatal = true;
      showBanner('error', 'Your session key is no longer valid (the dashboard service was probably restarted). Re-open the dashboard using the address shown in the console window.');
      setFooter('offline', 'Session expired');
      stopAutoRefresh();
      return true;
    }
    if (err.kind === 'network') {
      showBanner('error', err.message);
      setFooter('offline', 'Service unreachable');
      return true;
    }
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
    const queue = items.slice();
    const workers = [];
    for (let i = 0; i < Math.min(limit, queue.length); i++) {
      workers.push((async () => { while (queue.length) await worker(queue.shift()); })());
    }
    await Promise.all(workers);
  }

  // ---------------------------------------------------------------------------
  // Chrome: banner, footer, toasts, theme
  // ---------------------------------------------------------------------------
  function showBanner(kind, text) {
    const b = $('#banner');
    b.className = 'banner' + (kind === 'error' ? ' banner-error' : '');
    b.textContent = '';
    b.appendChild(icon(kind === 'error' ? 'x-circle' : 'info'));
    b.appendChild(el('span', { text: text }));
    b.hidden = false;
  }

  function setFooter(kind, text) {
    const f = $('#footer-status');
    f.textContent = '';
    f.appendChild(el('span', { class: 'dot dot-' + (kind === 'online' ? 'online' : kind === 'offline' ? 'offline' : 'unknown') }));
    f.appendChild(document.createTextNode(text));
  }

  function refreshFooter() {
    if (state.fatal) return;
    const auto = Number($('#auto-refresh').value);
    let text = state.demo ? 'Demo mode · sample data' : 'Connected to local dashboard service';
    if (auto) text += ' · auto-refresh every ' + plural(auto, 'minute');
    setFooter(state.demo ? 'unknown' : 'online', text);
  }

  function toast(kind, text, ms) {
    const iconName = { ok: 'check-circle', warning: 'alert', error: 'x-circle', info: 'info' }[kind] || 'info';
    const t = el('div', { class: 'toast toast-' + kind, role: 'status' }, [icon(iconName), el('div', { text: text })]);
    $('#toasts').appendChild(t);
    setTimeout(() => { t.classList.add('leaving'); setTimeout(() => t.remove(), 300); }, ms || 4500);
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    store('theme', theme);
  }

  // ---------------------------------------------------------------------------
  // Instances (sidebar)
  // ---------------------------------------------------------------------------
  function instanceById(id) { return state.cfg.instances.find(i => i.id === id); }
  function checkById(id) { return state.cfg.checks.find(c => c.id === id); }
  function orderedSelection() { return state.cfg.instances.filter(i => state.selected.has(i.id)).map(i => i.id); }

  function renderInstances() {
    const list = $('#instance-list');
    const q = $('#instance-filter').value.trim().toLowerCase();
    list.textContent = '';
    let lastGroup = null;
    let shown = 0;
    state.cfg.instances.forEach(inst => {
      const hay = [inst.name, inst.server, inst.group, inst.role, inst.description].join(' ').toLowerCase();
      if (q && hay.indexOf(q) < 0) return;
      shown++;
      if (inst.group !== lastGroup) {
        list.appendChild(el('div', { class: 'group-label', text: inst.group }));
        lastGroup = inst.group;
      }
      const st = state.inst[inst.id] || { state: 'unknown' };
      const meta = st.version ? st.version : (st.state === 'offline' ? 'Unreachable' : inst.server);
      const tip = [inst.server, inst.description, st.error].filter(Boolean).join('\n');
      list.appendChild(el('button', {
        class: 'instance', type: 'button', title: tip,
        'aria-pressed': state.selected.has(inst.id) ? 'true' : 'false',
        onclick: () => toggleInstance(inst.id)
      }, [
        el('span', { class: 'check' }, icon('check')),
        el('span', { class: 'instance-main' }, [
          el('span', { class: 'instance-name', text: inst.name }),
          el('span', { class: 'instance-meta', text: meta })
        ]),
        el('span', { class: 'instance-side' }, [
          inst.role ? el('span', { class: 'role-tag', text: inst.role }) : null,
          el('span', { class: 'latency' }, [
            el('span', { class: 'dot dot-' + st.state, title: st.state }), ' ',
            st.state === 'online' ? fmtMs(st.latencyMs) : st.state === 'offline' ? 'down' : st.state === 'checking' ? '…' : ''
          ])
        ])
      ]));
    });
    if (!shown) list.appendChild(el('div', { class: 'rs-empty', text: 'No instances match the filter.' }));
    updateTargets();
  }

  function toggleInstance(id) {
    if (state.selected.has(id)) state.selected.delete(id); else state.selected.add(id);
    saveSelection();
    renderInstances();
  }

  function saveSelection() { store('selected', JSON.stringify(Array.from(state.selected))); }

  function updateTargets() {
    const n = state.selected.size;
    const total = state.cfg.instances.length;
    const names = orderedSelection().map(id => instanceById(id).name);
    $('#target-summary').textContent = n === 0
      ? 'Select one or more instances to check.'
      : 'Target: ' + (n === total ? 'all ' + plural(total, 'instance') : names.slice(0, 3).join(', ') + (n > 3 ? ' and ' + (n - 3) + ' more' : '')) + '.';
    $('#sidebar-toggle-label').textContent = 'Instances · ' + n + ' of ' + total + ' selected';
  }

  async function pingAll() {
    const ids = state.cfg.instances.map(i => i.id);
    const btn = $('#ping-all');
    btn.disabled = true;
    ids.forEach(id => { state.inst[id] = Object.assign({}, state.inst[id], { state: 'checking' }); });
    renderInstances();
    try {
      await runPool(ids, state.cfg.ui.concurrency || 6, async id => {
        try {
          const r = await api('/api/run', { instanceId: id, checkId: '__ping' });
          applyPing(id, r);
        } catch (e) {
          if (handleFatal(e)) throw e;
          state.inst[id] = { state: 'offline', error: e.message };
        }
        renderInstances();
        updateKpis();
      });
    } catch (e) { /* fatal already reported */ }
    btn.disabled = false;
  }

  function applyPing(id, r) {
    if (!r.ok) {
      state.inst[id] = { state: 'offline', error: r.error };
      return;
    }
    const row = r.resultSets[0] && r.resultSets[0].rows[0];
    const cols = r.resultSets[0] ? r.resultSets[0].columns.map(c => c.name) : [];
    const get = n => row ? row[cols.indexOf(n)] : null;
    const ver = String(get('ProductVersion') || '');
    const major = parseInt(ver, 10);
    const name = SQL_VERSIONS[major] ? 'SQL ' + SQL_VERSIONS[major] : 'v' + ver;
    const level = [get('ProductLevel'), get('UpdateLevel')].filter(Boolean).join(' ');
    state.inst[id] = {
      state: 'online',
      latencyMs: r.durationMs,
      version: name + (level ? ' ' + level : '') + ' · ' + String(get('Edition') || '').replace(/ \(64-bit\)/, ''),
      error: null
    };
  }

  // ---------------------------------------------------------------------------
  // Check cards
  // ---------------------------------------------------------------------------
  function renderChecks() {
    const grid = $('#check-grid');
    grid.textContent = '';
    state.cfg.checks.forEach(c => {
      const run = state.runs.find(r => r.checkId === c.id);
      const busy = state.running.has(c.id);
      let status = el('span', { class: 'check-last', text: 'Not run yet' });
      if (busy) status = pill('running');
      else if (run && run.finishedAt) status = pill(run.sev, SEV_LABEL[run.sev] + ' · ' + fmtTime(run.finishedAt));

      grid.appendChild(el('article', { class: 'check-card' + (c.featured ? ' is-featured' : '') }, [
        el('div', { class: 'check-top' }, [
          el('span', { class: 'check-icon' }, icon(c.icon)),
          el('span', { class: 'check-cat', text: c.category })
        ]),
        el('h3', { text: c.title }),
        el('p', { text: c.description }),
        el('div', { class: 'check-foot' }, [
          status,
          el('button', {
            class: 'btn ' + (c.featured ? 'btn-primary' : 'btn-secondary') + ' btn-sm', type: 'button',
            disabled: busy, 'aria-label': 'Run ' + c.title,
            onclick: () => runChecks([c.id])
          }, busy ? [el('span', { class: 'spinner' }), 'Running'] : [icon('play'), 'Run'])
        ])
      ]));
    });
  }

  // ---------------------------------------------------------------------------
  // Running checks
  // ---------------------------------------------------------------------------
  function analyze(res) {
    res.counts = { critical: 0, warning: 0, info: 0, ok: 0, rows: 0 };
    if (!res.ok) { res.sev = 'error'; return res; }
    let sev = 'none';
    (res.resultSets || []).forEach(set => {
      set.statusIdx = set.columns.findIndex(c => /^status$/i.test(c.name));
      set.counts = { critical: 0, warning: 0, info: 0, ok: 0 };
      set.sev = 'none';
      res.counts.rows += set.rows.length;
      if (set.statusIdx < 0) return;
      set.rows.forEach(row => {
        const s = normSev(row[set.statusIdx]);
        if (s && set.counts[s] !== undefined) set.counts[s]++;
        if (s && SEV[s] > SEV[set.sev]) set.sev = s;
      });
      ['critical', 'warning', 'info', 'ok'].forEach(k => { res.counts[k] += set.counts[k]; });
      if (SEV[set.sev] > SEV[sev]) sev = set.sev;
    });
    res.sev = sev;
    return res;
  }

  function normSev(v) {
    const s = String(v === null || v === undefined ? '' : v).toLowerCase();
    if (s === 'ok' || s === 'healthy' || s === 'good') return 'ok';
    if (s === 'warning' || s === 'warn') return 'warning';
    if (s === 'critical' || s === 'error' || s === 'failed') return 'critical';
    if (s === 'info') return 'info';
    return null;
  }

  function newRun(checkId, targets) {
    const prev = state.runs.find(r => r.checkId === checkId);
    const run = {
      id: checkId + ':' + Date.now(),
      checkId: checkId,
      targets: targets,
      startedAt: new Date(),
      finishedAt: null,
      results: {},
      sev: 'none',
      ui: prev ? prev.ui : { collapsed: {}, sets: {} },
      el: null
    };
    if (prev) {
      const i = state.runs.indexOf(prev);
      state.runs.splice(i, 1, run);   // keep its place so the page does not jump
      if (prev.el) prev.el.replaceWith(buildRun(run));
    } else {
      state.runs.unshift(run);
    }
    targets.forEach(t => { run.results[t] = { status: 'queued' }; });
    return run;
  }

  async function runChecks(checkIds, opts) {
    if (state.fatal) return;
    const targets = (opts && opts.targets) || orderedSelection();
    if (!targets.length) {
      toast('warning', 'Select at least one instance first.');
      openSidebar();
      return;
    }
    checkIds = checkIds.filter(id => !state.running.has(id));
    if (!checkIds.length) return;

    // Create in reverse so the first check ends up on top (new runs are prepended).
    const runs = checkIds.slice().reverse().map(id => newRun(id, targets)).reverse();
    checkIds.forEach(id => state.running.add(id));
    renderResults();
    renderChecks();
    updateHeroButtons();
    if (!(opts && opts.silent)) {
      const first = runs[0].el;
      if (first && first.getBoundingClientRect().top > window.innerHeight) first.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    const tasks = [];
    runs.forEach(run => targets.forEach(t => tasks.push({ run: run, inst: t })));
    const started = performance.now();

    try {
      await runPool(tasks, state.cfg.ui.concurrency || 6, async task => {
        if (state.fatal) return;
        task.run.results[task.inst] = { status: 'running' };
        renderInstPanel(task.run, task.inst);
        let res;
        try {
          res = await api('/api/run', { instanceId: task.inst, checkId: task.run.checkId });
        } catch (e) {
          if (handleFatal(e)) throw e;
          res = { ok: false, error: e.message, durationMs: 0, resultSets: [], messages: [] };
        }
        res.status = 'done';
        task.run.results[task.inst] = analyze(res);
        noteReachability(task.inst, res);
        renderInstPanel(task.run, task.inst);
        updateRunHead(task.run);
      });
    } catch (e) { /* fatal - banner already shown */ }

    const now = new Date();
    runs.forEach(run => { run.finishedAt = now; updateRunHead(run); });
    checkIds.forEach(id => state.running.delete(id));
    state.lastRunAt = now;
    state.lastRunLabel = (checkIds.length > 1 ? 'Full health check' : checkById(checkIds[0]).title) + ' · ' + fmtMs(performance.now() - started);
    renderChecks();
    updateHeroButtons();
    updateKpis();
    if (!state.fatal && !(opts && opts.silent)) summaryToast(runs);
  }

  function noteReachability(instId, res) {
    const cur = state.inst[instId] || {};
    if (res.ok && cur.state !== 'online') {
      state.inst[instId] = Object.assign({}, cur, { state: 'online', latencyMs: cur.latencyMs || res.durationMs, error: null });
      renderInstances();
    } else if (!res.ok && /network-related|could not open a connection|login failed|timeout expired|server was not found/i.test(res.error || '')) {
      state.inst[instId] = Object.assign({}, cur, { state: 'offline', error: res.error });
      renderInstances();
    }
  }

  function summaryToast(runs) {
    let crit = 0, warn = 0, failed = 0;
    runs.forEach(run => run.targets.forEach(t => {
      const r = run.results[t];
      if (!r) return;
      if (r.sev === 'error') failed++;
      else if (r.counts) { crit += r.counts.critical; warn += r.counts.warning; }
    }));
    const what = runs.length === 1 ? checkById(runs[0].checkId).title : 'Health check';
    if (!crit && !warn && !failed) { toast('ok', what + ' complete - no issues found.'); return; }
    const parts = [];
    if (crit) parts.push(plural(crit, 'critical finding'));
    if (warn) parts.push(plural(warn, 'warning'));
    if (failed) parts.push(failed + ' failed to run');
    toast(crit || failed ? 'error' : 'warning', what + ' complete - ' + parts.join(', ') + '.', 6000);
  }

  function updateHeroButtons() {
    const featured = state.cfg.checks.find(c => c.featured) || state.cfg.checks[0];
    const fb = $('#run-featured');
    if (featured) {
      fb.disabled = state.running.has(featured.id);
      $('#run-featured-label').textContent = fb.disabled ? 'Checking…' : 'Check ' + featured.title;
    }
    $('#run-all').disabled = state.running.size > 0;
  }

  // ---------------------------------------------------------------------------
  // Results rendering
  // ---------------------------------------------------------------------------
  function renderResults() {
    const box = $('#results');
    const empty = $('#empty-results');
    empty.hidden = state.runs.length > 0;
    // Keep existing run elements (and their scroll/filter state); add new ones.
    state.runs.forEach((run, idx) => {
      if (!run.el) run.el = buildRun(run);
      const at = box.children[idx + 1];  // +1 for the empty-state element
      if (at !== run.el) box.insertBefore(run.el, at || null);
    });
    Array.prototype.slice.call(box.querySelectorAll('.run')).forEach(n => {
      if (!state.runs.some(r => r.el === n)) n.remove();
    });
    updateKpis();
  }

  function buildRun(run) {
    const check = checkById(run.checkId);
    const section = el('section', { class: 'run', 'aria-label': check.title + ' results' });
    run.el = section;
    run.headEl = el('div', { class: 'run-head' });
    run.bodyEl = el('div', { class: 'run-body' });
    run.instEls = {};
    section.appendChild(run.headEl);
    section.appendChild(run.bodyEl);
    run.targets.forEach(t => {
      run.instEls[t] = el('div');
      run.bodyEl.appendChild(run.instEls[t]);
      renderInstPanel(run, t);
    });
    updateRunHead(run);
    return section;
  }

  function updateRunHead(run) {
    if (!run.headEl) return;
    const check = checkById(run.checkId);
    let sev = 'none', crit = 0, warn = 0, failed = 0, done = 0;
    run.targets.forEach(t => {
      const r = run.results[t];
      if (!r || r.status !== 'done') return;
      done++;
      if (SEV[r.sev] > SEV[sev]) sev = r.sev;
      if (r.sev === 'error') failed++;
      crit += r.counts.critical;
      warn += r.counts.warning;
    });
    run.sev = sev;
    const finished = done === run.targets.length;
    const sub = plural(run.targets.length, 'instance') + ' · started ' + fmtTime(run.startedAt) +
      (finished && run.finishedAt ? ' · took ' + fmtMs(run.finishedAt - run.startedAt) : finished ? '' : ' · ' + done + '/' + run.targets.length + ' done');

    run.headEl.textContent = '';
    run.headEl.appendChild(el('div', { class: 'run-title' }, [
      el('span', { class: 'check-icon' }, icon(check.icon)),
      el('div', null, [el('h3', { text: check.title }), el('div', { class: 'run-sub', text: sub })])
    ]));
    const counts = el('div', { class: 'counts' });
    if (!finished) counts.appendChild(pill('running', 'Running ' + done + '/' + run.targets.length));
    if (crit) counts.appendChild(pill('critical', crit + ' critical'));
    if (warn) counts.appendChild(pill('warning', warn + ' warning' + (warn === 1 ? '' : 's')));
    if (failed) counts.appendChild(pill('error', failed + ' failed'));
    if (finished && !crit && !warn && !failed) counts.appendChild(pill(sev === 'none' ? 'ok' : sev, sev === 'info' || sev === 'none' ? 'No issues' : 'All healthy'));

    run.headEl.appendChild(el('div', { class: 'run-tools' }, [
      counts,
      el('button', {
        class: 'btn btn-ghost btn-sm', type: 'button', disabled: !finished || state.running.has(run.checkId),
        onclick: () => runChecks([run.checkId], { targets: run.targets })
      }, [icon('refresh'), 'Re-run']),
      el('button', {
        class: 'icon-btn', type: 'button', title: 'Remove these results', 'aria-label': 'Remove ' + check.title + ' results',
        disabled: !finished, onclick: () => { state.runs = state.runs.filter(r => r !== run); renderResults(); renderChecks(); }
      }, icon('x'))
    ]));
    updateKpis();
  }

  function renderInstPanel(run, instId) {
    const holder = run.instEls && run.instEls[instId];
    if (!holder) return;
    const inst = instanceById(instId);
    const res = run.results[instId] || { status: 'queued' };
    const check = checkById(run.checkId);

    const status = res.status === 'done' ? res.sev : res.status;
    if (res.status === 'done' && run.ui.collapsed[instId] === undefined) {
      run.ui.collapsed[instId] = run.targets.length > 2 && SEV[res.sev] < SEV.warning;
    }
    const collapsed = !!run.ui.collapsed[instId];

    const wrap = el('div', { class: 'inst sev-' + status + (collapsed ? ' is-collapsed' : '') });
    const metaBits = [];
    if (res.status === 'done') {
      if (res.ok) metaBits.push(el('span', { text: plural(res.counts.rows, 'row') }));
      metaBits.push(el('span', { class: 'inst-dur', text: fmtMs(res.durationMs || 0) }));
    }
    wrap.appendChild(el('button', {
      class: 'inst-head', type: 'button', 'aria-expanded': collapsed ? 'false' : 'true',
      onclick: () => { run.ui.collapsed[instId] = !collapsed; renderInstPanel(run, instId); }
    }, [
      icon('chevron', 'chev'),
      status === 'running' ? pill('running') : status === 'queued' ? pill('queued') : pill(status),
      el('span', { class: 'inst-name', text: inst.name }),
      inst.role ? el('span', { class: 'role-tag', text: inst.role }) : null,
      el('span', { class: 'inst-meta' }, metaBits)
    ]));

    if (res.status === 'done') {
      const body = el('div', { class: 'inst-body' });
      if (!res.ok) {
        body.appendChild(el('div', { class: 'alert alert-error', role: 'alert' }, [
          icon('x-circle'),
          el('div', null, [
            el('strong', { text: 'The check could not run on this instance.' }),
            el('pre', { text: res.error || 'Unknown error' }),
            el('div', { class: 'rs-note', text: 'Check the server name and port, firewall rules, and that your account has the permissions listed in the README.' })
          ])
        ]));
      }
      if (res.messages && res.messages.length) {
        body.appendChild(el('div', { class: 'alert' }, [
          icon('message'),
          res.messages.length === 1 ? el('div', { text: res.messages[0] })
            : el('ul', null, res.messages.map(m => el('li', { text: m })))
        ]));
      }
      (res.resultSets || []).forEach((set, i) => {
        body.appendChild(buildResultSet(run, instId, set, i, check));
      });
      if (res.ok && !(res.resultSets || []).length) body.appendChild(el('div', { class: 'rs-empty', text: 'The check returned no result sets.' }));
      wrap.appendChild(body);
    }

    holder.replaceWith(wrap);
    run.instEls[instId] = wrap;
  }

  function buildResultSet(run, instId, set, idx, check) {
    const key = instId + ':' + idx;
    const ui = run.ui.sets[key] || (run.ui.sets[key] = { q: '', sort: -1, dir: 1 });
    const title = (check.resultTitles && check.resultTitles[idx]) || ('Result set ' + (idx + 1));

    const countBits = [plural(set.rows.length, 'row')];
    if (set.counts.critical) countBits.push(set.counts.critical + ' critical');
    if (set.counts.warning) countBits.push(set.counts.warning + ' warning');

    const tableWrap = el('div', { class: 'table-wrap' });
    const input = el('input', { type: 'search', placeholder: 'Filter rows', 'aria-label': 'Filter ' + title, value: ui.q });
    input.addEventListener('input', () => { ui.q = input.value; drawTable(tableWrap, set, ui); });

    const container = el('div', { class: 'rs' }, [
      el('div', { class: 'rs-head' }, [
        el('div', { class: 'rs-title' }, [
          set.statusIdx >= 0 ? el('span', { class: 'dot dot-' + ({ critical: 'offline', warning: 'checking', ok: 'online' }[set.sev] || 'unknown') }) : null,
          title, el('span', { class: 'rs-count', text: '· ' + countBits.join(' · ') })
        ]),
        set.rows.length ? el('div', { class: 'rs-tools' }, [
          el('label', { class: 'rs-filter' }, [icon('search'), input]),
          el('button', { class: 'icon-btn', type: 'button', title: 'Copy (paste into Excel or e-mail)', 'aria-label': 'Copy ' + title, onclick: () => copySet(set) }, icon('copy')),
          el('button', { class: 'icon-btn', type: 'button', title: 'Download CSV', 'aria-label': 'Download ' + title + ' as CSV', onclick: () => downloadCsv(set, check, instId, title) }, icon('download'))
        ]) : null
      ])
    ]);

    if (!set.rows.length) {
      container.appendChild(el('div', { class: 'rs-empty', text: 'No rows - nothing to report here.' }));
    } else {
      container.appendChild(tableWrap);
      drawTable(tableWrap, set, ui);
    }
    if (set.truncated) container.appendChild(el('div', { class: 'rs-note', text: 'Only the first ' + set.rows.length + ' rows were returned (maxRowsPerResultSet).' }));
    return container;
  }

  const MAX_RENDER_ROWS = 1000;

  function drawTable(wrap, set, ui) {
    const cols = set.columns;
    const q = ui.q.trim().toLowerCase();
    let rows = set.rows;
    let hiddenByView = 0;

    if (state.view === 'issues' && set.statusIdx >= 0) {
      const before = rows.length;
      rows = rows.filter(r => { const s = normSev(r[set.statusIdx]); return s === 'warning' || s === 'critical'; });
      hiddenByView = before - rows.length;
    }
    if (q) rows = rows.filter(r => r.some(v => v !== null && String(v).toLowerCase().indexOf(q) >= 0));
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
      wrap.appendChild(el('div', { class: 'rs-empty', text: hiddenByView ? 'No issues - ' + plural(hiddenByView, 'healthy row') + ' hidden.' : 'No rows match the filter.' }));
      return;
    }

    const numeric = cols.map(c => NUMERIC_TYPES.test(c.type));
    const thead = el('tr', null, cols.map((c, i) => {
      const sorted = ui.sort === i;
      return el('th', {
        class: (numeric[i] ? 'num' : '') + (sorted ? ' sorted' : ''), scope: 'col', title: c.name + ' (' + c.type + ') - click to sort',
        'aria-sort': sorted ? (ui.dir > 0 ? 'ascending' : 'descending') : 'none',
        onclick: () => { if (ui.sort === i) ui.dir = -ui.dir; else { ui.sort = i; ui.dir = i === set.statusIdx ? -1 : 1; } drawTable(wrap, set, ui); }
      }, [i === set.statusIdx ? 'Status' : humanize(c.name), el('span', { class: 'sort', text: sorted ? (ui.dir > 0 ? '▲' : '▼') : '↕' })]);
    }));

    const tbody = el('tbody');
    rows.slice(0, MAX_RENDER_ROWS).forEach(r => {
      const sev = set.statusIdx >= 0 ? normSev(r[set.statusIdx]) : null;
      tbody.appendChild(el('tr', { class: sev ? 'row-' + sev : null }, r.map((v, i) => renderCell(v, i, cols[i], numeric[i], set.statusIdx))));
    });

    wrap.appendChild(el('table', { class: 'grid' }, [el('thead', null, thead), tbody]));
    if (rows.length > MAX_RENDER_ROWS) {
      wrap.appendChild(el('div', { class: 'rs-note', text: 'Showing the first ' + MAX_RENDER_ROWS + ' of ' + rows.length + ' rows. Use the filter or download the CSV to see everything.' }));
    }
  }

  function renderCell(v, i, col, isNum, statusIdx) {
    if (i === statusIdx) {
      const s = normSev(v);
      return el('td', null, s ? pill(s, String(v).toUpperCase() === 'OK' ? 'OK' : SEV_LABEL[s]) : String(v === null ? '' : v));
    }
    if (v === null || v === undefined) return el('td', { class: 'null', text: '—' });
    if (typeof v === 'boolean') return el('td', null, el('span', { class: v ? 'bool-yes' : 'bool-no', text: v ? 'Yes' : 'No' }));
    if (typeof v === 'number' && isNum) {
      const text = Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumFractionDigits: 2 });
      return el('td', { class: 'num', text: text });
    }
    const s = String(v);
    const isCode = /sql|statement/i.test(col.name);
    if (s.length > 90 || s.indexOf('\n') >= 0 || isCode) {
      const td = el('td', { class: 'clamp' + (isCode ? ' code' : ''), title: s.length > 600 ? null : s }, el('div', { text: s }));
      td.addEventListener('click', () => td.classList.toggle('open'));
      return td;
    }
    return el('td', { class: isNum ? 'num' : null, text: s });
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------
  function cellText(v) { return v === null || v === undefined ? '' : String(v); }

  function downloadCsv(set, check, instId, title) {
    const esc = v => { const s = cellText(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const lines = [set.columns.map(c => esc(c.name)).join(',')].concat(set.rows.map(r => r.map(esc).join(',')));
    const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
    const name = [check.id, instanceById(instId).name, title, stamp].join('_').replace(/[^A-Za-z0-9._-]+/g, '-') + '.csv';
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
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(tsv).then(done, () => fallbackCopy(tsv, done));
    } else {
      fallbackCopy(tsv, done);
    }
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
  // KPIs
  // ---------------------------------------------------------------------------
  function setKpi(id, value, foot, ok) {
    const k = $('#' + id);
    $('.kpi-value', k).textContent = value;
    $('.kpi-foot', k).textContent = foot;
    k.classList.toggle('is-ok', !!ok);
  }

  function updateKpis() {
    if (!state.cfg) return;
    const total = state.cfg.instances.length;
    const states = state.cfg.instances.map(i => (state.inst[i.id] || {}).state || 'unknown');
    const online = states.filter(s => s === 'online').length;
    const offline = states.filter(s => s === 'offline').length;
    const tested = online + offline;
    setKpi('kpi-online', tested ? online + ' / ' + total : '– / ' + total,
      !tested ? 'Not tested yet' : offline ? plural(offline, 'instance') + ' unreachable' : 'All tested instances reachable', tested && !offline);

    let crit = 0, warn = 0, failed = 0, checks = 0;
    state.runs.forEach(run => {
      checks++;
      run.targets.forEach(t => {
        const r = run.results[t];
        if (!r || r.status !== 'done') return;
        if (r.sev === 'error') failed++;
        crit += r.counts.critical;
        warn += r.counts.warning;
      });
    });
    const scope = checks ? 'Across ' + plural(checks, 'check') + ' on screen' : 'Run a check to see findings';
    setKpi('kpi-critical', String(crit + failed), failed ? crit + ' critical · ' + failed + ' failed to run' : scope, checks && !crit && !failed);
    setKpi('kpi-warning', String(warn), scope, checks && !warn);
    setKpi('kpi-last', state.lastRunAt ? fmtTime(state.lastRunAt) : '–', state.lastRunAt ? state.lastRunLabel : 'No checks run yet');

    const base = (state.cfg && state.cfg.title) || 'SQL Server Health Dashboard';
    document.title = (crit + failed ? '(' + (crit + failed) + ') ' : '') + base;
  }

  // ---------------------------------------------------------------------------
  // Auto refresh
  // ---------------------------------------------------------------------------
  function stopAutoRefresh() {
    if (state.autoTimer) clearInterval(state.autoTimer);
    state.autoTimer = null;
  }

  function setAutoRefresh(minutes) {
    stopAutoRefresh();
    store('autoRefresh', String(minutes));
    if (minutes > 0) {
      state.autoTimer = setInterval(() => {
        if (state.running.size || state.fatal || !state.runs.length) return;
        state.runs.slice().reverse().forEach(r => runChecks([r.checkId], { targets: r.targets, silent: true }));
      }, minutes * 60000);
    }
    refreshFooter();
  }

  // ---------------------------------------------------------------------------
  // Sidebar (mobile)
  // ---------------------------------------------------------------------------
  function setSidebar(open) {
    $('#sidebar').classList.toggle('is-collapsed', !open);
    $('#sidebar-toggle').setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  function openSidebar() {
    if (window.matchMedia('(max-width: 900px)').matches) {
      setSidebar(true);
      $('#sidebar').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  // ---------------------------------------------------------------------------
  // Start-up
  // ---------------------------------------------------------------------------
  function bindEvents() {
    $('#theme-toggle').addEventListener('click', () => {
      applyTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
    });
    $('#select-all').addEventListener('click', () => {
      state.cfg.instances.forEach(i => state.selected.add(i.id)); saveSelection(); renderInstances();
    });
    $('#select-none').addEventListener('click', () => { state.selected.clear(); saveSelection(); renderInstances(); });
    $('#instance-filter').addEventListener('input', renderInstances);
    $('#ping-all').addEventListener('click', pingAll);
    $('#run-featured').addEventListener('click', () => {
      const f = state.cfg.checks.find(c => c.featured) || state.cfg.checks[0];
      if (f) runChecks([f.id]);
    });
    $('#run-all').addEventListener('click', () => runChecks(state.cfg.checks.map(c => c.id)));
    $('#clear-results').addEventListener('click', () => {
      state.runs = state.runs.filter(r => state.running.has(r.checkId));
      renderResults();
      renderChecks();
    });
    $('#auto-refresh').addEventListener('change', e => setAutoRefresh(Number(e.target.value)));
    $('#sidebar-toggle').addEventListener('click', () => setSidebar($('#sidebar').classList.contains('is-collapsed')));
    $$('.segmented button').forEach(b => b.addEventListener('click', () => {
      state.view = b.getAttribute('data-view');
      $$('.segmented button').forEach(x => {
        x.classList.toggle('is-active', x === b);
        x.setAttribute('aria-checked', x === b ? 'true' : 'false');
      });
      state.runs.forEach(run => run.targets.forEach(t => renderInstPanel(run, t)));
    }));
  }

  function applyConfig() {
    const cfg = state.cfg;
    cfg.ui = cfg.ui || {};
    $('#app-title').textContent = cfg.title;
    document.title = cfg.title;
    $('#app-sub').textContent = plural(cfg.instances.length, 'instance') + ' · ' + plural(cfg.checks.length, 'health check') + (cfg.version ? ' · v' + cfg.version : '');
    if (cfg.environment) {
      const badge = $('#env-badge');
      badge.textContent = cfg.environment;
      badge.classList.toggle('env-nonprod', !/prod/i.test(cfg.environment));
      badge.hidden = false;
    }

    let saved = null;
    try { saved = JSON.parse(store('selected') || 'null'); } catch (e) { saved = null; }
    const valid = new Set(cfg.instances.map(i => i.id));
    if (Array.isArray(saved) && saved.some(id => valid.has(id))) saved.filter(id => valid.has(id)).forEach(id => state.selected.add(id));
    else cfg.instances.forEach(i => state.selected.add(i.id));

    const featured = cfg.checks.find(c => c.featured) || cfg.checks[0];
    if (featured) {
      $('#run-featured [data-icon]').innerHTML = svg(featured.icon);
    } else {
      $('#run-featured').hidden = true;
    }

    const savedAuto = store('autoRefresh');
    const auto = savedAuto !== null ? Number(savedAuto) : (cfg.ui.defaultAutoRefresh || 0);
    const sel = $('#auto-refresh');
    if (Array.prototype.some.call(sel.options, o => Number(o.value) === auto)) sel.value = String(auto);

    renderInstances();
    renderChecks();
    updateHeroButtons();
    updateKpis();
    setAutoRefresh(Number(sel.value));
    if (cfg.ui.pingOnLoad !== false) pingAll();
  }

  async function init() {
    hydrateIcons(document);
    bindEvents();
    if (window.matchMedia('(max-width: 900px)').matches) setSidebar(false);

    const wantDemo = location.protocol === 'file:' || /(^|[#&?])demo\b/.test(location.hash + location.search);
    state.token = wantDemo ? null : readToken();
    state.demo = wantDemo && !!window.SqlDashDemo;

    if (!state.demo && !state.token) {
      state.fatal = true;
      showBanner('error', 'No session key found. Open the dashboard with the full address printed in the dashboard console window (it ends with #t=…).');
      setFooter('offline', 'Not connected');
      return;
    }
    try {
      state.cfg = await api('/api/config');
    } catch (e) {
      if (!handleFatal(e)) showBanner('error', 'Could not load the configuration: ' + e.message);
      return;
    }
    if (state.demo) showBanner('info', 'Demo mode - showing sample data, no SQL Server connections are made. Start the dashboard with Start-Dashboard.cmd to use live data.');
    applyConfig();
    refreshFooter();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
