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
  return {find};
});
