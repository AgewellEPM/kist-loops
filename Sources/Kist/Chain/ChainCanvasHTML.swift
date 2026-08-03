import Foundation

/// The `/chain` visual builder — one self-contained page (vanilla JS + SVG, no external deps) served by
/// ChainServer. Drag nodes, connect trigger→steps, edit each step, then Save / Run. Zapier-simple.
enum ChainCanvasHTML {
    static let page = """
<!doctype html><html><head><meta charset="utf-8"><title>Kist Chains</title>
<style>
 :root{--bg:#0b0f14;--panel:#121821;--edge:#2a3441;--ink:#e6edf3;--dim:#8b98a5;--accent:#39d3ff;--go:#3ad29f;--warn:#ff6b6b}
 *{box-sizing:border-box;font-family:-apple-system,ui-monospace,Menlo,monospace}
 body{margin:0;background:var(--bg);color:var(--ink);height:100vh;display:flex;overflow:hidden}
 #side{width:210px;background:var(--panel);border-right:1px solid var(--edge);display:flex;flex-direction:column;padding:10px;gap:6px}
 #side h1{font-size:13px;margin:2px 0 8px;color:var(--accent);letter-spacing:.5px}
 .chain{padding:6px 8px;border-radius:6px;cursor:pointer;font-size:12px;color:var(--dim)}
 .chain:hover,.chain.sel{background:#1b2532;color:var(--ink)}
 button{background:#1b2532;color:var(--ink);border:1px solid var(--edge);border-radius:6px;padding:6px 8px;cursor:pointer;font-size:12px}
 button:hover{border-color:var(--accent)}
 button.go{border-color:var(--go);color:var(--go)}
 #main{flex:1;display:flex;flex-direction:column}
 #bar{height:44px;display:flex;align-items:center;gap:8px;padding:0 12px;border-bottom:1px solid var(--edge)}
 #bar input{background:#0b0f14;border:1px solid var(--edge);color:var(--ink);border-radius:6px;padding:6px 8px;font-size:13px}
 #wrap{flex:1;position:relative;overflow:hidden}
 #canvas{position:absolute;inset:0}
 svg{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
 .node{position:absolute;width:170px;background:var(--panel);border:1px solid var(--edge);border-radius:8px;padding:8px;cursor:grab;user-select:none;font-size:12px}
 .node.sel{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
 .node .k{font-size:10px;color:var(--dim);text-transform:uppercase;letter-spacing:.5px}
 .node .t{margin-top:2px;font-weight:600}
 .node .port{position:absolute;right:-7px;top:50%;width:12px;height:12px;border-radius:50%;background:var(--accent);cursor:crosshair;transform:translateY(-50%)}
 .node.trigger{border-left:3px solid var(--go)} .node.output{border-left:3px solid var(--accent)} .node.condition{border-left:3px solid #f5c451}
 #insp{width:280px;background:var(--panel);border-left:1px solid var(--edge);padding:12px;font-size:12px;overflow:auto}
 #insp label{display:block;color:var(--dim);margin:10px 0 4px}
 #insp input,#insp textarea{width:100%;background:#0b0f14;border:1px solid var(--edge);color:var(--ink);border-radius:6px;padding:6px;font-size:12px}
 #insp textarea{height:110px;resize:vertical}
 #results{max-height:40%;overflow:auto;border-top:1px solid var(--edge);padding:8px 12px;font-size:12px;background:#0b0f14}
 .step{margin:6px 0;padding:6px;border-left:2px solid var(--go);background:#121821;border-radius:0 6px 6px 0}
 .step .h{color:var(--accent)} .muted{color:var(--dim)}
</style></head><body>
<div id="side">
 <h1>⛓ KIST CHAINS</h1>
 <button onclick="newChain()">+ New chain</button>
 <div id="chains"></div>
 <div style="flex:1"></div>
 <div class="muted" style="font-size:11px">Zapier × LangGraph, for Kist.<br>Drag nodes · drag the ● to connect.</div>
</div>
<div id="main">
 <div id="bar">
  <input id="name" placeholder="chain name" style="width:220px">
  <button onclick="addNode('prompt')">+ Kist step</button>
  <button onclick="addNode('condition')">+ Condition</button>
  <button onclick="addNode('output')">+ Output</button>
  <div style="flex:1"></div>
  <button onclick="save()">Save</button>
  <button class="go" onclick="run()">▶ Run</button>
  <button onclick="delChain()">Delete</button>
 </div>
 <div id="wrap"><div id="canvas"></div><svg id="edges"></svg></div>
 <div id="results" class="muted">Run a chain to see each step here.</div>
</div>
<div id="insp"><div class="muted">Select a node to edit it.</div></div>
<script>
let chain={id:"",name:"",nodes:[],edges:[],enabled:true,schedule:null};
let sel=null, linkFrom=null;
const $=s=>document.querySelector(s), cv=$("#canvas"), svg=$("#edges");

async function listChains(){const r=await fetch("/api/chains");const cs=await r.json();
 $("#chains").innerHTML=cs.map(c=>`<div class="chain ${c.id===chain.id?'sel':''}" onclick="openChain('${c.id}')">${esc(c.name||c.id)}</div>`).join("")||'<div class="muted" style="font-size:11px">no chains yet</div>';}
function esc(s){return (s||"").replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m]));}

function newChain(){chain={id:"",name:"New chain",nodes:[{id:nid(),kind:"manualTrigger",title:"When run manually",config:{},x:60,y:120}],edges:[],enabled:true,schedule:null};sel=null;$("#name").value=chain.name;draw();listChains();}
async function openChain(id){const r=await fetch("/api/chain/"+id);chain=await r.json();sel=null;$("#name").value=chain.name;draw();listChains();}
function nid(){return "n"+Math.random().toString(36).slice(2,8);}

function addNode(kind){const titles={prompt:"Kist: do this…",condition:"If output contains…",output:"Output"};
 chain.nodes.push({id:nid(),kind,title:titles[kind]||kind,config:{},x:260+Math.random()*80,y:120+Math.random()*120});draw();}

function draw(){cv.innerHTML="";
 chain.nodes.forEach(n=>{const d=document.createElement("div");d.className="node "+(n.kind.includes("Trigger")?"trigger":n.kind);
  if(sel===n.id)d.className+=" sel";d.style.left=n.x+"px";d.style.top=n.y+"px";
  d.innerHTML=`<div class="k">${n.kind.replace("Trigger"," trigger")}</div><div class="t">${esc(n.title)}</div><div class="port"></div>`;
  d.onmousedown=e=>{if(e.target.className==="port"){linkFrom=n.id;e.stopPropagation();return;}sel=n.id;inspect();drag(e,n,d);};
  d.onmouseup=e=>{if(linkFrom&&linkFrom!==n.id){connect(linkFrom,n.id);linkFrom=null;}};
  cv.appendChild(d);});
 drawEdges();inspect();}

function connect(from,to){const c=chain.nodes.find(x=>x.id===from);
 if(c&&c.kind==="condition"){const has=chain.edges.filter(e=>e.from===from).length;chain.edges.push({from,to,label:has===0?"true":"false"});}
 else{chain.edges=chain.edges.filter(e=>e.from!==from||chain.nodes.find(x=>x.id===from).kind==="condition");chain.edges.push({from,to,label:null});}
 draw();}

function drawEdges(){const pos=id=>{const n=chain.nodes.find(x=>x.id===id);return n?{x:n.x+170,y:n.y+22,tx:n.x,ty:n.y+22}:null;};
 svg.innerHTML=chain.edges.map(e=>{const a=pos(e.from),b=chain.nodes.find(x=>x.id===e.to);if(!a||!b)return"";
  const bx=b.x,by=b.y+22;const mid=(a.x+bx)/2;
  return `<path d="M${a.x},${a.y} C${mid},${a.y} ${mid},${by} ${bx},${by}" stroke="#3ad29f" fill="none" stroke-width="2" opacity=".7"/>`+
   (e.label?`<text x="${mid}" y="${(a.y+by)/2-4}" fill="#8b98a5" font-size="10">${e.label}</text>`:"");}).join("");}

function drag(e,n,d){e.preventDefault();const sx=e.clientX-n.x,sy=e.clientY-n.y;
 const mv=ev=>{n.x=ev.clientX-sx;n.y=ev.clientY-sy;d.style.left=n.x+"px";d.style.top=n.y+"px";drawEdges();};
 const up=()=>{document.removeEventListener("mousemove",mv);document.removeEventListener("mouseup",up);};
 document.addEventListener("mousemove",mv);document.addEventListener("mouseup",up);}

function inspect(){const n=chain.nodes.find(x=>x.id===sel);const i=$("#insp");
 if(!n){i.innerHTML='<div class="muted">Select a node to edit it.</div>';return;}
 let f=`<label>Title</label><input id="f-title" value="${esc(n.title)}">`;
 if(n.kind==="prompt")f+=`<label>What should Kist do? (use {{input}} for the previous step's output)</label><textarea id="f-prompt">${esc(n.config.prompt||"")}</textarea>`;
 if(n.kind==="condition")f+=`<label>Take the "true" edge if the output contains…</label><input id="f-match" value="${esc(n.config.match||"")}">`;
 if(n.kind==="scheduleTrigger")f+=`<label>Schedule (e.g. daily 09:00)</label><input id="f-schedule" value="${esc(n.config.schedule||"")}">`;
 f+=`<div style="margin-top:14px"><button onclick="makeSchedule()">Make trigger scheduled</button> <button onclick="delNode()">Delete node</button></div>`;
 i.innerHTML=f;
 const bind=(id,key)=>{const el=$("#"+id);if(el)el.oninput=()=>{if(key==="title")n.title=el.value;else n.config[key]=el.value;draw2();};};
 bind("f-title","title");bind("f-prompt","prompt");bind("f-match","match");bind("f-schedule","schedule");}
function draw2(){/* live title/edge refresh without rebuilding inspector focus */
 chain.nodes.forEach(n=>{});const d=[...cv.children].find(()=>false);drawEdges();
 [...cv.querySelectorAll(".node")].forEach((el,i)=>{const n=chain.nodes[i];if(n)el.querySelector(".t").textContent=n.title;});}
function makeSchedule(){const n=chain.nodes.find(x=>x.id===sel);if(n&&n.kind.includes("Trigger")){n.kind="scheduleTrigger";n.title="On a schedule";draw();}}
function delNode(){chain.nodes=chain.nodes.filter(x=>x.id!==sel);chain.edges=chain.edges.filter(e=>e.from!==sel&&e.to!==sel);sel=null;draw();}

async function save(){chain.name=$("#name").value||"Untitled";
 const sch=chain.nodes.find(n=>n.kind==="scheduleTrigger");chain.schedule=sch?(sch.config.schedule||"daily 09:00"):null;
 const r=await fetch("/api/chain",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(chain)});
 const j=await r.json();chain.id=j.id;
 $("#results").innerHTML=(j.problems&&j.problems.length)?'<span style="color:#ff6b6b">Saved with warnings: '+j.problems.map(esc).join("; ")+'</span>':'<span class="muted">Saved ✓</span>';listChains();}
async function run(){if(!chain.id){await save();}$("#results").innerHTML='<span class="muted">running…</span>';
 const r=await fetch("/api/chain/"+chain.id+"/run",{method:"POST"});const j=await r.json();
 $("#results").innerHTML=(j.steps||[]).map(s=>`<div class="step"><span class="h">${esc(s.title)}</span> <span class="muted">[${s.kind}]</span><br>${esc(s.output).slice(0,600)}</div>`).join("")||'<span class="muted">no steps</span>';}
async function delChain(){if(!chain.id)return;await fetch("/api/chain/"+chain.id,{method:"DELETE"});newChain();listChains();}

newChain();listChains();
</script></body></html>
"""
}
