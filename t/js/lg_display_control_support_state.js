// Loads webui-lg.js into a vm sandbox and exercises the pure support-state
// helper. Browser globals the file expects at load time are stubbed; nothing
// here touches a TV or the network.
const fs=require('fs'), path=require('path'), vm=require('vm');
const src=fs.readFileSync(path.join(__dirname,'..','..','usr','share','PGenerator','webui-lg.js'),'utf8');
const noop=()=>{};
const sandbox={
  console, setTimeout:noop, clearTimeout:noop, setInterval:noop, clearInterval:noop,
  document:{getElementById:()=>null,querySelector:()=>null,querySelectorAll:()=>[],addEventListener:noop,body:{}},
  window:{}, navigator:{}, location:{href:''}, localStorage:{getItem:()=>null,setItem:noop,removeItem:noop},
  fetch:noop, fetchJSON:noop, toast:noop, alert:noop,
};
sandbox.globalThis=sandbox; sandbox.window=sandbox;
vm.createContext(sandbox);
try{ vm.runInContext(src,sandbox,{filename:'webui-lg.js'}); }
catch(e){ console.log(JSON.stringify({loadError:String(e&&e.message||e)})); process.exit(0); }

const f=sandbox.lgDisplayControlSupportState;
if(typeof f!=='function'){ console.log(JSON.stringify({loadError:'lgDisplayControlSupportState not defined'})); process.exit(0); }

// The exact shape a 2021 C1 returns: oledLight refused (no value), backlight usable.
const c1Caps={supportedKeys:['backlight','brightness','contrast'],
  unsupportedKeys:{oledLight:'500 Application error: Some keys are not allowed for the request. ( oledLight )',
                   oledPixelBrightness:'500 Application error: Some keys are not allowed for the request. ( oledPixelBrightness )'}};
const c1Vals={backlight:50,brightness:50,contrast:85};

const out={};
out.refused           = f('oledLight',c1Vals,c1Caps);
out.refusedSibling    = f('oledPixelBrightness',c1Vals,c1Caps);
out.works             = f('backlight',c1Vals,c1Caps);
out.worksBrightness   = f('brightness',c1Vals,c1Caps);
// CRITICAL: a live value must win even when the key is ALSO listed unsupported
// (daemon can do this: unscoped read refuses, scoped read returns a value).
// Old code disabled a working slider here; the fix must keep it usable.
out.valueWinsOverUnsupported = f('oledLight',{oledLight:40,backlight:50},
  {supportedKeys:['oledLight','backlight'],unsupportedKeys:{oledLight:'Some keys are not allowed for the request. ( oledLight )'}});
// No capability data (older daemon): must reproduce value-presence rule exactly.
out.legacyPresent     = f('backlight',{backlight:50},{});
out.legacyAbsent      = f('oledLight',{backlight:50},{});
out.legacyUndef       = f('backlight',{backlight:undefined},{});
// Defensive: junk inputs must not throw.
out.nullArgs          = f('backlight',null,null);
// Reverse equivalence: backlight refused, oledLight has a live value.
out.reverse           = f('backlight',{oledLight:40},
  {supportedKeys:['oledLight'],unsupportedKeys:{backlight:'Some keys are not allowed for the request. ( backlight )'}});
// A refused panel-light key with NO working sibling gets no brightness hint.
out.refusedNoSibling  = f('oledLight',{brightness:50},c1Caps);
// A non-panel-light key absent for this picture mode: explained, no hint.
out.notForThisMode    = f('tint',{backlight:50},{supportedKeys:['backlight'],unsupportedKeys:{}});
console.log(JSON.stringify(out));
