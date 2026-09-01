// Generates the two SVG tiles for round-11/v2's loading strap, using the mockup's own
// deterministic RNG (mk(41)) and its own geometry, baked into a seamless 12-stitch tile.
function mk(s){ return function(){ s|=0; s=s+0x6D2B79F5|0; var t=Math.imul(s^s>>>15,1|s);
  t=t+Math.imul(t^t>>>7,61|t)^t; return((t^t>>>14)>>>0)/4294967296; }; }

const PITCH = 10.5, N = 12, W = PITCH*N, H = 19, cy = H/2;
const srng = mk(41);
const holes = [];
for (let i=0;i<N;i++){
  const cx = (i+0.5)*PITCH;
  const jl = 2.9+(srng()-.5)*.7, ja = .16+(srng()-.5)*.12,
        ox = (srng()-.5)*.9, oy = (srng()-.5)*.8;
  const dx = Math.cos(ja), dy = Math.sin(ja);
  holes.push({ ax:cx+ox-dx*jl, ay:cy+oy-dy*jl, bx:cx+ox+dx*jl, by:cy+oy+dy*jl });
}
const r = (n) => Math.round(n*100)/100;

let dots = "";
for (const h of holes){
  for (const q of [[h.ax,h.ay],[h.bx,h.by]]){
    dots += "<circle cx='" + r(q[0]) + "' cy='" + r(q[1]) + "' r='1.3' fill='rgba(2,5,13,.95)'/>";
    dots += "<circle cx='" + r(q[0]+.15) + "' cy='" + r(q[1]+.85) + "' r='.72' fill='rgba(168,186,220,.26)'/>";
    dots += "<circle cx='" + r(q[0]-.3) + "' cy='" + r(q[1]-.85) + "' r='.6' fill='rgba(168,186,220,.10)'/>";
  }
}
const holesSvg = "<svg xmlns='http://www.w3.org/2000/svg' width='" + W + "' height='" + H + "'>" + dots + "</svg>";

const d = holes.map(h => "M" + r(h.ax) + " " + r(h.ay) + "L" + r(h.bx) + " " + r(h.by)).join("");
const threadSvg = "<svg xmlns='http://www.w3.org/2000/svg' width='" + W + "' height='" + H + "'>" +
  "<g fill='none' stroke-linecap='round'>" +
  "<path d='" + d + "' transform='translate(0 .5)' stroke='rgba(84,64,26,.85)' stroke-width='2.5'/>" +
  "<path d='" + d + "' stroke='#D2B266' stroke-width='1.7'/>" +
  "<path d='" + d + "' transform='translate(-.2 -.45)' stroke='rgba(255,238,190,.55)' stroke-width='.7'/>" +
  "</g></svg>";

const enc = (s) => s.replace(/</g,"%3C").replace(/>/g,"%3E").replace(/#/g,"%23");
console.log("PITCH " + PITCH + "  TILE " + W + "x" + H + "  stitches " + N);
console.log("\n--- HOLES ---");
console.log("url(\"data:image/svg+xml," + enc(holesSvg) + "\") left center / " + W + "px " + H + "px repeat-x");
console.log("\n--- THREAD ---");
console.log("url(\"data:image/svg+xml," + enc(threadSvg) + "\") left center / " + W + "px " + H + "px repeat-x");
