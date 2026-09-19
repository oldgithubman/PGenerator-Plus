// 18 Sep 2026: the status poll resent 150 KB of unchanged checks and
// activity every 2 s. The page now names the check revision and activity
// cursor it holds, keeps an unchanged check list, appends a partial feed and
// still exposes the same shapes (activity.entries, .truncated, preflight).
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const elements=new Map();
const element=id=>{if(!elements.has(id))elements.set(id,{style:{},dataset:{},innerHTML:'',textContent:'',setAttribute(){},querySelector(){return null;},querySelectorAll(){return [];},classList:{add(){},remove(){},toggle(){}}});return elements.get(id);};
const c=vm.createContext({document:{getElementById:element,querySelectorAll:()=>[],querySelector:()=>null,body:{classList:{add(){},remove(){}}}},setTimeout(){},clearTimeout(){},Date,console});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8'),c);
// Rendering is exercised elsewhere; here only what the poll holds matters.
vm.runInContext('var pgAutomationRenderActivityReal=pgAutomationRenderActivity;pgAutomationRenderLiveRun=()=>{};pgAutomationRenderActivity=()=>{};pgAutomationSyncCalibrationView=()=>{};pgAutomationRenderProgress=()=>{};',c);
let replies=[],requests=[];
c.fetchJSON=async url=>{requests.push(url);const reply=replies.shift();if(reply instanceof Error)throw reply;return reply;};
const poll=()=>vm.runInContext('pgAutomationPollLive()',c);
const current=()=>JSON.parse(vm.runInContext('JSON.stringify(pgAutomation.current)',c));
const run={id:'r',status:'running',items:[{}]};
const head=[{time:1,source:'Job check',message:'Look',level:'warning'},{time:2,source:'Startup',message:'Queue accepted',level:'info'}];
const line=n=>({time:100+n,source:'Runner',message:'line '+n,level:'info'});
const messages=()=>current().activity.entries.map(e=>e.message);
(async()=>{
 replies=[{status:'ok',run,execution:{},preflight:{id:'p',status:'started',rev:'rev-1',checks:[{ok:true}]},activity:{entries:[...head,line(1),line(2)],truncated:0,run_id:'r',head:2,cursor:'r:120:2.abc'}}];
 await poll();
 assert.equal(requests[0],'/api/automation/runs/current','the first poll names nothing');
 assert.deepEqual(messages(),['Look','Queue accepted','line 1','line 2'],'and holds the full feed');
 replies=[{status:'ok',run,execution:{},preflight_unchanged:true,activity:{entries:[line(3)],truncated:0,run_id:'r',head:2,cursor:'r:150:2.abc',partial:true}}];
 await poll();
 assert.equal(requests[1],'/api/automation/runs/current?preflight_rev=rev-1&activity_after=r%3A120%3A2.abc','the next poll names the revision and cursor it holds, encoded');
 let now=current();
 assert.equal(now.preflight.rev,'rev-1','an unchanged check list is kept');
 assert.deepEqual(now.preflight.checks,[{ok:true}],'whole');
 assert.deepEqual(messages(),['Look','Queue accepted','line 1','line 2','line 3'],'new lines are appended after what was held');
 assert.equal(now.activity.cursor,'r:150:2.abc','and the cursor advances');
 assert.equal(now.activity.partial,undefined,'the merged feed is not marked partial');
 assert.equal(now.activity.truncated,false,'a short feed is not truncated');
 assert.equal(now.activity.run_id,'r','and still names its run');
 replies=[{status:'ok',run,execution:{},preflight_unchanged:true,activity:{entries:[],truncated:0,run_id:'r',head:2,cursor:'r:150:2.abc',partial:true}}];
 await poll();
 assert.deepEqual(messages(),['Look','Queue accepted','line 1','line 2','line 3'],'an empty partial feed changes nothing');
 replies=[{status:'ok',run,execution:{},preflight_unchanged:true,activity:{entries:Array.from({length:299},(_,i)=>line(10+i)),truncated:0,run_id:'r',head:2,cursor:'r:999:2.abc',partial:true}}];
 await poll();now=current();
 assert.equal(now.activity.entries.length,302,'the feed holds the head plus at most 300 log lines, as a full read would');
 assert.deepEqual(now.activity.entries.slice(0,3).map(e=>e.message),['Look','Queue accepted','line 3'],'the oldest log lines go; the head stays');
 assert.equal(now.activity.entries[301].message,'line 308','the newest line is last');
 assert.equal(now.activity.truncated,true,'and the feed says it was cut');
 replies=[{status:'ok',run:{id:'r2',status:'running',items:[{}]},execution:{},preflight:{id:'p2',status:'started',rev:'rev-2'},activity_reset:true,activity:{entries:[line(1)],truncated:0,run_id:'r2',head:0,cursor:'r2:10:0.def'}}];
 await poll();now=current();
 assert.equal(requests[4],'/api/automation/runs/current?preflight_rev=rev-1&activity_after=r%3A999%3A2.abc','the poll named the cursor it held');
 assert.deepEqual(messages(),['line 1'],'a full feed replaces what was held');
 assert.equal(now.activity.run_id,'r2','for the run now current');
 assert.equal(now.preflight.rev,'rev-2','and a resent check list replaces the old one');
 replies=[new Error('Timed out')];
 await poll();
 assert.deepEqual(messages(),['line 1'],'a missed poll keeps the feed');
 replies=[{status:'ok',run:null,execution:null,preflight:null,activity:{entries:[],truncated:0,run_id:null,head:0,cursor:':0:0.x'}}];
 await poll();now=current();
 assert.equal(requests[6],'/api/automation/runs/current?preflight_rev=rev-2&activity_after=r2%3A10%3A0.def','and names the same revision and cursor again');
 assert.equal(now.preflight,null,'a check list the daemon no longer has is dropped');
 assert.deepEqual(messages(),[],'as is a feed for a run that is gone');
 replies=[{status:'ok',run,execution:{},preflight:{id:'p',status:'ready'},activity:{entries:[line(1)],truncated:0,run_id:'r'}}];
 await poll();
 assert.equal(requests[7],'/api/automation/runs/current?activity_after=%3A0%3A0.x','without a revision only the cursor is named');
 replies=[{status:'ok',run,execution:{},preflight:{id:'p',status:'ready'},activity:{entries:[line(1)],truncated:0,run_id:'r'}}];
 await poll();
 assert.equal(requests[8],'/api/automation/runs/current','a reply without a revision or cursor (an older daemon) leaves the next poll bare');
 assert.deepEqual(messages(),['line 1'],'and its feed replaces what was held');
 assert.deepEqual(JSON.parse(vm.runInContext('JSON.stringify(pgAutomationMergeActivity(undefined,{entries:[{message:"x"}],head:0,cursor:"c",partial:true}))',c)),{entries:[{message:'x'}],head:0,cursor:'c',truncated:false},'a partial feed with nothing held is taken as is');
 // A fresh check list is stamped with its arrival, so a check still running
 // shows its elapsed time advancing without being resent for it.
 replies=[{status:'ok',run,execution:{},preflight:{id:'p3',status:'checking',rev:'rev-3',started_at:1,elapsed_seconds:5},activity:{entries:[line(1)],truncated:0,run_id:'r',head:0,cursor:'r:9:0.x'}}];
 await poll();now=current();
 assert.ok(now.preflight.received_at>0,'a fresh check list is stamped with its arrival');
 const stamped=now.preflight.received_at;
 replies=[{status:'ok',run,execution:{},preflight_unchanged:true,activity:{entries:[],truncated:0,run_id:'r',head:0,cursor:'r:9:0.x',partial:true}}];
 await poll();now=current();
 assert.equal(now.preflight.received_at,stamped,'a kept check list keeps its stamp');
 const elapsed=pre=>vm.runInContext('pgAutomationPreflightElapsed('+JSON.stringify(pre)+')',c);
 assert.equal(elapsed({elapsed_seconds:5,received_at:Date.now()/1000-3.2}),8,'a check still running advances the daemon\'s figure by the time since it arrived');
 assert.equal(elapsed({elapsed_seconds:5,started_at:10,completed_at:16.9}),6,'a finished check says so itself');
 assert.equal(elapsed({started_at:10}),null,'nothing to say without a figure');
 // Entries without a time sort to the top of the log, as in a full read.
 replies=[{status:'ok',run,execution:{},preflight_unchanged:true,activity:{entries:[{source:'Log',message:'Saved runner log could not be read',level:'error'}],truncated:0,run_id:'r',head:0,cursor:'r:9:0.y',partial:true}}];
 await poll();
 assert.deepEqual(messages(),['line 1','Saved runner log could not be read'],'the untimed entry is appended');
 vm.runInContext('pgAutomation.tab="live";pgAutomationRenderActivityReal();',c);
 const log=elements.get('pgAutomationLog').innerHTML;
 assert.ok(log.includes('could not be read')&&log.indexOf('could not be read')<log.indexOf('line 1'),'and renders first, as a full read shows it');
 console.log(JSON.stringify({ok:true,checks:'bare first poll, encoded parameters, kept check list, appended lines, cap, reset, missed poll, dropped check list, older daemon, received stamp, elapsed advance, untimed entries first'}));
})().catch(e=>{console.error(e);process.exit(1);});
