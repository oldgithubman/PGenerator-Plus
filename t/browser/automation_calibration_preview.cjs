// Browser-only overlay of local observer UI on the appliance. All writes blocked.
// node t/browser/automation_calibration_preview.cjs http://192.168.50.110
const fs=require('fs'),path=require('path'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),base=process.argv[2]||'http://192.168.50.110';
(async()=>{
 const fragment=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8');
 const source=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8');
 const browser=await puppeteer.launch({headless:true});
 const errors=[],networkErrors=[];
 try{
  const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
  page.on('requestfailed',r=>networkErrors.push({url:r.url(),error:r.failure()?.errorText}));
  await page.setViewport({width:1440,height:1100});await page.setRequestInterception(true);
  page.on('request',r=>{
   if(!['GET','HEAD'].includes(r.method()))return r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only preview"}'});
   return r.continue();
  });
  await page.goto(base+'/',{waitUntil:'domcontentloaded',timeout:60000});
  await page.waitForFunction(()=>typeof pgAutomation!=='undefined'&&typeof meterCalibrationReflectActualPatternProvider==='function');
  await page.evaluate(fragment=>{
   const parsed=new DOMParser().parseFromString(fragment,'text/html');
   document.querySelector('.dashboard').append(parsed.getElementById('pgAutomationCalibrationCard'));
   document.head.append([...parsed.querySelectorAll('style')].at(-1));
  },fragment);
  // Keep the deployed global state/constants; replace functions in this browser only.
  await page.addScriptTag({content:source.slice(source.indexOf('function pgAutomationReferenceItems'))});
  await page.evaluate(()=>pgAutomationPollLive());
  try{await page.waitForFunction(()=>typeof pgAutomationSyncCalibrationView==='function'&&pgAutomation.current?.run,{timeout:15000});}
  catch(e){throw new Error(JSON.stringify({errors,networkErrors:networkErrors.slice(-8),state:await page.evaluate(()=>({ready:document.readyState,observer:typeof pgAutomationSyncCalibrationView,current:typeof pgAutomation==='undefined'?null:{status:pgAutomation.current?.status,run:pgAutomation.current?.run?.id,error:pgAutomation.statusError,polling:pgAutomation.polling}}))}));}
  await page.evaluate(()=>{pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('calibration');pgAutomationSyncCalibrationView(pgAutomation.current.run);});
  await page.waitForFunction(()=>pgAutomation.jobViews.calibration?.data&&!pgAutomation.reportBusy,{timeout:30000});
  const result=await page.evaluate(()=>({job:pgAutomation.jobViews.calibration.data.item.name,stage:pgAutomation.jobViews.calibration.data.active_stage,graphs:document.querySelectorAll('#pgAutomationCalibrationDetail img').length,manualInert:document.getElementById('meterCard').inert,manualHidden:getComputedStyle(document.getElementById('meterCard')).display==='none',title:document.querySelector('#pgAutomationCalibrationDetail .report-section-title')?.textContent,progress:pgAutomationEl('CalibrationProgress').textContent,graphError:pgAutomationEl('CalibrationDetail').querySelector('[data-job-graphs]').textContent.slice(0,180)}));
  await page.screenshot({path:'/tmp/pgen-calibration-observer-preview.png'});
  console.log(JSON.stringify({previewOnly:true,...result,errors}));
  if(errors.length||!result.manualInert||!result.manualHidden||/^Unable to draw/.test(result.graphError))throw new Error('Preview failed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
