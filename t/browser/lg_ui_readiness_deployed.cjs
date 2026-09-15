// Click-only readiness walkthrough; never starts a queue or saves a queue.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),puppeteer=require('puppeteer');
const [base,evidence]=process.argv.slice(2);
const report={steps:[],errors:[],blocked:[]};
(async()=>{
 const browser=await puppeteer.launch({headless:true});const page=await browser.newPage();
 page.setDefaultTimeout(60000);page.setDefaultNavigationTimeout(60000);await page.setViewport({width:1500,height:1100});
 const log=message=>{report.steps.push(message);console.log(message);};
 page.on('pageerror',e=>report.errors.push(e.message));
 page.on('dialog',async dialog=>{report.dialog=dialog.message();await dialog.dismiss();});
 await page.setRequestInterception(true);
 page.on('request',req=>{
  const route=new URL(req.url()).pathname;
  if(['GET','HEAD'].includes(req.method())||['/api/lg/picture-settings','/api/automation/readiness'].includes(route))return req.continue();
  report.blocked.push({route,method:req.method()});req.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Readiness-only test: starting, saving and resetting are blocked"}'});
 });
 try{
  await page.goto(base,{waitUntil:'domcontentloaded'});
  await page.click('button[data-layout-mode="desktop"]');
  await page.click('button[data-workspace-target="automation"]');log('Clicked Automation workspace');
  await page.click('#pgAutomationQueueTab');
  await page.waitForSelector('#pgAutomationSavedQueueSelect option[value="reference-settings"]');
  const options=await page.$$eval('#pgAutomationSavedQueueSelect option',els=>els.map(el=>el.value));
  await page.click('#pgAutomationSavedQueueSelect');await page.keyboard.press('Home');
  for(let i=0;i<options.indexOf('reference-settings');i++)await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');await page.keyboard.press('Tab');
  await page.waitForFunction(()=>document.querySelector('#pgAutomationSavedQueueSelect')?.value==='reference-settings'&&document.querySelectorAll('#pgAutomationQueueItems .auto-item').length===6);
  log('Selected the six-job Reference settings queue with the dropdown; no saved queue changed');
  await page.screenshot({path:path.join(evidence,'user-readiness-before.png')});
  const response=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/automation/readiness',{timeout:300000});
  await page.click('#pgAutomationReadinessButton');log('Clicked Check Readiness, not Run queue');
  const result=await(await response).json();
  report.result={status:result.status,ready:result.ready,message:result.message,checks:result.checks,items:result.items?.map(x=>({name:x.name,signal_format:x.signal_format,picture_mode:x.picture_mode,settings:x.settings}))};
  await page.waitForFunction(()=>document.querySelector('#pgAutomationReadinessButton')?.textContent==='Check Readiness',{timeout:300000});
  report.visible=await page.$eval('#pgAutomationReadiness',el=>el.innerText);
  await page.screenshot({path:path.join(evidence,'user-readiness-result.png')});
  assert.equal(result.ready,1,'Reference queue passes general readiness');
  assert.equal(report.errors.length,0);assert.equal(report.blocked.length,0);report.status='passed';log('General readiness passed; calibration was not started');
 }catch(e){report.status='failed';report.failure=e.message;await page.screenshot({path:path.join(evidence,'user-readiness-failure.png')}).catch(()=>{});}
 finally{fs.writeFileSync(path.join(evidence,'user-readiness.json'),JSON.stringify(report,null,2));await browser.close();}
 console.log(JSON.stringify(report));if(report.status!=='passed')process.exitCode=1;
})().catch(e=>{console.error(e.message);process.exitCode=1;});
