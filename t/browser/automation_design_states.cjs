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
