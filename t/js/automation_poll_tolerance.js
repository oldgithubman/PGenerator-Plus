// A slow appliance must not read as a lost connection. On 18 Sep 2026 the
// status poll took 6 to 13 s during a 1D LUT sweep against an 8 s timeout, so
// the card flipped between "Live" and "Connection lost" every few seconds.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const elements=new Map();
const element=id=>{if(!elements.has(id))elements.set(id,{style:{},dataset:{},innerHTML:'',textContent:'',setAttribute(){},querySelector(){return null;},querySelectorAll(){return [];},classList:{add(){},remove(){},toggle(){}}});return elements.get(id);};
const c=vm.createContext({document:{getElementById:element,querySelectorAll:()=>[],querySelector:()=>null,body:{classList:{add(){},remove(){}}}},setTimeout(){},clearTimeout(){},Date,console});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8'),c);
// Rendering is exercised elsewhere; here only the poll's bookkeeping matters.
vm.runInContext('pgAutomationRenderLiveRun=()=>{};pgAutomationRenderActivity=()=>{};pgAutomationSyncCalibrationView=()=>{};pgAutomationRenderProgress=()=>{};',c);
let replies=[],requests=[];
c.fetchJSON=async(url,opts)=>{requests.push({url,opts});const reply=replies.shift();if(reply instanceof Error)throw reply;return reply;};
const poll=()=>vm.runInContext('pgAutomationPollLive()',c);
const state=()=>JSON.parse(vm.runInContext('JSON.stringify({statusError:pgAutomation.statusError,delayed:!!pgAutomation.pollDelayed,misses:pgAutomation.pollMisses||0})',c));
const live=()=>vm.runInContext('pgAutomationReadouts({status:"running",heartbeat_age:1,items:[{}],created_at:Date.now()/1000-60},null,Date.now()/1000).live',c);
(async()=>{
 replies=[{status:'ok',run:{id:'r',status:'running',items:[{}]},execution:{}}];
 await poll();
 assert.equal(requests[0].opts._timeoutMs,20000,'a poll allows the appliance 20 s before it counts as missed');
 assert.deepEqual(state(),{statusError:'',delayed:false,misses:0});
 assert.equal(live(),'Live');
 replies=[new Error('Timed out'),{status:'error'}];
 await poll();
 assert.deepEqual(state(),{statusError:'',delayed:true,misses:1},'one miss is a delay, not an error');
 assert.equal(live(),'Updates delayed');
 await poll();
 assert.deepEqual(state(),{statusError:'',delayed:true,misses:2},'so is a second');
 replies=[new Error('Timed out')];
 await poll();
 assert.match(state().statusError,/connection failed/,'three misses in a row are a lost connection');
 assert.equal(live(),'Connection lost');
 replies=[{status:'ok',run:{id:'r',status:'running',items:[{}]},execution:{}}];
 await poll();
 assert.deepEqual(state(),{statusError:'',delayed:false,misses:0},'one good poll clears everything; no reconnect step exists or is needed');
 assert.equal(live(),'Live');
 replies=[new Error('Timed out'),new Error('Timed out'),{status:'ok',run:{id:'r',status:'running',items:[{}]},execution:{}}];
 await poll();await poll();
 assert.equal(state().misses,2,'two misses carried');
 vm.runInContext('pgAutomationBeginChecks("readiness")',c);
 await new Promise(resolve=>setImmediate(resolve));
 assert.deepEqual(state(),{statusError:'',delayed:false,misses:0},'starting a check resets the miss count, so its first slow poll is a delay again');
 vm.runInContext('pgAutomation.pendingChecks=null',c);
 console.log(JSON.stringify({ok:true,polls:requests.length}));
})().catch(e=>{console.error(e);process.exitCode=1;});
