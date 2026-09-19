// Read-only hardware UI preview. Injects local UI into a browser, uses captured
// real measurements, and never starts/resumes/stops a calibration.
// node t/browser/automation_job_preview.cjs http://PI RUN_ID /existing/evidence
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const [base,runId,evidence]=process.argv.slice(2),root=path.resolve(__dirname,'../..');
assert.ok(base&&runId&&evidence);
(async()=>{
 const run=(await(await fetch(base+'/api/automation/runs/'+runId)).json()).run;
 const details=await Promise.all(run.items.map(async(item,index)=>{
  const snapshots=[];
  for(const phase of ['pre','post'])for(const key of item[phase+'_series']||[]){
   const snapshot=await(await fetch(base+'/api/automation/runs/'+runId+'/artifact/items/'+index+'/'+phase+'/'+key+'.json')).json().catch(()=>null);
   if(snapshot?.readings?.length)snapshots.push({phase,key,snapshot});
  }
  for(const key of ['grey','3d','dv-profile'])if(item.calibration?.[key+'-state'])snapshots.push({phase:'calibration',key,snapshot:item.calibration[key+'-state']});
  const raw=await(await fetch(base+'/api/automation/runs/'+runId+'/artifact/items/'+index+'/settings-checks.ndjson')).text();
  const checks=raw.split('\n').flatMap(line=>{try{return [JSON.parse(line)]}catch{return []}});
  return {status:'ok',run_id:runId,item_number:index,item,checks,snapshots,fetched_at:Date.now()/1000};
 }));
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100});
  await page.setRequestInterception(true);
  page.on('request',request=>{
   const match=new URL(request.url()).pathname.match(/\/jobs\/(\d+)$/);
   if(match)return request.respond({status:200,contentType:'application/json',body:JSON.stringify(details[Number(match[1])])});
   if(request.method()!=='GET'&&request.method()!=='HEAD')return request.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only preview"}'});
   request.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#automationCard');
  await page.evaluate(html=>{
   clearTimeout(pgAutomation.liveTimer);pgAutomation.liveTimer=null;
   document.getElementById('automationCard').outerHTML=html;
  },fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8'));
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'').replace(/\bPG_AUTOMATION_/g,'PREVIEW_AUTOMATION_')});
  // Load the exact shared report renderer under test, not the deployed copy.
  const workspace=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-workspace.js'),'utf8');
  await page.addScriptTag({content:workspace.slice(workspace.indexOf('async function meterFullAutoCalBuildSnapshotReportSections('),workspace.indexOf('\nfunction meterFullAutoCalReportEntries('))});
  const app=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-app.js'),'utf8');
  const mismatch=app.match(/function meterNoteCodeMismatch\(mismatched,type\)\{[\s\S]*?\n\}/);
  assert.ok(mismatch);await page.addScriptTag({content:mismatch[0]});
  await page.evaluate(async({run,runId})=>{
   pgSelectDesktopWorkspace('automation');pgAutomation.current={run};pgAutomation.tab='live';pgAutomationEl('TabQueue').style.display='none';pgAutomationEl('TabLive').style.display='';
   pgAutomationRenderLiveRun(run);pgAutomationSelectJob('live',runId,0);
  },{run,runId});
  await page.waitForFunction(()=>document.querySelectorAll('#pgAutomationLiveDetail img').length>0&&!pgAutomation.reportBusy,{timeout:90000});
  await page.screenshot({path:path.join(evidence,'job-details-desktop.png')});
  const result=await page.$eval('#pgAutomationLiveDetail',el=>({images:el.querySelectorAll('img').length,text:el.innerText.slice(0,1200),width:el.getBoundingClientRect().width}));
  await page.setViewport({width:390,height:844});
  await page.evaluate(()=>{pgSetLayoutPreference('tablet');pgAutomationEl('LiveDetail').scrollIntoView({block:'start'});});
  assert.ok(await page.$eval('#automationCard',el=>el.getBoundingClientRect().width<=390),'phone layout fits the viewport');
  await page.screenshot({path:path.join(evidence,'job-details-mobile.png')});
  assert.deepEqual(errors,[]);console.log(JSON.stringify(result));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
