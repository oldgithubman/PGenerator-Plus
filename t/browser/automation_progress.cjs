// Offline regression of the real live-poll/render path. No appliance access.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),puppeteer=require('puppeteer');
const html=require('./automation_activity_preview.cjs');
const source=fs.readFileSync(path.resolve(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1400,height:1000});await page.setContent(html);
  await page.addScriptTag({content:source.slice(source.indexOf('async function pgAutomationPollLive(){'),source.indexOf('function pgAutomationHistorySummary('))});
  await page.evaluate(async()=>{
   const check=(ok,why)=>{if(!ok)throw Error(why);},now=Date.now()/1000;
   pgAutomation.pendingChecks=null;pgAutomation.tab='live';pgAutomation.logNotices=[];pgAutomation.statusError='';
   const run={id:'live-progress',queue_name:'Test Queue',status:'running',active_item:0,active_stage:'tv-setup-verified',heartbeat_age:1,created_at:now-600,stage_started_at:now-60,
    items:[{name:'SDR Filmmaker',status:'running'},{name:'SDR Cinema',status:'queued'}],
    progress:{completed:2.15,total:25,stage_completed:3,stage_total:19,unit:'settings and verification'},
    operation_progress:{stage:'tv-setup-verified',message:'Applying contrast (4/18)'},
    preflight_result:{scope:'queue',ready:1,checks:[{time:now-400,ok:1,message:'Saved readiness check'}]}};
   let sequence=1;
   fetchJSON=async()=>({status:'ok',run:structuredClone(run),activity:{entries:[{source:'Runner',time:now+sequence,message:'Live operation '+sequence}]},preflight:{id:run.id,status:'ready'}});
   await pgAutomationPollLive();clearTimeout(pgAutomation.liveTimer);
   check(pgAutomation.current.activity.entries[0].source==='Runner','saved readiness renderer must preserve live response');
   check(pgAutomationEl('Log').textContent.includes('Live operation 1'),'first live operation is visible');
   sequence++;run.progress.stage_completed=4;
   await pgAutomationPollLive();clearTimeout(pgAutomation.liveTimer);
   check(pgAutomationEl('Log').textContent.includes('Live operation 2'),'subsequent poll advances log');
   check(!pgAutomationEl('Log').textContent.includes('Saved readiness check'),'readiness does not overwrite live log');
   const bars=pgAutomationEl('Progress').querySelectorAll('progress');
   check(bars.length===2&&bars[0].value===4&&bars[0].max===19,'primary bar advances within TV setup');
   check(bars[1].value>0&&bars[1].value<1,'whole-queue bar advances before a whole job completes');
   check(pgAutomationEl('Progress').textContent.includes('Applying contrast'),'top display names current TV operation');
   const before=document.querySelector('[data-automation-clock]').textContent,realNow=Date.now;
   Date.now=()=>realNow()+2100;pgAutomationTickProgress();
   check(before===document.querySelector('[data-automation-clock]').textContent,'elapsed clock holds still within a minute');
   Date.now=()=>realNow()+61000;pgAutomationTickProgress();Date.now=realNow;
   check(before!==document.querySelector('[data-automation-clock]').textContent,'elapsed clock advances by whole minutes without a server poll');
   check(!document.querySelector('#pgAutomationProgress').textContent.match(/\d+s\b|ago/),'nothing in the card counts seconds');
   run.active_stage='queue-preflight';run.active_item=null;delete run.operation_progress;
   run.progress={completed:.33,total:25,stage_completed:3,stage_total:9,unit:'checks'};
   run.preflight_result={scope:'queue',total_items:2,jobs:[{status:'checked-limited'},{status:'checked-limited'}]};
   await pgAutomationPollLive();clearTimeout(pgAutomation.liveTimer);
   check(pgAutomationEl('Progress').textContent.includes('Checking the whole queue'),'initial checks have their own heading');
   check(pgAutomationEl('Progress').querySelector('progress').value===3,'initial checks are determinate before calibration');
   check(pgAutomationEl('Progress').textContent.includes('2 of 2 jobs checked'),'limited preflight jobs count as checked, not calibration complete');
   check(!pgAutomationEl('Progress').textContent.includes('0 of 2 jobs complete'),'preflight must not show calibration completion counts');
   // A rendering exception used to risk wedging polling=true forever.
   const render=pgAutomationRenderActivity;pgAutomationRenderActivity=()=>{throw Error('injected render failure')};
   await pgAutomationPollLive();clearTimeout(pgAutomation.liveTimer);
   check(!pgAutomation.polling&&pgAutomation.liveTimer,'renderer error releases guard and schedules another poll');
   pgAutomationRenderActivity=render;sequence++;
   await pgAutomationPollLive();clearTimeout(pgAutomation.liveTimer);
   check(!pgAutomation.statusError&&pgAutomationEl('Log').textContent.includes('Live operation 3'),'next poll recovers after renderer error');
   window.progressFixture=run;
  });
  const evidence=process.env.PGEN_UI_EVIDENCE;
  if(evidence){await page.$eval('#pgAutomationProgress',e=>e.scrollIntoView({block:'start'}));await page.screenshot({path:path.join(evidence,'initial-checks.png')});}
  await page.evaluate(()=>{
   const r=window.progressFixture,now=Date.now()/1000;
   r.active_stage='volume-done';r.active_item=0;r.created_at=now-3900;r.stage_started_at=now-1737;
   r.worker_status={status:'running',current_name:'25/0/100',message:'Reading 25/0/100',current_step:211,total_steps:765};
   r.progress={completed:7.26,total:25,stage_completed:210,stage_total:765,unit:'patches'};
   r.time_estimate={active_item:0,stage:r.active_stage,calculated_at:now,scope:'pass',pass_remaining_seconds:4500,job_remaining_seconds:5100,job_unknown_stages:1,batch_known_seconds:10800,batch_unknown_stages:2,known_stages:16,remaining_stages:18};
   pgAutomation.current={run:r,activity:{entries:[{source:'Runner',message:'3D LUT profile 211/765'}]}};
   pgAutomationRenderLiveRun(r);pgAutomationTickProgress();
  });
  for(const width of [1400,700,320]){
   await page.setViewport({width,height:1000});
   assert.ok(await page.$eval('#pgAutomationProgress',e=>e.scrollWidth<=e.clientWidth+1),`progress wraps at ${width}px`);
   if(evidence)await (await page.$('#pgAutomationProgress')).screenshot({path:path.join(evidence,`progress-${width}.png`)});
  }
  await page.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
  // The colour stage is named for the job's own signal, so an SDR or HDR job
  // never reads as Dolby Vision work.
  assert.equal(await page.$eval('#pgAutomationProgress progress',e=>e.getAttribute('aria-label')),'3D LUT profiling');
  assert.equal(await page.evaluate(()=>{const run=pgAutomation.current.run;const was=run.items[Number(run.active_item)].signal_format;
   run.items[Number(run.active_item)].signal_format='dv';pgAutomationRenderProgress();
   const label=document.querySelector('#pgAutomationProgress progress').getAttribute('aria-label');
   run.items[Number(run.active_item)].signal_format=was;pgAutomationRenderProgress();return label;}),'Dolby Vision profiling','a Dolby Vision job names its own profile');
  await page.evaluate(()=>{pgAutomation.current.run.status='paused';pgAutomationRenderProgress();pgAutomationTickProgress();});
  assert.match(await page.$eval('[data-automation-eta]',e=>e.textContent),/paused/);
  await page.evaluate(()=>{
   pgAutomation.current={preflight:{id:'limited-check',status:'ready',total_items:2,
    items:[{status:'checked-limited'},{status:'checked'}],issues:[{level:'warning',message:'Picture mode needs manual confirmation'}]}};
   pgAutomationRenderProgress();
   if(!pgAutomationEl('Progress').textContent.includes('2 of 2 jobs checked'))throw Error('saved limited checks are counted');
   if(!pgAutomationEl('Progress').textContent.includes('manual confirmation'))throw Error('limited verification warning is preserved');
  });
  assert.deepEqual(errors,[]);
  console.log('PASS live log survives readiness, repeated polling, advancing check/setup/patch bars, ticking elapsed time, render-error recovery, responsive progress and pause state');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
