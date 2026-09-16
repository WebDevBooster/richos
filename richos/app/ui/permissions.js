"use strict";
// Exact native action requests. Every answer remains scoped by the host to its turn.
(function () {
 const bridge=window.RichBridge;
 const panel=document.createElement("div");panel.id="permission-sheet";panel.className="overlay";panel.hidden=true;
 panel.setAttribute("role","dialog");panel.setAttribute("aria-modal","true");panel.setAttribute("aria-labelledby","permission-title");
 panel.innerHTML=`<div class="overlay-panel overlay-panel--compact"><h2 id="permission-title" class="overlay-title">Allow this action?</h2>
 <p id="permission-scope" class="overlay-note"></p><p id="permission-description" class="overlay-note"></p>
 <pre id="permission-input" class="desk-preview" style="max-height:45vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere"></pre>
 <p id="permission-status" class="overlay-note" role="status">This permission applies only to this action.</p>
 <div class="desk-card-actions"><button id="permission-deny" class="desk-btn" type="button">Decline</button>
 <button id="permission-allow" class="desk-btn desk-btn--confirm" type="button">Allow action</button></div></div>`;
 document.body.appendChild(panel);
 const field=id=>panel.querySelector("#permission-"+id);
 let current=null, answering=false, polling=false, returnFocus=null;
 function hide(){current=null;panel.hidden=true;returnFocus?.focus();returnFocus=null;}
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
   if(current?.id===request.id)return;
   current=request;returnFocus=document.activeElement;
   field("scope").textContent="Company: "+request.binding.entity_id+" · Action: "+request.tool;
   field("description").textContent=[request.description,request.reason].filter(Boolean).join(" ")||"Rich needs permission to run the action shown below.";
   field("input").textContent=JSON.stringify(request.input,null,2);
   field("status").textContent="This permission applies only to this action.";panel.hidden=false;field("deny").focus();
  }catch(error){if(current){field("status").textContent="The action's state could not be verified. Approval is unavailable.";field("allow").disabled=true;}}
  finally{polling=false;}
 }
 field("allow").addEventListener("click",()=>answer(true));field("deny").addEventListener("click",()=>answer(false));
 panel.addEventListener("keydown",event=>{
  if(event.key==="Escape"){event.stopPropagation();answer(false);}
  if(event.key==="Tab"){event.preventDefault();(document.activeElement===field("deny")?field("allow"):field("deny")).focus();}
 });
 setInterval(poll,500);poll();
})();
