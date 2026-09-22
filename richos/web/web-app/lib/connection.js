// Shared connection diagnosis. This never changes pairing, history or queue ownership.
(function(root,factory) {
  const value=factory(); if(typeof module==='object') module.exports=value; root.RichOSConnection=value;
})(globalThis,function() {
  const service='https://connect.richos.ceo/healthz';
  function managed(origin) { return /^https:\/\/c-[a-f0-9]{32}-g[1-9][0-9]*\.richos\.ceo$/.test(origin || ''); }
  function classify({connected,revoked,unsupported,phoneOnline,serviceState}) {
    if(revoked) return 'revoked';
    if(unsupported) return 'incompatible';
    if(connected) return 'connected';
    if(phoneOnline===false) return 'phone-offline';
    if(serviceState==='unavailable') return 'service-unavailable';
    return 'mac-unreachable';
  }
  async function probe(ports) {
    if(ports.online?.()===false) return {phoneOnline:false};
    try {
      const response=await ports.fetch(service,{redirect:'error',cache:'no-store',credentials:'omit',signal:AbortSignal.timeout(6000)});
      const body=await response.json();
      return {serviceState:response.status===200 && body.service==='richos-connect' && body.ready===true ? 'available' : 'unavailable'};
    } catch { return {serviceState:'unknown'}; }
  }
  function sentence(reason) {
    return {
      connected:'Connected to your Mac',
      'phone-offline':'Your phone has no internet connection. Messages stay on this phone.',
      'service-unavailable':'RichOS Connect is temporarily unavailable. Messages stay on this phone.',
      'mac-unreachable':'Your Mac cannot be reached. Keep it awake with RichOS running. Messages stay on this phone.',
      revoked:'This phone was removed from your Mac. Pair it again to reconnect.',
      incompatible:'This Mac needs a newer RichOS app. Your queued messages are kept.',
    }[reason] || 'Connecting to your Mac…';
  }
  return {managed,classify,probe,sentence};
});
