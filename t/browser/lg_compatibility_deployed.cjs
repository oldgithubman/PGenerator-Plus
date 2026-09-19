// Live LG compatibility verification. Default mode is read-only.
// node t/browser/lg_compatibility_deployed.cjs http://PI /existing/evidence inspect
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const puppeteer=require('puppeteer');
const [base,evidence,phase='inspect']=process.argv.slice(2);
assert.ok(base&&evidence&&fs.statSync(evidence).isDirectory());
const report={phase,started:new Date().toISOString(),errors:[],blocked:[],responses:[]};
const allowedValues={};let frozen=null;
function summary(r){return {status:r.status,message:r.message,error_code:r.error_code,
 current_input:r.current_input,picture_settings:r.picture_settings,setting_contracts:r.setting_contracts,
 setting_verification:r.setting_verification,verification_state:r.verification_state,
 settings_matrix:r.settings_matrix,generation_profile:r.generation_profile};}
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 const page=await browser.newPage();
 page.setDefaultTimeout(60000);page.setDefaultNavigationTimeout(60000);
 await page.setViewport({width:1500,height:1100});
 page.on('pageerror',e=>report.errors.push(e.message));
 await page.setRequestInterception(true);
 page.on('request',req=>{
  const url=new URL(req.url());
  let safe=['GET','HEAD'].includes(req.method())||url.pathname==='/api/lg/picture-settings';
  if(['roundtrip','guards'].includes(phase)&&url.pathname==='/api/lg/picture-settings/set'&&frozen){
   try{const p=JSON.parse(req.postData());const keys=Object.keys(p.settings||{});
    safe=keys.length===1&&allowedValues[keys[0]]?.includes(p.settings[keys[0]])&&p.tv_input===frozen.tv_input&&p.picture_mode===frozen.picture_mode&&(p.signal_mode===frozen.signal_mode||(phase==='guards'&&keys[0]==='gamma'&&p.signal_mode==='hdr10'));
   }catch{}
  }
  if(!safe){report.blocked.push({method:req.method(),path:url.pathname});return req.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Blocked by read-only LG test"}'});}
  req.continue();
 });
 page.on('response',async res=>{
  if(['/api/lg/picture-settings','/api/lg/picture-settings/set'].includes(new URL(res.url()).pathname)){
   try{report.responses.push(summary(await res.json()));}catch{}
  }
 });
 try{
  await page.goto(base,{waitUntil:'domcontentloaded'});
  console.log('Web UI loaded');
  await page.waitForFunction(()=>typeof pgSelectDesktopWorkspace==='function'&&typeof lgDisplayControlRefresh==='function');
  await page.evaluate(()=>{pgSetLayoutPreference('desktop');pgSelectDesktopWorkspace('display-control');});
  await page.waitForFunction(()=>lgStatusConnected(window.lgStatusState));
  await page.waitForFunction(()=>!lgDisplayControlPending);
  await page.evaluate(()=>lgDisplayControlRefresh(true));
  console.log('Live display controls loaded');
  report.ui=await page.evaluate(()=>({
   loaded:lgDisplayControlLoaded,error:lgDisplayControlError,signal:lgSignalModeKey(),pictureMode:lgDisplayControlPictureMode(),
   input:window.lgStatusState.currentInput,values:lgDisplayControlValues,
   controls:LG_DISPLAY_CONTROL_ITEMS.map(meta=>{const el=document.getElementById('lgDcInput_'+meta.key);return {key:meta.key,disabled:el?.disabled,value:el?.value,min:el?.min,max:el?.max,reason:lgDisplayControlSupportState(meta.key,lgDisplayControlValues,lgDisplayControlCapabilities).reason};})
  }));
  await page.screenshot({path:path.join(evidence,phase+'.png'),fullPage:true});
  assert.ok(report.ui.loaded,report.ui.error||'Display controls did not load');
  assert.equal(report.ui.error,'');
  await page.click('.lg-display-control-open-desktop');
  await page.waitForSelector('#lgDisplayControlModal',{visible:true});
  await page.screenshot({path:path.join(evidence,phase+'-controls.png')});
  if(phase==='roundtrip'){
   assert.equal(report.ui.signal,'sdr','This bounded test only changes SDR controls');
   assert.equal(report.ui.pictureMode,'filmMaker','Preserve the expected calibrated mode');
   assert.equal(report.ui.input,'hdmi4','Preserve the expected generator input');
   const original={brightness:Number(report.ui.values.brightness),contrast:Number(report.ui.values.contrast),noiseReduction:report.ui.values.noiseReduction};
   const changed={brightness:original.brightness===100?99:original.brightness+1,contrast:original.contrast===0?1:original.contrast-1,noiseReduction:original.noiseReduction==='off'?'low':'off'};
   const profile=report.responses.findLast(r=>r.generation_profile?.capability_profile_hash)?.generation_profile;
   assert.ok(profile?.capability_profile_hash);
   frozen={tv_input:report.ui.input,picture_mode:report.ui.pictureMode,signal_mode:report.ui.signal,expected_tv_input:report.ui.input,expected_profile_hash:profile.capability_profile_hash};
   for(const key of Object.keys(original))allowedValues[key]=[original[key],changed[key]];
   report.original=original;report.frozen=frozen;report.roundtrips=[];
   fs.writeFileSync(path.join(evidence,'restore-values.json'),JSON.stringify({frozen,original},null,2));
   async function api(route,payload){return page.evaluate(async(route,payload)=>{const r=await fetch(route,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(55000)});return r.json();},route,payload);}
   async function fresh(){const r=await api('/api/lg/picture-settings',{...frozen,keys:['pictureMode',...Object.keys(original)],include_current_input:true,ignore_calibration_picture_mode:true});assert.equal(r.status,'ok',r.message);assert.equal(r.current_input,frozen.tv_input);assert.equal(r.picture_settings.pictureMode,frozen.picture_mode);return r;}
   async function commit(key,value){
    const response=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/lg/picture-settings/set',{timeout:60000});
    const selector='#lgDcInput_'+key;
    if(key==='noiseReduction')await page.select(selector,String(value));
    else {await page.click(selector,{clickCount:3});await page.keyboard.type(String(value));await page.keyboard.press('Tab');}
    const r=await(await response).json();
    assert.equal(r.status,'ok',r.message);assert.equal(r.verification_state,'verified');
    assert.equal(String(r.picture_settings[key]),String(value));
    await page.waitForFunction(()=>!lgDisplayControlPending);
    return summary(r);
   }
   let needsRestore=null;
   try{
    for(const key of Object.keys(original)){
     needsRestore=key;console.log('Changing '+key+' through visible UI');
     const write=await commit(key,changed[key]);
     const read=await fresh();assert.equal(String(read.picture_settings[key]),String(changed[key]));
     await page.screenshot({path:path.join(evidence,'changed-'+key+'.png')});
     const restore=await commit(key,original[key]);
     const restored=await fresh();assert.equal(String(restored.picture_settings[key]),String(original[key]));
     needsRestore=null;report.roundtrips.push({key,original:original[key],test:changed[key],write,restore,independent_readback:read.picture_settings,restored:restored.picture_settings});
     console.log(key+' changed, independently read, restored and independently verified');
    }
   }finally{
    if(needsRestore){
     const r=await api('/api/lg/picture-settings/set',{...frozen,settings:{[needsRestore]:original[needsRestore]},readback_keys:[needsRestore,'pictureMode'],ignore_calibration_picture_mode:true});
     report.emergency_restore=summary(r);
     const read=await fresh();assert.equal(String(read.picture_settings[needsRestore]),String(original[needsRestore]),'Emergency restoration verified');
    }
   }
   report.final=summary(await fresh());
   for(const key of Object.keys(original))assert.equal(String(report.final.picture_settings[key]),String(original[key]));
   await page.screenshot({path:path.join(evidence,'restored-controls.png')});
  }
  if(phase==='guards'){
   assert.equal(report.ui.signal,'sdr');assert.equal(report.ui.input,'hdmi4');assert.equal(report.ui.pictureMode,'filmMaker');
   const saved=JSON.parse(fs.readFileSync(path.join(evidence,'restore-values.json'),'utf8'));
   frozen=saved.frozen;
   const original={...saved.original,gamma:report.ui.values.gamma};
   for(const [key,value] of Object.entries(original))allowedValues[key]=[value];
   allowedValues.brightness.push(101);
   allowedValues.noiseReduction.push('invalid-test-enum');
   async function api(route,payload){return page.evaluate(async(route,payload)=>{const r=await fetch(route,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(55000)});return r.json();},route,payload);}
   async function fresh(){const r=await api('/api/lg/picture-settings',{...frozen,keys:['pictureMode',...Object.keys(original)],include_current_input:true,ignore_calibration_picture_mode:true});assert.equal(r.status,'ok',r.message);assert.equal(r.current_input,frozen.tv_input);assert.equal(r.picture_settings.pictureMode,frozen.picture_mode);return r;}
   const before=await fresh();
   for(const [key,value] of Object.entries(original))assert.equal(String(before.picture_settings[key]),String(value),'Round-trip original remains restored: '+key);
   report.observedContracts=Object.fromEntries(Object.keys(saved.original).map(key=>[key,before.setting_contracts[key]]));
   report.guardTests=[];
   const cases=[
    {name:'out-of-range brightness',settings:{brightness:101},code:'invalid-setting-value'},
    {name:'invalid dropdown token',settings:{noiseReduction:'invalid-test-enum'},code:'invalid-setting-value'},
    {name:'stale TV profile',settings:{brightness:original.brightness},extra:{expected_profile_hash:'0'.repeat(64)},code:'lg-capability-context-changed'},
    {name:'wrong expected HDMI input',settings:{brightness:original.brightness},extra:{expected_tv_input:'hdmi1'},code:'lg-input-context-changed'},
    {name:'SDR gamma requested in HDR context',settings:{gamma:original.gamma},extra:{signal_mode:'hdr10'},code:'setting-not-applicable'}
   ];
   try{
    for(const test of cases){
     console.log('Checking rejection: '+test.name);
     const r=await api('/api/lg/picture-settings/set',{...frozen,...test.extra,settings:test.settings,readback_keys:Object.keys(test.settings),ignore_calibration_picture_mode:true});
     report.guardTests.push({name:test.name,response:summary(r)});
     assert.equal(r.status,'error',test.name+' must be rejected');assert.equal(r.error_code,test.code,test.name);
     const after=await fresh();for(const [key,value] of Object.entries(original))assert.equal(String(after.picture_settings[key]),String(value),test.name+' must not change '+key);
    }
   }finally{
    const after=await fresh();
    for(const [key,value] of Object.entries(original))if(String(after.picture_settings[key])!==String(value)){
     const restored=await api('/api/lg/picture-settings/set',{...frozen,settings:{[key]:value},readback_keys:[key],ignore_calibration_picture_mode:true});
     (report.emergency_restores??=[]).push(summary(restored));
     assert.equal(restored.verification_state,'verified','Restore after negative-test failure');
    }
   }
   report.final=summary(await fresh());
   console.log('All five unsafe requests rejected; original settings unchanged');
  }
  assert.equal(report.errors.length,0,'Browser has no uncaught errors');
  report.status='passed';
 }catch(e){report.status='failed';report.failure=e.message;await page.screenshot({path:path.join(evidence,phase+'-failure.png'),fullPage:true}).catch(()=>{});}
 finally{fs.writeFileSync(path.join(evidence,phase+'.json'),JSON.stringify(report,null,2));await browser.close();}
 console.log(JSON.stringify({status:report.status,failure:report.failure,ui:report.ui,errors:report.errors,blocked:report.blocked,responseCount:report.responses.length}));
 if(report.status!=='passed')process.exitCode=1;
})().catch(e=>{console.error(e.message);process.exitCode=1;});
