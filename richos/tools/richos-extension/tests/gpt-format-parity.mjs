import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { conversationToMarkdown, generateFilename, sanitizeProjectTag } from '../modules/gpt-exporter/export/markdown.js';
import { createBackupJson } from '../modules/gpt-exporter/export/json.js';
import { parseChatGPTConversationUrl } from '../modules/gpt-exporter/lib/chatgpt-url.js';
const root = new URL('../modules/gpt-exporter/', import.meta.url);
const upstream = JSON.parse(await readFile(new URL('UPSTREAM.json', root), 'utf8'));
for (const [name, hash] of Object.entries(upstream.unchangedFiles)) {
  assert.equal(createHash('sha256').update(await readFile(new URL(name, root))).digest('hex'), hash, `${name} matches reviewed standalone source`);
}
assert.equal(upstream.version, '2.2.1');
const conversation = { conversation_id: '12345678-1234-5678-9abc-def012345678', title: '中文 Tëster',
  create_time: 1700000000, update_time: 1700000100, current_node: 'a', _projectName: 'Unicode Project',
  mapping: { r: { id: 'r', parent: null, children: ['u'], message: null },
    u: { id: 'u', parent: 'r', children: ['a'], message: { author: { role: 'user' }, content: { content_type: 'text', parts: ['User content'] }, metadata: {} } },
    a: { id: 'a', parent: 'u', children: [], message: { author: { role: 'assistant' }, content: { content_type: 'text', parts: ['Assistant content'] }, metadata: { model_slug: 'test-model' } } } } };
const markdown = conversationToMarkdown(conversation);
assert.match(markdown.content, /User content/); assert.match(markdown.content, /Assistant content/);
assert.match(markdown.content, /12345678/); assert.match(markdown.content, /中文/);
assert.ok(markdown.filename.endsWith('.md'));
assert.equal(sanitizeProjectTag('Unicode Project'), 'unicode-project');
assert.ok(createBackupJson([conversation]).content.includes(conversation.conversation_id));
assert.equal(parseChatGPTConversationUrl(`https://chatgpt.com/c/${conversation.conversation_id}`).conversationId, conversation.conversation_id);
console.log('PASS pinned standalone formatter/library hashes, Unicode Markdown, JSON and conversation targets');
