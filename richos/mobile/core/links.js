(function (root, factory) {
  const value = factory(typeof module === 'object' ? require('../../web/web-app/lib/inbound.js') : root.RichOSInbound);
  if (typeof module === 'object') module.exports = value;
  root.RichOSMobileLinks = value;
})(globalThis, function (Inbound) {
  function destination(value, universalHosts = []) {
    if (typeof value !== 'string' || value.length > 4096 || /[\s\\]/.test(value)) throw Error('Invalid conversation link');
    const url = new URL(value);
    const allowed = (url.protocol === 'richos:' && url.hostname === 'conversation') || (url.protocol === 'https:' && universalHosts.includes(url.hostname));
    if (!allowed || url.username || url.password || url.port || url.pathname !== '/' || url.search) throw Error('Unrecognized conversation link');
    const result = Inbound.validateNavigate('/' + url.hash);
    if (!result.ok) throw Error(result.reason);
    const params = new URLSearchParams(result.value.split('#')[1] || '');
    return { threadId: params.get('thread'), messageId: params.get('at') };
  }
  return { destination };
});
