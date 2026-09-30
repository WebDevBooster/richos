// A tiny valid RGB PNG in `lib/png.js`'s accepted shape, for fixtures that need a picture that
// differs from a committed reference. Different `value` gives a different picture.

"use strict";

const zlib = require("zlib");

function tinyPng(value) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(4, 0);
  ihdr.writeUInt32BE(4, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const raw = Buffer.alloc(4 * (4 * 3 + 1));
  let p = 0;
  for (let y = 0; y < 4; y++) {
    raw[p++] = 0;
    for (let x = 0; x < 12; x++) raw[p++] = (value + x * 17 + y * 5) & 0xff;
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    return Buffer.concat([len, Buffer.from(type, "ascii"), data, Buffer.alloc(4)]);
  };
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

module.exports = { tinyPng };
