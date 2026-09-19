// Offline design/state regression. No device connection or calibration writes.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage();
  await page.setContent('<style>'+fs.readFileSync(path.join(root,'webui-theme.css'),'utf8')+'</style>'+fs.readFileSync(path.join(root,'webui-automation.html'),'utf8'));
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  await page.evaluate(()=>{
   pgAutomationRenderReadiness({ready:false,message:'Resolve these checks',checks:[{ok:false,level:'error',message:'Pair and connect the LG TV before starting automation'},{ok:false,level:'warning',message:'Verify TruMotion is off in the TV menu'},{ok:true,message:'Meter connected'}]});
  });
  assert.equal(await page.$$eval('#pgAutomationReadiness li',els=>els.length),2,'failed checks are directly visible, successful ones remain in the log');
  assert.match(await page.$eval('#pgAutomationReadiness',e=>e.textContent),/Pair and connect/);
  assert.equal(await page.$eval('#pgAutomationReadiness details',e=>e.open),true,'a failed check opens the list');
  // 18 Sep 2026: a six-job check listed 42 manual notices as one flat list in
  // the order the runner visited the jobs (last first). Group them by job in
  // queue order, equipment first, and keep warnings-only results folded.
  await page.evaluate(()=>{
   pgAutomation.queue={name:'Reference settings',items:[{name:'DV Filmmaker',signal_format:'dv'},{name:'HDR Filmmaker',signal_format:'hdr10'},{name:'SDR Filmmaker',signal_format:'sdr'}]};
   pgAutomationRenderReadiness({scope:'queue',ready:true,message:'All 3 pending jobs passed live preflight.',jobs:[{name:'DV Filmmaker'},{name:'HDR Filmmaker'},{name:'SDR Filmmaker'}],checks:[
    {ok:true,message:'Meter detected'},
    {ok:false,level:'warning',item_number:2,message:'TruMotion: verify Off in the TV menu'},
    {ok:false,level:'warning',item_number:2,message:'LG did not expose screenSaver through the control API'},
    {ok:true,item_number:2,message:'Picture mode filmMaker matches sdr'},
    {ok:false,level:'warning',item_number:1,message:'TruMotion: verify Off in the TV menu'},
    {ok:false,level:'warning',item_number:0,message:'TruMotion: verify Off in the TV menu'},
    {ok:false,level:'warning',item_number:'0',message:'TruMotion: verify Off in the TV menu'}]},
    {id:'r1',queue_name:'Reference settings',items:[{name:'DV Filmmaker'},{name:'HDR Filmmaker'},{name:'SDR Filmmaker'}]});
  });
  assert.equal(await page.$eval('#pgAutomationReadiness details',e=>e.open),false,'warnings only: the list stays folded behind the verdict');
  assert.match(await page.$eval('#pgAutomationReadiness summary',e=>e.textContent),/6 checks · 4 to check/,'the summary counts distinct checks and what needs a look');
  assert.deepEqual(await page.$$eval('#pgAutomationReadiness h5',els=>els.map(e=>e.textContent.replace(/\s+/g,' ').trim())),
   ['Equipment and queue passed','Job 1 · DV Filmmaker 1 to check','Job 2 · HDR Filmmaker 1 to check','Job 3 · SDR Filmmaker 2 to check · 1 passed'],
   'checks are grouped per job in queue order, matching the job list, however the runner visited them');
  assert.equal(await page.$$eval('#pgAutomationReadiness li',els=>els.filter(e=>/^Job \d+:/.test(e.textContent)).length),0,'a job heading replaces the per-line job prefix');
  // A reminder to check a TV menu the API does not expose is a note in the
  // muted colour; only a control that could not be verified is orange.
  await page.evaluate(()=>{
   pgAutomationRenderReadiness({scope:'queue',ready:true,message:'All 1 pending jobs passed live preflight.',jobs:[{name:'SDR Filmmaker'}],checks:[
    {ok:false,level:'warning',name:'item-0-manual',item_number:0,message:'TruMotion: verify Off in the TV menu; this control is not available through the API.'},
    {ok:false,level:'warning',name:'item-0-hazard-screenSaver',item_number:0,message:'LG did not expose screenSaver through the control API; verify it is disabled manually before calibration'},
    {ok:false,level:'warning',name:'item-0-panel-protection',item_number:0,message:'Panel protection (TPC/GSR) will be switched off for this job\'s measurements; the TV offers no readback.'},
    {ok:false,level:'warning',name:'item-0-key-colorGamut',item_number:0,message:'colorGamut: Requested Auto; LG reported Wide.'}]});
  });
  assert.deepEqual(await page.$$eval('#pgAutomationReadiness li',els=>els.map(e=>e.dataset.level)),['note','note','note','warning'],'menu reminders are notes; an unverified control stays a warning');
  assert.notEqual(await page.$eval('#pgAutomationReadiness [data-level=note]',e=>getComputedStyle(e).color),await page.$eval('#pgAutomationReadiness [data-level=warning]',e=>getComputedStyle(e).color),'notes are not coloured like warnings');
  assert.match(await page.$eval('#pgAutomationReadiness summary',e=>e.textContent),/4 checks · 1 to check · 3 manual/,'the summary separates what to check from what to remember');
  assert.notEqual(await page.$eval('#pgAutomationStartButton',e=>getComputedStyle(e).backgroundColor),'rgb(255, 68, 68)','Run queue is not a red button');
  assert.equal(await page.$$eval('#pgAutomationReadiness li',els=>els.length),4,'a job reported twice (batch and job pass) is listed once');
  await page.evaluate(()=>{
   pgAutomationRenderReadiness({ready:false,message:'Resolve these checks',checks:[{ok:false,level:'error',message:'Pair and connect the LG TV before starting automation'},{ok:false,level:'warning',message:'Verify TruMotion is off in the TV menu'},{ok:true,message:'Meter connected'}]});
  });
  for(const theme of ['dark','light']){
   await page.evaluate(theme=>document.documentElement.dataset.theme=theme,theme);
   assert.notEqual(await page.$eval('#pgAutomationReadiness [data-level=error]',e=>getComputedStyle(e).color),await page.$eval('#pgAutomationReadiness [data-level=warning]',e=>getComputedStyle(e).color),theme+': failures and warnings differ');
   await page.evaluate(()=>pgAutomationStateBadge('complete-with-warnings'));
   assert.equal(await page.$eval('#pgAutomationState',e=>getComputedStyle(e).color),await page.$eval('#pgAutomationReadiness [data-level=warning]',e=>getComputedStyle(e).color),theme+': completed warnings use the warning token');
  }
  await page.evaluate(()=>{
   pgAutomation.lastProblem='';pgAutomation.current={run:{id:'design',status:'running',active_item:0,active_stage:'greyscale-done',items:[{name:'SDR',status:'running',warnings:[{message:'Verify a manual control'}]}]}};
   pgAutomationRenderProgress();
  });
  assert.match(await page.$eval('#pgAutomationProgress [data-level=warning]',e=>e.textContent),/Verify a manual control/);
  assert.equal(await page.$eval('#pgAutomationProgress',e=>e.dataset.error),'false','warnings do not mark a run failed');
  await page.evaluate(()=>{pgAutomation.current.run.status='complete-with-warnings';pgAutomationRenderProgress();});
  assert.match(await page.$eval('#pgAutomationProgress .auto-run-warnings',e=>e.textContent),/1 recorded warning.*Verify a manual control/,'terminal summary retains warning count and reason');
  await page.evaluate(()=>{pgAutomationPollLive=()=>{};pgAutomationRefresh=()=>{};pgAutomationTab('queue');});
  await page.focus('#pgAutomationQueueTab');
  await page.keyboard.press('ArrowRight');
  assert.equal(await page.evaluate(()=>document.activeElement.id),'pgAutomationRecipesTab');
  await page.keyboard.press('End');
  assert.equal(await page.evaluate(()=>document.activeElement.id),'pgAutomationHistoryTab');
  await page.keyboard.press('Home');
  assert.equal(await page.evaluate(()=>document.activeElement.id),'pgAutomationQueueTab');
  assert.equal(await page.$$eval('[role=tab][tabindex="0"]',els=>els.length),1,'one selected tab is in the tab order');
  await page.evaluate(()=>{
   pgAutomationEl('HistoryList').innerHTML=pgAutomationHistorySummary({id:'test',queue_name:'Long queue name '.repeat(20),status:'complete'},0);
   pgAutomationTab=()=>{};pgAutomationEl('TabQueue').style.display='none';pgAutomationEl('TabHistory').style.display='';
  });
  await page.setViewport({width:320,height:900});
  assert.ok(await page.$eval('.auto-history-row',e=>e.scrollWidth<=e.clientWidth+1),'long history rows fit a narrow screen');
  await page.evaluate(()=>{const e=pgAutomationEl('StopButton');e.disabled=true;e.style.display='';});
  assert.ok(await page.$eval('#pgAutomationStopButton',e=>Number(getComputedStyle(e).opacity)<1),'disabled run controls have a visible disabled state');
  await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
  assert.equal(await page.$eval('#pgAutomationStartButton',e=>getComputedStyle(e).transitionDuration),'0s');
  console.log('Automation design state checks passed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
