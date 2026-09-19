// Validate real saved/live measurements in a read-only browser. --local overlays
// local chart fixes without deploying or changing the running calibration.
// node t/browser/automation_chart_deployed.cjs http://PI RUN_ID [--local]
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const [base,runId]=process.argv.slice(2),local=process.argv.includes('--local');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
(async()=>{
 const data=await(await fetch(base+'/api/automation/runs/'+runId+'/jobs/0',{signal:AbortSignal.timeout(30000)})).json();
 assert.equal(data.status,'ok');
 const snapshot=data.live?.key==='grey'&&data.live.snapshot?.readings?.length?data.live.snapshot:data.snapshots.find(s=>s.key==='grey')?.snapshot;
 assert.ok(snapshot?.readings?.length,'real 1D measurements available');assert.equal(snapshot.target_gamma,'2.2');
 // Freeze a read-only view of this measurement set so resizing is reproducible,
 // including after the real run has stopped. No requests can control a worker.
 const detail={...data,run_status:'running',active_stage:'greyscale-done',snapshots:[],live:{key:'grey',phase:'calibration',snapshot}};
 const current={status:'ok',run:{id:runId,status:'running',active_item:0,active_stage:'greyscale-done',items:[data.item]}};
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1600,height:1100,deviceScaleFactor:2});
  await page.setRequestInterception(true);page.on('request',r=>{
   if(!['GET','HEAD'].includes(r.method()))return r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only chart test"}'});
   const url=new URL(r.url());let response;
   if(url.pathname==='/api/automation/runs/current')response=current;
   if(/\/jobs\/\d+$/.test(url.pathname))response=detail;
   return response?r.respond({status:200,contentType:'application/json',body:JSON.stringify(response)}):r.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>typeof pgAutomationEl==='function');
  if(local){
   const html=fs.readFileSync(path.join(root,'webui-automation.html'),'utf8');
   await page.evaluate(css=>{const style=document.createElement('style');style.textContent=css;document.body.append(style);},[...html.matchAll(/<style>([^]*?)<\/style>/g)].map(m=>m[1]).join('\n'));
   const automation=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
   await page.addScriptTag({content:automation.slice(automation.indexOf('function pgAutomationReferenceItems')).replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
   for(const [file,pattern] of [['webui-app.js',/function meterTargetGammaLabel\([^]*?\n\}/],['webui-app.js',/function meterGreyTargetGammaSelection\([^]*?\n\}/],['webui-workspace.js',/async function meterFullAutoCalBuildSnapshotReportSections\([^]*?\n\}/]]){
    await page.addScriptTag({content:fs.readFileSync(path.join(root,file),'utf8').match(pattern)[0]});
   }
  }
  // Let native device/cache restoration finish before setting up the deliberately
  // conflicting manual selector. It is independent of snapshot rendering.
  await page.waitForNetworkIdle({idleTime:700,timeout:45000});
  // Do not edit the manual selector in the middle of an automatic snapshot.
  await page.waitForFunction(()=>!pgAutomation.reportBusy,{timeout:60000});
  await page.evaluate(current=>{
   document.getElementById('meterTargetGamma').value='bt1886';
   window.chartLabels=[];
   const original=meterBuildCurrentSeriesReportSection;
   meterBuildCurrentSeriesReportSection=function(title){chartLabels.push(meterTargetGammaLabel());window.renderGeometry={gamma:document.getElementById('meterTargetGamma').value,context:meterActiveCalibrationTargetContext,width:document.body.style.getPropertyValue('--automation-report-width'),source:document.getElementById('meterCard').getBoundingClientRect().width,max:getComputedStyle(document.getElementById('meterCard')).maxWidth,target:pgAutomationJobTarget('calibration').offsetWidth};return original(title);};
   pgAutomation.current=current;pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('calibration');pgAutomationSyncCalibrationView(current.run);
   const state=pgAutomation.jobViews.calibration;
   if(state?.data){state.graphSignature=null;pgAutomationRenderJobGraphs('calibration',state);}
  },current);
  const ready=()=>page.waitForFunction(()=>document.querySelectorAll('#pgAutomationCalibrationDetail img').length>=5&&!pgAutomation.reportBusy,{timeout:60000});
  await ready();
  async function check(){
   const result=await page.evaluate(()=>({labels:chartLabels,gamma:document.getElementById('meterTargetGamma').value,renderWidth:document.body.style.getPropertyValue('--automation-report-width'),images:[...document.querySelectorAll('#pgAutomationCalibrationDetail .report-chart-card')].map(c=>{const img=c.querySelector('img'),r=img.getBoundingClientRect();return {title:c.querySelector('.report-chart-title').textContent,native:[img.naturalWidth,img.naturalHeight],display:[r.width,r.height],required:r.width*devicePixelRatio};})}));
   assert.ok(result.labels.length&&result.labels.every(l=>l==='Gamma 2.2'),'every chart uses the job target, not the manual selector: '+JSON.stringify({labels:result.labels,geometry:await page.evaluate(()=>renderGeometry)}));
   assert.equal(result.gamma,'bt1886','manual selector restored');assert.equal(result.renderWidth,'','temporary sizing removed');
   for(const img of result.images){assert.ok(img.native[0]>=img.required-2,JSON.stringify({img,geometry:await page.evaluate(()=>renderGeometry)}));assert.ok(Math.abs(img.native[0]/img.native[1]-img.display[0]/img.display[1])<.02,'aspect ratio preserved');}
   const rgb=result.images.find(i=>i.title==='RGB Balance');
   for(const img of result.images.filter(i=>/EOTF|^Luminance$/.test(i.title)))assert.ok(Math.abs(img.display[0]-rgb.display[0])<2,'EOTF and luminance use full panel width');
   return result;
  }
  const desktop=await check();
  const oldSignature=await page.evaluate(()=>pgAutomation.jobViews.calibration.graphSignature);
  await page.setViewport({width:2200,height:1100,deviceScaleFactor:2});
  await page.waitForFunction(old=>!pgAutomation.reportBusy&&pgAutomation.jobViews.calibration.graphSignature!==old,{timeout:45000},oldSignature);
  const wide=await check();
  // Exercise changing measurements through normal browser polling, not just
  // initial image loading. Browser-only replay; never sends TV/meter writes.
  const updates=[];
  for(const view of ['live','calibration']){
   await page.evaluate(view=>{pgSelectDesktopWorkspace(view==='live'?'automation':'calibration');if(view==='live')pgAutomationTab('live');},view);
   const selector=view==='live'?'#pgAutomationLiveDetail img':'#pgAutomationCalibrationDetail img';
   await page.waitForFunction(selector=>document.querySelectorAll(selector).length>=5&&!pgAutomation.reportBusy,{timeout:45000},selector);
   for(const level of [20,25]){
    const previous=await page.$$eval(selector,els=>els.map(e=>e.src));
    const white=snapshot.readings.find(r=>Number(r.ire)===100);
    assert.ok(white?.Y>0,'replay uses a captured white reference');
    const fraction=Math.pow(level/100,2.2),timestamp=Date.now()/1000;
    detail.live.snapshot={...snapshot,status:'running',current_name:'Auto Cal 20%',current_step:3,current_delta_e:level,
     readings:[...snapshot.readings.filter(r=>Number(r.ire)!==20),{...white,ire:20,plot_ire:20,nominal_ire:20,stimulus:20,patch_ire:20,name:'20%',timestamp,
      signal_r_pct:20,signal_g_pct:20,signal_b_pct:20,X:white.X*fraction,Y:white.Y*fraction,Z:white.Z*fraction,luminance:white.Y*fraction,autocal_reference_only:false,autocal_white_reference:false}]};
    await page.waitForFunction((view,timestamp)=>pgAutomation.jobViews[view]?.data?.live?.snapshot?.readings.some(r=>r.timestamp===timestamp)&&!pgAutomation.jobViews[view].loading&&!pgAutomation.reportBusy,{timeout:45000},view,timestamp);
    await page.waitForFunction((selector,previous)=>[...document.querySelectorAll(selector)].some((e,i)=>e.src!==previous[i]),{timeout:45000},selector,previous);
    updates.push({view,level,changed:true});
   }
  }
  await page.screenshot({path:'/tmp/pgen-calibration-charts-fixed.png',fullPage:true});
  await page.setViewport({width:390,height:844,deviceScaleFactor:2});
  await page.evaluate(()=>pgSetLayoutPreference('tablet'));await ready();
  assert.ok(await page.$eval('#pgAutomationCalibrationCard',el=>el.scrollWidth<=el.clientWidth+1),'mobile fits without overflow');
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',readOnly:true,browserOnlyMeasurementReplay:true,updates,local,desktop,wide}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
