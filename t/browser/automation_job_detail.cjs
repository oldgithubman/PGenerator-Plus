// Isolated browser checks: no appliance requests or calibration writes.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000});
  await page.setContent(fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8'));
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  await page.evaluate(()=>{
   window.entries=[];window.calls=[];
   window.fetchJSON=async url=>{
    calls.push(url);const index=Number(url.split('/').pop());
    return {status:'ok',fetched_at:Date.now()/1000,item:{name:'Job '+index,status:index===0?'complete':'running',settings:{},signal_format:'sdr',manual_checks:[]},checks:[{key:'brightness',expected:50,observed:null,result:'unverifiable',timestamp:1789290000,checkpoint:'c1'}],snapshots:index===0?[{phase:'post',key:'greyscale-21',snapshot:{readings:[{Y:101}]}}]:[{phase:'pre',key:'greyscale-21',snapshot:{readings:[{Y:99}]}}],live:index===1?{phase:'calibration',key:'grey',snapshot:{readings:[{Y:100}]}}:null};
   };
   window.meterFullAutoCalBuildSnapshotReportSections=async e=>{entries=e;return '<p>Rendered measured graphs</p>'};
   pgAutomation.tab='live';pgAutomationEl('TabLive').style.display='';
   pgAutomation.current={run:{id:'test-run',status:'running',active_item:1,active_stage:'greyscale-done',items:[{name:'Done',status:'complete'},{name:'Active',status:'running'}]}};
   pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data&&!pgAutomation.reportBusy);
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.live.index),1,'automatically selects active job');
  assert.equal(await page.evaluate(()=>entries.length),2,'before and live readings sent to shared renderer');
  assert.match(await page.$eval('#pgAutomationLiveDetail',e=>e.textContent),/older record does not say/,'unknown readback cause stays unknown');
  await page.click('#pgAutomationLive [data-job-index="0"]');
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data?.item.name==='Job 0');
  assert.equal(await page.evaluate(()=>pgAutomation.followLive),false,'click pins prior job');
  assert.equal(await page.$eval('[data-job-toggles]',e=>e.textContent.includes('Before')),false,'no before toggle without before data');
  await page.evaluate(()=>pgAutomationRenderLiveRun(pgAutomation.current.run));
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.live.index),0,'poll does not steal selection');
  await page.evaluate(()=>{pgAutomation.current.run.active_item=0;pgAutomationRenderLiveRun(pgAutomation.current.run);});
  assert.equal(await page.evaluate(()=>pgAutomation.followLive),false,'job advance does not unpin selection');
  await page.evaluate(()=>{pgAutomation.current.run.active_item=1;});
  await page.evaluate(()=>pgAutomationBackToLive());
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data?.item.name==='Job 1');
  await page.evaluate(()=>pgAutomationGraphToggle('live','showBefore',false));
  await page.waitForFunction(()=>entries.length===1);
  assert.match(await page.evaluate(()=>entries[0].title),/Live calibration/,'before toggle leaves latest graph');
  assert.match(await page.evaluate(()=>pgAutomationSettingReason({result:'unverifiable',reason:'Reading this setting is unsupported'})),/unsupported/,'recorded unsupported reason retained');
  assert.match(await page.evaluate(()=>pgAutomationSettingReason({result:'mismatch',observed:null})),/does not prove the write failed/,'missing readback is not a failed write');
  assert.match(await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'brightness',expected:50,result:'apply-failed',reason:'TV rejected request',timestamp:1789290000,checkpoint:'c4'}],{manual_checks:[]})),/Failed to apply[\s\S]*TV rejected request[\s\S]*After reset and reapply/,'write failures show reason and named stage');
  assert.equal(await page.evaluate(()=>pgAutomationEl('LiveDetail').textContent.includes('target missed')),false,'does not introduce target-missed status');
  assert.match(await page.evaluate(()=>pgAutomationApplyAllNote({'apply-all':{outcome:'sent-unconfirmed',confirmation_unavailable:true,confirmed:false}})),/Apply to All Inputs sent.*confirmation unavailable on this TV/,'known unsupported confirmation is an informational job note');
  assert.equal(await page.evaluate(()=>pgAutomationApplyAllNote({'apply-all':{outcome:'unverified',confirmation_unavailable:false}})),'','other unverified outcomes are not relabelled informational');
  assert.match(await page.evaluate(()=>pgAutomationStageLabel('greyscale-settings-verified')),/Checking TV settings after 1D/,'boundary progress names the actual check');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'c7-confirm'})),/before calibration exit.*fresh confirmation/,'readback evidence names boundary and confirmation');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'c8-stable'})),/After calibration exit.*stability check/,'repair evidence distinguishes post-exit stability');
  const managed=await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'colorGamut',expected:'auto',observed:'wide',verified:false,result:'lut-managed',reason:'The verified 3D LUT controls gamut',checkpoint:'c8'},{key:'brightness',expected:50,observed:50,verified:true}],{}));
  assert.match(managed,/LUT-managed[\s\S]*Requested: auto · TV reported: wide/,'LUT ownership shows both raw values');
  assert.doesNotMatch(managed,/Readback mismatch|All recorded settings matched/,'LUT ownership is neither a false match nor an error');
  const expectedGamut=await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'colorGamut',expected:'auto',observed:'wide',verified:false,result:'expected-calibration-state',checkpoint:'c6'},{key:'brightness',expected:50,observed:50,verified:true}],{}));
  assert.match(expectedGamut,/Expected calibration state[\s\S]*Requested: auto · TV reported: wide/,'expected calibration transition retains diagnostic values');
  assert.match(expectedGamut,/After 1D calibration/,'informational state retains its phase');
  assert.doesNotMatch(expectedGamut,/auto-setting-problem|Warning|Readback mismatch|All recorded settings matched/,'expected state has no warning, error or false match');
  const realDrift=await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'colorGamut',expected:'auto',observed:'wide',result:'expected-calibration-state',checkpoint:'c6'},{key:'brightness',expected:50,observed:55,result:'mismatch',checkpoint:'c6'}],{}));
  assert.match(realDrift,/auto-setting-problem[\s\S]*brightness · Readback mismatch/,'other setting failures remain prominent');
  const gamutWarning=await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'colorGamut',expected:'auto',observed:'wide',verified:false,result:'readback-warning',checkpoint:'c6'}],{}));
  assert.match(gamutWarning,/Warning — LG gamut readback[\s\S]*Requested: auto · TV reported: wide/,'warning displays raw values prominently');
  assert.doesNotMatch(gamutWarning,/Readback mismatch|All recorded settings matched|LUT-managed/,'warning is not a match, ownership claim or failure');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'c4-mode'})),/before settings/,'mode confirmation explains write ordering');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'dv-profile-before-upload'})),/After Dolby Vision profile measurements, before upload/,'profile upload boundary has a meaningful label');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'3d-processing-transition-4'})),/After calibration transition, before further measurements/,'worker transition has a meaningful label');
  assert.match(await page.evaluate(()=>pgAutomationCheckStage({checkpoint:'resume-profile-baseline'})),/Saved 1D and unity baseline restored before profile retry/,'baseline restoration has a meaningful label');
  assert.match(await page.evaluate(()=>pgAutomationIssueText('greyscale-settings-verified-unverified')),/Checking TV settings after 1D calibration: verification incomplete.*recorded checks/,'internal warning codes are explained in plain language');
  const realMismatch=await page.evaluate(()=>pgAutomationSettingsEvidence([{key:'colorGamut',expected:'auto',observed:'wide',result:'lut-managed'},{key:'brightness',expected:50,observed:55,verified:false,result:'mismatch'}],{}));
  assert.match(realMismatch,/brightness · Readback mismatch/,'LUT ownership cannot hide another control mismatch');
  await page.evaluate(async()=>{
   const state=pgAutomation.jobViews.live;state.showBefore=true;state.showAfter=true;
   state.graphGroup='3d'; // A selection left over from an older UI cannot hide data.
   state.data={item:{signal_format:'sdr'},snapshots:[
    {key:'saturations-24',phase:'post',snapshot:{readings:[{Y:30}]}},
    {key:'3d',phase:'calibration',snapshot:{readings:[{Y:20}]}},
    {key:'greyscale-21',phase:'pre',snapshot:{readings:[{Y:9}]}},
    {key:'colors-24',phase:'pre',snapshot:{readings:[{Y:25}]}},
    {key:'grey',phase:'calibration',snapshot:{readings:[{Y:10}]}},
    {key:'colors-24',phase:'post',snapshot:{readings:[{Y:26}]}}
   ],live:{key:'3d',phase:'calibration',snapshot:{readings:[{Y:21}]}}};
   await pgAutomationRenderJobGraphs('live',state);
  });
  assert.deepEqual(await page.evaluate(()=>entries.map(e=>e.snapshot.readings[0].Y)),[9,10,21,25,26,30],'all measurement families appear together, ordered with before/latest pairs and no duplicate live profile');
  assert.equal(await page.$('[data-job-graph-select]'),null,'no measurement dropdown is needed');
  assert.equal((await page.$eval('#pgAutomationLiveDetail [data-job-graphs]',e=>getComputedStyle(e).gridTemplateColumns)).split(' ').length,1,'results remain a continuous single column on desktop');
  await page.evaluate(()=>pgAutomationGraphToggle('live','showBefore',false));
  await page.waitForFunction(()=>entries.length===4);
  assert.deepEqual(await page.evaluate(()=>entries.map(e=>e.snapshot.readings[0].Y)),[10,21,26,30],'before toggle applies across every measurement family');
  await page.evaluate(()=>pgAutomationGraphToggle('live','showAfter',false));
  await page.waitForFunction(()=>document.querySelector('#pgAutomationLiveDetail [data-job-graphs]').textContent.includes('Select a comparison'));
  await page.evaluate(async()=>{
   const state=pgAutomation.jobViews.live;state.showAfter=true;
   state.data={item:{signal_format:'dv'},snapshots:[
    {key:'dv-profile',phase:'calibration',snapshot:{steps:[{name:'white',luminance:500,x:.3127,y:.329}]}},
    {key:'grey',phase:'calibration',snapshot:{readings:[{Y:100}]}},
    {key:'greyscale-21',phase:'post',snapshot:{readings:[{Y:101}]}}
   ]};
   await pgAutomationRenderJobGraphs('live',state);
  });
  assert.deepEqual(await page.evaluate(()=>entries.map(e=>e.snapshot.readings[0].Y??e.snapshot.readings[0].luminance)),[101,500],'post greyscale replaces calibration greyscale without hiding the native DV profile');
  const desktop=await page.$eval('#pgAutomationTabLive .auto-job-layout',e=>getComputedStyle(e).gridTemplateColumns);
  assert.equal(desktop.split(' ').length,2,'desktop has side-by-side panel');
  await page.setViewport({width:390,height:844});
  assert.equal((await page.$eval('#pgAutomationTabLive .auto-job-layout',e=>getComputedStyle(e).gridTemplateColumns)).split(' ').length,1,'mobile stacks panel');
  assert.equal(await page.evaluate(()=>calls.every(c=>/^\/api\/automation\/runs\/test-run\/jobs\/\d+$/.test(c))),true,'inspection only uses read-only job route');
  await page.evaluate(async()=>{
   const original=window.fetchJSON;window.fetchJSON=async()=>null;
   await pgAutomationFetchJob('live',pgAutomation.jobViews.live);window.fetchJSON=original;
  });
  assert.match(await page.$eval('[data-job-error]',e=>e.textContent),/last received, not confirmed current/,'failed refresh labels cached data stale');
  await page.evaluate(()=>{pgAutomationEl('HistoryDetail').innerHTML='<div id="pgAutomationHistoryJobs"></div><aside id="pgAutomationHistoryJobDetail"></aside>';pgAutomationSelectJob('history','test-run',0);});
  await page.waitForFunction(()=>pgAutomation.jobViews.history?.data&&!pgAutomation.reportBusy);
  assert.match(await page.$eval('#pgAutomationHistoryJobDetail',e=>e.textContent),/Job 0[\s\S]*Rendered measured graphs/,'history uses same job results and graphs');
  await page.evaluate(()=>{pgAutomation.current={run:null};pgAutomationRenderLiveRun(null);});
  assert.equal(await page.$eval('#pgAutomationLiveDetail',e=>e.innerHTML),'','no active run clears stale live selection');
  assert.deepEqual(errors,[]);
  console.log('Job details browser checks passed');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
