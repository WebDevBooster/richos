"use strict";
// Exact native action requests. Every answer remains scoped by the host to its turn.
(function () {
 const bridge=window.RichBridge;
 const panel=document.createElement("div");panel.id="permission-sheet";panel.className="overlay";panel.hidden=true;
 panel.setAttribute("role","dialog");panel.setAttribute("aria-modal","true");panel.setAttribute("aria-labelledby","permission-title");
 // ESCAPE DECLINES, FROM ANYWHERE (CEO, 2026-09-17, item 1). The keydown listener below is on
 // the PANEL, so it only ever fired while focus was inside it — true on open, false the moment
 // a click lands anywhere else, and then the sheet could not be closed from the keyboard at
 // all. `data-dismiss` hands the same act to main.js's document-level handler: not a second
 // implementation of "decline", the button itself. A permission request has exactly one safe
 // way out and it is Decline; nothing here may hide the question without answering it.
 panel.setAttribute("data-dismiss","control:#permission-deny");
 // WHAT HE IS BEING ASKED, FIRST — AND THE RAW FORM BEHIND A DOOR (audit-9 row 5).
 //
 // Ray, walking candidate .9: the sheet put a shell command line, inside a JSON object, with
 // escaped quotes and a backslash alternation, in a small scrollable box, in front of a man who
 // is not going to read it — and the one line he CAN judge, the description, sat underneath it.
 //
 //     {
 //       "command": "cd /private/tmp/.../qa-fixture-repo && git log --oneline -5 --all && echo
 //       --- && git status --short && echo --- && grep -in \"nine\\|eight\" notes.txt; git branch -a",
 //       "description": "Check the fixture repo's history and notes file"
 //     }
 //
 // So the order is inverted here and the `<pre>` starts closed. NOTHING IS HIDDEN FROM HIM: the
 // exact request is one press away, the press is a real `<button>` with `aria-expanded`, and the
 // text is in the document either way — `textContent` reads it closed, which is how
 // `tests/permissions.js` still proves the input was not interpreted as markup.
 //
 // THE CONTROL CARRIES NO BORDER, deliberately. `.desk-btn`'s border is `var(--line)`, which is
 // `--line-strong` — computed against the panel's own `--surface` (= `--card`) it is 1.24:1 in
 // dark and 1.50:1 in light, both under the 3:1 floor a non-text indicator has to clear. Every
 // other `.desk-btn` in the app has that border today and that is a row for somebody to take;
 // this control is new, so it does not add another one. What identifies it instead is its label
 // — `--ink-soft` on `--surface`, 5.78:1 dark and 6.38:1 light, both over the 4.5:1 floor — and
 // `.desk-btn:focus-visible`'s 2px `--accent` ring, 6.36:1 dark and 3.83:1 light against the
 // same panel, both over 3:1. Computed, not eyeballed.
 panel.innerHTML=`<div class="overlay-panel overlay-panel--compact"><h2 id="permission-title" class="overlay-title">Allow this action?</h2>
 <p id="permission-description" class="overlay-note"></p><p id="permission-scope" class="overlay-note"></p>
 <button id="permission-detail" class="desk-btn desk-btn--plain" type="button" aria-expanded="false" aria-controls="permission-input">Show the technical detail</button>
 <pre id="permission-input" class="desk-preview" style="max-height:45vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere" hidden></pre>
 <p id="permission-status" class="overlay-note" role="status">This permission applies only to this action.</p>
 <div class="desk-card-actions"><button id="permission-deny" class="desk-btn" type="button">Decline</button>
 <button id="permission-allow" class="desk-btn desk-btn--confirm" type="button">Allow action</button></div></div>`;
 document.body.appendChild(panel);
 const field=id=>panel.querySelector("#permission-"+id);
 let current=null, answering=false, polling=false, returnFocus=null;
 // BOTH LABELS SAY WHAT THE PRESS DOES, and both survive being spoken aloud.
 const SHOW_DETAIL="Show the technical detail", HIDE_DETAIL="Hide the technical detail";
 function setDetailOpen(open){
  field("input").hidden=!open;
  field("detail").setAttribute("aria-expanded",open?"true":"false");
  field("detail").textContent=open?HIDE_DETAIL:SHOW_DETAIL;
 }
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
   // CLOSED FOR EVERY NEW REQUEST. A disclosure left open by the last question would show him
   // the raw form of a question he has not read yet, which is the thing this row is about.
   setDetailOpen(false);
   field("status").textContent="This permission applies only to this action.";panel.hidden=false;field("deny").focus();
  }catch(error){if(current){field("status").textContent="The action's state could not be verified. Approval is unavailable.";field("allow").disabled=true;}}
  finally{polling=false;}
 }
 field("allow").addEventListener("click",()=>answer(true));field("deny").addEventListener("click",()=>answer(false));
 field("detail").addEventListener("click",()=>setDetailOpen(field("input").hidden));
 panel.addEventListener("keydown",event=>{
  if(event.key==="Escape"){event.stopPropagation();answer(false);}
  // THE RING IS THREE CONTROLS NOW, NOT TWO. The trap used to flip between Decline and Allow;
  // leaving the disclosure out of it would put the exact request one press away for a mouse and
  // out of reach entirely for a keyboard, which is worse than not offering it.
  if(event.key==="Tab"){
   event.preventDefault();
   const ring=[field("deny"),field("allow"),field("detail")];
   const at=ring.indexOf(document.activeElement);
   const step=event.shiftKey?-1:1;
   ring[(at<0?0:at+step+ring.length)%ring.length].focus();
  }
 });
 setInterval(poll,500);poll();
})();
