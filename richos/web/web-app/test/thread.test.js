'use strict';

// The thread the phone renders — a view of the ledger on his Mac. `node --test "test/*.test.js"`.
//
// The properties asserted here are the ones that keep the phone from being a second record: the
// Mac's cursor is the only order, the Mac's row always wins, and his own optimistic bubble
// disappears the instant the Mac's row for it arrives rather than one repaint later.

const test = require('node:test');
const assert = require('node:assert');

const { createThread } = require('../lib/thread.js');

const row = (over) => Object.assign({
	id: 'm1', thread_id: 't', cursor: 1, role: 'rich', kind: 'text', text: 'On it!',
	created_at: '2026-09-18T10:00:00Z', complete: true
}, over);

test('rows are ordered by the cursor the Mac issued, whatever order they arrive in', () => {
	const thread = createThread();
	thread.merge([row({ id: 'c', cursor: 3 }), row({ id: 'a', cursor: 1 }), row({ id: 'b', cursor: 2 })]);
	assert.deepStrictEqual(thread.view([]).map((m) => m.id), ['a', 'b', 'c']);
});

test('a row with no cursor is dropped rather than placed somewhere invented', () => {
	const thread = createThread();
	thread.merge([row({ id: 'a', cursor: 1 }), { id: 'b', text: 'no cursor' }]);
	assert.deepStrictEqual(thread.view([]).map((m) => m.id), ['a']);
});

test('the clock on this phone orders nothing', () => {
	const thread = createThread();
	// Timestamps that disagree with the cursors — which is what a phone with a wrong clock, or a
	// Mac in another time zone, actually produces.
	thread.merge([
		row({ id: 'later-cursor', cursor: 9, created_at: '2020-01-01T00:00:00Z' }),
		row({ id: 'earlier-cursor', cursor: 2, created_at: '2030-01-01T00:00:00Z' })
	]);
	assert.deepStrictEqual(thread.view([]).map((m) => m.id), ['earlier-cursor', 'later-cursor']);
});

test('the Mac overwrites: a row that arrives again replaces what was held', () => {
	const thread = createThread();
	thread.merge(row({ id: 'm1', text: 'On it!', complete: false }));
	thread.merge(row({ id: 'm1', text: 'On it! Here is the answer.', complete: true }));
	assert.strictEqual(thread.size(), 1);
	assert.strictEqual(thread.get('m1').text, 'On it! Here is the answer.');
	assert.strictEqual(thread.get('m1').complete, true);
});

test('his reply streams in while he watches, and a delta that beats its own row still lands', () => {
	const thread = createThread();
	thread.applyDelta({ message_id: 'm2', cursor: 5, text: 'Looking' });
	thread.applyDelta({ message_id: 'm2', cursor: 5, text: ' at it now' });
	assert.strictEqual(thread.get('m2').text, 'Looking at it now');
	assert.strictEqual(thread.get('m2').complete, false);

	thread.applyState({ message_id: 'm2', complete: true, state: 'done' });
	assert.strictEqual(thread.get('m2').complete, true);
	assert.strictEqual(thread.get('m2').state, 'done');
});

test('a state update for a message this phone has never seen is ignored, not conjured into one', () => {
	const thread = createThread();
	thread.applyState({ message_id: 'unknown', state: 'done' });
	assert.strictEqual(thread.size(), 0);
});

test('his own message appears once: the optimistic bubble goes the moment the Mac row arrives', () => {
	const thread = createThread();
	const pending = [{ clientId: 'c-1', kind: 'text', text: 'where are we?', state: 'sending', queuedAt: '2026-09-18T10:00:00Z' }];

	// Before the Mac has it: one pending bubble, at the bottom.
	let view = thread.view(pending);
	assert.strictEqual(view.length, 1);
	assert.strictEqual(view[0].pending, true);
	assert.strictEqual(view[0].text, 'where are we?');

	// The Mac's own row for the same message, matched on the client id the send carried.
	thread.merge(row({ id: 'server-1', cursor: 10, role: 'ceo', text: 'where are we?', client_id: 'c-1' }));
	view = thread.view(pending);
	assert.strictEqual(view.length, 1, 'his message was shown twice');
	assert.strictEqual(view[0].id, 'server-1');
	assert.strictEqual(view[0].pending, undefined);
	assert.ok(thread.knowsClientId('c-1'));
});

test('waiting messages sit below everything the Mac has, in the order he sent them', () => {
	const thread = createThread();
	thread.merge([row({ id: 'a', cursor: 1 }), row({ id: 'b', cursor: 2 })]);
	const view = thread.view([
		{ clientId: 'c-1', kind: 'text', text: 'first', state: 'waiting', queuedAt: '2026-09-18T10:00:00Z' },
		{ clientId: 'c-2', kind: 'voice', seconds: 3, state: 'waiting', queuedAt: '2026-09-18T10:00:05Z' }
	]);
	assert.deepStrictEqual(view.map((m) => m.id), ['a', 'b', 'pending:c-1', 'pending:c-2']);
	assert.strictEqual(view[3].kind, 'voice');
	assert.strictEqual(view[3].seconds, 3);
});

test('older messages load behind a scroll, and the beginning of the thread is a real end', () => {
	const thread = createThread();
	thread.merge([row({ id: 'e', cursor: 5 }), row({ id: 'f', cursor: 6 })]);
	assert.strictEqual(thread.oldestCursor(), 5);
	assert.strictEqual(thread.atTheBeginning(), false);

	thread.prependOlder({ messages: [row({ id: 'c', cursor: 3 }), row({ id: 'd', cursor: 4 })], more: true });
	assert.deepStrictEqual(thread.view([]).map((m) => m.id), ['c', 'd', 'e', 'f']);
	assert.strictEqual(thread.oldestCursor(), 3);
	assert.strictEqual(thread.atTheBeginning(), false);

	thread.prependOlder({ messages: [row({ id: 'a', cursor: 1 })], more: false });
	assert.strictEqual(thread.atTheBeginning(), true);
	assert.strictEqual(thread.oldestCursor(), 1);
});

test('the latest cursor is what the stream resumes from, so nothing is fetched twice or missed', () => {
	const thread = createThread();
	assert.strictEqual(thread.latestCursor(), null);
	thread.merge([row({ id: 'a', cursor: 4 }), row({ id: 'b', cursor: 11 }), row({ id: 'c', cursor: 7 })]);
	assert.strictEqual(thread.latestCursor(), 11);
});

test('switching threads leaves nothing of the old one behind', () => {
	const thread = createThread();
	thread.merge(row({ id: 'a', cursor: 1, client_id: 'c-1' }));
	thread.reset();
	assert.strictEqual(thread.size(), 0);
	assert.strictEqual(thread.latestCursor(), null);
	assert.strictEqual(thread.oldestCursor(), null);
	assert.strictEqual(thread.knowsClientId('c-1'), false);
	assert.strictEqual(thread.atTheBeginning(), false);
});

test('voice confirmation retires against the transcript hash in either arrival order',async()=>{
 const hash=text=>require('node:crypto').createHash('sha256').update(text).digest('hex');
 for(const projectionFirst of [true,false]){
  const model=createThread(),speech=row({id:'speech',role:'ceo',text:'Quick voice message',cursor:2});
  if(projectionFirst)model.merge(speech);
  model.confirm({clientId:'voice',kind:'voice',seconds:5},{cursor:1,text_sha256:hash(speech.text)});
  if(!projectionFirst){assert.equal(await model.reconcileVoice(hash),false);model.merge(speech);}
  assert.equal(await model.reconcileVoice(hash),true);assert.deepStrictEqual(model.view([]).map(r=>r.id),['speech']);
  assert.equal(await model.reconcileVoice(hash),false);
 }
});
test('unrelated speech cannot retire a voice confirmation',async()=>{
 const model=createThread();model.merge(row({role:'ceo',text:'Other message'}));
 model.confirm({clientId:'voice',kind:'voice'},{cursor:2,text_sha256:'a'.repeat(64)});
 assert.equal(await model.reconcileVoice(()=> 'b'.repeat(64)),false);assert.equal(model.view([]).length,2);
});
