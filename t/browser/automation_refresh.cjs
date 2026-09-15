// A slow History response must not delay or overwrite the live run.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const html=require('./automation_activity_preview.cjs');
const source=fs.readFileSync(path.resolve(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setContent(html);
  await page.addScriptTag({content:source.slice(source.indexOf('async function pgAutomationPollLive(){'),source.indexOf('function pgAutomationHistorySummary('))+source.slice(source.indexOf('async function pgAutomationRefresh(){'),source.indexOf('function pgAutomationInit(){'))});
  await page.evaluate(()=>{
   pgAutomation.current={};pgAutomation.pendingChecks=null;pgAutomation.editingRunId='';
   pgAutomationSyncCalibrationView=()=>{};window.calls={live:0,history:0};window.liveRendered=[];
   const render=pgAutomationRenderLiveRun;pgAutomationRenderLiveRun=(run,execution)=>{liveRendered.push(run?.id);render(run,execution);};
   fetchJSON=async url=>{
    if(url==='/api/automation/runs/current'){calls.live++;return {status:'ok',run:{id:'new-live',status:'running',active_item:0,active_stage:'greyscale-done',items:[{name:'Dolby Vision Filmmaker',status:'running'}]}};}
    if(url==='/api/automation/runs'){calls.history++;return new Promise(resolve=>{window.finishHistory=resolve;});}
    return {status:'ok',queues:[],recipes:[]};
   };
   window.refreshes=[pgAutomationRefresh(),pgAutomationRefresh()];
  });
  await page.waitForFunction(()=>liveRendered.includes('new-live'));
  assert.deepEqual(await page.evaluate(()=>calls),{live:1,history:1},'concurrent refreshes coalesce their requests');
  assert.equal(await page.evaluate(()=>!!pgAutomation.refreshing),true,'history is still pending while the live card is already updated');
  assert.match(await page.$eval('#pgAutomationProgress',el=>el.textContent),/Dolby Vision Filmmaker/);
  await page.evaluate(async()=>{finishHistory({status:'error',message:'History unavailable'});await Promise.all(refreshes);});
  assert.equal(await page.evaluate(()=>pgAutomation.current.run.id),'new-live','late history failure cannot replace live state');
  assert.equal(await page.evaluate(()=>pgAutomation.statusError||''),'','history failure is not a live-status failure');
  assert.match(await page.$eval('#pgAutomationHistoryList',el=>el.textContent),/Cannot load saved runs/);
  assert.equal(await page.evaluate(()=>pgAutomation.refreshing),null,'refresh lock released for retry');
  await page.evaluate(()=>clearTimeout(pgAutomation.liveTimer));
  assert.deepEqual(errors,[]);console.log('PASS independent live updates, coalesced refreshes, history failure isolation');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
