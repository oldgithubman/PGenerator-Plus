const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),http=require('http'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
const html='<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+read('webui-theme.css')+'</style>'+read('webui-automation.html')+'<script>window.fetchJSON=async(url,options)=>{const response=await fetch(url,options);return response.json();};</script><script>'+read('webui-automation.js')+'</script>';
// 23 Sep 2026: a draft saved while editing pending jobs of run
// 20260921-174459-e011aa outlived the run. Every reload restored the binding,
// so Run queue stayed hidden and + New queue was refused.
const job=(name,status)=>({name,signal_format:'sdr',picture_mode:'expert1',...(status?{status,checkpoints:[{name:'greyscale',status:'done'}]}:{})});
const draft=runId=>JSON.stringify({queue:{name:'Evening queue',items:[job('Job A','complete'),job('Job B','queued'),job('Job C','queued')]},editingRunId:runId,firstPending:1,selectedQueue:'',loadedQueueSnapshot:''});
// runs/current names the bound run with this status; null means no current run.
let current=null;const runs={'finished-run':'complete','active-run':'running'},calls=[];
(async()=>{
 const server=http.createServer((req,res)=>{
  req.resume();req.on('end',()=>{
   if(!req.url.startsWith('/api/')){res.setHeader('Content-Type','text/html');return res.end(html);}
   calls.push(req.method+' '+req.url);res.setHeader('Content-Type','application/json');
   let result={status:'ok',recipes:[],queues:[],runs:[]};
   const url=req.url.split('?')[0],one=url.match(/^\/api\/automation\/runs\/([^/]+)$/);
   if(url==='/api/automation/runs/current')result={status:'ok',run:current,execution:null,preflight:null,activity:{}};
   else if(one)result=runs[one[1]]?{status:'ok',run:{id:one[1],status:runs[one[1]],items:[]},activity:{}}:{status:'error',error_code:'not-found',message:'Automation run not found'};
   res.end(JSON.stringify(result));
  });
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await puppeteer.launch({headless:true});
 const base='http://127.0.0.1:'+server.address().port;
 async function open(runId){
  const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.setViewport({width:1280,height:1000});
  await page.goto(base+'/blank');await page.evaluate(value=>localStorage.setItem('pgen.automation.queueDraft',value),draft(runId));
  await page.goto(base);await page.waitForFunction(()=>pgAutomation.loaded&&pgAutomation.current);
  return {page,errors};
 }
 const state=page=>page.evaluate(()=>({
  start:getComputedStyle(pgAutomationEl('StartButton')).display,pending:pgAutomationEl('SavePendingButton').style.display,
  context:pgAutomationEl('QueueContext').textContent,notice:pgAutomationEl('Notice').textContent,
  names:pgAutomation.queue.items.map(item=>item.name),statuses:pgAutomation.queue.items.map(item=>item.status??null),
  saved:JSON.parse(localStorage.getItem('pgen.automation.queueDraft')).editingRunId,
 }));
 const released=page=>page.waitForFunction(()=>!pgAutomation.editingRunId,{timeout:5000});
 try{
  // Run folder deleted: runs/current is empty and the run lookup is not-found.
  let {page,errors}=await open('missing-run');await released(page);
  let s=await state(page);
  assert.notEqual(s.start,'none','Run queue is offered again');
  assert.equal(s.pending,'none','Save Pending Changes is gone');
  assert.equal(s.context,'','no locked-items banner');
  assert.deepEqual(s.names,['Job A','Job B','Job C'],'every job survives as a draft');
  assert.deepEqual(s.statuses,[null,null,null],'run status is stripped from the draft');
  assert.equal(s.saved,'','the stored draft no longer carries the binding, so a reload stays fixed');
  assert.match(s.notice,/no longer exists/);assert.match(s.notice,/first job already ran/);
  await page.evaluate(()=>pgAutomationNewQueue());
  assert.ok(await page.$eval('#pgAutomationQueueDialog',el=>el.open),'+ New queue opens its dialog');
  await page.reload();await page.waitForFunction(()=>pgAutomation.loaded&&pgAutomation.current);
  s=await state(page);assert.notEqual(s.start,'none','still fixed after reload');assert.deepEqual(s.names,['Job A','Job B','Job C']);
  assert.deepEqual(errors,[]);await page.close();

  // Run still on disk but finished, and no longer the current run.
  ({page,errors}=await open('finished-run'));await released(page);
  s=await state(page);assert.notEqual(s.start,'none');assert.match(s.notice,/has ended \(complete\)/);
  assert.deepEqual(errors,[]);await page.close();

  // Run is the current one and reports a terminal status on the live poll.
  current={id:'polled-run',status:'stopped',items:[]};
  ({page,errors}=await open('polled-run'));await released(page);
  s=await state(page);assert.notEqual(s.start,'none');assert.match(s.notice,/has ended \(stopped\)/);
  assert.ok(!calls.includes('GET /api/automation/runs/polled-run'),'the live poll answer is enough; no extra lookup');
  assert.deepEqual(errors,[]);await page.close();

  // Control: an active bound run keeps the edit binding and its locks.
  current={id:'active-run',status:'running',active_item:0,items:[]};
  ({page,errors}=await open('active-run'));
  await page.evaluate(()=>pgAutomationPollLive());
  s=await state(page);
  assert.equal(await page.evaluate(()=>pgAutomation.editingRunId),'active-run','a running batch stays bound');
  assert.equal(s.start,'none');assert.match(s.context,/Editing pending items for active-run/);
  // Declining the question leaves everything as it was.
  await page.evaluate(()=>{globalThis.pgAutomationConfirmOverride=()=>false;});
  await page.click('#pgAutomationStopEditingButton');await page.evaluate(()=>pgAutomationNewQueue());
  assert.equal(await page.evaluate(()=>pgAutomation.editingRunId),'active-run','cancel keeps the binding');
  assert.ok(!await page.$eval('#pgAutomationQueueDialog',el=>el.open),'cancel does not open the new-queue dialog');
  // Stop editing: the way out while the batch is still running.
  await page.evaluate(()=>{globalThis.pgAutomationConfirmOverride=()=>true;});
  await page.click('#pgAutomationStopEditingButton');
  await page.evaluate(()=>pgAutomationPollLive());
  s=await state(page);
  assert.notEqual(s.start,'none','Run queue returns after Stop editing');
  assert.deepEqual(s.names,[],'the page starts from an empty queue');
  assert.equal(s.saved,'','the stored draft is unbound');assert.equal(s.context,'');
  assert.match(s.notice,/Stopped editing active-run/);
  assert.ok(!calls.some(call=>call.startsWith('POST /api/automation/runs/active-run')),'the batch itself is never touched');
  assert.deepEqual(errors,[]);await page.close();

  // + New queue while bound asks once, then opens the dialog instead of refusing.
  ({page,errors}=await open('active-run'));
  await page.evaluate(()=>{globalThis.pgAutomationConfirmOverride=()=>true;});
  await page.evaluate(()=>pgAutomationNewQueue());
  assert.equal(await page.evaluate(()=>pgAutomation.editingRunId),'','+ New queue ends the edit');
  assert.ok(await page.$eval('#pgAutomationQueueDialog',el=>el.open),'+ New queue opens its dialog');
  assert.deepEqual(errors,[]);await page.close();
  console.log('PASS stale edit binding released for missing, finished and polled-terminal runs; active run stays bound until Stop editing or + New queue');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1});
