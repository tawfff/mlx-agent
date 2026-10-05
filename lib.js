// Pure helpers shared by index.html and check.js.

// Split a raw SSE buffer into complete JSON events plus the unfinished tail.
function parseSSE(buf) {
  const events = [];
  const parts = buf.split('\n');
  const rest = parts.pop();
  for (const line of parts) {
    const s = line.trim();
    if (!s.startsWith('data:')) continue;
    const payload = s.slice(5).trim();
    if (payload === '[DONE]') { events.push({ done: true }); continue; }
    try { events.push(JSON.parse(payload)); } catch { /* keep-alive or partial noise */ }
  }
  return { events, rest };
}

// Some models put reasoning inside <think> tags in the answer instead of a
// separate reasoning_content field. Pull it out so it renders the same way.
function splitThink(text) {
  const open = text.indexOf('<think>');
  if (open === -1) return { think: '', answer: text, thinking: false };
  const close = text.indexOf('</think>', open);
  if (close === -1) return { think: text.slice(open + 7), answer: text.slice(0, open), thinking: true };
  return { think: text.slice(open + 7, close).trim(), answer: (text.slice(0, open) + text.slice(close + 8)).trim(), thinking: false };
}

function titleFrom(text) {
  const t = text.replace(/\s+/g, ' ').trim();
  return t.length > 48 ? t.slice(0, 46).trimEnd() + '...' : t || 'New chat';
}

function buildMessages(system, msgs) {
  const out = system && system.trim() ? [{ role: 'system', content: system.trim() }] : [];
  for (const m of msgs) if (m.content) out.push({ role: m.role, content: m.content });
  return out;
}

// Merge a streaming delta's tool_calls into an accumulator keyed by index.
// Returns the accumulator so callers can keep a running array.
function accToolCalls(acc, delta) {
  for (const tc of delta.tool_calls || []) {
    const i = tc.index ?? acc.length;
    const slot = (acc[i] ||= { id: '', type: 'function', function: { name: '', arguments: '' } });
    if (tc.id) slot.id = tc.id;
    if (tc.function?.name) slot.function.name += tc.function.name;
    if (tc.function?.arguments) slot.function.arguments += tc.function.arguments;
  }
  return acc;
}

// Fallback: some local models emit tool calls as <tool_call>{...}</tool_call> text
// in the content instead of the structured field. Pull those out.
function parseToolCalls(text) {
  const calls = [];
  for (const m of text.matchAll(/<tool_call>\s*(\{[\s\S]*?\})\s*<\/tool_call>/g)) {
    try {
      const j = JSON.parse(m[1]);
      const args = j.arguments ?? j.parameters ?? {};
      calls.push({ id: 'call_' + calls.length, type: 'function', function: { name: j.name, arguments: typeof args === 'string' ? args : JSON.stringify(args) } });
    } catch { /* partial */ }
  }
  return calls;
}

if (typeof module !== 'undefined') module.exports = { parseSSE, splitThink, titleFrom, buildMessages, accToolCalls, parseToolCalls };
