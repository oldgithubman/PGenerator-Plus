// Read-only hardware-result audit. Never starts a run or sends TV/meter controls.
// node t/browser/automation_saved_batch_deployed.cjs http://PI RUN_ID [--local]
// Optional PGEN_UI_EVIDENCE points to an existing screenshot directory.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const [base,id]=process.argv.slice(2);
const local=process.argv.includes('--local'),root=path.resolve(__dirname,'../../usr/share/PGenerator');
if(!base||!id)throw new Error('Provide appliance URL and completed run ID');
(async()=>{
 const current=await(await fetch(base+'/api/automation/runs/current')).json();
 assert.equal(current.run.id,id);assert.match(current.run.status,/^complete/);
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[],results=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1000,deviceScaleFactor:2});
  await page.setRequestInterception(true);
  page.on('request',r=>{
   const path=new URL(r.url()).pathname;
   if(!['GET','HEAD'].includes(r.method())||/^\/api\/cec\/(?!status$)/.test(path))return r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only audit"}'});
   return r.continue();
  });
  await page.goto(base,{waitUntil:'domcontentloaded',timeout:30000});
  await page.waitForFunction(()=>typeof pgAutomationShowJob==='function'&&pgAutomation.current?.run,{timeout:30000});
  if(local){
   await page.waitForFunction(()=>!pgAutomation.reportBusy,{timeout:60000});
   const html=fs.readFileSync(path.join(root,'webui-automation.html'),'utf8');
   await page.evaluate(css=>{const style=document.createElement('style');style.textContent=css;document.body.append(style);},[...html.matchAll(/<style>([^]*?)<\/style>/g)].map(m=>m[1]).join('\n'));
   const automation=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
   await page.addScriptTag({content:automation.slice(automation.indexOf('function pgAutomationReferenceItems')).replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  }
  await page.evaluate(()=>{pgSelectDesktopWorkspace('automation');pgAutomationTab('live')});
  for(let i=0;i<current.run.items.length;i++){
   await page.evaluate(({id,i})=>pgAutomationSelectJob('live',id,i),{id,i});
   await page.waitForFunction(i=>pgAutomation.jobViews.live?.index===i&&pgAutomation.jobViews.live?.data&&!pgAutomation.jobViews.live.loading&&!pgAutomation.reportBusy,i===0?{timeout:45000}:{timeout:30000},i);
   assert.equal(await page.$('#pgAutomationLiveDetail select[aria-label="Measurement graphs"]'),null,'all measurements are visible without a dropdown');
   await page.waitForFunction(()=>!pgAutomation.reportBusy&&document.querySelectorAll('#pgAutomationLiveDetail img').length>0&&[...document.querySelectorAll('#pgAutomationLiveDetail img')].every(e=>e.complete&&e.naturalWidth>0),{timeout:60000});
   const sections=await page.$$eval('#pgAutomationLiveDetail .report-section',es=>es.filter(e=>e.querySelector('img')).map(e=>({title:e.querySelector('.report-section-title').textContent,charts:e.querySelectorAll('img').length,top:e.getBoundingClientRect().top,bottom:e.getBoundingClientRect().bottom})));
   assert.match(sections[0].title,/Greyscale|1D LUT/,'greyscale comes first');
   const volume=await page.evaluate(()=>pgAutomation.jobViews.live.data.snapshots.some(s=>['3d','dv-profile'].includes(s.key)&&(s.snapshot?.readings?.length||s.snapshot?.steps?.some(p=>p.luminance!=null))));
   if(volume)assert.ok(sections.some(s=>/3D LUT|Dolby Vision profile/.test(s.title)),'saved volume charts appear alongside greyscale');
   assert.ok(await page.$$eval('#pgAutomationLiveDetail .report-section-title',es=>es.every(e=>e.getAttribute('role')==='heading')),'section headings support screen-reader navigation');
   sections.slice(1).forEach((s,n)=>assert.ok(s.top>=sections[n].bottom-1,'sections stack vertically, never side by side: '+JSON.stringify(sections)));
   results.push({job:i+1,name:current.run.items[i].name,sections});
  }
  if(process.env.PGEN_UI_EVIDENCE){
   const folder=process.env.PGEN_UI_EVIDENCE;
   await page.$eval('#pgAutomationLiveDetail',e=>e.scrollIntoView({block:'start'}));
   await page.screenshot({path:path.join(folder,'continuous-desktop.png')});
   await page.$$eval('#pgAutomationLiveDetail .report-section',es=>es.find(e=>/3D LUT|Dolby Vision profile/.test(e.querySelector('.report-section-title')?.textContent))?.scrollIntoView({block:'center'}));
   await page.screenshot({path:path.join(folder,'continuous-volume.png')});
   const signature=await page.evaluate(()=>pgAutomation.jobViews.live.graphSignature);
   await page.setViewport({width:390,height:844,deviceScaleFactor:2});
   await page.evaluate(()=>pgSetLayoutPreference('tablet'));
   await page.waitForFunction(old=>!pgAutomation.reportBusy&&pgAutomation.jobViews.live.graphSignature!==old,{timeout:60000},signature);
   assert.ok(await page.$eval('#automationCard',e=>e.scrollWidth<=e.clientWidth+1),'mobile has no horizontal overflow');
   await page.$eval('#pgAutomationLiveDetail',e=>e.scrollIntoView({block:'start'}));
   await page.screenshot({path:path.join(folder,'continuous-mobile.png')});
   await page.$eval('#pgAutomationLiveDetail [data-job-graphs]',e=>e.scrollIntoView({block:'start'}));
   await page.screenshot({path:path.join(folder,'continuous-mobile-graphs.png')});
   await page.$$eval('#pgAutomationLiveDetail .report-section',es=>es.find(e=>/3D LUT|Dolby Vision profile/.test(e.querySelector('.report-section-title')?.textContent))?.scrollIntoView({block:'start'}));
   await page.screenshot({path:path.join(folder,'continuous-mobile-volume.png')});
   await page.evaluate(async()=>{pgSetThemeMode('light');const state=pgAutomation.jobViews.live;state.graphSignature=null;await pgAutomationRenderJobGraphs('live',state);});
   await page.waitForFunction(()=>!pgAutomation.reportBusy&&[...document.querySelectorAll('#pgAutomationLiveDetail img')].every(e=>e.complete&&e.naturalWidth>0),{timeout:60000});
   await page.$eval('#pgAutomationLiveDetail [data-job-graphs]',e=>e.scrollIntoView({block:'start'}));
   await page.screenshot({path:path.join(folder,'continuous-mobile-light.png')});
  }
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',readOnly:true,local,results,browserErrors:errors}));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
