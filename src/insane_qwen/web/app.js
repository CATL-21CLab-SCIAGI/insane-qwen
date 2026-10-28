'use strict';
// Text-only rendering; private Tailscale authentication.

const $ = (s) => document.querySelector(s);
// Authentication is supplied by the private Tailscale Serve proxy.
try { localStorage.removeItem('agentPlaygroundToken'); } catch {}
const EXAMPLES = {
  agent: [
    ['Damped oscillator', 'Simulate a damped harmonic oscillator (m=1, k=4, true damping ratio 0.15) with scipy, add 2% Gaussian noise to the position, then estimate the damping ratio by curve fitting. Report the estimate, its standard error and the relative error versus the true value. Save the script as fit.py.'],
    ['Arrhenius fit', 'Generate synthetic Arrhenius data k = A*exp(-Ea/(R*T)) with A=1e7 1/s, Ea=55 kJ/mol at 8 temperatures between 300 and 400 K with 5% multiplicative noise. Fit Ea and A with uncertainties (linearised and nonlinear least squares), compare the two methods, and write results.csv.'],
    ['Peak finding', 'Write a function that finds peaks in a noisy 1-D spectrum and reports centre and FWHM for each. Test it on a synthetic spectrum with 4 Gaussian peaks plus noise and show that the recovered values are within 2% of the ground truth.'],
    ['Lyapunov exponent', 'Estimate the Lyapunov exponent of the logistic map for r in {2.9, 3.5, 3.83, 3.9, 4.0} numerically. Explain which values are chaotic and check r=4.0 against the analytic value ln 2.'],
    ['Data audit', 'Create a CSV of 500 synthetic sensor readings (temperature, pressure, flow) with a few injected faults: stuck values, spikes and a drift. Write a script that detects each fault type, then report precision and recall against the injected labels.'],
  ],
  chat: [
    ['A small win', 'I finally finished a difficult project. What would you say to me?'],
    ['A disagreement', 'My friend thinks my idea is bad. How should I respond?'],
    ['Plan an experiment', 'I want to know whether a new catalyst coating lowers activation energy. Design a minimal experiment: which measurements, how many temperatures and replicates, and how to analyse the result.'],
    ['Explain a method', 'Explain bootstrap confidence intervals to a process engineer, with a short numeric example.'],
    ['Debug reasoning', 'A regression on plant data gives R^2 = 0.98 on training data but fails on next month. List the most likely causes and how to check each one.'],
  ],
};

let mode = 'chat';
let running = false;
let controllers = [];
let images = {};
const chats = { a: [], b: [] };

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

async function api(path, options = {}) {
  const headers = { ...(options.body ? { 'Content-Type': 'application/json' } : {}) };
  const response = await fetch(path, { ...options, headers });
  if (response.status === 401) throw new Error('Enable Tailscale and connect with your authorized account.');
  return response;
}

async function readSSE(response, onEvent) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
    let cut;
    while ((cut = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, cut);
      buffer = buffer.slice(cut + 2);
      let event = 'message';
      const data = [];
      for (const line of block.split('\n')) {
        if (line.startsWith('event:')) event = line.slice(6).trim();
        else if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
      }
      if (data.length) onEvent(event, data.join('\n'));
    }
  }
}

// ---------- panes ----------
class Pane {
  constructor(id) {
    this.root = $(id);
    this.log = this.root.querySelector('.log');
    this.state = this.root.querySelector('.state');
    this.stats = this.root.querySelector('.stats');
    this.modelLabel = this.root.querySelector('.model');
    this.calls = new Map();
  }
  reset(model) {
    this.log.replaceChildren();
    this.calls.clear();
    this.modelLabel.textContent = model;
    this.steps = 0; this.tokens = 0; this.started = Date.now();
    this.setStats();
  }
  setState(text, kind = '') { this.state.textContent = text; this.state.className = `state ${kind}`; }
  setStats() {
    const seconds = Math.round((Date.now() - (this.started || Date.now())) / 1000);
    this.stats.textContent = `${this.steps} steps · ${this.tokens.toLocaleString()} tokens · ${seconds}s`;
  }
  add(node) {
    const atBottom = this.log.scrollHeight - this.log.scrollTop - this.log.clientHeight < 40;
    this.log.append(node);
    if (atBottom) this.log.scrollTop = this.log.scrollHeight;
    return node;
  }
  note(text, error = false) { return this.add(el('div', error ? 'note err' : 'note', text)); }

  assistant(message, step) {
    this.steps = Math.max(this.steps, step + 1);
    this.add(el('div', 'step', `step ${step + 1}`));
    if (message.content) this.add(el('div', 'msg', message.content));
    for (const call of message.tool_calls || []) {
      const fn = call.function || {};
      let command = fn.arguments || '';
      try {
        const args = JSON.parse(fn.arguments || '{}');
        command = args.command ?? command;
      } catch { /* show raw arguments */ }
      const card = this.add(el('div', 'call'));
      card.append(el('pre', 'cmd', command));
      const details = el('details');
      details.append(el('summary', '', 'running…'));
      card.append(details);
      this.calls.set(call.id, details);
    }
  }
  tool(message) {
    const details = this.calls.get(message.tool_call_id);
    const output = message.content || '';
    const rc = /Tool metadata: \{'returncode': (-?\d+|None)\}\s*$/.exec(output);
    const body = rc ? output.slice(0, rc.index).trimEnd() : output;
    const target = details || this.add(el('details'));
    const summary = target.querySelector('summary') || target.appendChild(el('summary'));
    summary.textContent = `output · ${body.length.toLocaleString()} chars · returncode ${rc ? rc[1] : '?'}`;
    if (rc && rc[1] !== '0') summary.classList.add('rc-bad');
    target.append(el('pre', '', body || '(no output)'));
  }
}
const panes = { a: new Pane('#pane-a'), b: new Pane('#pane-b') };

// ---------- agent mode ----------
async function runAgent(pane, model, task, image, steps, signal) {
  pane.reset(model);
  pane.setState('starting sandbox…', 'running');
  pane.add(el('div', 'msg user', task));
  const timer = setInterval(() => pane.setStats(), 1000);
  let completed = false;
  try {
    const response = await api('/agent/runs', {
      method: 'POST', signal, body: JSON.stringify({ model, task, image, max_steps: steps, ...steeringBody(model) }),
    });
    if (!response.ok) throw new Error(`${response.status}: ${(await response.text()).slice(0, 300)}`);
    await readSSE(response, (event, raw) => {
      const data = JSON.parse(raw);
      if (event === 'run') { pane.setState(`running in ${data.cwd}`, 'running'); pane.runId = data.id; }
      else if (event === 'assistant') {
        pane.tokens += data.usage?.completion_tokens || 0;
        pane.assistant(data, data.step);
      } else if (event === 'tool') pane.tool(data);
      else if (event === 'error') pane.note(data.error, true);
      else if (event === 'done') {
        completed = true;
        const kind = data.status === 'finished' ? 'finished' : 'failed';
        pane.setState(data.status === 'finished' ? 'finished (model stopped calling tools)' : data.status, kind);
      }
    });
    if (!completed) throw new Error('Connection ended before the final result. Check history before retrying.');
  } catch (error) {
    if (error.name === 'AbortError') pane.setState('stopped', 'failed');
    else { pane.setState('failed', 'failed'); pane.note(String(error.message || error), true); }
  } finally {
    clearInterval(timer);
    pane.setStats();
  }
}

// ---------- chat mode ----------
async function runChat(key, model, text, signal) {
  const pane = panes[key];
  if (!chats[key].length) pane.reset(model);
  pane.modelLabel.textContent = model;
  chats[key].push({ role: 'user', content: text });
  pane.add(el('div', 'msg user', text));
  const out = pane.add(el('div', 'msg', ''));
  pane.setState('generating…', 'running');
  pane.started = Date.now();
  const timer = setInterval(() => pane.setStats(), 1000);
  let reply = '';
  let completed = false;
  let finishReason = null;
  try {
    const response = await api('/v1/chat/completions', {
      method: 'POST', signal, body: JSON.stringify({
        model, ...steeringBody(model), messages: chats[key], stream: true, stream_options: { include_usage: true },
        temperature: 0.7, top_p: 0.8, top_k: 20, max_tokens: 1024, chat_template_kwargs: { enable_thinking: false },
      }),
    });
    if (!response.ok) throw new Error(`${response.status}: ${(await response.text()).slice(0, 300)}`);
    await readSSE(response, (_, raw) => {
      if (raw === '[DONE]') { completed = true; return; }
      const chunk = JSON.parse(raw);
      if (chunk.error) throw new Error(chunk.error.message || String(chunk.error));
      finishReason = chunk.choices?.[0]?.finish_reason || finishReason;
      const delta = chunk.choices?.[0]?.delta?.content;
      if (delta) { reply += delta; out.textContent = reply; pane.log.scrollTop = pane.log.scrollHeight; }
      if (chunk.usage) pane.tokens += chunk.usage.completion_tokens || 0;
    });
    if (!completed || !finishReason) throw new Error('Connection ended before the final result.');
    chats[key].push({ role: 'assistant', content: reply });
    pane.steps += 1;
    pane.setState(finishReason === 'length' ? 'token limit' : 'done', 'finished');
  } catch (error) {
    chats[key].pop();
    if (error.name === 'AbortError') pane.setState('stopped', 'failed');
    else { pane.setState('failed', 'failed'); pane.note(String(error.message || error), true); }
  } finally {
    clearInterval(timer);
    pane.setStats();
  }
}

// ---------- history ----------
async function loadHistory() {
  const list = $('#runs');
  try {
    const ids = await (await api('/agent/runs')).json();
    list.replaceChildren();
    for (const id of ids.slice(-60).reverse()) {
      const item = el('li');
      item.append(el('span', '', id));
      const open = el('button', 'ghost', 'Open');
      open.addEventListener('click', () => openRun(id));
      item.append(open);
      list.append(item);
    }
    if (!ids.length) list.append(el('li', 'muted', 'no runs yet'));
  } catch (error) { list.replaceChildren(el('li', 'error', String(error.message || error))); }
}

async function openRun(id) {
  const record = await (await api(`/agent/runs/${encodeURIComponent(id)}`)).json();
  const key = record.model === $('#model-a').value ? 'a' : 'b';
  const pane = panes[key];
  $('#columns').classList.remove('single');
  pane.reset(`${record.model} · ${id}`);
  let step = 0;
  for (const message of record.messages || []) {
    if (message.role === 'user') pane.add(el('div', 'msg user', message.content));
    else if (message.role === 'assistant') pane.assistant(message, step++);
    else if (message.role === 'tool') pane.tool(message);
  }
  pane.started = record.started * 1000;
  pane.stats.textContent = `${pane.steps} steps · ${Math.round((record.finished - record.started) || 0)}s`;
  pane.setState(`${record.status} · ${record.image}`, record.status === 'finished' ? 'finished' : 'failed');
  pane.root.scrollIntoView?.({ behavior: 'smooth' });
}

// ---------- controls ----------
function setMode(next) {
  mode = next;
  document.querySelectorAll('.tab').forEach((t) => { t.classList.toggle('active', t.dataset.mode === mode); t.setAttribute('aria-selected', String(t.dataset.mode === mode)); });
  document.querySelectorAll('.agent-only').forEach((n) => { n.hidden = mode !== 'agent'; });
  document.querySelectorAll('.chat-only').forEach((n) => { n.hidden = mode !== 'chat'; });
  $('#run').textContent = mode === 'agent' ? 'Run both' : 'Send to both';
  $('#task').placeholder = mode === 'agent'
    ? 'Describe a task. The model works in an isolated, offline sandbox with a bash tool.'
    : 'Ask both models the same question.';
  const box = $('#examples');
  box.replaceChildren();
  for (const [label, text] of EXAMPLES[mode]) {
    const chip = el('button', 'chip', label);
    chip.type = 'button';
    chip.addEventListener('click', () => { $('#task').value = text; });
    box.append(chip);
  }
}

function fillSelect(select, values, preferred) {
  select.replaceChildren(...values.map((v) => { const o = el('option', '', v); o.value = v; return o; }));
  const pick = values.find(preferred);
  if (pick) select.value = pick;
}

function fillImages() {
  const select = $('#image');
  const scratch = el('optgroup'); scratch.label = 'Scratch workspaces';
  const tasks = el('optgroup'); tasks.label = 'Code tasks (repository checkouts)';
  for (const [key, spec] of Object.entries(images)) {
    const option = el('option', '', key); option.value = key;
    (spec.cwd === '/tmp' ? scratch : tasks).append(option);
  }
  select.replaceChildren(scratch, tasks);
  if (images['science-py312']) select.value = 'science-py312';
  showImageNote();
}
function showImageNote() {
  const spec = images[$('#image').value] || {};
  $('#image-note').textContent = [spec.note, spec.cwd && `working directory ${spec.cwd}`].filter(Boolean).join(' · ');
}

async function refreshStatus(models) {
  try {
    const health = await (await api('/healthz')).json();
    $('#status').textContent = `${models ?? health.models.length} models · ${health.sandboxes} live sandboxes`;
  } catch { /* keep the last status */ }
}

async function connect() {
  $('#login-error').textContent = '';
  try {
    const health = await (await api('/healthz')).json();
    const models = (await (await api('/v1/models')).json()).data.map((m) => m.id);
    images = await (await api('/images')).json();
    fillSelect($('#model-a'), models, (m) => m === 'qwen35-4b-native' || (!models.includes('qwen35-4b-native') && /native/.test(m)));
    fillSelect($('#model-b'), models, (m) => m === 'qwen35-4b-steered' || (!models.includes('qwen35-4b-steered') && /rl/.test(m)));
    showSteeringNote();
    fillImages();
    $('#status').textContent = `${models.length} models · ${health.sandboxes} live sandboxes`;
    for (const id of ['#controls', '#columns', '#history']) $(id).hidden = false;
    $('#login').hidden = true;
    loadHistory();
  } catch (error) {
    $('#login').hidden = false;
    $('#login-error').textContent = String(error.message || error);
    $('#status').textContent = 'not connected';
  }
}

function showSteeringNote() {
  $('#steering-note').hidden = ![$('#model-a').value, $('#model-b').value].includes('qwen35-4b-steered');
}

function steeringBody(model) {
  if (model !== 'qwen35-4b-steered') return {};
  const preset = $('#preset').value;
  if (preset === 'lyra' || preset === 'reverse') {
    const sign = preset === 'reverse' ? -1 : 1;
    return { steering: [
      { layer: 14, neuron: 8949, operation: 'add', intensity: sign, calibration: 'prompt' },
      { layer: 13, neuron: 7956, operation: 'add', intensity: -sign, calibration: 'prompt' },
    ] };
  }
  return { steering: { layer: Number($('#layer').value), neuron: Number($('#neuron').value),
    operation: $('#operation').value, intensity: Number($('#intensity').value), calibration: $('#calibration').value } };
}

function updateSteering(event) {
  if (event.target.id !== 'preset') $('#preset').value = 'custom';
  else if ($('#preset').value === 'discovered') {
    for (const [id, value] of Object.entries({ layer: 20, neuron: 8888, intensity: 0.6, operation: 'add', calibration: 'fixed' })) $(`#${id}`).value = value;
  }
  const compound = ['lyra', 'reverse'].includes($('#preset').value);
  for (const id of ['layer', 'neuron', 'operation', 'intensity', 'calibration']) $(`#${id}`).disabled = compound;
  const limit = $('#operation').value === 'multiply' ? 512 : 4;
  $('#intensity').min = -limit; $('#intensity').max = limit;
  const recipe = steeringBody('qwen35-4b-steered').steering;
  const list = Array.isArray(recipe) ? recipe : [recipe];
  $('#recipe-summary').textContent = list.map(h => `L${h.layer} · N${h.neuron} · ${h.operation} ${h.intensity >= 0 && h.operation === 'add' ? '+' : ''}${h.intensity} · ${h.calibration === 'fixed' ? 'fixed reference' : 'current prompt'}`).join(' / ') + '. Applied to the steered model only.';
  // New parameters must not inherit a conversation produced with another recipe.
  for (const key of ['a', 'b']) if ($(`#model-${key}`).value === 'qwen35-4b-steered') {
    chats[key] = []; panes[key].reset($(`#model-${key}`).value); panes[key].setState('new steering');
  }
}

function busy(on) {
  running = on;
  for (const s of ['#model-a', '#model-b', '#single', '#reset-chat', '#image', '#preset', '#layer', '#neuron', '#operation', '#intensity', '#calibration']) $(s).disabled = on;
  document.querySelectorAll('.tab').forEach(t => { t.disabled = on; });
  $('#run').disabled = on;
  $('#stop').disabled = !on;
  if (!on && ['lyra', 'reverse'].includes($('#preset').value)) for (const id of ['layer', 'neuron', 'operation', 'intensity', 'calibration']) $(`#${id}`).disabled = true;
}

async function run() {
  if (running) return;
  const task = $('#task').value.trim();
  if (!task) { $('#task').focus(); return; }
  for (const field of document.querySelectorAll('#steering-note input')) if (!field.reportValidity()) return;
  const single = $('#single').checked;
  $('#columns').classList.toggle('single', single);
  const jobs = single ? ['b'] : ['a', 'b'];
  controllers = jobs.map(() => new AbortController());
  busy(true);
  const model = (key) => $(key === 'a' ? '#model-a' : '#model-b').value;
  if (mode === 'agent') {
    const image = $('#image').value;
    const steps = Math.max(1, Math.min(300, Number($('#steps').value) || 30));
    await Promise.all(jobs.map((k, i) => runAgent(panes[k], model(k), task, image, steps, controllers[i].signal)));
    loadHistory();
  } else {
    $('#task').value = '';
    await Promise.all(jobs.map((k, i) => runChat(k, model(k), task, controllers[i].signal)));
  }
  busy(false);
  refreshStatus();
}

document.addEventListener('DOMContentLoaded', () => {
  setMode('chat');
  for (const id of ['preset', 'layer', 'neuron', 'operation', 'intensity', 'calibration']) $(`#${id}`).addEventListener(['layer', 'neuron', 'intensity'].includes(id) ? 'input' : 'change', updateSteering);
  $('#reconnect').addEventListener('click', connect);
  document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => setMode(t.dataset.mode)));
  $('#image').addEventListener('change', showImageNote);
  $('#run').addEventListener('click', run);
  $('#stop').addEventListener('click', () => { controllers.forEach((c) => c.abort()); });
  $('#reset-chat').addEventListener('click', () => {
    chats.a = []; chats.b = [];
    Object.values(panes).forEach((p) => { p.reset(''); p.setState('idle'); });
  });
  for (const key of ['a', 'b']) $(`#model-${key}`).addEventListener('change', () => {
    chats[key] = []; panes[key].reset($(`#model-${key}`).value); panes[key].setState('new conversation'); showSteeringNote();
  });
  $('#refresh-history').addEventListener('click', loadHistory);
  $('#task').addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) run();
  });
  connect();
});
