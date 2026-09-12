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

// The exact shape a 2021 C1 returns: oledLight refused, backlight usable.
const c1Caps={supportedKeys:['backlight','brightness','contrast'],
  unsupportedKeys:{oledLight:'500 Application error: Some keys are not allowed for the request. ( oledLight )',
                   oledPixelBrightness:'500 Application error: Some keys are not allowed for the request. ( oledPixelBrightness )'}};
const c1Vals={backlight:50,brightness:50,contrast:85};

const out={};
out.refused           = f('oledLight',c1Vals,c1Caps);
out.refusedSibling    = f('oledPixelBrightness',c1Vals,c1Caps);
out.works             = f('backlight',c1Vals,c1Caps);
out.worksBrightness   = f('brightness',c1Vals,c1Caps);
// No capability data at all (older daemon): must reproduce value-presence rule.
out.legacyPresent     = f('backlight',{backlight:50},{});
out.legacyAbsent      = f('oledLight',{backlight:50},{});
out.legacyUndef       = f('backlight',{backlight:undefined},{});
// Defensive: junk inputs must not throw.
out.nullArgs          = f('backlight',null,null);
// Reverse equivalence: backlight refused, oledLight usable.
out.reverse           = f('backlight',{oledLight:40},
                          {supportedKeys:['oledLight'],unsupportedKeys:{backlight:'Some keys are not allowed for the request. ( backlight )'}});
// A non-refusal reason is passed through, not reworded.
out.passthrough       = f('tint',{},{supportedKeys:['backlight'],unsupportedKeys:{tint:'No value returned by TV'}});
console.log(JSON.stringify(out));
