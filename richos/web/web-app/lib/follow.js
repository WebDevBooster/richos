// One conversation-follow policy for the PWA and native web view.
(function(root,factory){const value=factory();if(typeof module==='object')module.exports=value;root.RichOSFollow=value;})(globalThis,function(){
  function attach(area, content, latest, {ResizeObserver:Observer=globalThis.ResizeObserver}={}) {
    let following=true, renderedTop=area.scrollTop, renderedGeometry='', touchY=null;
    const geometry=()=>[area.clientWidth,area.clientHeight,area.scrollHeight].join(':');
    const atBottom=()=>area.scrollHeight-area.scrollTop-area.clientHeight<=2;
    const mark=()=>{renderedTop=area.scrollTop;renderedGeometry=geometry();latest.hidden=following;};
    const pin=()=>{area.scrollTop=Math.max(0,area.scrollHeight-area.clientHeight);mark();};
    const resume=()=>{following=true;pin();};
    const pause=()=>{if(area.scrollTop>0){following=false;latest.hidden=false;}};
    const bindings=[];
    const on=(name,fn)=>{area.addEventListener(name,fn,{passive:true});bindings.push([name,fn]);};
    on('wheel',e=>{if(e.deltaY<0)pause();});
    on('touchstart',e=>{touchY=e.touches[0]?.clientY;});
    on('touchmove',e=>{const y=e.touches[0]?.clientY;if(touchY!==null && y>touchY)pause();touchY=y;});
    on('touchend',()=>{touchY=null;});
    on('keydown',e=>{if(['ArrowUp','PageUp','Home'].includes(e.key))pause();});
    on('scroll',()=>{
      if(geometry()!==renderedGeometry){if(following)pin();else mark();return;}
      if(area.scrollTop===renderedTop)return;
      following=atBottom();mark();
    });
    latest.onclick=resume;
    const observer=Observer?new Observer(()=>{if(following)pin();}):null;
    observer?.observe(area);observer?.observe(content);mark();
    return {
      get following(){return following;}, resume, pause, atBottom,
      capture:()=>({top:area.scrollTop,height:area.scrollHeight}),
      restore(before,{force=false,prepend=false}={}){
        if(force)following=true;
        if(following)pin();
        else {area.scrollTop=before.top+(prepend?area.scrollHeight-before.height:0);mark();}
      },
      focus(row){if(!row)return;following=false;row.scrollIntoView({block:'center'});following=atBottom();mark();},
      close(){observer?.disconnect();for(const [name,fn] of bindings)area.removeEventListener(name,fn);}
    };
  }
  return {attach};
});
