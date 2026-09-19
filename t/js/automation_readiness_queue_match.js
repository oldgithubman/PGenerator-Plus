// Regression for PR 14 test report P1 and P8: a readiness result is matched to
// the draft the way the server stores item names, an empty draft owns no
// result, and a slow page refresh after a save never keeps Save locked.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.join(__dirname,'../../usr/share/PGenerator');
const els=new Map();
const el=id=>{if(!els.has(id))els.set(id,{id,disabled:false,open:false,innerHTML:'',textContent:'',value:'',checked:false,style:{},dataset:{},scrollIntoView(){}});return els.get(id);};
const ctx=vm.createContext({console,Promise,JSON,Math,Date,Array,String,Number,Set,Map,
 document:{querySelectorAll:()=>[],querySelector:()=>null,getElementById:el},
 localStorage:{getItem:()=>null,setItem(){},removeItem(){}},setTimeout:()=>0,clearTimeout(){},setInterval:()=>0,clearInterval(){},
 pgAutomationConfirmOverride:()=>true,fetchJSON:()=>{throw new Error('no network in this test');}});
vm.runInContext(fs.readFileSync(path.join(root,'webui-automation.js'),'utf8'),ctx);
const run=code=>vm.runInContext(code,ctx);
(async()=>{
 // P1: names as stored by the server.
 run(`pgAutomation.queue={name:'Q',items:[{name:''},{name:'${'x'.repeat(130)}'},{title:'Titled'}]};`);
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r1',items:[{name:'Automation item'},{name:'${'x'.repeat(120)}'},{name:'Titled'}]})`),true,
  'a blank name, an over-long name and a title-only item match the names the server stored');
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r1',items:[{name:'Automation item'},{name:'${'y'.repeat(120)}'},{name:'Titled'}]})`),false,
  'a different stored name still does not match');
 run(`pgAutomation.queue={name:'Q',items:[{name:'0'}]};`);
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r1',items:[{name:'Automation item'}]})`),true,'a name the server treats as blank matches too');
 run(`pgAutomation.queue={name:'Q',items:[{name:'${'\u{1F4FA}'.repeat(125)}'}]};`);
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r1',items:[{name:'${'\u{1F4FA}'.repeat(120)}'}]})`),true,'names are trimmed by characters, as the server trims them');
 // A plain string slice counts UTF-16 units: these names differ within their
 // first 120 characters but not within their first 120 code units.
 run(`pgAutomation.queue={name:'Q',items:[{name:'${'\u{1F4FA}'.repeat(60)}a'}]};`);
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r1',items:[{name:'${'\u{1F4FA}'.repeat(60)}b'}]})`),false,'names are compared by characters, not UTF-16 units');
 run(`pgAutomation.queue={name:'Empty',items:[]};pgAutomation.editingRunId='';`);
 assert.equal(run(`pgAutomationReadinessQueueMatches({id:'r2',items:[]})`),false,'an empty draft never owns a readiness result');
 // P8: Save is released as soon as the save is stored.
 let releaseRefresh,refreshStarted=false,stateDuringRefresh=null;
 run(`pgAutomationRecipeFromForm=()=>({name:'Job',signal_format:'sdr',picture_mode:'filmMaker'});
  pgAutomationRequest=async()=>({status:'ok'});pgAutomationSaveDraft=()=>{};pgAutomationRenderQueue=()=>{};pgAutomationTab=()=>{};
  pgAutomationCancelEditor=()=>{};pgAutomationNotice=()=>{};pgAutomationModeEligibility=()=>{};
  pgAutomation.queue={name:'Q',items:[]};pgAutomation.editorTarget='queue';pgAutomation.editingQueueIndex=null;`);
 ctx.__refresh=()=>{refreshStarted=true;stateDuringRefresh={saving:run('pgAutomation.editorSaving'),disabled:el('pgAutomationEditorSave').disabled};return new Promise(resolve=>{releaseRefresh=resolve;});};
 run(`pgAutomationRefresh=()=>globalThis.__refresh();`);
 const saving=run('pgAutomationSaveRecipe()');
 for(let i=0;i<20&&!refreshStarted;i++)await new Promise(resolve=>setImmediate(resolve));
 assert.ok(refreshStarted,'the page refresh runs after the save');
 assert.deepEqual(stateDuringRefresh,{saving:false,disabled:false},'Save is unlocked while the refresh is still pending');
 releaseRefresh();await saving;
 assert.equal(run('pgAutomation.queue.items.length'),1,'the item was saved once');
 run(`pgAutomationRequest=async()=>{throw new Error('Recipe rejected');};pgAutomationChecked=()=>true;`);
 let refreshed=0;ctx.__refresh=async()=>{refreshed++;};
 await run('pgAutomationSaveRecipe()');
 assert.equal(refreshed,0,'a failed save does not refresh as if it had succeeded');
 assert.equal(run('pgAutomation.editorSaving'),false,'and leaves Save unlocked');
 console.log('PASS automation readiness queue match and save release');
})().catch(error=>{console.error(error);process.exit(1);});
