// Read-only full-application design audit. --local previews the pending fragment.
// No device writes; sample readiness/log states exist only in the browser.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const base=process.argv[2]||'http://192.168.50.110',local=process.argv.includes('--local');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1050,deviceScaleFactor:2});
  await page.setRequestInterception(true);
  page.on('request',r=>['GET','HEAD'].includes(r.method())?r.continue():r.respond({status:403,body:'{}'}));
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof pgAutomation!=='undefined'&&pgAutomation.current?.run,{timeout:30000});
  await page.waitForNetworkIdle({idleTime:700,timeout:30000});
  if(local){
   await page.evaluate(html=>{
    const box=document.createElement('div');box.innerHTML=html;
    for(const id of ['automationCard','pgAutomationCalibrationCard'])document.getElementById(id).replaceWith(box.querySelector('#'+id));
    box.querySelectorAll('style').forEach(s=>document.body.append(s));
   },fs.readFileSync(path.join(root,'webui-automation.html'),'utf8'));
   const js=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
   await page.addScriptTag({content:js.slice(js.indexOf('function pgAutomationReferenceItems')).replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  }
  await page.evaluate(()=>{
   pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('automation');
   pgAutomation.queue=pgAutomationReferenceQueue();pgAutomation.queueSource='reference-settings';
   pgAutomationRenderSavedQueues();pgAutomationRenderQueue();pgAutomationRenderLiveRun(pgAutomation.current.run);pgAutomationTab('queue');
  });
  const capture=async(name,selector='#automationCard')=>{
   assert.ok(await page.$eval(selector,e=>e.scrollWidth<=e.clientWidth+1),name+' has no horizontal overflow');
   await page.screenshot({path:'/tmp/pgen-design-'+name+'.png',fullPage:false});
  };
  await capture('queue');
  for(const [index,signal] of [[4,'sdr'],[2,'hdr10'],[0,'dv']]){
   await page.evaluate(i=>pgAutomationQueueEdit(i),index);
   await capture('editor-'+signal,'#pgAutomationEditor');
   await page.evaluate(()=>{pgAutomationEl('SettingsEditor').closest('details').open=true;pgAutomationEl('PanelHeading').scrollIntoView({block:'start'});});
   await capture('settings-'+signal,'#pgAutomationEditor');
   await page.evaluate(()=>{const editor=pgAutomationEl('Editor');editor.scrollTop=editor.scrollHeight;});
   await capture('editor-end-'+signal,'#pgAutomationEditor');
   await page.evaluate(()=>pgAutomationCancelEditor());
  }
  await page.evaluate(()=>{pgAutomation.recipes=[{...pgAutomationReferenceQueue().items[4],id:'design-preview'}];pgAutomationRenderRecipeList();pgAutomationTab('recipes');});
  await capture('recipes');
  await page.evaluate(()=>pgAutomationTab('live'));
  await page.waitForFunction(()=>pgAutomation.jobViews.live?.data&&!pgAutomation.reportBusy,{timeout:45000});
  await capture('live');
  await page.evaluate(()=>pgAutomationTab('history'));
  await page.waitForFunction(()=>pgAutomation.history?.length,{timeout:45000});
  await capture('history');
  await page.evaluate(()=>pgAutomationOpenHistory(0));
  await page.waitForFunction(()=>pgAutomation.jobViews.history?.data&&!pgAutomation.reportBusy,{timeout:45000});
  await page.evaluate(()=>pgAutomationEl('HistoryDetail').scrollIntoView({block:'start'}));
  await capture('history-detail');
  await page.evaluate(()=>pgAutomationTab('queue'));
  for(const width of [390,320]){
   await page.setViewport({width,height:950,deviceScaleFactor:2});
   await page.evaluate(()=>{pgSetLayoutPreference('tablet');document.getElementById('automationCard').scrollIntoView();});
   await capture('queue-'+width);
   await page.evaluate(()=>pgAutomationQueueEdit(4));
   await capture('editor-'+width,'#pgAutomationEditor');
   await page.evaluate(()=>pgAutomationCancelEditor());
  }
  await page.evaluate(()=>{
   pgAutomationRenderReadiness({ready:false,message:'Startup blocked',checks:[{ok:false,level:'error',message:'Pair and connect the LG TV before starting automation'},{ok:false,level:'warning',message:'Verify TruMotion is off in the TV menu'},{ok:true,message:'Meter connected'}]});
   pgAutomationEl('Readiness').scrollIntoView({block:'center'});
  });
  await capture('readiness-mobile');
  await page.evaluate(()=>{pgAutomationEl('Activity').open=true;pgAutomationEl('Activity').scrollIntoView({block:'start'});});
  await capture('log-mobile');
  await page.evaluate(()=>{pgAutomationEl('Activity').open=false;pgAutomationEl('Readiness').innerHTML='';});
  await page.setViewport({width:1440,height:1050,deviceScaleFactor:2});
  await page.evaluate(()=>{document.documentElement.dataset.theme='light';pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('automation');document.getElementById('automationCard').scrollIntoView({block:'start'});});
  await capture('queue-light');
  await page.evaluate(()=>pgAutomationQueueEdit(4));
  await capture('editor-light','#pgAutomationEditor');
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',local,readOnly:true,surfaces:['queue','editor-sdr','editor-hdr10','editor-dv','recipes','live','history'],widths:[1440,390,320],themes:['dark','light']}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
