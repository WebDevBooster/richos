// ax.js — the guest's accessibility tree, and the press that drives it.
//
// Run INSIDE the guest, by ax.sh, as:
//
//     <the AX_PARAMS block> + this file  |  osascript -l JavaScript -
//
// ax.js never parses arguments. ax.sh prepends one line — `var AX_PARAMS =
// {...};` — and the whole text travels on stdin, so nothing here is ever
// interpolated into a remote command line.
//
// It prints ONE JSON OBJECT PER LINE. The first is `{"meta":true,...}`; every
// line after it is a node, a `{"clicked":...}` or an `{"error":...}`. The host
// renders them; the guest decides nothing about formatting.
//
// ===========================================================================
// WHY JAVASCRIPT AND NOT APPLESCRIPT — THE GEOMETRY IS THE WHOLE REASON
// ===========================================================================
// AppleScript renders a list as a string by CONCATENATING its items. MEASURED
// on this Mac (macOS 15.6), 2026-09-20:
//
//     $ osascript -e 'set sz to {1024, 700}' -e 'return (sz as string)'
//     1024700
//
// A 1024x700 window and a 102x4700 one are the same six characters. A tree that
// prints geometry that way is WORSE than one that prints none, because it
// prints a number that looks right — and the app derives a 1024x700 window in
// this very guest (docs/testvm.md), so that is not a hypothetical pair.
//
// AppleScript can be made to punctuate the items by hand (`item 1 of sz`, which
// is what ax.sh's own --windows does), and every walk that forgot to got a
// fused number. JavaScript for Automation returns a REAL ARRAY from position()
// and size(), and ships JSON.stringify, so the four numbers are never adjacent
// in the first place. Measured the same day, same Mac:
//
//     $ osascript -l JavaScript /tmp/t.js        // return JSON.stringify([1024,700])
//     [1024,700]
//
// The host renderer still REFUSES a fused token if one ever reaches it. A
// structural fix plus a check for the fix having held is the shape this harness
// uses everywhere else.
//
// ===========================================================================
// WHY A PRESS AND NOT A CLICK AT COORDINATES
// ===========================================================================
// `el.actions["AXPress"].perform()` sends the press to the ELEMENT. It does not
// care where the element is, whether the window moved, whether the app is
// frontmost, or whether something is drawn over it. A coordinate click cares
// about all four, and three of them change between one run and the next.
// `--at x,y` exists for the controls that expose no AXPress, and it refuses
// unless the target process is frontmost — the same discipline ax.sh's --key
// has carried since a synthetic key landed in the wrong process on 2026-09-19.
//
// ===========================================================================
// EVERY AX CALL IS WRAPPED, BECAUSE EVERY AX CALL THROWS
// ===========================================================================
// An accessibility attribute an element does not implement raises rather than
// returning empty, and a tree walk that lets one of those escape stops at the
// first unusual node — which on a Tauri window is roughly immediately. Each
// read is its own try/catch with its own default.

// ---------------------------------------------------------------------------
// THE MATCHER — top level, and exported, so it is TESTED and not just asserted
// ---------------------------------------------------------------------------
// TEXT MATCHES TITLE **OR** DESCRIPTION. An aria-label on a web view's control
// surfaces as AXDescription and not as AXTitle, which is why the THIRD rewrite
// of the same press script was the one that finally found the theme buttons:
// `axpress.js` matched the title, `axpress2.js` added a role filter and still
// reported NOTFOUND on buttons that were plainly on the screen, and
// `axpress3.js` added the description. Matching the title alone is the defect,
// not a simplification.
//
// These two are outside run() because run() needs System Events and a guest,
// and this rule needs neither: the test suite loads this file in node and drives
// them directly. A rule that cost three rewrites is worth a test rather than a
// comment.
function axTextHit(P, hay, want) {
  if (!hay) return false;
  return P.contains ? (hay.indexOf(want) >= 0) : (hay === want);
}

function axMatches(P, n) {
  if (P.role && n.role !== P.role) return false;
  if (P.sub && n.sub !== P.sub) return false;
  if (P.text !== null && P.text !== undefined) {
    if (!axTextHit(P, n.title, P.text) && !axTextHit(P, n.desc, P.text)) return false;
  }
  if (P.value !== null && P.value !== undefined) {
    if (!axTextHit(P, n.value, P.value)) return false;
  }
  return true;
}

// Breadth-first search reaches controls beside a long transcript before walking
// every message. Matching reads only the attributes actually requested.
function axSearch(roots, P, api) {
  var queue = roots.map(function(e) { return {el:e, d:0, parent:null}; });
  var head = 0, count = 0, hits = [], shallow = [], truncated = false, stoppedEarly = false;
  var limit = P.first ? 1 : (P.nth !== null && P.nth !== undefined ? P.nth + 1 : null);
  var scoped = !P.scope || P.scope === "window";
  while (head < queue.length) {
    if (count >= P.max) { truncated = true; break; }
    var q = queue[head++]; count++;
    if (q.d <= 5 && shallow.length < 64) shallow.push(q);
    if (!scoped) {
      if (api.scope(q.el, P.scope)) {
        // A composer is its containing group, including adjacent controls.
        queue = [{el:api.scopeRoot ? api.scopeRoot(q.el,q.parent,P.scope) : q.el, d:0, parent:null}];
        head = 0; scoped = true; continue;
      }
    } else if (P.mode === "tree" || api.matches(q.el)) {
      hits.push(q);
      if (limit !== null && hits.length >= limit) { stoppedEarly = true; break; }
    }
    if (q.d < P.depth) {
      var kids = api.children(q.el);
      for (var i=0; i<kids.length; i++) queue.push({el:kids[i], d:q.d+1, parent:q.el});
    } else if (api.children(q.el).length) {
      truncated = true;
    }
  }
  return {hits:hits, shallow:shallow, count:count, truncated:truncated, scoped:scoped,
          exhaustive:head >= queue.length && !truncated && !stoppedEarly};
}

function run() {
  var P = AX_PARAMS, se = Application("System Events"), proc, wins;
  function get(el, attr, fallback) { try { return el[attr](); } catch(e) { return fallback; } }
  function attr(el, name, fallback) { try { return el.attributes.byName(name).value(); } catch(e) { return fallback; } }
  function error(code, detail) { return JSON.stringify({error:code, detail:String(detail)}); }
  try {
    proc = P.app ? se.processes.byName(P.app) : se.processes.whose({unixId:P.pid})[0];
    P.pid = proc.unixId();
  } catch(e) { return error("noprocess", "target process is absent"); }
  var name = proc.name();
  // Diagnose the common blocking system dialog before entering the app's tree.
  if (name !== "SecurityAgent") {
    try {
      var security = se.processes.byName("SecurityAgent");
      if (security.exists() && security.windows().length) return error("blocked", "SecurityAgent has a keychain dialog; target="+name+" pid="+P.pid);
    } catch(e) {}
  }
  try { wins = proc.windows(); } catch(e) { return error("blocked", e); }
  var roots = wins;
  if (P.window) roots = wins.length >= P.window ? [wins[P.window-1]] : [];
  if (P.windowTitle) roots = roots.filter(function(w) { return get(w,"name","") === P.windowTitle; });
  if (!roots.length) return error("nowindow", "target="+name+" pid="+P.pid+" windows="+wins.length);

  function front() { try { return se.processes.whose({frontmost:true})[0].unixId() === P.pid; } catch(e) { return false; } }
  if (P.mode === "clickat") {
    if (!front()) return error("notfrontmost", "coordinate click would land in another process");
    // JXA's click({at:...}) cannot coerce this command's direct parameter.
    // Run the supported AppleScript form with numeric data only.
    var app = Application.currentApplication(); app.includeStandardAdditions = true;
    try { app.doShellScript("osascript -e 'tell application \"System Events\" to click at {"+P.atx+", "+P.aty+"}'"); }
    catch(e) { return error("clickfailed", e); }
    return JSON.stringify({clicked:true, at:true, x:P.atx, y:P.aty});
  }
  function match(el) {
    if (P.role && get(el,"role","") !== P.role) return false;
    if (P.sub && get(el,"subrole","") !== P.sub) return false;
    if (P.text !== null && !axTextHit(P, get(el,"title",""), P.text) && !axTextHit(P, get(el,"description",""), P.text)) return false;
    if (P.value !== null && !axTextHit(P, String(get(el,"value","")), P.value)) return false;
    return true;
  }
  function scope(el, which) {
    var role = get(el,"role","");
    if (which === "dialog") return role === "AXSheet" || (role === "AXGroup" && get(el,"subrole","") === "AXApplicationDialog");
    if (which === "composer") return role === "AXTextArea" || (role === "AXGroup" && attr(el,"AXDOMIdentifier","") === "composer");
    if (which === "sidebar") return role === "AXGroup" && (get(el,"description","") === "Entities and threads" || attr(el,"AXDOMIdentifier","") === "rail");
    return false;
  }
  function full(q) {
    var el=q.el, pos=get(el,"position",[]), size=get(el,"size",[]);
    return {d:q.d,role:get(el,"role",""),sub:get(el,"subrole",""),title:get(el,"title",""),
      desc:get(el,"description",""),value:String(get(el,"value","")).slice(0,203),enabled:get(el,"enabled",null),current:attr(el,"AXARIACurrent",null),selected:get(el,"selected",null),
      x:pos[0],y:pos[1],w:size[0],h:size[1]};
  }
  function missing(detail) {
    // A modal web dialog hides the underlying composer from the AX tree.
    // Inspect the focused element's ancestors only on a miss, avoiding an
    // extra attribute read on every transcript node during successful lookups.
    var focused=attr(proc,"AXFocusedUIElement",null);
    for (var level=0; focused && level<10; level++) {
      if (get(focused,"subrole","") === "AXApplicationDialog" ||
          get(focused,"role","") === "AXSheet") {
        return error("blocked", "target="+name+" modal="+get(focused,"title",get(focused,"description","dialog"))+"; "+detail);
      }
      focused=attr(focused,"AXParent",null);
    }
    // A background webview may have no AXFocusedUIElement. Its dialog is a
    // shallow ancestor of the visible controls already visited by the search.
    for (var i=0; i<result.shallow.length; i++) {
      var q=result.shallow[i];
      if (get(q.el,"subrole","") === "AXApplicationDialog" ||
          (q.d<=1 && get(q.el,"role","") === "AXSheet")) {
        return error("blocked", "target="+name+" modal="+get(q.el,"title","dialog")+"; "+detail);
      }
    }
    return error("notfound",detail);
  }
  var result = axSearch(roots, P, {matches:match, scope:scope, scopeRoot:function(el,parent,which) { return which === "composer" && get(el,"role","") === "AXTextArea" && parent ? parent : el; }, children:function(el) { return get(el,"uiElements",[]); }});
  var hits = result.hits;
  var meta = JSON.stringify({meta:true,app:name,pid:P.pid,windows:wins.length,nodes:result.count,
    truncated:result.truncated,mode:P.mode,matches:hits.length,exhaustive:result.exhaustive});
  if (!result.scoped) return meta+"\n"+missing("scope is absent: "+P.scope);
  if (result.truncated) return meta+"\n"+error("incomplete", "node/depth cap reached; absence or uniqueness is not established");
  if (P.mode === "tree") return meta+"\n"+hits.map(function(q) { return JSON.stringify(full(q)); }).join("\n");
  if (!hits.length) return meta+"\n"+missing("nothing matched");
  if (P.mode === "find") {
    if (P.nth !== null) hits = hits.slice(P.nth,P.nth+1);
    if (!hits.length) return meta+"\n"+error("notfound", "requested match index is absent");
    return meta+"\n"+hits.map(function(q) { return JSON.stringify(full(q)); }).join("\n");
  }
  if (!P.first && P.nth === null && hits.length !== 1) return meta+"\n"+error("ambiguous", "multiple matches; specify --first or --nth (zero based)");
  var target = hits[P.nth || 0];
  if (!target) return meta+"\n"+error("notfound", "requested match index is absent");
  var el=target.el;
  try {
    if (!get(el,"enabled",false)) return meta+"\n"+error("disabled", "matched element is disabled");
    if (P.mode === "click") {
      var actions=el.actions().map(function(a) { return a.name(); });
      if (actions.indexOf("AXPress") < 0) return meta+"\n"+error("noaction", "element has no AXPress; actions="+actions.join(","));
      var pressedNode=full(target); // A dismissal can invalidate this AX node.
      el.actions.byName("AXPress").perform();
      return meta+"\n"+JSON.stringify({clicked:true,node:pressedNode,matches:hits.length});
    }
    proc.frontmost = true;
    el.focused = true;
    if (!front() || !get(el,"focused",false)) return meta+"\n"+error("focusfailed", "target did not receive focus; no text sent");
    if (P.mode === "type") {
      if (P.replace) se.keystroke("a", {using:"command down"});
      se.keystroke(P.input);
      // WebKit updates AXValue asynchronously after System Events returns.
      // Observe the effect without resending text; the outer deadline still
      // bounds this entire operation, including these short verification polls.
      var value, verified=false;
      for (var attempt=0; attempt<20; attempt++) {
        value=String(get(el,"value",""));
        verified=P.replace ? value === P.input : value.indexOf(P.input) >= 0;
        if (verified) break;
        delay(0.05);
      }
      if (!verified) return meta+"\n"+error("typefailed", "field value does not contain the requested text");
    }
    return meta+"\n"+JSON.stringify({action:P.mode,verified:true,node:full(target)});
  } catch(e) { return meta+"\n"+error(P.mode+"failed", e); }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {axMatches:axMatches, axTextHit:axTextHit, axSearch:axSearch, run:run};
}
