// Issue #50: the Wi-Fi scan list used to build each row with
// d.innerHTML='...'+n.ssid+'...'. SSIDs are attacker-controlled over the air,
// so a beacon named <img src=x onerror=...> executed script in the WebUI
// origin the moment an operator opened the scan list.
//
// This driver loads the REAL scanWifi() from webui-app.js into a Node vm
// sandbox with a minimal fake DOM whose innerHTML setter RECORDS every write,
// feeds it a crafted SSID, and asserts the row renders the payload as inert
// text: no markup ever reaches innerHTML during rendering, and no element is
// ever created from the payload.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const app=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-app.js'),'utf8');

const innerHTMLWrites=[];
let liveElements=0;
function factory(){
 liveElements++;
 const el={tagName:'DIV',className:'',style:{},_text:'',children:[],_onclick:null,
  set textContent(v){this._text=v==null?'':String(v);},
  get textContent(){return this._text+(this.children.length?this.children.map(c=>c.textContent).join(''):'');},
  set innerHTML(v){innerHTMLWrites.push(String(v));},
  appendChild(c){this.children.push(c);return c;},
  querySelectorAll(){return[];},
  classList:{add(){},remove(){}},
  set onclick(fn){this._onclick=fn;},get onclick(){return this._onclick;}};
 return el;
}
const wifiList=factory();
let formArgs=null;
const ctx={console,showWifiForm:(ssid,sec)=>{formArgs=[ssid,sec];},
 document:{getElementById:id=>id==='wifiList'?wifiList:factory(),createElement:factory}};
const src=app.match(/async function scanWifi\(\)\{[^]*?\n\}/);
assert.ok(src,'scanWifi found in webui-app.js');
let payload;
vm.createContext(ctx);
vm.runInContext(src[0],ctx);

(async()=>{
 payload='<img src=x onerror="steal(document.cookie)">';
 ctx.fetchJSON=async()=>[
  {ssid:payload,security:'WPA2',signal:-50},
  {ssid:'Home',security:'WPA3',signal:-40},
  {ssid:payload,security:'WPA2',signal:-70},// duplicate: dedupe keeps one row
 ];
 innerHTMLWrites.length=0;
 await ctx.scanWifi();
 // The only innerHTML writes allowed are the static ones (scan-start spinner,
 // list clear): nothing carrying scan data may ever go through innerHTML.
 assert.deepEqual(innerHTMLWrites.filter(w=>w!==''&&w.indexOf('spinner')<0),[],
  'no dynamic innerHTML write while rendering scan rows');
 const rows=wifiList.children;
 assert.equal(rows.length,2,'dedupe keeps one row per SSID');
 const row=rows.find(r=>r.children.length&&r.children[0].children[0].textContent===payload);
 assert.ok(row,'payload row exists');
 assert.equal(row.children[0].children[0].children.length,0,
  'the SSID name div has no element children: payload is text, never parsed');
 assert.equal(row.children.length,2,'row keeps the name/security + signal layout');
 assert.equal(row.children[1].textContent,'-50 dBm','signal still renders');
 row.onclick();
 // Selection handler passes the raw SSID to the form untouched.
 assert.deepEqual(formArgs,[payload,'WPA2'],'selection still hands the raw SSID/security to the form');
 console.log(JSON.stringify({ok:true,rows:rows.length,payloadText:row.children[0].children[0].textContent}));
})().catch(e=>{console.error('FAIL '+e.message);process.exit(1);});
