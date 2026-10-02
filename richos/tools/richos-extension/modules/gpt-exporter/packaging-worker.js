/** File/ZIP assembly runs off the recorder's audio and heartbeat thread. */
importScripts('lib/jszip.min.js');
self.onmessage = async ({ data: message }) => {
  try {
    let blob;
    if (message.action === 'create-zip-blob-url') {
      const zip = new JSZip();
      for (const file of message.files) zip.file(file.filename, file.content);
      blob = await zip.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } });
    } else if (message.isBase64) {
      const binary = atob(message.content);
      const bytes = Uint8Array.from(binary, ch => ch.charCodeAt(0));
      blob = new Blob([bytes], { type: message.mimeType });
    } else blob = new Blob([message.content], { type: message.mimeType });
    self.postMessage({ blob });
  } catch (error) { self.postMessage({ error: error.message }); }
};
