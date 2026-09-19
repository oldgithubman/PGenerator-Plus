// Visible, isolated Google Chrome session for supervised UI-only LG testing.
// Actions arrive as one JSON object per stdin line; no application API calls.
const fs=require('node:fs'),path=require('node:path'),readline=require('node:readline'),puppeteer=require('puppeteer');
const [base,evidence]=process.argv.slice(2);
const report={steps:[],responses:[],errors:[],blocked:[]};
const save=()=>fs.writeFileSync(path.join(evidence,'visible-chrome.json'),JSON.stringify(report,null,2));
(async()=>{
 const browser=await puppeteer.launch({headless:false,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',defaultViewport:null,slowMo:100,args:['--new-window','--window-size=1500,1100']});
 const pages=await browser.pages();const page=pages[0];page.setDefaultTimeout(45000);page.setDefaultNavigationTimeout(60000);
 page.on('pageerror',e=>{report.errors.push(e.message);save();});
 page.on('dialog',async dialog=>{const accept=dialog.type()==='confirm'&&dialog.message().startsWith('Temporarily change panel brightness by one step');report.steps.push({action:'dialog',message:dialog.message(),accepted:accept});save();if(accept)await dialog.accept();else await dialog.dismiss();});
 await page.setRequestInterception(true);
 page.on('request',req=>{
  const route=new URL(req.url()).pathname;let safe=['GET','HEAD'].includes(req.method())||['/api/lg/picture-settings','/api/automation/settings-plan','/api/automation/readiness','/api/automation/readiness/dismiss'].includes(route);
  if(route==='/api/lg/connect')try{const p=JSON.parse(req.postData());safe=!p.ip||p.ip==='192.168.50.28';}catch{}
  if(route==='/api/lg/picture-settings/set')try{const p=JSON.parse(req.postData()),keys=Object.keys(p.settings||{}),values={backlight:[18,19],brightness:[50,51],contrast:[85,84],noiseReduction:['off','low']};safe=keys.length===1&&values[keys[0]]?.includes(p.settings[keys[0]])&&p.tv_input==='hdmi4'&&p.picture_mode==='filmMaker'&&p.signal_mode==='sdr';}catch{}
  if(route==='/api/lg/verify-panel-light')try{const p=JSON.parse(req.postData());safe=p.confirm_reversible_test===true&&p.tv_input==='hdmi4'&&p.picture_mode==='filmMaker'&&p.signal_mode==='sdr'&&p.expected_profile_hash==='0ec9ce704b6166c382aec8b1c762eefbdffcb294ccab9d1b8d49a7c457f9efde';}catch{}
  if(!safe){report.blocked.push({route,method:req.method()});save();return req.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Outside supervised UI test scope"}'});}
  req.continue();
 });
 page.on('response',async res=>{
  const route=new URL(res.url()).pathname;if(!['/api/automation/settings-plan','/api/lg/picture-settings','/api/lg/picture-settings/set','/api/lg/verify-panel-light','/api/automation/readiness'].includes(route))return;
  if(route==='/api/automation/settings-plan'){try{const r=await res.json();report.responses.push({route,...r});save();console.log(JSON.stringify({event:'settings-plan',status:r.status,message:r.message,model:r.model_name,panel:r.panel_light,automatic:r.automatic,manual:r.manual,blocked:r.blocked}));}catch{}return;}
  if(route==='/api/lg/verify-panel-light'){try{const r=await res.json();report.responses.push({route,...r});save();console.log(JSON.stringify({event:'roundtrip',...r}));}catch{}return;}
  try{const r=await res.json();const entry={at:new Date().toISOString(),route,status:r.status,message:r.message,error_code:r.error_code,verification_state:r.verification_state,values:r.picture_settings,input:r.current_input,profile:r.generation_profile?.capability_profile_id,hash:r.generation_profile?.capability_profile_hash,ready:r.ready,checks:r.checks,contracts:r.setting_contracts};report.responses.push(entry);save();console.log(JSON.stringify({event:'response',route,status:entry.status,verification:entry.verification_state,values:entry.values,ready:entry.ready}));}catch{}
 });
 await page.goto(base,{waitUntil:'domcontentloaded'});await page.bringToFront();console.log('VISIBLE_CHROME_READY');
 const input=readline.createInterface({input:process.stdin});
 for await(const line of input){
  try{const cmd=JSON.parse(line);report.steps.push({at:new Date().toISOString(),...cmd});save();
   if(cmd.action==='click')await page.click(cmd.selector);
   else if(cmd.action==='type'){await page.click(cmd.selector,{clickCount:3});await page.keyboard.type(cmd.text,{delay:150});}
   else if(cmd.action==='key')await page.keyboard.press(cmd.key);
   else if(cmd.action==='scroll'){await page.mouse.move(cmd.x||1100,cmd.y||700);await page.mouse.wheel({deltaY:cmd.deltaY});}
   else if(cmd.action==='reload')await page.reload({waitUntil:'domcontentloaded'});
   else if(cmd.action==='waitEnabled')await page.waitForFunction(s=>{const e=document.querySelector(s);return e&&!e.disabled;},{timeout:45000},cmd.selector);
   else if(cmd.action==='screenshot')await page.screenshot({path:path.join(evidence,cmd.name+'.png')});
   else if(cmd.action==='modes')console.log(JSON.stringify(await page.evaluate(()=>({mode:document.querySelector('#pgAutomationPictureMode')?.value,signal:document.querySelector('#pgAutomationSignal')?.value,eligibility:document.querySelector('#pgAutomationModeEligibility')?.textContent,options:Array.from(document.querySelector('#pgAutomationPictureMode')?.options||[]).map(e=>({value:e.value,label:e.textContent,disabled:e.disabled})),saveDisabled:document.querySelector('#pgAutomationEditorSave')?.disabled,error:document.querySelector('#pgAutomationEditorError')?.textContent}))));
   else if(cmd.action==='verification')console.log(JSON.stringify(await page.evaluate(()=>({report:document.querySelector('#lgVerificationReport')?.innerText,scanDisabled:document.querySelector('#lgVerifyTvBtn')?.disabled,testDisabled:document.querySelector('#lgVerifyPanelLightBtn')?.disabled,panelControls:Array.from(document.querySelectorAll('#lgDisplayControlGrid .lg-display-control-item')).map(e=>e.innerText),panelValue:document.querySelector('#lgDcInput_backlight')?.value,aliasesPresent:['oledLight','oledPixelBrightness'].filter(k=>document.getElementById('lgDcInput_'+k))}))));
   else if(cmd.action==='read')console.log(JSON.stringify(await page.evaluate(()=>({title:document.title,workspace:document.querySelector('#desktopWorkspaceTitle')?.textContent,status:document.querySelector('#lgDisplayControlStatus')?.textContent,input:document.querySelector('#lgCurrentInput')?.textContent,controls:Array.from(document.querySelectorAll('#lgDisplayControlGrid [id^="lgDcInput_"]')).map(e=>({key:e.id.replace('lgDcInput_',''),value:e.value,disabled:e.disabled,options:e.tagName==='SELECT'?Array.from(e.options).map(o=>({text:o.textContent,value:o.value})):undefined})),readiness:document.querySelector('#pgAutomationReadiness')?.innerText,queues:Array.from(document.querySelectorAll('#pgAutomationSavedQueueSelect option')).map(e=>({text:e.textContent,value:e.value})),queueCount:document.querySelector('#pgAutomationQueueCount')?.textContent}))));
   else if(cmd.action==='editor')console.log(JSON.stringify(await page.evaluate(()=>({binding:document.querySelector('#pgAutomationPanelBinding')?.textContent,help:document.querySelector('#pgAutomationPanelBindingHelp')?.textContent,manual:document.querySelector('#pgAutomationManualSettings')?.textContent,pins:Array.from(document.querySelectorAll('[data-pg-automation-pin]:checked')).map(e=>e.dataset.pgAutomationPin),panelKey:document.querySelector('#pgAutomationPanelKey')?.value,keyType:document.querySelector('#pgAutomationPanelKey')?.type,targetDisabled:document.querySelector('#pgAutomationPanelTargetRadio')?.disabled,policy:document.querySelector('#pgAutomationPanelPolicy')?.value,saveDisabled:document.querySelector('#pgAutomationEditorSave')?.disabled}))));
   else if(cmd.action==='close'){await browser.close();break;}
   else throw Error('Unknown browser action');
   console.log('ACTION_COMPLETE '+cmd.action);
  }catch(e){console.log('ACTION_ERROR '+e.message);}
 }
})().catch(e=>{console.error(e.message);process.exitCode=1;});
