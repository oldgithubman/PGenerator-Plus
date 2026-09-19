// Regression for PR 14 test report P5 and P34: the Resolution list retries an
// empty first load, and switching Signal Mode restores the operator's last
// transport profile for that signal instead of fixed defaults.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const app=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-app.js'),'utf8');
const grab=name=>{const code=app.match(new RegExp('(?:async )?function '+name+'\\([^]*?\\n\\}'))?.[0];assert.ok(code,name+' found');return code;};
function select(value,options){return {value,options:options.map(v=>({value:v})),innerHTML:'',children:[],appendChild(o){this.children.push(o);}};}
function page(){
 const els={signal_mode:select('hdr10',['sdr','hdr10','hlg','dv']),max_bpc:select('10',['8','10','12']),color_format:select('0',['0','1','2']),
  colorimetry:select('9',['2','9']),rgb_quant_range:select('0',['0','1','2']),eotf:select('2',['0','1','2','3']),primaries:select('2',['0','1','2','3']),
  dv_transport:select('',['']),dv_interface:select('0',['0']),mode_idx:select('',[])};
 const store=new Map(),timers=[];
 const ctx={localStorage:{getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v))},
  document:{getElementById:id=>els[id]||null,createElement:()=>({})},
  setTimeout:(fn)=>{timers.push(fn);return timers.length;},clearTimeout(){},toast(){},syncModeSelectValue(){},
  dvTransportDefaults:()=>({dv_transport:'',dv_interface:'0',color_format:'0',max_bpc:'12'}),
  applyMeterTargetGamutDefault(){},applyMeterTargetGammaDefault(){},meterApplyPatternInsertionDefaults(){},saveMeterSettings(){},updateModeVisibility(){},
  meterWarnTargetWhiteAboveHdrMax(){},updateDropdowns(){},checkSettingsChanged(){},meterUpdateCardMode(){},meterQueueOutputSettingsRefresh(){}};
 vm.createContext(ctx);
 const listener=app.match(/document\.getElementById\('signal_mode'\)\.addEventListener\('change',(function\(\)\{[^]*?\n\})\);/)?.[1];
 assert.ok(listener,'signal mode change handler found');
 const retry=app.match(/const loadModesRetry=\{[^\n]*\};/)?.[0];assert.ok(retry,'mode retry state found');
 vm.runInContext(['setVal','getVal','webuiOutputProfileKey','webuiRememberOutputProfile','webuiRememberedOutputProfile','webuiApplyRememberedOutputProfile','webuiAutoColorimetryForSignalMode','formatModeLabel'].map(n=>{try{return grab(n);}catch(e){if(n==='getVal')return 'function getVal(id){const el=document.getElementById(id);return el?el.value:"";}';throw e;}}).join('\n')
  +'\n'+retry+'\nlet modes=[];\n'+grab('loadModes')+'\nthis.changeSignal=value=>{const el=document.getElementById("signal_mode");el.value=value;('+listener+').call(el);};',ctx);
 return {els,ctx,store,timers};
}
{
 const {els,ctx}=page();
 ctx.changeSignal('sdr');
 assert.equal(els.max_bpc.value,'8','with no remembered SDR profile the fixed 8-bit baseline is used');
 assert.equal(els.primaries.value,'0','SDR shows BT.709 primaries, which is what Apply sends');
 assert.equal(els.eotf.value,'0','and SDR gamma');
}
{
 // A full quota used to lose the profile silently, so a later switch back fell
 // to the fixed 8-bit baseline (seen live on the appliance).
 const {els,ctx,store}=page();
 let full=true,reclaimed=0;
 ctx.localStorage.setItem=(k,v)=>{if(full){const e=new Error('quota');e.name='QuotaExceededError';throw e;}store.set(k,String(v));};
 ctx.meterStorageQuotaError=e=>!!e&&e.name==='QuotaExceededError';
 ctx.meterSeriesCacheReclaimSpace=()=>{reclaimed++;full=false;return 1;};
 ctx.webuiRememberOutputProfile('sdr',{max_bpc:'10',color_format:'1',rgb_quant_range:'1',colorimetry:'2'});
 assert.equal(reclaimed,1,'a full quota reclaims disposable series space once');
 assert.ok(ctx.webuiRememberedOutputProfile('sdr'),'and the profile is stored on the retry');
 ctx.changeSignal('hdr10');ctx.changeSignal('sdr');
 assert.equal(els.max_bpc.value,'10','so switching back still restores the operator profile');
}
{
 const {els,ctx}=page();
 ctx.webuiRememberOutputProfile('sdr',{max_bpc:'10',color_format:'0',rgb_quant_range:'2',colorimetry:'2'});
 ctx.changeSignal('sdr');
 assert.equal(els.max_bpc.value,'10','the owner\'s remembered 10-bit SDR profile is restored');
 assert.equal(els.rgb_quant_range.value,'2','with its range');
 assert.equal(els.primaries.value,'0','and BT.709 primaries');
 ctx.changeSignal('dv');
 assert.equal(els.max_bpc.value,'12','Dolby Vision keeps its own transport defaults');
 ctx.webuiRememberOutputProfile('sdr',{max_bpc:'16'});
 ctx.changeSignal('sdr');
 assert.equal(els.max_bpc.value,'8','a remembered value the page does not offer is ignored');
}
(async()=>{
 const {els,ctx,timers}=page();
 const flush=()=>new Promise(resolve=>setImmediate(resolve));
 const replies=[[],[],[{idx:'3',resolution:'3840x2160',refresh:'60'}]];
 ctx.fetchJSON=async()=>replies.shift();
 await ctx.loadModes(true);
 assert.equal(timers.length,1,'an empty first load schedules a quiet retry');
 timers.shift()();await flush();
 assert.equal(timers.length,1,'and keeps retrying while the list is empty');
 timers.shift()();await flush();
 assert.equal(els.mode_idx.children.length,1,'the list fills once the renderer reports its modes');
 assert.equal(timers.length,0,'and retrying stops');
 // Round 4: the retry that fills the list after the page loaded does not
 // leave the form looking unapplied.
 {
  const fresh=page();
  let rebaselined=0,refiltered=0,checked=0,unsaved=false;
  Object.assign(fresh.ctx,{window:{_savedConfig:'baseline'},hasUnsavedSettings:()=>unsaved,
   refreshSavedSettingsSnapshot:()=>{rebaselined++;},updateDropdowns:()=>{refiltered++;},checkSettingsChanged:()=>{checked++;}});
  const later=[[],[{idx:'3',resolution:'3840x2160',refresh:'60'}]];
  fresh.ctx.fetchJSON=async()=>later.shift();
  await fresh.ctx.loadModes(true);
  fresh.timers.shift()();await flush();
  assert.equal(fresh.els.mode_idx.children.length,1,'the late retry fills the list');
  assert.equal(refiltered,1,'the dependent dropdowns are filtered again');
  assert.equal(rebaselined,1,'and the filled form becomes the applied state, so no false apply bar');
  // With an operator edit pending, the edit stays flagged and nothing is re-baselined.
  const edited=page();
  Object.assign(edited.ctx,{window:{_savedConfig:'baseline'},hasUnsavedSettings:()=>true,
   refreshSavedSettingsSnapshot:()=>{rebaselined++;},updateDropdowns:()=>{refiltered++;},checkSettingsChanged:()=>{checked++;}});
  const again=[[{idx:'3',resolution:'3840x2160',refresh:'60'}]];
  edited.ctx.fetchJSON=async()=>again.shift();
  rebaselined=0;checked=0;
  await edited.ctx.loadModes(true);
  assert.equal(rebaselined,0,'an operator edit made before the list filled is not discarded');
  assert.equal(checked,1,'it is re-checked against the saved state instead');
  // A normal reload of an already filled list changes nothing.
  const filled=page();filled.els.mode_idx.options=[{value:'3'}];
  Object.assign(filled.ctx,{window:{_savedConfig:'baseline'},hasUnsavedSettings:()=>false,refreshSavedSettingsSnapshot:()=>{rebaselined++;}});
  filled.ctx.fetchJSON=async()=>[{idx:'3',resolution:'3840x2160',refresh:'60'}];
  rebaselined=0;
  await filled.ctx.loadModes(true);
  assert.equal(rebaselined,0,'reloading a list that was already filled does not reset the applied state');
  // A slow earlier request that lands after a newer one never rebuilds the list.
  const racing=page();
  let releaseSlow;
  const slow=new Promise(resolve=>{releaseSlow=resolve;});
  const answers=[slow,Promise.resolve([{idx:'5',resolution:'1920x1080',refresh:'60'}])];
  racing.ctx.fetchJSON=()=>answers.shift();
  const first=racing.ctx.loadModes(true);
  await racing.ctx.loadModes(true);
  assert.equal(racing.els.mode_idx.children.length,1,'the newer request builds the list');
  releaseSlow([{idx:'9',resolution:'640x480',refresh:'60'}]);await first;
  assert.equal(racing.els.mode_idx.children.length,1,'the stale answer is ignored');
  assert.equal(racing.els.mode_idx.children[0].value,'5','and the list keeps the newer modes');
 }
 ctx.fetchJSON=async()=>[];
 for(let i=0;i<10;i++){await ctx.loadModes(true);if(timers.length){timers.shift()();await flush();}}
 assert.ok(vm.runInContext('loadModesRetry.attempts',ctx)<=6,'retries are bounded');
 console.log('PASS output page defaults: remembered per-signal transport, SDR primaries, DV defaults, bounded mode-list retry');
})().catch(error=>{console.error(error);process.exit(1);});
