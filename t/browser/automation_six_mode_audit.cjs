// Read-only deployed six-mode UI audit. Never starts/stops or changes TV settings.
// node t/browser/automation_six_mode_audit.cjs http://PI RUN_ID EVIDENCE_DIRECTORY
const assert=require('node:assert/strict'),path=require('path'),fs=require('fs'),puppeteer=require('puppeteer');
const [base,runId,evidence]=process.argv.slice(2);assert.ok(base&&runId&&evidence);
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try {
  const page=await browser.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100});
  await page.setRequestInterception(true);
  page.on('request',r=>['GET','HEAD'].includes(r.method())?r.continue():r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only UI audit"}'}));
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof pgAutomationCurrentRun==='function'&&pgAutomationCurrentRun()?.id,{timeout:60000});
  const localLogFix=process.argv.includes('--local-log-fix');
  if(localLogFix){
   const source=fs.readFileSync(path.resolve(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8');
   for(const name of ['pgAutomationLogScroll','pgAutomationRenderActivity']){
    const start=source.indexOf('function '+name+'('),end=source.indexOf('\nfunction ',start+1),asyncEnd=source.indexOf('\nasync function ',start+1);
    await page.addScriptTag({content:source.slice(start,Math.min(...[end,asyncEnd].filter(i=>i>=0)))});
   }
  }
  const reference=await page.evaluate(()=>pgAutomationReferenceItems(PG_AUTOMATION_REFERENCE_MODES.map(m=>m.id)).map(i=>({mode:i.picture_mode,target:i.calibration.target_delta_e,stages:i.stages})));
  assert.equal(reference.length,6);
  assert.ok(reference.some(i=>i.mode==='hdrCinema'));
  assert.ok(!reference.some(i=>i.mode==='hdrCinemaBright'));
  reference.forEach(i=>{assert.equal(i.target,0.5);assert.ok(!i.stages.pre_readings&&!i.stages.post_readings)});
  await page.evaluate(()=>{pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('automation');pgAutomationTab('live')});
  assert.equal(await page.evaluate(()=>pgAutomationCurrentRun().id),runId);
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data&&!pgAutomation.reportBusy&&document.querySelectorAll('#pgAutomationLiveDetail img').length>0,{timeout:90000});
  const current=await page.evaluate(()=>({index:pgAutomation.jobViews.live.index,name:pgAutomation.jobViews.live.data.item.name,following:pgAutomation.followLive,graphs:document.querySelectorAll('#pgAutomationLiveDetail img').length,stage:pgAutomationCurrentRun().active_stage}));
  assert.ok(current.following);
  await page.evaluate(()=>{
   const card=document.getElementById('automationCard'),box=pgAutomationEl('Log'),display=card.style.display;
   pgAutomationEl('Activity').open=true;
   box.innerHTML='';box.scrollTop=0;card.style.display='none';pgAutomation.logSignature=null;pgAutomation.logFollow=true;
   pgAutomationRenderActivity();card.style.display=display;pgAutomationRenderActivity();
   if(!box.clientHeight||box.scrollHeight-box.clientHeight-box.scrollTop>=24)throw new Error('Following latest does not show latest log entries after reveal');
   box.scrollTop=0;pgAutomationLogScroll();pgAutomationRenderActivity();
   if(pgAutomation.logFollow||box.scrollTop!==0)throw new Error('Manual scroll-back was not preserved');
   pgAutomationLogLatest();
   if(pgAutomationCurrentRun().status==='complete'&&!pgAutomationEl('Progress').textContent.includes('No calibration is running'))throw new Error('Completed batch must be shown as inactive');
  });
  await page.screenshot({path:path.join(evidence,'six-mode-live-audit.png')});
  await page.click('#pgAutomationLive [data-job-index="0"]');
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.index===0&&pgAutomation.jobViews.live?.data?.item_number===0&&!pgAutomation.reportBusy,{timeout:60000});
  assert.equal(await page.evaluate(()=>pgAutomation.followLive),false);
  assert.ok(await page.$$eval('#pgAutomationLiveDetail img',imgs=>imgs.length)>0,'completed job has saved graphs');
  assert.equal(await page.$eval('#pgAutomationLiveDetail [data-job-toggles]',e=>e.textContent.includes('Before')),false,'no invented before when pre-readings disabled');
  const checks=await page.evaluate(()=>pgAutomation.jobViews.live.data.checks.length);
  assert.ok(checks>0,'completed job retains setting verification');
  await page.screenshot({path:path.join(evidence,'six-mode-completed-job-audit.png')});
  await page.setViewport({width:390,height:844});
  assert.equal((await page.$eval('#pgAutomationTabLive .auto-job-layout',e=>getComputedStyle(e).gridTemplateColumns)).split(' ').length,1,'narrow layout stacks detail');
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',runId,localLogFix,reference,current,completedJobChecks:checks,browserErrors:errors}));
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
