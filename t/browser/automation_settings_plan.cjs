// Real editor interaction with deterministic, read-only matrix responses.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
(async()=>{
 const browser=await puppeteer.launch(process.env.PGEN_VISIBLE_CHROME?{headless:false,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',slowMo:80}:{headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100});
  await page.setContent('<style>'+read('webui-theme.css')+'</style>'+read('webui-automation.html'));
  await page.addScriptTag({content:read('webui-lg.js').match(/const LG_DISPLAY_CONTROL_ITEMS=\[[\s\S]*?const LG_DISPLAY_CONTROL_KEYS=[^;]+;/)[0]});
  await page.addScriptTag({content:read('webui-automation.js').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  await page.evaluate(catalogue=>{
   window.testModel='g3';window.holdPlan=false;window.pendingPlans=[];window.calls=[];window.planFailure='Connect the TV';window.liveContext=false;
   window.fetchJSON=async(url,opts)=>{
    if(url!=='/api/automation/settings-plan')throw Error('Unexpected write/request '+url);
    const body=JSON.parse(opts.body);calls.push(body);
    const manual=testModel==='c1'?{gamma:{value:body.settings.gamma,reason:'Automatic readback is unavailable'}}:{};
    const result={status:'ok',known:testModel!=='unknown',model_name:testModel==='c1'?'OLED65C1PUB':'OLED55G36LA',automatic:Object.fromEntries(Object.entries(body.settings).filter(([k])=>!['backlight',...Object.keys(manual)].includes(k))),manual,blocked:{},panel_light:{label:'OLED Pixel Brightness',wire_key:testModel==='unknown'?'':'backlight',writable:testModel!=='unknown',target_available:testModel==='g3',source:'tv_matrix'}};
    const modes=body.signal_mode==='hdr10'?['hdrCinema','hdrFilmMaker','hdrGame']:body.signal_mode==='dv'?['dolbyVisionFilmMaker','dolbyVisionCinemaBright']:['filmMaker','cinema'];
    const rows=Object.values(catalogue[body.signal_mode]||{}).map(row=>({...row,label:row.value==='hdrCinema'?'HDR Cinema (catalogue label)':row.label}));
    result.calibration_mode={signal_mode:body.signal_mode,picture_mode:body.picture_mode,catalogue:rows,allowed:modes.includes(body.picture_mode),allowed_modes:modes,message:modes.includes(body.picture_mode)?'Mode eligible for AutoCal':'No reviewed AutoCal calibration bank is available. Choose HDR Cinema, HDR Filmmaker or HDR Game, or turn AutoCal off and enable readings.'};
    result.live_context_matches=liveContext;
    if(testModel==='offline')return {status:'error',message:planFailure};
    if(holdPlan)return new Promise(resolve=>pendingPlans.push(()=>resolve(result)));
    return result;
   };
  },JSON.parse(read('tv/lg/picture-modes/catalogue.json')).profiles[0].data.picture_modes);
  const open=async()=>{await page.click('button[onclick="pgAutomationNewRecipe(\'queue\')"]');await page.waitForFunction(()=>!pgAutomation.planPending);};
  const state=()=>page.$eval('#pgAutomationCompatibility',e=>e.dataset.state);
  const shot=async name=>{if(process.env.PGEN_COMPATIBILITY_SCREENSHOTS){await page.$eval('#pgAutomationEditor',e=>e.scrollTop=0);await page.screenshot({path:path.join(process.env.PGEN_COMPATIBILITY_SCREENSHOTS,name+'.png')});}};
  await page.evaluate(()=>holdPlan=true);
  await page.click('button[onclick="pgAutomationNewRecipe(\'queue\')"]');
  assert.equal(await state(),'checking','pending check is explicit at the top of the editor');
  assert.ok(await page.$eval('#pgAutomationCompatibility',e=>{const r=e.getBoundingClientRect();return r.top>=0&&r.bottom<innerHeight;}),'status is in the first viewport');
  assert.match(await page.$eval('#pgAutomationCompatibilityDetail',e=>e.textContent),/Required before saving/);
  assert.match(await page.$eval('#pgAutomationModeSaveHelp',e=>e.textContent),/Checking TV compatibility/,'Save explains the pending check');
  assert.ok(await page.$eval('#pgAutomationCompatibilityButton',e=>e.disabled),'duplicate checks cannot be launched by the button');
  assert.equal(await page.$eval('.auto-compatibility-copy',e=>e.getAttribute('role')),'status');
  await shot('checking');
  await page.evaluate(()=>{holdPlan=false;pendingPlans.shift()();});await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.equal(await state(),'checked');
  assert.match(await page.$eval('#pgAutomationCompatibilityDetail',e=>e.textContent),/Live checks will run after/,'matrix selection is not claimed as live verification');
  await shot('checked');
  await page.click('button[aria-label="Close item editor"]');
  await open();
  assert.equal(await page.$eval('#pgAutomationPanelKey',e=>e.type),'hidden','no API-alias dropdown');
  assert.equal(await page.$eval('#pgAutomationPanelBinding',e=>e.textContent),'OLED Pixel Brightness');
  assert.ok(await page.$eval('[data-pg-automation-pin="contrast"]',e=>e.checked),'reference contrast selected by default');
  await page.click('#pgAutomationPanelTargetRadio');
  assert.equal(await page.evaluate(()=>pgAutomationRecipeFromForm().panel_light.key),'backlight','target uses matrix binding');
  await page.evaluate(()=>{pgAutomationCancelEditor();testModel='c1';});await open();
  assert.equal(await state(),'limited');
  assert.match(await page.$eval('#pgAutomationCompatibilityDetail',e=>e.textContent),/Review manual steps/);
  await shot('manual-checks');
  assert.ok(await page.$eval('[data-pg-automation-pin="gamma"]',e=>!e.checked&&e.disabled),'unreadable gamma is manual, not auto-pinned');
  assert.ok(await page.$eval('#pgAutomationPanelTargetRadio',e=>e.disabled),'write-only panel cannot target luminance');
  await page.evaluate(()=>{pgAutomationEl('Gamma').value='2.2';pgAutomationGammaChanged();});
  assert.ok(await page.$eval('[data-pg-automation-pin="gamma"]',e=>!e.checked),'gamma link cannot bypass matrix');
  let saved=await page.evaluate(()=>pgAutomationRecipeFromForm());
  assert.equal(saved.reference_manual_settings.gamma.value,'medium');
  assert.ok(saved.manual_checks.some(x=>x.includes('medium')),'manual instructions persisted');
  await page.click('button[onclick="pgAutomationResolveSettingsPlan()"]');await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.match(await page.$eval('#pgAutomationManualSettings',e=>e.textContent),/medium/,'refresh retains manual instructions');
  await page.evaluate(recipe=>{pgAutomationCancelEditor();pgAutomationOpenEditor('queue',recipe,0);},saved);await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.match(await page.$eval('#pgAutomationManualSettings',e=>e.textContent),/medium/,'reopening retains manual instructions');
  await page.evaluate(()=>{pgAutomationCancelEditor();testModel='g3';holdPlan=true;pgAutomationNewRecipe('queue');});
  assert.ok(await page.$eval('#pgAutomationEditorSave',e=>e.disabled),'save waits for compatibility');
  await page.evaluate(()=>{const e=document.querySelector('[data-pg-automation-key="contrast"]');e.value='61';pendingPlans.shift()();});
  await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.equal(await page.evaluate(()=>pgAutomationRecipeFromForm().settings.contrast),61,'typing during matrix read is preserved');
  await page.evaluate(()=>{pgAutomationResolveSettingsPlan();pgAutomationEl('Signal').value='hdr10';pgAutomationModesChanged();pgAutomationSignalDefaults();pendingPlans.shift()();});
  assert.ok(await page.evaluate(()=>pgAutomation.planPending),'old SDR response cannot unlock HDR save');
  assert.equal(await state(),'checking','stale response cannot show checked for a new signal');
  await page.evaluate(()=>pendingPlans.shift()());await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.equal(await page.evaluate(()=>pgAutomationRecipeFromForm().settings.contrast),100,'HDR receives reference contrast');
  await page.evaluate(()=>{pgAutomationCancelEditor();holdPlan=false;testModel='offline';});await open();
  assert.ok(await page.$eval('#pgAutomationEditorSave',e=>e.disabled),'offline lookup cannot save a guessed binding');
  assert.equal(await state(),'error');
  assert.equal(await page.$eval('#pgAutomationCompatibilityButton',e=>e.textContent),'Retry compatibility check');
  assert.match(await page.$eval('#pgAutomationModeSaveHelp',e=>e.textContent),/check failed.*retry before saving/,'Save explains how to recover from a failed check');
  await shot('failed');
  assert.match(await page.$eval('#pgAutomationPanelBindingHelp',e=>e.textContent),/Connect the TV/);
  await page.evaluate(()=>{testModel='g3';liveContext=true;});
  await page.focus('#pgAutomationPictureMode');await page.keyboard.press('Tab');
  assert.ok(await page.$eval('#pgAutomationCompatibilityButton',e=>e.matches(':focus-visible')&&getComputedStyle(e).outlineStyle!=='none'),'retry has visible keyboard focus');
  await page.keyboard.press('Enter');await page.waitForFunction(()=>!pgAutomationEl('EditorSave').disabled);
  assert.equal(await state(),'checked','keyboard retry clears the failed status');
  assert.match(await page.$eval('#pgAutomationCompatibilityDetail',e=>e.textContent),/current TV mode/);
  assert.ok(await page.$eval('#pgAutomationModeSaveHelp',e=>e.hidden),'successful retry clears the stale save blocker');
  await page.evaluate(()=>testModel='unknown');await page.click('#pgAutomationCompatibilityButton');await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.equal(await state(),'limited','unknown TV does not receive a green checked status');
  assert.match(await page.$eval('#pgAutomationCompatibilityDetail',e=>e.textContent),/No reviewed TV profile matched/);
  await page.evaluate(()=>{testModel='offline';planFailure='The TV connection could not be checked. '+('Long firmware diagnostic message. '.repeat(12));});
  await page.click('#pgAutomationCompatibilityButton');await page.waitForFunction(()=>!pgAutomation.planPending);
  for(const theme of ['light','dark']){
   await page.evaluate(theme=>document.documentElement.dataset.theme=theme,theme);
   for(const width of [320,390,1440]){
    await page.setViewport({width,height:1100});
    assert.ok(await page.$eval('#pgAutomationCompatibility',e=>e.scrollWidth<=e.clientWidth+1),'long failure reflows at '+width+' in '+theme);
    assert.ok(await page.$eval('.auto-editor-actions',e=>e.getBoundingClientRect().height<250),'long diagnostic cannot fill the viewport with a sticky footer');
   }
  }
  await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
  await page.setViewport({width:1440,height:1100});
  await page.evaluate(()=>document.documentElement.style.zoom='2');
  assert.ok(await page.$eval('#pgAutomationCompatibility',e=>e.scrollWidth<=e.clientWidth+1),'compatibility text reflows at 200% CSS zoom');
  await page.evaluate(()=>document.documentElement.style.zoom='');
  await page.setViewport({width:320,height:1100});await shot('failed-narrow');
  await page.evaluate(()=>{testModel='g3';planFailure='Connect the TV';});await page.click('#pgAutomationCompatibilityButton');await page.waitForFunction(()=>!pgAutomation.planPending);
  for(const width of [320,390,1440]){
   await page.setViewport({width,height:1100});
   assert.ok(await page.$eval('#pgAutomationEditor',e=>e.scrollWidth<=e.clientWidth+1),'editor fits '+width);
  }
  await page.evaluate(()=>{pgAutomationCancelEditor();pgAutomationOpenEditor('queue',{name:'HDR Cinema Home',signal_format:'hdr10',picture_mode:'hdrCinemaBright',settings:{contrast:100},stages:{calibration:true},panel_light:{key:'backlight',policy:'fixed',fixed_value:100}},1);});
  await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.equal(await page.$eval('#pgAutomationPictureMode',e=>e.value),'hdrCinemaBright','unsupported saved mode is never silently replaced');
  assert.ok(await page.$eval('#pgAutomationEditorSave',e=>e.disabled),'saved unsupported AutoCal job is blocked in editor');
  assert.equal(await state(),'error','unsupported AutoCal mode has actionable compatibility status');
  assert.equal(await page.$eval('#pgAutomationPictureMode option[value="hdrCinema"]',e=>e.textContent),'HDR Cinema (catalogue label)','mode labels come from the resolved catalogue, not a second UI list');
  assert.match(await page.$eval('#pgAutomationModeEligibility',e=>e.textContent),/turn AutoCal off and enable readings/,'restriction appears beside the mode');
  assert.match(await page.$eval('#pgAutomationModeSaveHelp',e=>e.textContent),/HDR Cinema/,'disabled Save has visible recovery guidance');
  assert.ok(await page.$eval('#pgAutomationPictureMode',e=>e.selectedOptions[0].disabled&&e.selectedOptions[0].textContent.endsWith('readings only')),'mode picker marks non-AutoCal modes');
  for(const width of [320,390,1440]){await page.setViewport({width,height:1100});assert.ok(await page.$eval('#pgAutomationEditor',e=>e.scrollWidth<=e.clientWidth+1),'mode error reflows at '+width);}
  if(process.env.PGEN_MODE_SCREENSHOT)await page.screenshot({path:process.env.PGEN_MODE_SCREENSHOT});
  await page.click('#pgAutomationCal');await page.click('#pgAutomationPre');
  assert.equal(await state(),'checked','readings-only selection removes the AutoCal compatibility blocker');
  assert.ok(await page.$eval('#pgAutomationEditorSave',e=>!e.disabled),'turning off AutoCal enables measurement-only save');
  assert.equal(await page.evaluate(()=>pgAutomationRecipeFromForm().picture_mode),'hdrCinemaBright','readings retain chosen viewing preset');
  await page.click('#pgAutomationCal');
  await page.select('#pgAutomationPictureMode','hdrCinema');await page.waitForFunction(()=>!pgAutomation.planPending);
  assert.ok(await page.$eval('#pgAutomationEditorSave',e=>!e.disabled),'explicit supported mode selection fixes the job');
  assert.equal(await page.evaluate(()=>pgAutomationRecipeFromForm().picture_mode),'hdrCinema');
  assert.deepEqual(errors,[]);console.log('PASS compatibility status, keyboard retry, loading/error recovery, matrix/live distinction, legacy/unknown limits, stale replies, mode guards and responsive editor');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
