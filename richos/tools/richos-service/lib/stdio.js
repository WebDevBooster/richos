/**
 * RichOS local service — Chrome native-messaging stdio framing.
 *
 * Chrome frames every message as a 4-byte length prefix (native byte order — little-endian on
 * every platform Chrome ships on) followed by that many bytes of UTF-8 JSON. Messages to the host
 * arrive on stdin; messages to Chrome go to stdout. The 1 MB/message cap is irrelevant for the
 * few-KB Opus chunks the contract streams (the system architecture §5.1).
 *
 * The encode/decode functions are PURE (Buffer in / Buffer out) so the framing is node-testable
 * without a real pipe. `NativeChannel` wraps a readable+writable stream pair for the live host.
 */

import { EventEmitter } from 'node:events';

export const MAX_MESSAGE_BYTES = 1024 * 1024;

/**
 * Encode one message object into a length-prefixed frame.
 * @param {any} message
 * @returns {Buffer}
 */
export function encodeMessage(message) {
  const json = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(json.length, 0);
  return Buffer.concat([header, json]);
}

/**
 * A streaming frame decoder. Feed it arbitrary chunks; it yields complete messages.
 */
export class FrameDecoder {
  constructor() {
    this._buf = Buffer.alloc(0);
  }

  /**
   * @param {Buffer} chunk
   * @returns {any[]} zero or more decoded messages
   */
  push(chunk) {
    this._buf = Buffer.concat([this._buf, chunk]);
    const out = [];
    while (this._buf.length >= 4) {
      const len = this._buf.readUInt32LE(0);
      if (len > MAX_MESSAGE_BYTES) throw new Error(`native message too large: ${len} bytes`);
      if (this._buf.length < 4 + len) break;
      const json = this._buf.subarray(4, 4 + len).toString('utf8');
      this._buf = this._buf.subarray(4 + len);
      out.push(JSON.parse(json));
    }
    return out;
  }
}

/**
 * Live native-messaging channel over a readable (stdin) + writable (stdout).
 * Emits `message` per decoded message and `end` when the peer closes the pipe.
 */
export class NativeChannel extends EventEmitter {
  /**
   * @param {NodeJS.ReadableStream} input
   * @param {NodeJS.WritableStream} output
   */
  constructor(input, output) {
    super();
    this._output = output;
    this._decoder = new FrameDecoder();
    input.on('data', (chunk) => {
      try {
        for (const message of this._decoder.push(chunk)) this.emit('message', message);
      } catch (err) {
        this.emit('error', err);
      }
    });
    input.on('end', () => this.emit('end'));
    input.on('close', () => this.emit('end'));
  }

  /** @param {any} message */
  send(message) {
    this._output.write(encodeMessage(message));
  }
}
