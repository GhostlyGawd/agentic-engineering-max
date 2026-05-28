// webui/app.js -- Control Plane HUD front-end (spec T-302 / D-S13).
//
// Vanilla ES module. No framework, no bundler, no npm. Polls the D-S10 JSON API
// every POLL_MS and re-renders the Loops / Board / Gates tabs; the Logs tab is
// fetched on demand. Every mutation delegates to a POST route -- the server is
// never load-bearing, so the same effects are reachable from the CLI.
//
// D-S10 route contract (kept as literal strings so the regression test can grep
// that the front-end wires every route it uses):
const API = {
  board:   '/api/board',
  gates:   '/api/gates',
  loops:   '/api/loops',
  logs:    '/api/logs',
  approve: '/api/approve',
  decline: '/api/decline',
  retry:   '/api/retry',
  launch:  '/api/launch',
  stop:    '/api/stop',
};

const POLL_MS = 2500;

// --- tiny fetch helpers ----------------------------------------------------

async function getJSON(path) {
  const res = await fetch(path, { headers: { 'Accept': 'application/json' } });
  if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}`);
  return res.json();
}

async function postJSON(path, body) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  let data = null;
  try { data = await res.json(); } catch { data = null; }
  if (!res.ok) {
    const msg = (data && data.error) ? data.error : `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return data;
}

// --- DOM helpers -----------------------------------------------------------

function el(id) { return document.getElementById(id); }

function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

// Build an element with attrs + text/children. Uses textContent only (no
// innerHTML) so API strings can never inject markup.
function h(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    }
  }
  for (const kid of kids) {
    if (kid == null) continue;
    node.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
  }
  return node;
}

function statusBadge(status) {
  const s = (status || 'open').toLowerCase();
  return h('span', { class: `badge status-${s}`, text: s });
}

// --- tab switching ---------------------------------------------------------

function initTabs() {
  for (const btn of document.querySelectorAll('.tab-btn')) {
    btn.addEventListener('click', () => {
      for (const b of document.querySelectorAll('.tab-btn')) b.classList.remove('active');
      for (const p of document.querySelectorAll('.tab-panel')) p.classList.remove('active');
      btn.classList.add('active');
      el(btn.dataset.tab).classList.add('active');
    });
  }
}

// --- Loops -----------------------------------------------------------------

function renderHeartbeats(container, beats) {
  clear(container);
  if (!beats || beats.length === 0) {
    container.appendChild(h('div', { class: 'empty', text: 'none' }));
    return;
  }
  for (const b of beats) {
    const alive = b.state === 'FRESH';
    container.appendChild(h('div', { class: `hb ${alive ? 'hb-alive' : 'hb-stale'}` },
      h('span', { class: 'hb-dot' }),
      h('span', { class: 'hb-id', text: b.id }),
      h('span', { class: 'muted', text: `${b.slug} - ${b.state} - last tick ${b.age_sec}s ago` }),
    ));
  }
}

async function refreshLoops() {
  const data = await getJSON(API.loops);
  renderHeartbeats(el('loops-controllers'), data.controllers);
  renderHeartbeats(el('loops-workers'), data.workers);
  renderHeartbeats(el('loops-reviewers'), data.reviewers);
  el('loops-log-tail').textContent = (data.controller_log_tail || []).join('\n');
}

function initLoopActions() {
  el('btn-launch').addEventListener('click', async () => {
    const slug = el('loops-slug').value.trim();
    await runAction('loops-action-result', () => postJSON(API.launch, { slug }),
      (r) => `launched ${r.slug} (pid ${r.pid})`);
  });
  el('btn-stop').addEventListener('click', async () => {
    const slug = el('loops-slug').value.trim();
    await runAction('loops-action-result', () => postJSON(API.stop, { slug }),
      (r) => `stop sentinel dropped for ${r.slug}`);
  });
}

// Run a mutation, show success/error text in a result span, then re-poll.
async function runAction(resultId, fn, okText) {
  const span = el(resultId);
  span.textContent = 'working...';
  span.className = 'muted';
  try {
    const r = await fn();
    span.textContent = okText(r);
    span.className = 'ok';
    await pollOnce();
  } catch (e) {
    span.textContent = `error: ${e.message}`;
    span.className = 'err';
  }
}

// --- Board -----------------------------------------------------------------

let lastBoard = null;

// The "gated" filter keys off a task carrying gate fields. The board task rows
// do not surface gate_decider, so we cross-reference the live gate queue's ids.
let gatedTaskIds = new Set();

function populateFilterOptions(board) {
  const slugs = new Set();
  const statuses = new Set();
  const kinds = new Set();
  for (const p of board.portfolio || []) {
    slugs.add(p.slug);
    for (const c of p.containers || []) { statuses.add(c.status); kinds.add(c.kind); }
    for (const t of p.tasks || []) { statuses.add(t.status); kinds.add(t.kind); }
  }
  syncSelect(el('filter-slug'), slugs);
  syncSelect(el('filter-status'), statuses);
  syncSelect(el('filter-kind'), kinds);
}

// Add any new values as <option>s without clobbering the current selection.
function syncSelect(select, values) {
  const have = new Set(Array.from(select.options).map(o => o.value));
  for (const v of Array.from(values).sort()) {
    if (v && !have.has(v)) select.appendChild(h('option', { value: v, text: v }));
  }
}

function renderBoard() {
  if (!lastBoard) return;
  const fSlug = el('filter-slug').value;
  const fStatus = el('filter-status').value;
  const fGate = el('filter-gate').value;
  const fKind = el('filter-kind').value;
  const tree = el('board-tree');
  clear(tree);

  const passesLeaf = (node) => {
    if (fStatus && node.status !== fStatus) return false;
    if (fKind && node.kind !== fKind) return false;
    if (fGate === 'gated' && !gatedTaskIds.has(node.id)) return false;
    if (fGate === 'ungated' && gatedTaskIds.has(node.id)) return false;
    return true;
  };

  for (const p of lastBoard.portfolio || []) {
    if (fSlug && p.slug !== fSlug) continue;

    // Index this slug's nodes by id and group children by parent.
    const childrenOf = new Map();
    const addChild = (parent, node) => {
      const key = parent || '';
      if (!childrenOf.has(key)) childrenOf.set(key, []);
      childrenOf.get(key).push(node);
    };
    const containers = p.containers || [];
    const tasks = p.tasks || [];
    for (const c of containers) addChild(c.parent, { ...c, _container: true });
    for (const t of tasks) addChild(t.parent, { ...t, _container: false });

    const slugNode = h('details', { class: 'node slug-node', open: 'open' },
      h('summary', null,
        h('span', { class: 'kind-tag', text: 'slug' }),
        h('span', { class: 'node-title', text: p.slug }),
        p.parent ? h('span', { class: 'muted', text: `parent: ${p.parent}` }) : null,
      ),
    );

    const built = renderNodes(childrenOf, '', childrenOf, passesLeaf, fKind || fStatus || fGate);
    for (const n of built) slugNode.appendChild(n);
    tree.appendChild(slugNode);
  }

  if (!tree.firstChild) tree.appendChild(h('div', { class: 'empty', text: 'no matching tasks' }));
}

// Recursively render the children under a parent id. Containers become
// collapsible <details>; leaves become rows. A container is kept if any of its
// descendant leaves pass the filter (so the tree path to a match stays visible).
function renderNodes(childrenOf, parentKey, root, passesLeaf, filtering) {
  const kids = childrenOf.get(parentKey) || [];
  const out = [];
  for (const node of kids) {
    if (node._container) {
      const inner = renderNodes(childrenOf, node.id, root, passesLeaf, filtering);
      if (filtering && inner.length === 0) continue; // prune empty branches when filtering
      const det = h('details', { class: 'node container-node', open: 'open' },
        h('summary', null,
          h('span', { class: 'kind-tag', text: node.kind }),
          h('span', { class: 'node-title', text: `${node.id} ${node.title || ''}` }),
          statusBadge(node.status),
          h('span', { class: 'progress', text: node.progress || '' }),
        ),
      );
      for (const c of inner) det.appendChild(c);
      out.push(det);
    } else {
      if (!passesLeaf(node)) continue;
      out.push(h('div', { class: 'node leaf-node' },
        h('span', { class: 'kind-tag', text: node.kind }),
        h('span', { class: 'node-title', text: `${node.id} ${node.title || ''}` }),
        statusBadge(node.status),
        gatedTaskIds.has(node.id) ? h('span', { class: 'badge gate-flag', text: 'gate' }) : null,
      ));
    }
  }
  return out;
}

async function refreshBoard() {
  const board = await getJSON(API.board);
  lastBoard = board;
  populateFilterOptions(board);
  renderBoard();
}

function initBoardFilters() {
  for (const id of ['filter-slug', 'filter-status', 'filter-gate', 'filter-kind']) {
    el(id).addEventListener('change', renderBoard);
  }
}

// --- Gates -----------------------------------------------------------------

function renderGates(gatesObj) {
  const gates = (gatesObj && gatesObj.gates) || [];
  gatedTaskIds = new Set(gates.map(g => g.task_id));
  el('gates-count').textContent = String(gates.length);
  const list = el('gates-list');
  clear(list);
  if (gates.length === 0) {
    list.appendChild(h('div', { class: 'empty', text: 'no gates awaiting decision' }));
    return;
  }
  for (const g of gates) {
    const notes = h('textarea', { class: 'gate-notes', rows: '2', placeholder: 'notes (sent with Retry/Decline)' });
    const result = h('span', { class: 'muted' });

    const decide = (route, label) => async () => {
      result.textContent = 'working...';
      result.className = 'muted';
      try {
        const r = await postJSON(route, { slug: g.slug, task_id: g.task_id, notes: notes.value });
        result.textContent = `${label} -> ${r.status || 'ok'}${r.gate_state ? ' (' + r.gate_state + ')' : ''}`;
        result.className = 'ok';
        await pollOnce();
      } catch (e) {
        result.textContent = `error: ${e.message}`;
        result.className = 'err';
      }
    };

    const viewPlan = g.design_path
      ? h('a', { class: 'btn btn-link', href: '/' + g.design_path, target: '_blank' }, 'View plan')
      : h('span', { class: 'muted', text: 'no design path' });

    list.appendChild(h('div', { class: 'gate-card' },
      h('div', { class: 'gate-head' },
        h('span', { class: 'badge', text: g.slug }),
        h('span', { class: 'gate-id', text: g.task_id }),
        h('span', { class: 'kind-tag', text: g.kind || 'task' }),
        h('span', { class: 'muted', text: `${g.gate_action || ''} / ${g.gate_state || ''}` }),
      ),
      h('div', { class: 'gate-title', text: g.title || '' }),
      notes,
      h('div', { class: 'gate-actions' },
        viewPlan,
        h('button', { class: 'btn btn-go', onclick: decide(API.approve, 'approve') }, 'Approve'),
        h('button', { class: 'btn btn-stop', onclick: decide(API.decline, 'decline') }, 'Decline'),
        h('button', { class: 'btn', onclick: decide(API.retry, 'retry') }, 'Retry'),
        result,
      ),
    ));
  }
}

async function refreshGates() {
  const gatesObj = await getJSON(API.gates);
  renderGates(gatesObj);
}

// --- Logs ------------------------------------------------------------------

async function refreshLogs() {
  const file = el('logs-file').value.trim();
  const tail = el('logs-tail').value.trim() || '200';
  const result = el('logs-result');
  if (!file) { result.textContent = 'enter a log filename'; result.className = 'muted'; return; }
  result.textContent = 'loading...';
  result.className = 'muted';
  try {
    const data = await getJSON(`${API.logs}?file=${encodeURIComponent(file)}&tail=${encodeURIComponent(tail)}`);
    el('logs-output').textContent = (data.lines || []).join('\n');
    result.textContent = `${(data.lines || []).length} lines of ${data.file}`;
    result.className = 'ok';
  } catch (e) {
    el('logs-output').textContent = '';
    result.textContent = `error: ${e.message}`;
    result.className = 'err';
  }
}

function initLogs() {
  el('btn-logs-refresh').addEventListener('click', refreshLogs);
}

// --- poll loop -------------------------------------------------------------

let pollTimer = null;

async function pollOnce() {
  const state = el('poll-state');
  try {
    // Gates first so gatedTaskIds is populated before the board renders its flags.
    await refreshGates();
    await Promise.all([refreshLoops(), refreshBoard()]);
    state.textContent = 'live';
    state.className = 'pill pill-ok';
    el('last-updated').textContent = `updated ${new Date().toLocaleTimeString()}`;
  } catch (e) {
    state.textContent = `offline: ${e.message}`;
    state.className = 'pill pill-err';
  }
}

function startPolling() {
  pollOnce();
  pollTimer = setInterval(pollOnce, POLL_MS);
}

// --- boot ------------------------------------------------------------------

initTabs();
initLoopActions();
initBoardFilters();
initLogs();
startPolling();
