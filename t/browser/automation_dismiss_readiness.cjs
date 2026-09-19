const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),http=require('http'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
let dismissed=false,calls=[];
const preflight={id:'saved-failure',started_at:1,status:'blocked',total_items:0,issues:[{level:'error',message:'Add at least one automation item'}],message:'Automation readiness failed'};
const html='<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+read('webui-theme.css')+'</style>'+read('webui-automation.html')+'<script>window.fetchJSON=async(url,options)=>{const response=await fetch(url,options);return response.json();};</script><script>'+read('webui-automation.js')+'</script>';
(async()=>{
 const server=http.createServer((req,res)=>{
  let body='';req.on('data',chunk=>body+=chunk);req.on('end',()=>{
   if(!req.url.startsWith('/api/')){res.setHeader('Content-Type','text/html');return res.end(html)}
   calls.push(req.url);res.setHeader('Content-Type','application/json');
   let result={status:'ok',recipes:[],queues:[],runs:[]};
   if(req.url==='/api/automation/runs/current')result={status:'ok',preflight:dismissed?null:preflight};
   if(req.url==='/api/automation/readiness/dismiss'){
    assert.equal(JSON.parse(body).request_id,preflight.id);dismissed=true;result={status:'ok',dismissed:preflight.id};
   }
   res.end(JSON.stringify(result));
  });
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.setViewport({width:1440,height:1000});await page.goto('http://127.0.0.1:'+server.address().port);
  await page.waitForSelector('#pgAutomationDismissReadiness');
  assert.match(await page.$eval('#pgAutomationProgress',el=>el.textContent),/Last readiness check did not pass/);
  assert.equal(await page.$eval('#pgAutomationState',el=>el.textContent),'Idle');
  await page.focus('#pgAutomationDismissReadiness');await page.keyboard.press('Enter');
  await page.waitForFunction(()=>document.getElementById('pgAutomationProgress').style.display==='none');
  assert.equal(await page.evaluate(()=>document.activeElement.id),'pgAutomationReadinessButton','keyboard focus returns to readiness');
  assert.ok(dismissed,'actual dismissal request sent');
  await page.reload();await page.waitForFunction(()=>pgAutomation.loaded&&pgAutomation.current);
  assert.equal(await page.$eval('#pgAutomationProgress',el=>el.style.display),'none','banner stays dismissed after real refresh');
  await page.click('#pgAutomationReadinessButton');await page.click('#pgAutomationStartButton');
  assert.equal(calls.filter(url=>url==='/api/automation/readiness'||url==='/api/automation/runs/start').length,0,'empty queue never calls readiness or start');
  assert.equal(await page.$eval('#pgAutomationProgress',el=>el.style.display),'none','empty queue does not create another stuck error');
  assert.match(await page.$eval('#pgAutomationNotice',el=>el.textContent),/Add a job/);
  await page.evaluate(()=>{
   pgAutomation.current={preflight:{id:'saved-failure',started_at:2,status:'blocked',issues:[{message:'New attempt failed'}]}};
   pgAutomationRenderLiveRun(null);
  });
  assert.ok(await page.$('#pgAutomationDismissReadiness'),'new failed attempts remain dismissible');
  for(const width of [320,390,720,1440]){
   await page.setViewport({width,height:1000});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'no overflow at '+width);
  }
  await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
  await page.evaluate(()=>{document.body.style.zoom='2';pgAutomation.current={preflight:{id:'active',status:'checking'}};pgAutomationRenderLiveRun(null);});
  assert.equal(await page.$('#pgAutomationDismissReadiness'),null,'active checks have no dismiss control');
  assert.ok(await page.$eval('#pgAutomationReadinessButton',el=>el.disabled));
  assert.deepEqual(errors,[]);
  console.log('PASS persisted dismissal, keyboard/focus, refresh, empty queue, active checks, widths and reduced motion');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1});
