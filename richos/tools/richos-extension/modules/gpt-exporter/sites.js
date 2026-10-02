/** Exact origin boundary, shared by exporter UI and background. */
export function isChatGPTPage(url) {
  try { return new URL(url).origin === 'https://chatgpt.com'; } catch { return false; }
}
