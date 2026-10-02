/**
 * Fixture conversation builders for the branch-trim test.
 *
 * These mirror the real ChatGPT export shape that markdown.js consumes:
 * a `mapping` of node id -> { id, parent, children, message } traversed
 * backwards from `current_node` via `.parent` (see extractMessages in
 * ../markdown.js). Each fixture is a plain JS object with no browser APIs
 * involved, so it can drive markdown.js directly from Node.
 */

function textMessage(role, text, metadata) {
    return {
        author: { role },
        content: { content_type: 'text', parts: [text] },
        metadata: metadata || {}
    };
}

/**
 * A branched conversation: two pre-branch messages, then a branch point,
 * then two post-branch messages. The branch metadata lives on the LAST
 * pre-branch message (branch.metadata on n2), matching how ChatGPT marks
 * the inherited tail of a branched-from conversation.
 */
export function buildBranchedConversation() {
    const mapping = {
        root: { id: 'root', parent: undefined, children: ['n1'], message: null },
        n1: {
            id: 'n1',
            parent: 'root',
            children: ['n2'],
            message: textMessage('user', 'Pre-branch question one.')
        },
        n2: {
            id: 'n2',
            parent: 'n1',
            children: ['n3'],
            message: textMessage('assistant', 'Pre-branch answer one.', {
                branching_from_conversation_id: 'parent-conv-id-123456',
                branching_from_conversation_title: 'RichOS Market Fit'
            })
        },
        n3: {
            id: 'n3',
            parent: 'n2',
            children: ['n4'],
            message: textMessage('user', 'Post-branch question one.')
        },
        n4: {
            id: 'n4',
            parent: 'n3',
            children: [],
            message: textMessage('assistant', 'Post-branch answer one.')
        }
    };

    return {
        title: 'Loro features · RichOS Market Fit',
        conversation_id: '6a8b1379-ea34-83ed-8a15-73192c39bb8e',
        create_time: 1787499662,
        update_time: 1787500000,
        current_node: 'n4',
        mapping
    };
}

/**
 * A non-branched conversation: no node carries branching metadata, so the
 * checkbox must have zero effect on the output either way.
 */
export function buildNonBranchedConversation() {
    const mapping = {
        root: { id: 'root', parent: undefined, children: ['n1'], message: null },
        n1: {
            id: 'n1',
            parent: 'root',
            children: ['n2'],
            message: textMessage('user', 'A regular question, no branch.')
        },
        n2: {
            id: 'n2',
            parent: 'n1',
            children: [],
            message: textMessage('assistant', 'A regular answer, no branch.')
        }
    };

    return {
        title: 'Regular Conversation',
        conversation_id: 'plain-conv-id-abcdef01',
        create_time: 1787499000,
        update_time: 1787499500,
        current_node: 'n2',
        mapping
    };
}
