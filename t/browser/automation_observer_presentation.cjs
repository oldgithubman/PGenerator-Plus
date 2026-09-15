// Read-only appliance/browser presentation check. --local previews pending UI.
// State variants below are browser-only fixtures; no TV or meter writes.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const base=process.argv[2]||'http://192.168.50.110',local=process.argv.includes('--local');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
(async()=>{
 const current=await(await fetch(base+'/api/automation/runs/current')).json();
 const run=current.run,index=Math.min(Number(run.active_item||0),run.items.length-1);
 const data=await(await fetch(base+'/api/automation/runs/'+run.id+'/jobs/'+index)).json();
 assert.equal(data.status,'ok');
 const saved=data.snapshots.find(s=>s.key==='grey');assert.ok(saved?.snapshot?.readings.length);
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100,deviceScaleFactor:2});
  await page.setRequestInterception(true);
  page.on('request',r=>{
   if(!['GET','HEAD'].includes(r.method()))return r.respond({status:403,body:'{}'});
   const p=new URL(r.url()).pathname;
   const value=p==='/api/automation/runs/current'?current:/\/jobs\/\d+$/.test(p)?data:null;
   return value?r.respond({status:200,contentType:'application/json',body:JSON.stringify(value)}):r.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof pgAutomationSyncCalibrationView==='function');
  await page.waitForNetworkIdle({idleTime:700,timeout:30000});
  if(local){
   const html=fs.readFileSync(path.join(root,'webui-automation.html'),'utf8');
   await page.evaluate(html=>{
    const box=document.createElement('div');box.innerHTML=html;
    document.getElementById('pgAutomationCalibrationCard').replaceWith(box.querySelector('#pgAutomationCalibrationCard'));
    box.querySelectorAll('style').forEach(s=>document.body.append(s));
   },html);
   const js=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
   await page.addScriptTag({content:js.slice(js.indexOf('function pgAutomationReferenceItems')).replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  }
  for(const status of ['stopped','running','paused','failed','complete','complete-with-warnings']){
   run.status=status;data.run_status=status;
   run.active_stage=status==='running'||status==='paused'?'greyscale-done':'';data.active_stage=run.active_stage;
   run.worker_status={current_name:'Auto Cal 5%',current_step:2,total_steps:26,message:'Reading 5% sample 1/2'};
   data.live=status==='running'?{...saved,snapshot:{...saved.snapshot,status:'running',message:'Reading 5% sample 1/2'},phase:'calibration'}:null;
   data.item.status=status;data.item.failure=status==='failed'?{message:'Meter connection lost',stage:'greyscale-done'}:null;
   await page.evaluate(current=>{
    pgAutomation.current=current;pgAutomation.calibrationObserver=current.run.id;
    delete pgAutomation.jobViews.calibration;
    pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('calibration');pgAutomationSyncCalibrationView(current.run);
   },current);
   await page.waitForFunction(()=>pgAutomation.jobViews.calibration?.data&&!pgAutomation.jobViews.calibration.loading&&!pgAutomation.reportBusy,{timeout:30000});
   const state=await page.evaluate(()=>({title:document.querySelector('.auto-observer-title').textContent,headings:document.querySelectorAll('#pgAutomationCalibrationCard h3').length,
    stage:document.querySelector('.auto-observer-stage').textContent,release:getComputedStyle(document.getElementById('pgAutomationCalibrationRelease')).display,
    inert:document.getElementById('meterCard').inert,images:document.querySelectorAll('#pgAutomationCalibrationDetail img').length}));
   assert.equal(state.headings,1,'one job heading, not repeated metadata');
   assert.ok(state.inert,'manual controls remain inert in observer');
   assert.ok(state.images>=5,status+': saved/live graphs preserved');
   if(['stopped','failed','complete','complete-with-warnings'].includes(status)){assert.doesNotMatch(state.stage,/Between stages|Auto Cal 5%/);assert.notEqual(state.release,'none');}
   else assert.equal(state.release,'none');
   assert.equal(await page.$eval('#pgAutomationCalibrationCard .report-summary',e=>getComputedStyle(e).display),'grid','statistics use the responsive card grid');
   await page.screenshot({path:'/tmp/pgen-observer-'+status+'.png',fullPage:false});
  }
  await page.setViewport({width:390,height:844,deviceScaleFactor:2});
  await page.evaluate(()=>{pgSetLayoutPreference('tablet');document.getElementById('pgAutomationCalibrationCard').scrollIntoView();});
  await page.waitForFunction(()=>!pgAutomation.reportBusy);
  assert.ok(await page.$eval('#pgAutomationCalibrationCard',e=>e.scrollWidth<=e.clientWidth+1),'narrow card has no horizontal overflow');
  await page.screenshot({path:'/tmp/pgen-observer-mobile.png',fullPage:false});
  await page.evaluate(()=>document.documentElement.dataset.theme='light');
  await page.screenshot({path:'/tmp/pgen-observer-light.png',fullPage:false});
  await page.setViewport({width:320,height:844,deviceScaleFactor:2});
  assert.ok(await page.$eval('#pgAutomationCalibrationCard',e=>e.scrollWidth<=e.clientWidth+1),'320px card has no horizontal overflow');
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',local,readOnly:true,browserOnlyStateVariants:true,states:['stopped','running','paused','failed','complete','complete-with-warnings'],mobile:true}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
