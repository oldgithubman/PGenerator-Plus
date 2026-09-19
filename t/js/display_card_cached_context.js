// Regression for PR 14 test report P21: while automation owns the TV, the
// Display card names the context of the remembered values it shows.
const fs=require('fs'),vm=require('vm'),path=require('path'),assert=require('node:assert/strict');
const els=new Map();
const el=id=>{if(!els.has(id))els.set(id,{id,style:{},dataset:{},innerHTML:'',textContent:'',value:'',disabled:false,
 classList:{add(){},remove(){},toggle(){},contains(){return false;}},setAttribute(){},addEventListener(){},querySelector(){return null;},querySelectorAll(){return [];},appendChild(){}});return els.get(id);};
const ctx=vm.createContext({console:{log(){},warn(){},error(){}},setTimeout,clearTimeout,setInterval(){},clearInterval(){},Date,JSON,Math,Promise,
 localStorage:{getItem(){return null;},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null;},setItem(){}},
 document:{getElementById:el,querySelector(){return null;},querySelectorAll(){return [];},createElement:()=>el('x'+Math.random()),addEventListener(){},body:el('body')},
 navigator:{},location:{hostname:'pi'},toast(){},fetch(){return Promise.reject(new Error('no net'));}});
ctx.window=ctx;
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-lg.js'),'utf8'),ctx);
(async()=>{
 vm.runInContext('lgDisplayControlConnected=()=>true;lgDisplayControlValues={oledPixelBrightness:55,contrast:85};',ctx);
 const status=()=>el('lgDisplayControlStatus').textContent,grid=()=>el('lgDisplayControlGrid');
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{},cache_context_available:false,message:'No coherent cached values for this context.'});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.match(status(),/different TV context/,'values from another context are labelled as such');
 assert.equal(grid().dataset.valueContext,'other','and the card is marked as showing another context');
 assert.equal(vm.runInContext('lgDisplayControlValues.contrast',ctx),85,'without pretending the controls are unsupported');
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{contrast:90},cache_context_available:true,message:'Values from the last read'});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.match(status(),/last read in this TV context/,'matching remembered values say they belong to this context');
 assert.equal(grid().dataset.valueContext,'','and the card is not marked stale');
 assert.equal(vm.runInContext('lgDisplayControlValues.contrast',ctx),90,'matching remembered values are shown');

 // Another context after a matching one: the mark persists past the hold and
 // the next ordinary refresh reads live.
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{},cache_context_available:false,cache_present:true});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 vm.runInContext('lgDisplayControlLoaded=true;lgAutomationCachedUntil=0;lgDisplayControlRender();',ctx);
 assert.match(status(),/different TV context/,'the label stays after the automation hold lapses');
 assert.equal(grid().dataset.valueContext,'other','and so does the mark');
 let live=0;
 ctx.fetchJSON=async()=>{live++;return {status:'ok',picture_settings:{contrast:71},supported_picture_keys:['contrast']};};
 await vm.runInContext('lgDisplayControlRefresh(false)',ctx);
 assert.equal(live,1,'an ordinary refresh reads live instead of treating other-context values as loaded');
 assert.equal(grid().dataset.valueContext,'','the live read clears the mark');
 // Matching remembered values replace, never merge into, another context's values.
 vm.runInContext('lgDisplayControlValues={contrast:40,oledPixelBrightness:55};lgDisplayControlOtherContext=true;',ctx);
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{contrast:90},cache_context_available:true});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.equal(vm.runInContext('lgDisplayControlValues.oledPixelBrightness',ctx),undefined,'another context values are not mixed into this context');
 // Round 3: remembered values for this context never merge into values read
 // for a different signal or picture mode, even when those were a live read.
 let mode='filmMaker',signal='sdr';
 vm.runInContext('lgDisplayControlPictureMode=()=>globalThis.__mode;lgSignalModeKey=()=>globalThis.__signal;',ctx);
 ctx.__mode=mode;ctx.__signal=signal;
 vm.runInContext('lgAutomationCachedUntil=0;',ctx);
 ctx.fetchJSON=async()=>({status:'ok',picture_settings:{contrast:80,gamma:'2.2'},supported_picture_keys:['contrast','gamma']});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 // Round 4: a live read stamps its context, so a remembered partial read for
 // the same context merges into it.
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{brightness:48},cache_context_available:true});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.equal(vm.runInContext('lgDisplayControlValues.gamma',ctx),'2.2','a same-context remembered read keeps the live values');
 assert.equal(vm.runInContext('lgDisplayControlValues.brightness',ctx),48,'and adds its own');
 ctx.__mode='hdrFilmMaker';ctx.__signal='hdr10';
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{contrast:95},cache_context_available:true});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.equal(vm.runInContext('lgDisplayControlValues.contrast',ctx),95,'the remembered value for the new context is shown');
 assert.equal(vm.runInContext('lgDisplayControlValues.gamma',ctx),undefined,'an SDR live reading is not mixed into the HDR context');
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{brightness:50},cache_context_available:true});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.equal(vm.runInContext('lgDisplayControlValues.contrast',ctx),95,'partial reads in the same context still merge');
 assert.equal(vm.runInContext('lgDisplayControlValues.brightness',ctx),50,'with the newly remembered key');
 vm.runInContext('lgDisplayControlInvalidate();',ctx);
 assert.equal(vm.runInContext('lgDisplayControlValuesContext',ctx),'','invalidating forgets the values context');
 // Round 4: values shown from before automation took the TV, with no remembered
 // context at all, are named as such.
 vm.runInContext('lgDisplayControlValues={contrast:40};lgDisplayControlOtherContext=false;',ctx);
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{},cache_context_available:false,cache_present:false});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.match(status(),/from before automation took the TV/,'values read before automation are labelled as such');
 assert.equal(grid().dataset.valueContext,'other','and marked as possibly another context');
 // Nothing read yet: say so rather than claiming values are shown.
 vm.runInContext('lgDisplayControlValues={};lgDisplayControlOtherContext=false;',ctx);
 ctx.fetchJSON=async()=>({status:'ok',cached:true,automation_active:true,picture_settings:{},cache_context_available:false,cache_present:false});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.match(status(),/No values have been read in this TV context yet/,'an empty card does not claim to show values');
 vm.runInContext('lgDisplayControlValues={contrast:40};lgDisplayControlOtherContext=true;lgDisplayControlRender();lgDisplayControlConnected=()=>false;lgDisplayControlRender();',ctx);
 assert.equal(grid().dataset.valueContext,'','disconnecting clears the mark');
 vm.runInContext('lgDisplayControlConnected=()=>true;lgDisplayControlInvalidate();',ctx);
 assert.equal(vm.runInContext('lgDisplayControlOtherContext',ctx),false,'invalidating the card clears the other-context state');
 vm.runInContext('lgAutomationCachedUntil=0;',ctx);
 ctx.fetchJSON=async()=>({status:'ok',picture_settings:{contrast:70},supported_picture_keys:['contrast']});
 await vm.runInContext('lgDisplayControlRefresh(true)',ctx);
 assert.doesNotMatch(status(),/different TV context|last read/,'a live read clears the remembered-values label');
 console.log('PASS display card cached context: other-context label, same-context label, live read clears');
})().catch(error=>{console.error(error);process.exit(1);});
