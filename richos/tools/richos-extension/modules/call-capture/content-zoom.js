/** Zoom keeps the guest meeting URL after the host ends it. Observe its terminal dialog. */
(() => {
  if (!/^\/wc\/(?:join\/)?\d{6,}(?:\/|$)/.test(location.pathname)) return;
  let delivered = false;
  let sending = false;
  const terminal = /(?:this\s+)?meeting\s+(?:has\s+been\s+|was\s+)?ended\s+by\s+(?:the\s+)?host|(?:the\s+)?host\s+(?:has\s+)?ended\s+(?:this\s+|the\s+)?meeting|meeting\s+has\s+ended/i;
  async function check() {
    if (delivered || sending) return;
    const ended = [...document.querySelectorAll('[role="dialog"]')].some(dialog => dialog.getClientRects().length && terminal.test(dialog.textContent || ''));
    if (!ended) return;
    sending = true;
    try {
      const result = await chrome.runtime.sendMessage({target:'sw', module:'callCapture', type:'cc:platform-ended'});
      delivered = Boolean(result?.ok);
    } catch { /* A waking service worker may need the next bounded poll. */ }
    finally { sending = false; }
    if (delivered) { observer.disconnect(); clearInterval(timer); }
  }
  const observer = new MutationObserver(check);
  observer.observe(document.documentElement, {subtree:true, childList:true, characterData:true, attributes:true, attributeFilter:['role','style','class','hidden']});
  const timer = setInterval(check, 1000);
  void check();
})();
