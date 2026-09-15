// Explicit hardware check: may reconnect an already-paired TV, then reads
// TV/meter readiness; never starts calibration or saves queues.
// Usage: node t/browser/automation_live_readiness.cjs http://PI [existing-evidence-directory]
const puppeteer=require('puppeteer');
const assert=require('node:assert/strict');
const path=require('node:path');
const base=process.argv[2],evidence=process.argv[3];
if(!base)throw new Error('Supply the generator URL explicitly');
(async()=>{
 const current=await (await fetch(base+'/api/automation/runs/current')).json();
 assert.ok(!current.run||['complete','failed','stopped'].includes(current.run.status),'Do not check while a run is active');
 const tv=await (await fetch(base+'/api/lg/status')).json();
 assert.ok(tv.paired,'Pair the TV before running this check; readiness will reconnect if needed');
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];let result;
  page.on('pageerror',error=>errors.push(error.message));
  page.on('response',async response=>{
   if(response.url().endsWith('/api/automation/readiness')&&response.request().method()==='POST'){
    try{result=await response.json();}catch{}
   }
  });
  await page.setViewport({width:1440,height:1100});
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#automationCard');
  await page.evaluate(async()=>{pgSelectDesktopWorkspace('automation');await pgAutomationRefresh();});
  await page.select('#pgAutomationSavedQueueSelect','reference-settings');
  const requestId=await page.evaluate(()=>{window.readinessFinished=false;pgAutomationReadiness().finally(()=>{window.readinessFinished=true;});return pgAutomation.pendingChecks?.id;});
  let last='',screenshot=false;const jobs=new Set();
  for(let i=0;i<110;i++){
   await new Promise(resolve=>setTimeout(resolve,3000));
   const state=await page.evaluate(()=>({done:window.readinessFinished,preflight:pgAutomation.current?.preflight,banner:pgAutomationEl('Progress').textContent}));
   const pre=state.preflight,key=pre?.status+':'+pre?.active_item;
   if(pre?.id!==requestId)continue;
   if(key!==last){console.log(JSON.stringify({status:pre?.status,job:pre?.active_item==null?null:Number(pre.active_item)+1,total:pre?.total_items,message:pre?.message,banner:state.banner.slice(0,220)}));last=key;}
   if(pre?.active_item!=null)jobs.add(Number(pre.active_item));
   if(evidence&&!screenshot&&pre?.active_item>=1&&pre.status==='checking'){
    await page.screenshot({path:path.join(evidence,'checking.png')});screenshot=true;
   }
   if(state.done)break;
  }
  if(evidence)await page.screenshot({path:path.join(evidence,'result.png')});
  console.log(JSON.stringify({ready:result?.ready,checks:result?.checks?.length,errors:result?.checks?.filter(c=>!c.ok&&c.level==='error'),warningCount:result?.checks?.filter(c=>!c.ok&&c.level==='warning').length,jobsObserved:[...jobs],browserErrors:errors}));
  assert.equal(result?.ready,1,'All six reference jobs pass actual TV readiness');
  assert.equal(jobs.size,6,'Live progress observed for every job');assert.deepEqual(errors,[]);
  console.log('PASS live six-job readiness. No calibration started or queues saved.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
