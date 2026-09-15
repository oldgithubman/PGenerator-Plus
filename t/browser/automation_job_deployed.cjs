// Verify the deployed UI using GET requests only. No calibration controls.
// node t/browser/automation_job_deployed.cjs http://PI RUN_ID /existing/evidence
const assert=require('node:assert/strict'),path=require('path'),fs=require('fs'),puppeteer=require('puppeteer');
const [base,runId,evidence]=process.argv.slice(2);assert.ok(base&&runId&&evidence);
const preview=process.argv.includes('--local-charts');
(async()=>{
 const detail=await(await fetch(base+'/api/automation/runs/'+runId+'/jobs/0')).json();
 assert.equal(detail.status,'ok');assert.equal(detail.run_id,runId);
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100});await page.setRequestInterception(true);
  page.on('request',request=>{
   if(!['GET','HEAD'].includes(request.method()))return request.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only deployment check"}'});
   request.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof pgAutomationSelectJob==='function');
  if(preview){
   const root=path.resolve(__dirname,'../../usr/share/PGenerator');
   const html=fs.readFileSync(path.join(root,'webui-automation.html'),'utf8');
   await page.addStyleTag({content:Array.from(html.matchAll(/<style>([^]*?)<\/style>/g),m=>m[1]).join('\n')});
   const app=fs.readFileSync(path.join(root,'webui-app.js'),'utf8');
   await page.addScriptTag({content:app.match(/function meterGreyInverseEotfSignalFromLuminance\([^]*?\n\}/)[0]});
  }
  await page.evaluate(async runId=>{
   pgSetLayoutPreference('desktop');
   pgSelectDesktopWorkspace('automation');await pgAutomationRefresh();pgAutomationTab('history');
   const index=pgAutomation.history.findIndex(run=>run.id===runId);
   if(index<0)throw new Error('Run missing from history');
   await pgAutomationOpenHistory(index);
  },runId);
  await page.waitForFunction(()=>document.querySelectorAll('#pgAutomationHistoryJobDetail img').length>0&&!pgAutomation.reportBusy,{timeout:90000});
  const dimensions=await page.$$eval('#pgAutomationHistoryJobDetail .report-chart-card',cards=>cards.filter(c=>/EOTF|^Luminance$/.test(c.querySelector('.report-chart-title')?.textContent)).map(c=>({title:c.querySelector('.report-chart-title').textContent,width:c.querySelector('img').naturalWidth,height:c.querySelector('img').naturalHeight})));
  // A completed job with both sweeps has two chart pairs: before and after.
  const eotf=dimensions.filter(d=>/EOTF/.test(d.title));
  const luminance=dimensions.filter(d=>d.title==='Luminance');
  assert.ok(eotf.length>0,'EOTF images are present');
  assert.equal(eotf.length,luminance.length,'each displayed comparison has both EOTF and luminance images');
  dimensions.forEach(d=>assert.ok(d.width/d.height>2,`${d.title} is landscape, not a stretched sidebar snapshot: ${JSON.stringify(d)}`));
  assert.ok(await page.evaluate(()=>document.body.classList.contains('layout-desktop')&&!document.body.classList.contains('pg-automation-report-render')&&getComputedStyle(document.getElementById('chartsGreyscaleFullWrap')).display==='grid'),'snapshot sizing is scoped; normal desktop chart grid is restored');
  const controls=await page.evaluate(()=>['meterTargetGamut','meterDeltaEForm','meterColorDeltaEForm','meterCustomD65Enabled','meterTargetWhiteX','meterTargetWhiteY'].map(id=>({id,value:document.getElementById(id).value,checked:document.getElementById(id).checked})));
  assert.equal(await page.$('#pgAutomationHistoryJobDetail select[aria-label="Measurement graphs"]'),null,'all measurement families share one continuous page');
  await page.evaluate(()=>{const state=pgAutomation.jobViews.history;state.graphSignature=null;return pgAutomationRenderJobGraphs('history',state);});
  await page.waitForFunction(()=>!pgAutomation.reportBusy,{timeout:30000});
  const after=await page.evaluate(()=>['meterTargetGamut','meterDeltaEForm','meterColorDeltaEForm','meterCustomD65Enabled','meterTargetWhiteX','meterTargetWhiteY'].map(id=>({id,value:document.getElementById(id).value,checked:document.getElementById(id).checked})));
  assert.deepEqual(after,controls,'report restores operator target selectors');
  await page.screenshot({path:path.join(evidence,'deployed-desktop.png')});
  for(const title of ['EOTF','Luminance']){
   const cards=await page.$$('#pgAutomationHistoryJobDetail .report-chart-card');
   for(const card of cards)if((await card.$eval('.report-chart-title',el=>el.textContent)).includes(title))await card.screenshot({path:path.join(evidence,title.toLowerCase()+'.png')});
  }
  await page.evaluate(async runId=>{pgAutomationTab('history');await pgAutomationRefresh();const index=pgAutomation.history.findIndex(run=>run.id===runId);if(index<0)throw new Error('Run missing from history');await pgAutomationOpenHistory(index);},runId);
  await page.waitForFunction(()=>document.querySelectorAll('#pgAutomationHistoryJobDetail img').length>0&&!pgAutomation.reportBusy,{timeout:90000});
  await page.setViewport({width:390,height:844});
  await page.evaluate(()=>{pgSetLayoutPreference('tablet');pgAutomationEl('HistoryJobDetail').scrollIntoView({block:'start'});});
  assert.ok(await page.$eval('#automationCard',el=>el.getBoundingClientRect().width<=390));
  await page.screenshot({path:path.join(evidence,'deployed-mobile-history.png')});
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',preview,run:runId,dimensions,checks:detail.checks.length,snapshots:detail.snapshots.length,readinessIssues:detail.readiness_issues.length,historyGraphs:await page.$$eval('#pgAutomationHistoryJobDetail img',images=>images.length)}));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
