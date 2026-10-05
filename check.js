// Run: node check.js
const assert = require('assert');
const { parseSSE, splitThink, titleFrom, buildMessages, accToolCalls, parseToolCalls } = require('./lib.js');

// An event split across two network chunks is held back, then completed.
let r = parseSSE('data: {"a":1}\n\ndata: {"b"');
assert.deepStrictEqual(r.events, [{ a: 1 }]);
r = parseSSE(r.rest + ':2}\n\ndata: [DONE]\n');
assert.deepStrictEqual(r.events, [{ b: 2 }, { done: true }]);
assert.strictEqual(r.rest, '');

assert.deepStrictEqual(splitThink('<think>hmm'), { think: 'hmm', answer: '', thinking: true });
assert.deepStrictEqual(splitThink('<think> plan </think>\n\nHi'), { think: 'plan', answer: 'Hi', thinking: false });
assert.deepStrictEqual(splitThink('plain'), { think: '', answer: 'plain', thinking: false });

assert.strictEqual(titleFrom('  hello\n world '), 'hello world');
assert.ok(titleFrom('x'.repeat(80)).length <= 49);

assert.deepStrictEqual(buildMessages(' be brief ', [{ role: 'user', content: 'q' }, { role: 'assistant', content: '' }]),
  [{ role: 'system', content: 'be brief' }, { role: 'user', content: 'q' }]);

// Tool calls arrive split across streaming deltas and must reassemble by index.
let acc = [];
accToolCalls(acc, { tool_calls: [{ index: 0, id: 'c1', function: { name: 'web_sea' } }] });
accToolCalls(acc, { tool_calls: [{ index: 0, function: { arguments: '{"que' } }] });
accToolCalls(acc, { tool_calls: [{ index: 0, function: { name: 'rch', arguments: 'ry":"hi"}' } }] });
assert.strictEqual(acc.length, 1);
assert.strictEqual(acc[0].id, 'c1');
assert.strictEqual(acc[0].function.name, 'web_search');
assert.deepStrictEqual(JSON.parse(acc[0].function.arguments), { query: 'hi' });

// Text fallback for models that print tool calls inline.
const tc = parseToolCalls('sure <tool_call>{"name":"run_command","arguments":{"command":"ls"}}</tool_call> done');
assert.strictEqual(tc.length, 1);
assert.strictEqual(tc[0].function.name, 'run_command');
assert.deepStrictEqual(JSON.parse(tc[0].function.arguments), { command: 'ls' });
assert.strictEqual(parseToolCalls('no calls here').length, 0);

console.log('ok');
