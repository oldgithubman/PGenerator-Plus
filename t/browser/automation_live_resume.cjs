// Explicit hardware operation: resume one interrupted/paused batch through the
// browser, then observe it every two minutes. Never retries or changes jobs.
// node t/browser/automation_live_resume.cjs http://PI RUN_ID EXISTING_EVIDENCE_DIR
// Add --observe to watch an already-started run without issuing Resume.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const [base,runId,evidence]=process.argv.slice(2);
assert.ok(base&&runId&&evidence,'Supply the generator URL, exact run ID and evidence directory');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function record(value){const line=JSON.stringify(value);console.log(line);fs.appendFileSync(path.join(evidence,'monitor.jsonl'),line+'\n');}
(async()=>{
 if(!process.argv.includes('--observe')){
 const browser=await require('puppeteer').launch({headless:true});
 try{
  const page=await browser.newPage();await page.setViewport({width:1440,height:1100});
  page.on('pageerror',error=>record({browserError:error.message}));
  await page.goto(base,{waitUntil:'domcontentloaded'});await page.waitForSelector('#automationCard');
  await page.evaluate(async()=>{pgSelectDesktopWorkspace('automation');await pgAutomationRefresh();pgAutomationTab('live');});
  // Initial page boot also polls asynchronously. Wait for a populated current
  // run before inspecting; never resume an unknown or different run.
  await page.waitForFunction(()=>pgAutomationCurrentRun()?.id,{timeout:30000});
  const before=await page.evaluate(()=>({id:pgAutomationCurrentRun()?.id,status:pgAutomationCurrentRun()?.status}));
  assert.equal(before.id,runId,'Only resume the requested run');assert.ok(['interrupted','paused'].includes(before.status),'Run must be resumable');
  const response=page.waitForResponse(r=>r.url().endsWith('/control/resume')&&r.request().method()==='POST',{timeout:300000});
  await page.click('#pgAutomationResumeButton');
  const result=await(await response).json();record({action:'resume',status:result.status,message:result.message,ready:result.ready});
  assert.equal(result.status,'ok');assert.notEqual(result.ready,0,'Readiness must pass');
  await page.waitForFunction(()=>pgAutomationCurrentRun()?.status==='running',{timeout:20000});
  await page.screenshot({path:path.join(evidence,'resumed.png')});
 }finally{await browser.close();}
 }
 let last='',errors=0;
 for(let tick=0;tick<720;tick++){
  await pause(120000);
  try{
   const d=await(await fetch(base+'/api/automation/runs/current',{signal:AbortSignal.timeout(15000)})).json(),r=d.run;
   assert.equal(r?.id,runId,'Current run changed; stop observing this attempt');
   const state={time:new Date().toISOString(),status:r.status,job:r.active_item==null?null:Number(r.active_item)+1,stage:r.active_stage,heartbeatAge:r.heartbeat_age,worker:r.worker_status,failure:r.failure};
   const key=[state.status,state.job,state.stage,state.worker?.status].join(':');
   if(key!==last||tick%5===0||r.heartbeat_age>120){record(state);last=key;}
   errors=0;
   if(['interrupted','failed','stopped','complete'].includes(r.status)){record({terminal:true,...state});return;}
  }catch(error){record({statusUnconfirmed:error.message});if(++errors>=3)throw error;}
 }
 throw Error('Observation window ended without completion');
})().catch(error=>{console.error(error);process.exitCode=1;});
