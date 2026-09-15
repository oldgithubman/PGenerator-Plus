// Real user-path test: all application actions use clicks, keys or selects.
// No page-side fetch calls, application-function calls or state injection.
// Network responses are observed passively. Destructive endpoints are blocked.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),puppeteer=require('puppeteer');
const [base,evidence]=process.argv.slice(2);
assert.ok(base&&evidence&&fs.statSync(evidence).isDirectory());
const report={started:new Date().toISOString(),steps:[],responses:[],errors:[],blocked:[]};
const original={brightness:50,contrast:85,noiseReduction:'off'};
const targets={brightness:51,contrast:84,noiseReduction:'low'};
const pending=new Set();let page,browser;
function save(){fs.writeFileSync(path.join(evidence,'user-clicks.json'),JSON.stringify(report,null,2));}
function log(step){report.steps.push({at:new Date().toISOString(),step});console.log(step);save();}
function slim(r){return {status:r.status,message:r.message,error_code:r.error_code,verification_state:r.verification_state,settings:r.picture_settings,input:r.current_input,profile:r.generation_profile?.capability_profile_id,hash:r.generation_profile?.capability_profile_hash,contracts:r.setting_contracts,scope_confirmed:r.settings_matrix?.context_confirmed};}
async function ready(){await page.waitForFunction(()=>document.querySelector('#lgDisplayControlStatus')?.textContent==='Picture controls loaded'&&document.querySelector('#lgDcInput_brightness')?.disabled===false,{timeout:60000});}
async function ui(){return page.evaluate(()=>({status:document.querySelector('#lgDisplayControlStatus')?.textContent,badge:document.querySelector('#lgDisplayControlBadge')?.textContent,input:document.querySelector('#lgCurrentInput')?.textContent,mode:document.querySelector('#lgPictureMode')?.value,controls:Array.from(document.querySelectorAll('#lgDisplayControlGrid [id^="lgDcInput_"]')).map(el=>({key:el.id.replace('lgDcInput_',''),value:el.value,disabled:el.disabled,min:el.min,max:el.max,options:el.tagName==='SELECT'?Array.from(el.options).map(o=>o.value):undefined}))}));}
async function screenshot(name){await page.screenshot({path:path.join(evidence,name+'.png')});}
async function refresh(){
 await ready();
 const next=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/lg/picture-settings'&&JSON.parse(r.request().postData()||'{}').keys?.includes('brightness'),{timeout:60000});
 await page.click('#lgDisplayControlRefreshBtn');
 const r=await(await next).json();assert.equal(r.status,'ok',r.message);assert.equal(r.current_input,'hdmi4');assert.equal(r.picture_settings.pictureMode,'filmMaker');
 await ready();return r;
}
async function set(key,value){
 await ready();
 const selector='#lgDcInput_'+key;
 await page.waitForFunction(selector=>{const el=document.querySelector(selector);return el&&!el.disabled;},{timeout:60000},selector);
 const next=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/lg/picture-settings/set'&&Object.hasOwn(JSON.parse(r.request().postData()||'{}').settings||{},key),{timeout:60000});
 if(key==='noiseReduction'){
  await page.click(selector);
  await page.keyboard.press('Home');
  if(value==='low')await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  // On macOS the native popup may commit on Enter or on focus leaving it.
  await page.keyboard.press('Tab');
 }else{
  await page.click(selector,{clickCount:3});
  await page.keyboard.type(String(value),{delay:80});
  await page.click('#lgDisplayControlPanel h2');
 }
 const r=await(await next).json();
 assert.equal(r.status,'ok',r.message);assert.equal(r.verification_state,'verified');assert.equal(String(r.picture_settings[key]),String(value));
 await ready();
 return slim(r);
}
(async()=>{
 browser=await puppeteer.launch({headless:true});page=await browser.newPage();
 page.setDefaultTimeout(60000);page.setDefaultNavigationTimeout(60000);await page.setViewport({width:1500,height:1100});
 page.on('pageerror',e=>report.errors.push(e.message));
 await page.setRequestInterception(true);
 page.on('request',req=>{
  const route=new URL(req.url()).pathname;
  let safe=['GET','HEAD'].includes(req.method())||route==='/api/lg/picture-settings';
  if(route==='/api/lg/picture-settings/set')try{const p=JSON.parse(req.postData());const keys=Object.keys(p.settings||{});safe=keys.length===1&&Object.hasOwn(original,keys[0])&&[original[keys[0]],targets[keys[0]]].includes(p.settings[keys[0]])&&p.tv_input==='hdmi4'&&p.picture_mode==='filmMaker'&&p.signal_mode==='sdr';}catch{}
  if(!safe){report.blocked.push({route,method:req.method()});return req.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Outside bounded UI test scope"}'});}
  req.continue();
 });
 page.on('response',async res=>{if(['/api/lg/picture-settings','/api/lg/picture-settings/set'].includes(new URL(res.url()).pathname))try{report.responses.push({route:new URL(res.url()).pathname,...slim(await res.json())});save();}catch{}});
 try{
  await page.goto(base,{waitUntil:'domcontentloaded'});log('Opened deployed application');
  await page.click('button[data-layout-mode="desktop"]');log('Clicked Desktop');
  await page.click('button[data-workspace-target="display-control"]');log('Clicked LG Display workspace');
  await page.waitForFunction(()=>document.querySelector('#lgStatusBadge')?.textContent==='Connected');
  await page.click('.lg-display-control-open-desktop');log('Clicked Display Control');
  await ready();report.before=await ui();await screenshot('user-01-controls');
  const before=await refresh();log('Clicked Refresh Settings and read original values');
  for(const [key,value] of Object.entries(original))assert.equal(String(before.picture_settings[key]),String(value),'Expected original '+key);
  const controls=(await ui()).controls;
  assert.equal(controls.find(c=>c.key==='oledPixelBrightness').disabled,true);
  assert.equal(controls.find(c=>c.key==='brightness').max,'100');
  assert.ok(controls.find(c=>c.key==='noiseReduction').options.includes('low'));
  report.roundtrips=[];
  for(const [key,value] of Object.entries(targets)){
   pending.add(key);log('Editing '+key+' through its visible control');
   const changed=await set(key,value);await screenshot('user-changed-'+key);
   const reread=await refresh();assert.equal(String(reread.picture_settings[key]),String(value));log('Refresh Settings confirmed '+key+'='+value);
   const restored=await set(key,original[key]);
   const checked=await refresh();assert.equal(String(checked.picture_settings[key]),String(original[key]));pending.delete(key);
   report.roundtrips.push({key,changed,restored,refreshed:checked.picture_settings});log('Restored '+key+'='+original[key]+' and confirmed with Refresh Settings');
  }
  await page.click('#lgDisplayControlPanel button[onclick="lgCloseDisplayControl()"]');log('Clicked Close');
  await page.reload({waitUntil:'domcontentloaded'});log('Reloaded application to discard UI memory');
  await page.click('button[data-workspace-target="display-control"]');await page.click('.lg-display-control-open-desktop');await ready();
  const reloaded=await refresh();for(const [key,value] of Object.entries(original))assert.equal(String(reloaded.picture_settings[key]),String(value));
  report.after=await ui();await screenshot('user-final-restored');
  assert.equal(report.errors.length,0);assert.equal(report.blocked.length,0);report.status='passed';log('Reload confirmed all original values; no JavaScript errors');
 }catch(e){report.status='failed';report.failure=e.stack;log('FAILED: '+e.message);await screenshot('user-failure').catch(()=>{});}
 finally{
  for(const key of pending){try{log('Restoring '+key+' using UI after failed check');await set(key,original[key]);const r=await refresh();assert.equal(String(r.picture_settings[key]),String(original[key]));log('UI restoration confirmed for '+key);}catch(e){(report.restoreFailures??=[]).push({key,error:e.message});}}
  save();await browser.close();
 }
 console.log(JSON.stringify({status:report.status,completed:report.roundtrips?.map(x=>x.key),failure:report.failure,restoreFailures:report.restoreFailures}));if(report.status!=='passed')process.exitCode=1;
})().catch(e=>{report.status='failed';report.failure=e.stack;save();console.error(e.message);process.exitCode=1;browser?.close();});
