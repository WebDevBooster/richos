// Resolve a notification through the same authenticated history API in both clients.
(function(root,factory){const value=factory();if(typeof module==='object')module.exports=value;root.RichOSNotificationTarget=value;})(globalThis,function(){
  async function find({model,matches,fetchPage,isCurrent=()=>true}) {
    const match=async rows=>{for(const row of rows)if(await matches(row))return row;return null;};
    let found=await match(model.view([]));
    while(!found && isCurrent() && !model.atTheBeginning()) {
      const before=model.oldestCursor() ?? Number.MAX_SAFE_INTEGER;
      const page=await fetchPage(before);
      if(!isCurrent())return null;
      model.prependOlder(page);
      found=await match(model.view([]));
      // A malformed or stale page must not cause an endless request loop.
      if(!found && (model.oldestCursor()===null || model.oldestCursor()>=before))break;
    }
    return isCurrent()?found:null;
  }
  function receipts(send) {
    const acknowledged=new Set(),pending=new Set();
    return async function observe(thread,rows,visible) {
      if(!visible || !thread)return;
      const row=[...rows].reverse().find(r=>r.role==='rich' && r.complete!==false && r.id);
      if(!row)return;
      const key=JSON.stringify([thread,row.id]);
      if(acknowledged.has(key) || pending.has(key))return;
      pending.add(key);
      try {await send(thread,row.id);acknowledged.add(key);if(acknowledged.size>64)acknowledged.delete(acknowledged.values().next().value);}
      catch { /* Retry on the next render or foreground return. A missed receipt permits push. */ }
      finally {pending.delete(key);}
    };
  }
  return {find,receipts};
});
