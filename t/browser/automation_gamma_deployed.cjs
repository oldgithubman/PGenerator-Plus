// Read-only check of the served editor. Never saves a queue or changes the TV.
// node t/browser/automation_gamma_deployed.cjs http://192.168.50.110
const assert=require('node:assert/strict'),puppeteer=require('puppeteer');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.setRequestInterception(true);
  page.on('request',request=>['GET','HEAD'].includes(request.method())?request.continue():request.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only deployment check"}'}));
  await page.goto(process.argv[2]||'http://192.168.50.110',{waitUntil:'domcontentloaded',timeout:60000});
  await page.waitForFunction(()=>typeof pgAutomationGammaChanged==='function');
  const result=await page.evaluate(()=>{
   const reference=pgAutomationReferenceQueue().items.map(item=>({
    mode:item.picture_mode,gamma:item.target_gamma,tvGamma:item.settings.gamma||null,
    followsTarget:item.tv_gamma_follows_target,delta:item.calibration.target_delta_e,
    pre:item.stages.pre_readings,post:item.stages.post_readings
   }));
   pgAutomationNewRecipe('queue');
   const gamma=()=>document.querySelector('[data-pg-automation-key="gamma"]');
   const initial=pgAutomationRecipeFromForm();
   if(initial.stages.pre_readings||initial.stages.post_readings)throw new Error('New jobs must default to sweeps off');
   if(!document.getElementById('pgAutomationCalibrationCard'))throw new Error('Calibration observer missing');
   if(typeof pgAutomationEstimateText!=='function')throw new Error('Time estimate helper missing');
   const runButton=pgAutomationEl('StartButton');
   if(!runButton.classList.contains('btn-sm')||!runButton.classList.contains('btn-danger'))throw new Error('Compact run button missing');
   const label=gamma().selectedOptions[0].textContent;
   pgAutomationEl('Gamma').value='2.4';pgAutomationEl('Gamma').dispatchEvent(new Event('change'));
   const changed=pgAutomationRecipeFromForm().settings.gamma;
   pgAutomationEl('PictureMode').value='cinema';pgAutomationModeChanged();
   const cinema=pgAutomationRecipeFromForm();
   pgAutomationEl('Signal').value='hdr10';pgAutomationModesChanged();pgAutomationSignalDefaults();
   const hdrHasGamma=!!gamma();
   pgAutomationEl('Signal').value='dv';pgAutomationModesChanged();pgAutomationSignalDefaults();
   const dvHasGamma=!!gamma();
   pgAutomationCancelEditor();
   return {reference,initialGamma:initial.settings.gamma,initialTarget:initial.target_gamma,delta:initial.target_delta_e,label,changed,cinemaGamma:cinema.settings.gamma,cinemaTarget:cinema.target_gamma,hdrHasGamma,dvHasGamma};
  });
  const reference=result.reference;delete result.reference;
  assert.deepEqual(reference.map(item=>item.mode),['dolbyVisionFilmMaker','dolbyVisionCinemaBright','hdrFilmMaker','hdrCinema','filmMaker','cinema']);
  assert.deepEqual(reference.map(item=>item.gamma),['st2084','st2084','st2084','st2084','bt1886','2.2']);
  assert.deepEqual(reference.map(item=>item.tvGamma),[null,null,null,null,'high2','medium']);
  assert.deepEqual(reference.map(item=>item.followsTarget),[false,false,false,false,true,true]);
  assert.ok(reference.every(item=>item.delta===.5&&!item.pre&&!item.post));
  assert.deepEqual(result,{initialGamma:'high2',initialTarget:'bt1886',delta:.5,label:'BT.1886',changed:'high1',cinemaGamma:'medium',cinemaTarget:'2.2',hdrHasGamma:false,dvHasGamma:false});
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({status:'ok',result,reference,browserErrors:errors,readOnly:true}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
