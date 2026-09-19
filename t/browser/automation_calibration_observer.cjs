// Read-only Calibration workspace follows automation, not manual cached sweeps.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000});
  await page.setContent('<div id="meterCard"><button id="manualStart" onclick="window.manualWrites++">Start manual</button></div>'+fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8'));
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  await page.evaluate(()=>{
   window.manualWrites=0;window.calls=[];window.rendered=[];
   window.data={status:'ok',run_id:'observer-run',run_status:'running',active_stage:'greyscale-done',fetched_at:Date.now()/1000,item:{name:'SDR Filmmaker',signal_format:'sdr',status:'running'},checks:[],snapshots:[{key:'greyscale-21',phase:'pre',snapshot:{readings:[{Y:999}]}}],live:{key:'grey',phase:'calibration',snapshot:{readings:[{Y:100}],target_gamma:'bt1886'}}};
   window.fetchJSON=async(url,options)=>{calls.push({url,method:options?.method||'GET'});return JSON.parse(JSON.stringify(data));};
   window.meterFullAutoCalBuildSnapshotReportSections=async entries=>{rendered=entries;return '<p>'+entries.map(e=>e.title+' Y='+e.snapshot.readings[0].Y).join(' | ')+'</p>';};
   pgAutomation.current={run:{id:'observer-run',status:'running',active_item:0,active_stage:'greyscale-done',items:[{name:'SDR Filmmaker'},{name:'HDR Filmmaker'}],worker_status:{current_name:'Reading 2.3%',current_step:33,total_steps:34}}};
   pgAutomation.liveSelection={runId:'observer-run',index:1};pgAutomation.followLive=false;
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  const ready=()=>page.waitForFunction(()=>pgAutomation.jobViews.calibration?.data&&!pgAutomation.jobViews.calibration.loading&&!pgAutomation.reportBusy);
  await ready();
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.calibration.index),0,'follows active job independently of Automation inspection selection');
  assert.equal(await page.$eval('#meterCard',el=>el.inert&&getComputedStyle(el).display==='none'),true,'manual calibration controls are hidden and inert');
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.snapshot.readings[0].Y)),[100],'live 1D data replaces pre-read graphs');
  assert.match(await page.$eval('#pgAutomationCalibrationProgress',el=>el.textContent),/Job 1 of 2.*Reading 2.3%.*33 \/ 34/,'current job and worker progress are visible');
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation active · Read-only','active automation ownership is clearly labelled');
  for(const value of [105,110,115]){
   await page.evaluate(async value=>{data.live.snapshot.readings=[{Y:value,timestamp:1789395000+value}];await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);},value);
   assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),new RegExp('Y='+value),'successive live measurements replace the graphs');
  }
  await page.evaluate(async()=>{data.live.snapshot.message='Retrying invalid measurement for 5% (2/4)';data.live.snapshot.measurement_retry={attempt:2,limit:4};await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);});
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-measurement]',el=>el.textContent),/Retrying invalid measurement.*2\/4.*last measurements/,'invalid samples explain why graphs have not advanced');
  assert.equal(await page.$eval('#pgAutomationCalibrationDetail [data-job-measurement]',el=>el.style.color),'var(--orange)','retry notice is amber, not an execution error');
  await page.evaluate(async()=>{delete data.live.snapshot.measurement_retry;data.live.snapshot.message='Reading 7%';await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);});
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-measurement]',el=>el.textContent),/Reading 7%.*Last valid measurement/,'recovery shows activity and last measured time');
  assert.equal(await page.$eval('#pgAutomationCalibrationDetail [data-job-measurement]',el=>el.style.color),'','successful read clears amber state');
  await page.evaluate(()=>{pgAutomation.current.run.status='paused';pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation paused · Read-only','badge does not imply a paused batch is actively calibrating');
  await page.evaluate(()=>{pgAutomation.current.run.status='running';pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  await page.evaluate(()=>pgAutomationReleaseCalibrationView());
  assert.equal(await page.$eval('#meterCard',el=>el.inert),true,'cannot unlock manual controls during a batch');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_stage='volume-done';data.active_stage='volume-done';data.live={key:'3d',phase:'calibration',snapshot:{readings:[]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),/No measurements for the current stage/,'new stage waits without relabelling old graphs');
  await page.evaluate(async()=>{data.live.snapshot.readings=[{Y:200}];await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);});
  assert.match(await page.evaluate(()=>rendered[0].title),/Live calibration · 3D LUT/,'3D stage automatically selects profile charts');
  assert.equal(await page.evaluate(()=>rendered[0].snapshot.type),'colors','profile uses shared colour chart renderer');
  await page.evaluate(async()=>{
   data.snapshots.push({key:'grey',phase:'calibration',snapshot:{readings:[{Y:115}]}});
   await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);
  });
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.title)),['Saved calibration · 1D LUT','Live calibration · 3D LUT'],'earlier calibration remains visible above the live profile with truthful labels');
  assert.equal(await page.$('#pgAutomationCalibrationDetail [data-job-graph-select]'),null,'observer shows both sections without a selector');
  await page.evaluate(()=>{data.snapshots=data.snapshots.filter(s=>s.phase==='pre');});
  await page.evaluate(()=>{
   pgAutomation.current.run.active_stage='post-readings-done';data.active_stage='post-readings-done';data.live={key:'saturations-24',phase:'post',snapshot:{readings:[{Y:300}]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.evaluate(()=>rendered[0].title),/After \(measuring\).*Saturation/,'post-read stage follows the active sweep');
  await page.evaluate(async()=>{
   const original=fetchJSON;fetchJSON=async()=>{throw new Error('Network lost');};
   await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);fetchJSON=original;
  });
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-error]',el=>el.textContent),/last received, not confirmed current/,'lost connection labels old measurements stale');
  assert.equal(await page.$eval('#meterCard',el=>el.inert),true,'connection loss does not unlock controls');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_item=1;pgAutomation.current.run.active_stage='greyscale-done';data.active_stage='greyscale-done';data.item={name:'HDR Filmmaker',signal_format:'hdr10'};data.live={key:'grey',phase:'calibration',snapshot:{readings:[{Y:400}]}};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.calibration.index),1,'automatically follows the next job');
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.snapshot.readings[0].Y)),[400],'previous job graphs do not leak');
  assert.deepEqual(await page.evaluate(()=>{
   const d={run_status:'running',active_stage:'volume-done',item:{signal_format:'dv'},snapshots:[{phase:'pre',key:'colors-30',snapshot:{readings:[{Y:999}]}}],live:{phase:'calibration',key:'dv-profile',snapshot:{readings:[{Y:123}]}}};
   const live=pgAutomationCalibrationSnapshots(d);d.active_stage='volume-settings-verified';
   return {key:live[0].key,readings:live[0].snapshot.readings.length,between:pgAutomationCalibrationSnapshots(d).length};
  }),{key:'dv-profile',readings:1,between:0},'Dolby Vision follows its profile and verification stages never borrow pre-read graphs');
  await page.evaluate(async()=>{
   pgAutomation.current.run.active_stage='volume-done';data.active_stage='volume-done';
   data.item={name:'DV Filmmaker',signal_format:'dv',target_gamma:'st2084',color_format:'0',signal_range:'2',max_bpc:8};
   // Real worker schema: measured xyY lives in steps, with no readings array.
   data.live={key:'dv-profile',phase:'calibration',snapshot:{steps:[
    {name:'black',kind:'black',x:.3127,y:.329,luminance:0},
    {name:'white',kind:'white',x:.3127,y:.329,luminance:500},
    {name:'red',kind:'red',x:.64,y:.33,luminance:100}
   ]}};
   await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);
  });
  assert.deepEqual(await page.evaluate(()=>({
   count:rendered[0].snapshot.readings.length,key:rendered[0].snapshot.cache_key,
   gamma:rendered[0].snapshot.target_gamma,map:rendered[0].snapshot.dv_map_mode
  })),{count:3,key:'lg-dv-profile',gamma:'2.2',map:'2'},'real partial DV profile reaches its native chart, not the no-data placeholder');
  // 18 Sep 2026: while the whole queue is checked no job has started, yet both
  // panes named job 1 as if it were running while the runner restored modes.
  await page.evaluate(()=>{
   pgAutomation.current.run.active_item=null;pgAutomation.current.run.active_stage='queue-preflight';
   pgAutomation.current.run.worker_status={message:'Restoring original output and picture modes after queue checks'};
   pgAutomation.followLive=true;pgAutomation.liveSelection=null;
   pgAutomationSyncCalibrationView(pgAutomation.current.run);pgAutomationSyncLiveDetail(pgAutomation.current.run);
  });
  assert.match(await page.$eval('#pgAutomationCalibrationProgress',el=>el.textContent),/Queue check.*Checking the whole queue.*Initial checks.*Restoring original output/s,'the observer names the queue check while no job has started');
  assert.doesNotMatch(await page.$eval('#pgAutomationCalibrationProgress',el=>el.textContent),/Job \d+ of|Filmmaker/,'and borrows no job name');
  assert.match(await page.$eval('#pgAutomationCalibrationDetail',el=>el.textContent),/Queue check.*Checking the whole queue before any calibration begins/s,'the observer detail says the same');
  assert.match(await page.$eval('#pgAutomationLiveDetail',el=>el.textContent),/Queue check.*Checking the whole queue before any calibration begins/s,'and so does the live pane');
  assert.equal(await page.evaluate(()=>pgAutomation.jobViews.calibration||pgAutomation.jobViews.live||null),null,'no job detail is fetched for a job that has not started');
  await page.evaluate(()=>{
   pgAutomation.current.run.active_item=1;pgAutomation.current.run.active_stage='volume-done';pgAutomation.current.run.worker_status={current_name:'Reading 2.3%',current_step:33,total_steps:34};
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationProgress',el=>el.textContent),/Job 2 of 2/,'the job view returns once a job starts');
  await page.evaluate(()=>{
   pgAutomation.current.run.status='complete';pgAutomation.current.run.active_item=2;pgAutomation.current.run.active_stage='item-complete';data.run_status='complete';data.active_stage='item-complete';data.live=null;data.snapshots=[{key:'greyscale-21',phase:'post',snapshot:{readings:[{Y:500}]}}];
   pgAutomationSyncCalibrationView(pgAutomation.current.run);
  });
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),/After.*500/,'terminal state retains final results');
  await page.evaluate(async()=>{
   data.snapshots.push({key:'dv-profile',phase:'calibration',snapshot:{steps:[{name:'white',luminance:510,x:.3127,y:.329}]}});
   await pgAutomationFetchJob('calibration',pgAutomation.jobViews.calibration);
  });
  assert.deepEqual(await page.evaluate(()=>rendered.map(e=>e.title)),['After · Greyscale','Saved calibration · Dolby Vision profile'],'final greyscale sweep does not hide the saved volume result');
  assert.equal(await page.$eval('#pgAutomationCalibrationBadge',el=>el.textContent),'Automation complete · Read-only','finished results are not labelled as active automation');
  await page.evaluate(()=>{pgAutomation.current.run.status='complete-with-warnings';data.run_status='complete-with-warnings';pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  await ready();
  assert.match(await page.$eval('#pgAutomationCalibrationDetail [data-job-graphs]',el=>el.textContent),/After.*500/,'completed runs with warnings retain saved graphs too');
  assert.match(await page.$eval('#pgAutomationCalibrationHelp',el=>el.textContent),/Review the warnings/,'completed warnings have specific help');
  const navigation=await page.evaluate(()=>{
   const originalTab=pgAutomationTab,originalShow=pgAutomationShowJob;
   let selected;pgAutomationTab=()=>{document.getElementById('pgAutomationTabLive').style.display='';};pgAutomationShowJob=(view,id,index)=>{selected={view,id,index};};
   pgAutomationEl('Live').innerHTML='<button id="unsafeFocus">Stop</button><button data-job-index="1">Final job</button>';
   pgAutomationOpenRun();
   const result={selected,focus:document.activeElement.dataset.jobIndex};
   pgAutomationTab=originalTab;pgAutomationShowJob=originalShow;return result;
  });
  assert.equal(navigation.selected.index,1,'completed batch navigation clamps to the last real job');
  assert.equal(navigation.focus,'1','navigation focuses the job, never a run-control button');
  await page.setViewport({width:390,height:844});
  assert.equal(await page.$eval('#pgAutomationCalibrationCard',el=>el.scrollWidth<=el.clientWidth+1),true,'observer fits narrow screens');
  await page.click('#pgAutomationCalibrationRelease');
  assert.equal(await page.$eval('#meterCard',el=>el.inert),false,'manual controls restored only after terminal run and explicit return');
  assert.equal(await page.$eval('#pgAutomationCalibrationCard',el=>el.style.display),'none','observer closes cleanly');
  assert.equal(await page.evaluate(()=>manualWrites),0,'observation never triggers manual calibration');
  assert.equal(await page.evaluate(()=>calls.every(c=>c.method==='GET'&&/^\/api\/automation\/runs\/observer-run\/jobs\/[01]$/.test(c.url))),true,'observer fetches job data only, never worker-control endpoints');
  assert.deepEqual(errors,[]);
  console.log('Calibration automation observer checks passed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
