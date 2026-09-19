// Offline regression for slow/failed saved-run listings. No TV writes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),puppeteer=require('puppeteer');
const html=require('./automation_activity_preview.cjs');
const source=fs.readFileSync(path.resolve(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setContent(html);
  await page.addScriptTag({content:source.slice(source.indexOf('async function pgAutomationRefresh(){'),source.indexOf('function pgAutomationInit(){'))});
  const checks=await page.evaluate(async()=>{
   const check=(value,message)=>{if(!value)throw new Error(message);};
   let fail=true,timeout;
   pgAutomation.history=[];
   fetchJSON=async(url,options)=>{
    if(url==='/api/automation/runs'){timeout=options._timeoutMs;return fail?null:{status:'ok',runs:[]};}
    return {status:'ok',recipes:[],queues:[]};
   };
   await pgAutomationRefresh();
   const list=pgAutomationEl('HistoryList');
   check(timeout===30000,'history uses the detail request timeout, not the five-second live timeout');
   check(list.querySelector('[role="alert"]')&&!list.textContent.includes('No automation history.'),'failed listing is not presented as empty history');
   check(list.querySelector('button').textContent==='Retry','history failure has a retry control');
   pgAutomation.history=[{id:'saved',queue_name:'Saved result',status:'complete',items:[]}];
   await pgAutomationRefresh();
   check(pgAutomation.history.length===1&&list.textContent.includes('Saved result'),'failure preserves saved results');
   fail=false;await pgAutomationRefresh();
   check(!pgAutomation.historyError&&!list.querySelector('[role="alert"]')&&list.textContent==='No automation history.','successful retry clears the warning and accepts an empty history');
   return 'timeout, visible failure, retry, preserved results, recovery';
  });
  assert.deepEqual(errors,[]);console.log(JSON.stringify({status:'ok',checks}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
