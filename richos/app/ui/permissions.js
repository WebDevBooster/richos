"use strict";
(function () {
 const bridge=window.RichBridge;
 const panel=document.createElement("div");panel.id="permission-sheet";panel.className="question-card permission-inline";panel.hidden=true;
 panel.setAttribute("role","group");panel.setAttribute("aria-labelledby","permission-title");

 panel.innerHTML=`<div><h2 id="permission-title" class="overlay-title">Allow this action?</h2>
 <p id="permission-description" class="overlay-note"></p><p id="permission-scope" class="overlay-note"></p>
 <button id="permission-detail" class="desk-btn desk-btn--plain" type="button" aria-expanded="false" aria-controls="permission-input">Show the technical detail</button>
 <pre id="permission-input" class="desk-preview" style="max-height:45vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere" hidden></pre>
 <p id="permission-status" class="overlay-note" role="status">This permission applies only to this action.</p>
 <div class="desk-card-actions"><button id="permission-deny" class="desk-btn" type="button">Decline</button>
 <button id="permission-allow" class="desk-btn desk-btn--confirm" type="button">Allow action</button></div></div>`;
 (document.getElementById("conversation")||document.body).appendChild(panel);
 const field=id=>panel.querySelector("#permission-"+id);
 let current=null, answering=false, polling=false, returnFocus=null;
 const SHOW_DETAIL="Show the technical detail", HIDE_DETAIL="Hide the technical detail";
 function setDetailOpen(open){
  field("input").hidden=!open;
  field("detail").setAttribute("aria-expanded",open?"true":"false");
  field("detail").textContent=open?HIDE_DETAIL:SHOW_DETAIL;
 }
 function hide(){current=null;panel.hidden=true;returnFocus=null;}
 async function answer(allow){
  if(!current||answering)return;
  const requestId=current.id;answering=true;field("allow").disabled=true;field("deny").disabled=true;
  try{await bridge.invoke("answer_permission",{requestId,allow});hide();}
  catch(error){field("status").textContent=String(error);}
  finally{answering=false;field("allow").disabled=false;field("deny").disabled=false;}
 }
 async function poll(){
  if(polling||answering)return;polling=true;
  try{
   const request=await bridge.invoke("pending_permission");
   if(!request){if(current)hide();return;}
   const conversation=document.getElementById("conversation");
   if(conversation && panel.parentElement!==conversation)conversation.appendChild(panel);
   if(current?.id===request.id)return;
   current=request;returnFocus=document.activeElement;
   field("scope").textContent="Company: "+request.binding.entity_id+" · Action: "+request.tool;
   field("description").textContent=[request.description,request.reason].filter(Boolean).join(" ")||"Rich needs permission to run the action shown below.";
   field("input").textContent=JSON.stringify(request.input,null,2);
   setDetailOpen(false);
   field("status").textContent="This action is waiting for your permission. You can keep talking to Rich.";panel.hidden=false;
  }catch(error){if(current){field("status").textContent="The action's state could not be verified. Approval is unavailable.";field("allow").disabled=true;}}
  finally{polling=false;}
 }
 field("allow").addEventListener("click",()=>answer(true));field("deny").addEventListener("click",()=>answer(false));
 field("detail").addEventListener("click",()=>setDetailOpen(field("input").hidden));
 panel.addEventListener("keydown",event=>{
  if(event.key==="Escape"){event.preventDefault();event.stopPropagation();document.getElementById("input")?.focus();}
 });
 setInterval(poll,500);poll();
})();
