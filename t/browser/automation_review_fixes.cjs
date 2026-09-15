// Click-through regression with a loopback server and mocked hardware only.
const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),http=require('http'),puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
const meta=read('webui-lg.js').match(/const LG_DISPLAY_CONTROL_ITEMS=\[[\s\S]*?const LG_DISPLAY_CONTROL_KEYS=[^;]+;/)[0];
const html='<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+read('webui-theme.css')+'</style>'+read('webui-automation.html')+'<script>'+meta+'</script><script>'+read('webui-automation.js')+'</script><script>'+`
window.requests=[];
window.fetchJSON=async(url,opts={})=>{
 const body=opts.body?JSON.parse(opts.body):null;requests.push({url,body});
 if(url==='/api/automation/runs/current')return {status:'ok'};
 if(url==='/api/automation/recipes')return {recipes:[]};
 if(url==='/api/automation/queues')return {queues:[]};
 if(url==='/api/automation/runs')return {runs:[]};
 if(url==='/api/automation/settings-plan')return {status:'ok',known:true,model_name:'OLED55G36LA',automatic:Object.fromEntries(Object.entries(body.settings).filter(([key])=>!['backlight','energySaving'].includes(key))),manual:{},blocked:{energySaving:{reason:'Not writable'}},panel_light:{label:'OLED Pixel Brightness',wire_key:'backlight',writable:true,target_available:true,source:'native_readback'}};
 if(url==='/api/automation/readiness')return {status:'ok',ready:0,message:'First job needs attention',checks:[{ok:0,name:'item-0-key-gamma',message:'gamma is not supported by the LG TV. Configure this job.',item_number:0}]};
 if(url==='/api/lg/picture-settings')return {status:'ok',supported_picture_keys:['backlight','brightness','contrast'],picture_settings:{pictureMode:'filmMaker',backlight:25,brightness:50,contrast:85,energySaving:'off'},unsupported_picture_keys:{gamma:'Read unavailable'},setting_contracts:{energySaving:{write_decision:'blocked'}}};
 if(url==='/api/automation/runs/saved/queue')return {status:'ok',queue:{name:'Recovered server draft',items:[{name:'Recovered SDR',signal_format:'sdr',picture_mode:'filmMaker',settings:{contrast:85},stages:{calibration:true},panel_light:{key:'backlight',policy:'fixed',fixed_value:33}}]}};
 throw new Error('Unexpected request: '+url);
};
window.confirm=()=>true;
`+'</script>';
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
  await page.click('#pgAutomationReadinessButton');
  await page.waitForFunction(()=>pgAutomationEl('Readiness').textContent.includes('gamma'));
  assert.equal(await page.evaluate(()=>requests.find(x=>x.url.endsWith('/readiness')).body.scope),'preview');
  assert.ok(await page.$eval('#pgAutomationReadiness',el=>el.getBoundingClientRect().bottom<document.getElementById('pgAutomationQueueItems').getBoundingClientRect().top),'readiness is beside actions, before jobs');
  await page.evaluate(()=>{
   const failure={stage:'job-readiness',message:'Combined failure'};
   pgAutomation.current={run:{id:'parked',status:'interrupted',active_item:0,failure,items:[{name:'Job',failure,readiness:{checks:Array.from({length:13},(_,i)=>({name:'item-0-key-control'+i,ok:0,level:'error',message:'control'+i+' is not supported by the LG TV. Configure this job.'}))}}]}};
   pgAutomationRenderLiveRun(pgAutomation.current.run);
  });
  assert.ok(await page.$eval('#pgAutomationStartButton',el=>el.disabled&&el.title.includes('interrupted')));
  assert.match(await page.$eval('#pgAutomationActionBlocker',el=>el.textContent),/Stop/);
  assert.match(await page.$eval('#pgAutomationProgress',el=>el.textContent),/Problems requiring attention \(13\)/);
  assert.equal(await page.$eval('#pgAutomationActivity',el=>el.open),false,'failure never forces log open');
  await page.click('#pgAutomationActionBlocker button');
  assert.equal(await page.evaluate(()=>pgAutomation.tab),'live');
  await page.evaluate(()=>{
   pgAutomationEl('Activity').open=false;pgAutomation.current={run:{id:'different',status:'running',items:[]}};pgAutomationRenderActivity();
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
