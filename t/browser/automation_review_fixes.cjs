// Click-through regression with a loopback server and mocked hardware only.
const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),http=require('http'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
const meta=read('webui-lg.js').match(/const LG_DISPLAY_CONTROL_ITEMS=\[[\s\S]*?const LG_DISPLAY_CONTROL_KEYS=[^;]+;/)[0];
const html='<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+read('webui-theme.css')+'</style>'+read('webui-automation.html')+'<script>'+meta+'</script><script>'+`
window.requests=[];
window.fetchJSON=async(url,opts={})=>{
 const body=opts.body?JSON.parse(opts.body):null;requests.push({url,body});
 if(url==='/api/automation/runs/current')return window.mockCurrent||{status:'ok'};
 if(url==='/api/automation/recipes')return {recipes:[]};
 if(url==='/api/automation/queues')return {queues:[]};
 if(url==='/api/automation/runs')return {runs:[]};
 if(url==='/api/automation/settings-plan')return {status:'ok',known:true,model_name:'OLED55G36LA',automatic:Object.fromEntries(Object.entries(body.settings).filter(([key])=>!['backlight','energySaving'].includes(key))),manual:{},blocked:{energySaving:{reason:'Not writable'}},panel_light:{label:'OLED Pixel Brightness',wire_key:'backlight',writable:true,target_available:true,source:'native_readback'}};
 if(url==='/api/automation/readiness')return {status:'blocked',ready:0,message:'First job needs attention',checks:[{ok:0,name:'item-0-key-gamma',message:'gamma is not supported by the LG TV. Configure this job.',item_number:0}]};
 if(url==='/api/lg/picture-settings')return {status:'ok',supported_picture_keys:['backlight','brightness','contrast'],picture_settings:{pictureMode:'filmMaker',backlight:25,brightness:50,contrast:85,energySaving:'off'},unsupported_picture_keys:{gamma:'Read unavailable'},setting_contracts:{energySaving:{write_decision:'blocked'}}};
 if(url==='/api/automation/runs/saved/queue')return {status:'ok',queue:{name:'Recovered server draft',items:[{name:'Recovered SDR',signal_format:'sdr',picture_mode:'filmMaker',settings:{contrast:85},stages:{calibration:true},panel_light:{key:'backlight',policy:'fixed',fixed_value:33}}]}};
 throw new Error('Unexpected request: '+url);
};
window.pgAutomationConfirmOverride=()=>true;
`+'</script><script>'+read('webui-automation.js')+'</script>';
(async()=>{
 const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(html)});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.setViewport({width:1440,height:1100});
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.waitForFunction(()=>pgAutomation.loaded);
  await page.click('button[onclick="pgAutomationNewRecipe(\'queue\')"]');
  await page.waitForFunction(()=>!pgAutomationEl('EditorSave').disabled);
  assert.ok(await page.$$eval('[data-pg-automation-pin]:checked',nodes=>nodes.length)>0,'matrix-filtered reference controls start selected');
  await page.click('button[onclick="pgAutomationResetPictureDefaults()"]');
  await page.waitForFunction(()=>!pgAutomationEl('EditorSave').disabled);
  await page.click('#pgAutomationKeysButton');
  await page.waitForFunction(()=>!pgAutomationEl('KeysButton').disabled);
  assert.deepEqual(await page.evaluate(()=>Object.keys(pgAutomationRecipeFromForm().settings).sort()),['backlight','brightness','contrast'],'unread and matrix-blocked controls are unpinned');
  await page.click('#pgAutomationEditorSave');
  await page.waitForFunction(()=>!pgAutomationEl('Editor').open);
  await page.reload();await page.waitForFunction(()=>pgAutomation.loaded&&pgAutomation.queue.items.length===1);
  assert.equal(await page.evaluate(()=>pgAutomation.queue.items[0].settings.contrast),85,'draft survives real browser refresh');
  await page.evaluate(()=>window.pgAutomationConfirmOverride=()=>false);
  const beforeCheck=await page.evaluate(()=>requests.filter(x=>x.url.endsWith('/readiness')).length);
  await page.click('#pgAutomationReadinessButton');
  await page.evaluate(()=>new Promise(resolve=>setTimeout(resolve,50)));
  assert.equal(await page.evaluate(()=>requests.filter(x=>x.url.endsWith('/readiness')).length),beforeCheck,'cancelling consent makes no device request');
  await page.evaluate(()=>window.pgAutomationConfirmOverride=()=>true);
  await page.click('#pgAutomationReadinessButton');
  await page.waitForFunction(()=>pgAutomationEl('Readiness').textContent.includes('gamma'));
  assert.equal(await page.evaluate(()=>requests.find(x=>x.url.endsWith('/readiness')).body.scope),'queue');
  assert.equal(await page.evaluate(()=>requests.find(x=>x.url.endsWith('/readiness')).body.confirm_mode_switches),true,'mode switching is explicitly confirmed');
  // P11 round 3: the real in-page confirmation is a styled modal, Escape and
  // Cancel decline, a second question never replaces an open one, and the
  // readiness guards are re-checked after the answer.
  await page.evaluate(()=>{delete window.pgAutomationConfirmOverride;window.confirmAnswers=[];pgAutomationConfirm('First question?','Go ahead').then(answer=>confirmAnswers.push(['first',answer]));});
  await page.waitForFunction(()=>document.getElementById('pgAutomationConfirmDialog')?.open);
  const look=await page.evaluate(()=>{const d=document.getElementById('pgAutomationConfirmDialog'),style=getComputedStyle(d),backdrop=getComputedStyle(d,'::backdrop');
   return {position:style.position,radius:style.borderRadius,background:style.backgroundColor,backdrop:backdrop.backgroundColor,text:d.querySelector('#pgAutomationConfirmText').textContent,ok:d.querySelector('#pgAutomationConfirmOk').textContent,focused:document.activeElement?.id,width:d.getBoundingClientRect().width};});
  assert.equal(look.position,'fixed','the confirmation is styled like the queue dialog');
  assert.equal(look.radius,'12px','with the same rounded panel');
  assert.equal(look.backdrop,'rgba(0, 0, 0, 0.7)','and the same dimmed backdrop');
  assert.notEqual(look.background,'rgba(0, 0, 0, 0)','and an opaque surface');
  assert.ok(look.width<=440,'at the queue dialog width');
  assert.deepEqual([look.text,look.ok,look.focused],['First question?','Go ahead','pgAutomationConfirmOk'],'it names the action and focuses it');
  assert.equal(await page.evaluate(()=>Promise.race([pgAutomationConfirm('Second question?','Replace'),new Promise(resolve=>setTimeout(()=>resolve('still pending'),1000))])),false,'a second question while one is open is declined at once');
  assert.equal(await page.$eval('#pgAutomationConfirmText',el=>el.textContent),'First question?','and never replaces the open question');
  await page.keyboard.press('Escape');
  await page.waitForFunction(()=>confirmAnswers.length===1);
  assert.deepEqual(await page.evaluate(()=>confirmAnswers[0]),['first',false],'Escape declines');
  await page.evaluate(()=>{pgAutomationConfirm('Third question?','Continue').then(answer=>confirmAnswers.push(['third',answer]));});
  await page.waitForFunction(()=>document.getElementById('pgAutomationConfirmDialog').open);
  await page.click('#pgAutomationConfirmOk');
  await page.waitForFunction(()=>confirmAnswers.length===2);
  assert.deepEqual(await page.evaluate(()=>confirmAnswers[1]),['third',true],'the action button confirms');
  const beforeGuard=await page.evaluate(()=>requests.filter(x=>x.url.endsWith('/readiness')).length);
  await page.evaluate(()=>{window.pgAutomationConfirmOverride=()=>{pgAutomation.busy=true;return true;};});
  await page.evaluate(()=>pgAutomationReadiness());
  await page.evaluate(()=>{pgAutomation.busy=false;window.pgAutomationConfirmOverride=()=>{window.savedItems=pgAutomation.queue.items;pgAutomation.queue.items=[];return true;};});
  await page.evaluate(()=>pgAutomationReadiness());
  await page.evaluate(()=>{pgAutomation.queue.items=window.savedItems;window.pgAutomationConfirmOverride=()=>true;});
  assert.equal(await page.evaluate(()=>requests.filter(x=>x.url.endsWith('/readiness')).length),beforeGuard,'a run started or an emptied queue while the question was open makes no device request');
  assert.ok(await page.$eval('#pgAutomationReadiness',el=>el.getBoundingClientRect().bottom<document.getElementById('pgAutomationQueueItems').getBoundingClientRect().top),'readiness is beside actions, before jobs');
  await page.evaluate(()=>{
   const failure={stage:'job-readiness',message:'Combined failure'};
   pgAutomation.current=window.mockCurrent={run:{id:'parked',status:'interrupted',active_item:0,failure,items:[{name:'Job',failure,readiness:{checks:Array.from({length:13},(_,i)=>({name:'item-0-key-control'+i,ok:0,level:'error',message:'control'+i+' is not supported by the LG TV. Configure this job.'}))}}]}};
   pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  assert.ok(await page.$eval('#pgAutomationStartButton',el=>el.disabled&&el.title.includes('interrupted')));
  assert.match(await page.$eval('#pgAutomationActionBlocker',el=>el.textContent),/Stop/);
  assert.match(await page.$eval('#pgAutomationProgress',el=>el.textContent),/Problems requiring attention \(13\)/);
  assert.equal(await page.$eval('#pgAutomationActivity',el=>el.open),false,'failure never forces log open');
  await page.click('#pgAutomationActionBlocker button');
  assert.equal(await page.evaluate(()=>pgAutomation.tab),'live');
  await page.evaluate(()=>{
   pgAutomation.current.run.cleanup_required=true;
   pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  assert.equal(await page.$eval('#pgAutomationResumeButton',el=>el.disabled),true,'cleanup blocks Resume');
  assert.equal(await page.$eval('#pgAutomationStopButton',el=>el.textContent),'Retry cleanup','failed cleanup has an explicit retry action');
  assert.equal(await page.$eval('#pgAutomationStopButton',el=>el.disabled),false,'cleanup retry is enabled');
  await page.evaluate(()=>{
   pgAutomation.current=window.mockCurrent={run:{id:'checked',status:'failed',preflight_only:true,items:pgAutomation.queue.items.map(item=>({name:item.name||item.picture_mode,status:'checked'})),preflight_result:{scope:'queue',ready:0,message:'Queue blocked before calibration',checks:[{ok:0,level:'error',item_number:3,message:'Job four unsupported'}]}}};
   pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  assert.match(await page.$eval('#pgAutomationLive',el=>el.textContent),/Last whole-queue check/,'check-only run is not reported as a calibration');
  assert.match(await page.$eval('#pgAutomationReadiness',el=>el.textContent),/Job four unsupported/,'late incompatibility is visible');
  // P1: the same saved result is not shown under a different (here empty) queue.
  await page.evaluate(()=>{pgAutomation.queue={name:'Test Queue',items:[]};pgAutomationRenderLiveRun(pgAutomation.current.run);});
  assert.match(await page.$eval('#pgAutomationReadiness',el=>el.textContent),/belongs to .*Check Readiness again for this queue/,'a readiness result is never shown under a queue it did not check');
  assert.doesNotMatch(await page.$eval('#pgAutomationReadiness',el=>el.textContent),/Job four unsupported/,'its checks are not listed under the other queue');
  await page.evaluate(()=>{
   pgAutomationEl('Activity').open=false;pgAutomation.current=window.mockCurrent={run:{id:'different',status:'running',items:[]}};pgAutomationRenderActivity();
   pgAutomation.historyActivity={run:{id:'saved',items:[{name:'Summary only'}]}};
   pgAutomationEl('HistoryDetail').innerHTML='<button id="recover" onclick="pgAutomationRecoverQueue()">Recover queue</button>';
   pgAutomationTab('history');
  });
  assert.equal(await page.$eval('#pgAutomationActivity',el=>el.open),false,'scope changes preserve log collapse');
  await page.click('#recover');await page.waitForFunction(()=>pgAutomation.queue.name==='Recovered server draft');
  assert.equal(await page.evaluate(()=>pgAutomation.queue.items[0].panel_light.fixed_value),33,'recovery fetches full server settings');
  await page.reload();await page.waitForFunction(()=>pgAutomation.queue.name==='Recovered server draft');
  for(const width of [320,390,1440]){
   await page.setViewport({width,height:1000});
   assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'no horizontal overflow at '+width);
  }
  assert.deepEqual(errors,[]);
  console.log('PASS click-through defaults, native import, refresh persistence, readiness, 13 blockers, disabled reasons, log collapse, server recovery and responsive layout');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1});
