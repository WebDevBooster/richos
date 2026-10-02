/** Stored ZIP archive. One explicit download carries a complete portable session directory. */
const encoder = new TextEncoder();
const crcTable = Array.from({ length: 256 }, (_, value) => {
  for (let i = 0; i < 8; i++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function header(size, signature) {
  const bytes = new Uint8Array(size);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, signature, true);
  return { bytes, view };
}
export function sessionZip(entries) {
  if (entries.length > 65535) throw new Error('Too many archive entries');
  const chunks = [], directory = [];
  let offset = 0, directoryBytes = 0;
  const names = new Set();
  for (const entry of entries) {
    if (!entry.name || entry.name.startsWith('/') || entry.name.includes('\\') || entry.name.split('/').some(p => !p || p === '..' || p === '.') || names.has(entry.name)) throw new Error('Unsafe or duplicate archive path');
    names.add(entry.name);
    const name = encoder.encode(entry.name);
    const data = typeof entry.data === 'string' ? encoder.encode(entry.data) : new Uint8Array(entry.data);
    if (name.length > 65535 || data.length >= 0xffffffff || offset + data.length + name.length + 30 >= 0xffffffff) throw new Error('Archive exceeds ZIP32 limits');
    const crc = crc32(data);
    const local = header(30, 0x04034b50);
    local.view.setUint16(4, 20, true); local.view.setUint16(6, 0x800, true);
    local.view.setUint32(14, crc, true); local.view.setUint32(18, data.length, true); local.view.setUint32(22, data.length, true);
    local.view.setUint16(26, name.length, true);
    chunks.push(local.bytes, name, data);
    const central = header(46, 0x02014b50);
    central.view.setUint16(4, 20, true); central.view.setUint16(6, 20, true); central.view.setUint16(8, 0x800, true);
    central.view.setUint32(16, crc, true); central.view.setUint32(20, data.length, true); central.view.setUint32(24, data.length, true);
    central.view.setUint16(28, name.length, true); central.view.setUint32(42, offset, true);
    directory.push(central.bytes, name);
    directoryBytes += 46 + name.length;
    offset += 30 + name.length + data.length;
  }
  if (offset + directoryBytes + 22 >= 0xffffffff) throw new Error('Archive exceeds ZIP32 limits');
  const end = header(22, 0x06054b50);
  end.view.setUint16(8, entries.length, true); end.view.setUint16(10, entries.length, true);
  end.view.setUint32(12, directoryBytes, true); end.view.setUint32(16, offset, true);
  return new Blob([...chunks, ...directory, end.bytes], { type: 'application/zip' });
}
