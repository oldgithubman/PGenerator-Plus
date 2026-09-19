// Load the real UI, but intercept every write: this test never controls the TV.
const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),puppeteer=require('puppeteer');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage();
  await page.setRequestInterception(true);
  page.on('request',r=>r.method()==='GET'?r.continue():r.respond({status:403,contentType:'application/json',body:'{"status":"error","message":"Read-only browser test"}'}));
  await page.goto(process.env.PGEN_TEST_URL||'http://192.168.50.110/',{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof meterRecoverSeries==='function');
  if(!process.argv.includes('--deployed')){
   for(const [file,name] of [['webui-app.js','meterRecoverSeries'],['webui-workspace.js','meterClearDisplayPattern']]){
    const source=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator',file),'utf8');
    await page.addScriptTag({content:source.match(new RegExp('function '+name+'\\([^]*?\\n\\}'))[0]});
   }
  }
  const result=await page.evaluate(async()=>{
   const timers=[],requests=[];
   const originalInterval=window.setInterval,originalFetch=window.fetchJSON;
   window.setInterval=(fn,ms)=>{timers.push(fn.name);return 12345;};
   window.fetchJSON=async(url,opts)=>{requests.push({url,body:opts?.body&&JSON.parse(opts.body)});return {status:'ok'};};
   try{
    const snapshot={status:'running',type:'greyscale',points:21,steps:meterBuildStepsJS('greyscale',21),readings:[]};
    // This is the exact no-ID recovery performed by cache/report restore.
    meterRecoverSeries({...snapshot,series_id:null});
    const cached={running:meterSeriesRunning,id:meterSharedSeriesId,timers:[...timers]};
    meterClearDisplayPattern();await meterPatternDisplayQueue;
    meterRecoverSeries({...snapshot,series_id:'greyscale-test-live'});
    return {cached,live:{running:meterSeriesRunning,id:meterSharedSeriesId,timers:[...timers]},requests};
   }finally{window.setInterval=originalInterval;window.fetchJSON=originalFetch;}
  });
  assert.equal(result.cached.running,false,'a cached graph cannot adopt an unrelated live measurement');
  assert.deepEqual(result.cached.timers,[],'cached running snapshot does not start an ownerless poll');
  assert.equal(result.live.running,true,'server-identified live series still recovers');
  assert.equal(result.live.id,'greyscale-test-live');
  assert.ok(result.live.timers.includes('meterPollSeries'));
  assert.equal(result.requests.find(r=>r.url==='/api/pattern')?.body.only_if_unowned,true,'background completion cannot blank a newer worker-owned patch');
  console.log('PASS: cached/live recovery and completion-pattern ownership');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
