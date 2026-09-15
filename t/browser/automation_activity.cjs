const assert=require('node:assert/strict'),puppeteer=require('puppeteer');
const html=require('./automation_activity_preview.cjs');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1400,height:1100});await page.setContent(html);
  const names=()=>page.evaluate(()=>pgAutomation.queue.items.map(item=>item.name));
  const original=await names();
  await page.evaluate(()=>{
   const card=document.getElementById('automationCard'),box=pgAutomationEl('Log');
   box.innerHTML='';box.scrollTop=0;card.style.display='none';pgAutomation.logSignature=null;pgAutomation.logFollow=true;
   pgAutomationRenderActivity();
   card.style.display='';pgAutomationRenderActivity();
   if(box.scrollHeight-box.clientHeight-box.scrollTop>=24)throw new Error('Opening workspace must follow latest even when log content is unchanged');
  });
  async function drag(from,to,after=true,cancel=false){
   const source='[data-queue-index="'+from+'"] .auto-reorder',target='[data-queue-index="'+to+'"]';
   await page.$eval(source,el=>el.scrollIntoView({block:'center'}));
   const start=await page.$eval(source,el=>{const r=el.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}});
   await page.mouse.move(start.x,start.y);await page.mouse.down();
   await page.$eval(target,el=>el.scrollIntoView({block:'center'}));
   const end=await page.$eval(target,(el,after)=>{const r=el.getBoundingClientRect();return {x:r.x+r.width/2,y:after?r.bottom-12:r.top+12}},after);
   await page.mouse.move(end.x,end.y,{steps:12});
   if(cancel)await page.keyboard.press('Escape');
   await page.mouse.up();
  }
  await drag(0,2);
  assert.deepEqual(await names(),[original[1],original[2],original[0],...original.slice(3)],'pointer drag inserts after target');
  await drag(2,0,false);assert.deepEqual(await names(),original,'drag upward inserts before target');
  await drag(0,3,true,true);assert.deepEqual(await names(),original,'Escape cancels without mutation');
  await page.focus('[data-queue-index="0"] .auto-reorder');await page.keyboard.press('ArrowDown');
  assert.equal((await names())[1],original[0],'keyboard reorder');
  assert.ok(await page.$eval('[data-queue-index="1"] .auto-reorder',el=>el===document.activeElement),'focus follows keyboard move');
  await page.evaluate(()=>{pgAutomation.editingRunId='live';pgAutomation.firstPending=2;pgAutomationRenderQueue();});
  assert.equal(await page.$$eval('[data-queue-index="0"] .auto-reorder',els=>els.length),0,'locked job has no handle');
  const locked=await names();await drag(2,0,false);assert.deepEqual(await names(),locked,'cannot drop onto locked prefix');
  await drag(2,4);assert.equal((await names())[4],locked[2],'pending jobs can reorder');
  await page.evaluate(()=>{pgAutomation.current.run={id:'live',active_item:4,status:'running',items:[]};pgAutomationQueueMove(3,2);});
  assert.equal((await names())[3],locked[4],'server advancement locks stale pending job');
  const logChecks=await page.evaluate(()=>{
   const check=(condition,message)=>{if(!condition)throw new Error(message);};
   delete pgAutomation.current.run;pgAutomationRenderActivity();
   const box=pgAutomationEl('Log');
   check(box.scrollHeight>box.clientHeight&&box.clientHeight<300,'log height bounded');
   const count=box.children.length;pgAutomationRenderActivity();check(box.children.length===count,'poll does not duplicate log');
   box.scrollTop=0;pgAutomationLogScroll();check(!pgAutomation.logFollow,'scrolling back pauses following');
   pgAutomation.current.activity.entries.push({time:1789297400,source:'Runner',message:'<img src=x onerror="throw 1"> failed',level:'error'});pgAutomationRenderActivity();
   check(box.scrollTop===0&&!box.querySelector('img'),'new output preserves scroll and escapes markup');
   pgAutomationLogLatest();check(box.scrollHeight-box.clientHeight-box.scrollTop<24,'Jump to latest follows output');
   pgAutomation.current.activity.entries=Array.from({length:1000},(_,i)=>({time:i,source:'Runner',message:'Line '+i}));pgAutomationRenderActivity();check(box.children.length===500,'long history is bounded');
   pgAutomation.historyActivity={run:{id:'older',queue_name:'Earlier run'},activity:{entries:[{source:'Runner',message:'Older output'}]}};pgAutomation.tab='history';pgAutomationRenderActivity();
   check(box.textContent.includes('Older output')&&!box.textContent.includes('Line 999'),'History does not mix current logs');
   pgAutomation.tab='queue';pgAutomation.current={run:{id:'old',status:'stopped'},preflight:{id:'new',status:'checking',message:'Reconnecting TV'},activity:{entries:[]}};pgAutomationRenderActivity();check(pgAutomation.logScope==='new','new startup takes precedence over stopped run');
   pgAutomation.current={run:{id:'logging',status:'running',active_stage:'greyscale-done',worker_status:{current_name:'Auto Cal 7%',message:'Reading 7% sample 1/1'}},activity:{entries:[{source:'Runner',message:'7% | Attempt 4/8 | dE 0.610'}]}};
   pgAutomationRenderActivity();
   check(box.children.length===1&&!box.textContent.includes('Observed in browser'),'saved worker event is not duplicated by browser status');
   pgAutomation.current.run.worker_status.message='Reading 7% sample 2/2';pgAutomationRenderActivity();
   check(box.children.length===1,'sample counter changes do not add activity lines');
   pgAutomation.statusError='Connection lost; displaying last known progress';pgAutomationRenderActivity();pgAutomationRenderActivity();
   check(box.children.length===2&&box.textContent.includes('Connection lost'),'browser connection failure remains visible once');
   pgAutomation.statusError='';
   return 'scroll, deduplication, escaping, limits and history isolation';
  });
  await page.evaluate(()=>{
   const failure={stage:'pre-readings-done',error_code:'meter-integration-restart-failed',message:'Meter communication failed'};
   pgAutomation.pendingChecks=null;pgAutomation.lastProblem='';pgAutomation.statusError='';
   pgAutomation.current={run:{id:'interrupted',status:'interrupted',active_item:2,active_stage:'pre-readings-done',failure,
    worker_status:{message:'Cleanup complete: All workers stopped; meter released; TV acknowledged calibration exit'},
    items:[{status:'complete'},{status:'complete'},{name:'Dolby Vision Cinema Home',status:'failed',failure:{...failure}}]}};
   pgAutomationRenderProgress();
   const box=pgAutomationEl('Progress');
   if(!box.textContent.includes('Problems requiring attention (1)'))throw new Error('same job/run failure must appear once');
   if(!box.textContent.includes('Job 3: Before readings')||!box.textContent.includes('Cleanup complete'))throw new Error('failure keeps job context and cleanup result');
   pgAutomation.current.run.failure={...failure,message:'A separate cleanup failure'};pgAutomationRenderProgress();
   if(!box.textContent.includes('Problems requiring attention (2)'))throw new Error('distinct run and job failures must both remain visible');
  });
  await page.evaluate(()=>{
   const check=(condition,message)=>{if(!condition)throw new Error(message);};
   const now=Date.now()/1000;
   const run={id:'eta',status:'running',active_item:0,active_stage:'greyscale-done',heartbeat_age:1,items:[{name:'SDR Filmmaker',status:'running'}],
    time_estimate:{scope:'batch',remaining_seconds:1200,calculated_at:now,active_item:0,stage:'greyscale-done'}};
   pgAutomation.statusError='';pgAutomation.pendingChecks=null;pgAutomation.current={run};pgAutomationRenderProgress();
   check(pgAutomationEl('Progress').querySelector('[data-automation-eta]').textContent==='Estimated batch remaining: ~15m–30m','main progress bar shows a rough batch time range');
   run.time_estimate.scope='stage';pgAutomationRenderProgress();
   check(pgAutomationEl('Progress').textContent.includes('Estimated current stage:')&&pgAutomationEl('Progress').textContent.includes('Batch estimate still learning'),'stage ETA cannot masquerade as whole-batch remaining time');
   run.time_estimate.scope='unknown';check(pgAutomationEstimateText(run)==='Estimating time remaining…','no timing evidence shows estimating');
   run.time_estimate.scope='batch';run.time_estimate.calculated_at=now-181;
   check(pgAutomationEstimateText(run,now)==='Updating time estimate…','old estimate never becomes a stale countdown');
   run.time_estimate.calculated_at=now;run.time_estimate.remaining_seconds=NaN;
   check(pgAutomationEstimateText(run,now)==='Updating time estimate…','invalid ETA cannot render NaN');
   run.time_estimate.remaining_seconds=30;
   check(!pgAutomationEstimateText(run,now).includes('0m'),'positive ETA never rounds to zero');
   run.time_estimate.remaining_seconds=1200;run.time_estimate.stage='volume-done';
   check(pgAutomationEstimateText(run)==='Estimating time remaining…','old-stage ETA is ignored');
   run.time_estimate.stage=run.active_stage;run.heartbeat_age=61;
   check(pgAutomationEstimateText(run).includes('waiting for live progress'),'lost heartbeat suspends ETA');
   run.heartbeat_age=1;pgAutomation.statusError='Offline';
   check(pgAutomationEstimateText(run).includes('waiting for live progress'),'browser disconnection suspends ETA');
   pgAutomation.statusError='';run.status='paused';check(pgAutomationEstimateText(run)==='Time estimate paused','pause has no running countdown');
   run.status='running';Object.assign(run.time_estimate,{job_remaining_seconds:600,job_unknown_stages:0,batch_known_seconds:3600,batch_unknown_stages:0,known_stages:20,remaining_stages:20,approximate_history:true,stage_remaining_seconds:500});
   let text=pgAutomationEstimateText(run,now);
   check(text.includes('Current job: ~')&&text.includes('Batch: ~')&&text.includes('Uses similar-job timings'),'current job and whole batch estimates are separate and explain approximate history');
   run.time_estimate.batch_unknown_stages=5;run.time_estimate.known_stages=15;
   text=pgAutomationEstimateText(run,now);
   check(text.includes('15/20 remaining stages estimated')&&text.includes('of timed work'),'partial timing coverage cannot masquerade as whole batch');
   run.time_estimate.scope='unknown';run.time_estimate.job_unknown_stages=2;
   check(pgAutomationEstimateText(run,now).includes('+ untimed stages'),'useful known timing survives an unknown current stage');
   run.time_estimate.calculated_at=now-181;
   check(pgAutomationEstimateText(run,now)==='Updating time estimate…','new estimate format also rejects stale timing');
   run.time_estimate.calculated_at=now;
   run.status='complete';pgAutomationRenderProgress();check(!pgAutomationEl('Progress').querySelector('[data-automation-eta]'),'finished batch removes estimate');
   run.status='running';pgAutomationRenderProgress();
  });
  await page.setViewport({width:390,height:844});
  assert.ok(await page.$eval('#pgAutomationProgress',el=>el.scrollWidth<=el.clientWidth+1),'time estimate wraps on narrow screens');
  await page.evaluate(()=>{pgAutomation.editingRunId='';pgAutomationRenderQueue();});
  assert.ok(await page.$eval('#automationCard',el=>el.scrollWidth<=el.clientWidth+1),'mobile card has no horizontal overflow');
  const beforeTouch=await names(),cdp=await page.createCDPSession();
  await page.$eval('[data-queue-index="0"]',el=>el.scrollIntoView({block:'start'}));
  const touch=await page.evaluate(()=>{
   const a=document.querySelector('[data-queue-index="0"] .auto-reorder').getBoundingClientRect(),b=document.querySelector('[data-queue-index="1"]').getBoundingClientRect();
   return {x:a.x+a.width/2,y:a.y+a.height/2,tx:b.x+b.width/2,ty:b.bottom-12};
  });
  await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:touch.x,y:touch.y}]});
  await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:touch.tx,y:touch.ty}]});
  await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
  assert.equal((await names())[1],beforeTouch[0],'touch drag reorders jobs on narrow screens');
  await page.evaluate(()=>{
   pgAutomation.lastProblem='';pgAutomationNotice('Pending changes saved; optional control unverified','warning');
   if(pgAutomation.logNotices.at(-1).level!=='warning'||pgAutomationEl('Notice').style.color!=='var(--orange)'||pgAutomation.lastProblem)throw new Error('A successful save with a warning must not become a red blocking error');
   pgAutomationNotice('Upload failed',true);
   if(pgAutomation.logNotices.at(-1).level!=='error'||pgAutomationEl('Notice').style.color!=='var(--red)')throw new Error('Actual failures remain red');
   const stopped=pgAutomationJobFailureHtml({status:'stopped',failure:{status:'interrupted',stage:'volume-done'}});
   if(!stopped.includes('Stopped during')||stopped.includes('--red'))throw new Error('Normal cancellation stage is neutral');
   const failed=pgAutomationJobFailureHtml({status:'stopped',failure:{status:'interrupted',stage:'volume-done',message:'Cleanup failed'}});
   if(!failed.includes('--red'))throw new Error('A stopped job with an actual failure remains red');
  });
  assert.deepEqual(errors,[]);console.log('PASS drag/drop, locks, cancel, keyboard, mobile; '+logChecks);
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
