// Read-only end-to-end appliance check. Real page startup and real API state;
// no synthetic run injection or response overrides. Works on stopped runs too.
// node t/browser/automation_native_load.cjs http://PI RUN_ID
const assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const [base,runId]=process.argv.slice(2);
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[],failures=[],timings=[],starts=new Map();
  page.on('pageerror',e=>errors.push(e.message));
  page.on('request',r=>{starts.set(r,Date.now());});
  page.on('requestfailed',r=>{if(r.url().includes('/api/automation/'))failures.push({path:new URL(r.url()).pathname,error:r.failure()?.errorText});});
  page.on('response',r=>{if(r.url().endsWith('/api/automation/runs/current'))timings.push(Date.now()-(starts.get(r.request())||Date.now()));});
  await page.setViewport({width:1600,height:1100,deviceScaleFactor:2});
  await page.setRequestInterception(true);
  page.on('request',r=>['GET','HEAD'].includes(r.method())?r.continue():r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only deployment check"}'}));
  await page.goto(base,{waitUntil:'domcontentloaded',timeout:30000});
  await page.waitForFunction(id=>typeof pgAutomation!=='undefined'&&pgAutomation.current?.run?.id===id,{timeout:15000},runId);
  await page.evaluate(()=>{pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('automation');pgAutomationTab('live');});
  await page.waitForFunction(()=>document.querySelectorAll('#pgAutomationLiveDetail img').length>=5&&!pgAutomation.reportBusy,{timeout:30000});
  const contention=await page.evaluate(async()=>{
   const history=fetch('/api/automation/runs').then(r=>r.json());
   const started=performance.now();
   const status=await(await fetch('/api/automation/runs/current')).json();
   const ms=performance.now()-started;
   await history;return {ms,status:status.status,run:status.run?.id};
  });
  assert.equal(contention.status,'ok');assert.equal(contention.run,runId);
  assert.ok(contention.ms<8000,'live status remains below its eight-second deadline during history loading');
  assert.deepEqual(failures,[],'automation requests do not time out');
  assert.deepEqual(errors,[],'page has no JavaScript errors');
  const state=await page.evaluate(()=>({run:pgAutomation.current?.run?.id,status:pgAutomation.current?.run?.status,error:pgAutomation.statusError||'',images:document.querySelectorAll('#pgAutomationLiveDetail img').length}));
  assert.equal(state.error,'');
  await page.screenshot({path:'/tmp/pgen-native-live-load.png',fullPage:true});
  console.log(JSON.stringify({status:'ok',readOnly:true,realPageStartup:true,state,statusResponseMs:timings,whileHistoryLoading:contention}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
