// Offline regression for descriptive History titles, the per-job detail and
// the LG Calibration History "From run" line. No Pi/TV requests or writes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),puppeteer=require('puppeteer');
const html=require('./automation_activity_preview.cjs');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
const source=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
const lg=fs.readFileSync(path.join(root,'webui-lg.js'),'utf8');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.emulateTimezone('UTC');
  await page.setContent(html);
  // The preview stubs refresh; load the real one, and the LG history renderer.
  await page.addScriptTag({content:source.slice(source.indexOf('async function pgAutomationRefresh(){'),source.indexOf('function pgAutomationInit(){'))});
  await page.addScriptTag({content:'function lgEscapeHtml(v){return String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",\'"\':"&quot;"}[c]));}'
   +lg.slice(lg.indexOf('let lgCalHistoryCache=[];'),lg.indexOf('let lgCalHistoryRefreshInFlight=null;'))});
  const hdr={id:'20260915-201855-714a0d',queue_name:'Reference settings',status:'complete',created_at:1789496335,created_at_iso:'2026-09-15T20:18:55Z',preflight_only:0,
   digest:{job_count:1,job_names:['HDR10 Filmmaker'],status:'complete-with-warnings',lut_1d:1,lut_3d:1,de:0.9745,formula:'deitp'}};
  const check={id:'20260921-215409-fb874a',queue_name:'Reference settings',status:'complete',created_at:1789999999,preflight_only:1,digest:{job_count:1,job_names:['SDR Filmmaker'],lut_1d:0,lut_3d:0,formula:'deitp'}};
  const multi={id:'20260917-045844-adcf92',queue_name:'Reference settings',status:'complete-with-warnings',created_at:1789621000,preflight_only:0,
   digest:{job_count:6,job_names:['Dolby Vision Filmmaker','Dolby Vision Cinema Home','HDR10 Filmmaker']}};
  const old={id:'20260914-233812-056a82',queue_name:'TV calibration queue',status:'stopped',created_at:1789400000,preflight_only:0,digest_pending:1};
  const job={name:'HDR10 Filmmaker',signal:'hdr10',picture_mode:'hdrFilmMaker',tv_input:'hdmi2',stages:['calibration','apply_all'],status:'complete-with-warnings',
   lut_1d:1,lut_3d:1,de:0.9745,formula:'deitp',peak_nits:673.97,post_readings:0,
   artifacts:[{id:'3d:20260915_214849_OLED65C1PUB_hdr10',type:'3d'},{id:'1dfile:20260915_220659_OLED65C1PUB_hdr10_hdrFilmMaker_smoothed',type:'1d',variant:'smoothed',inferred:1}]};
  const checks=await page.evaluate(async(rows,job)=>{
   const check=(value,message)=>{if(!value)throw new Error(message);};
   const [hdr,readiness,multi,old]=rows;
   let digestCalls=0,listCalls=0;
   fetchJSON=async url=>{
    if(url==='/api/automation/runs'){listCalls++;return {status:'ok',runs:listCalls===1?[hdr,old]:[hdr,{...old,digest_pending:undefined,digest:{job_count:1,job_names:['DV Cinema']}}]};}
    if(url.endsWith('/digest')){digestCalls++;return {status:'ok',run_id:hdr.id,jobs:[job]};}
    return {status:'ok',recipes:[],queues:[]};
   };
   pgAutomationEl('TabHistory').style.display='';
   pgAutomation.history=rows;pgAutomationRenderHistoryList();
   const titles=[...document.querySelectorAll('#pgAutomationHistoryList .auto-history-row strong')].map(el=>el.textContent);
   check(/^Sep 15, [^·]*\d\d:\d\d[^·]* · HDR10 Filmmaker \(1D \+ 3D\) · complete with warnings · ΔE ITP 0\.97$/.test(titles[0].replace(/\u202f/g,' ')),'a calibration title names the job, both LUTs, the job outcome and dE: '+titles[0]);
   check(titles[1].includes('Readiness check · SDR Filmmaker · complete')&&!titles[1].includes('1D')&&!titles[1].includes('ΔE'),'a readiness pass is labeled and claims no calibration: '+titles[1]);
   check(titles[2].includes('6 jobs: Dolby Vision Filmmaker, Dolby Vision Cinema Home, HDR10 Filmmaker, …')&&!titles[2].includes('ΔE'),'a multi-job run lists its jobs without one dE: '+titles[2]);
   check(titles[3].includes('TV calibration queue · stopped'),'a row still awaiting its digest falls back to the queue name: '+titles[3]);
   check(document.querySelector('.auto-history-row small').textContent.includes('Reference settings · '+hdr.id),'the queue name and run ID stay visible under the title');
   // Keyboard: the detail opens from its summary like any disclosure.
   const summary=document.querySelector('.auto-history-row .auto-history-details>summary');
   summary.focus();check(document.activeElement===summary,'the job detail is reachable by keyboard');
   summary.click();await new Promise(r=>setTimeout(r,50));
   const detail=document.querySelector('.auto-history-row .auto-history-jobs').textContent;
   check(digestCalls===1,'expanding a row fetches that one run');
   for(const text of ['HDR10 · hdrFilmMaker · HDMI2','Stages: calibration, apply all','Outcome: complete with warnings','ΔE ITP 0.97 (final)','Peak 674 cd/m²','3D LUT uploaded: yes','Post-readings: none','matched by time and picture mode'])
    check(detail.includes(text),'the detail says '+text+': '+detail);
   // A refresh rebuilds the rows and keeps the open one open, without refetching.
   pgAutomationRenderHistoryList();await new Promise(r=>setTimeout(r,50));
   check(document.querySelector('.auto-history-row .auto-history-details').open,'a refresh keeps the expanded row open');
   check(digestCalls===1&&document.querySelector('.auto-history-row .auto-history-jobs').textContent.includes('HDR10 Filmmaker'),'and reuses the fetched digest');
   // A running run keeps its status while its jobs progress: never reuse its digest.
   const running=document.createElement('details');running.innerHTML='<div class="auto-history-jobs"></div>';running.open=true;
   pgAutomation.history.push({...hdr,id:'live-run',status:'running'});
   await pgAutomationHistoryDetails(running,pgAutomation.history.length-1);delete running.dataset.loaded;
   await pgAutomationHistoryDetails(running,pgAutomation.history.length-1);
   check(digestCalls===3,'a running run is fetched again each time it is expanded');
   pgAutomation.history.pop();
   // Artifact buttons open LG Calibration History at the entry.
   document.body.insertAdjacentHTML('beforeend','<div id="lgCalHistoryModal" style="display:none"><div data-id="3d:other"></div><div data-id="3d:20260915_214849_OLED65C1PUB_hdr10">entry</div></div>');
   let opened=0;window.lgOpenCalHistoryModal=()=>{opened++;document.getElementById('lgCalHistoryModal').style.display='block';};window.lgRefreshCalHistory=async()=>{};
   document.querySelector('[data-artifact-id^="3d:"]').click();await new Promise(r=>setTimeout(r,50));
   const target=document.querySelector('#lgCalHistoryModal [data-id="3d:20260915_214849_OLED65C1PUB_hdr10"]');
   check(opened===1&&target.classList.contains('lg-cal-hist-highlight')&&document.activeElement===target,'an artifact button opens and focuses its LG Calibration History entry');
   // Rows still awaiting a digest are refreshed until the server finishes them.
   pgAutomation.tab='history';pgAutomation.digestRetries=0;
   await pgAutomationRefresh();
   check(pgAutomation.history.some(run=>run.digest_pending),'the first listing still has a pending row');
   await new Promise(r=>setTimeout(r,1900));
   check(listCalls===2&&!pgAutomation.history.some(run=>run.digest_pending),'History refreshes itself until every row has its digest');
   await new Promise(r=>setTimeout(r,1700));
   check(listCalls===2,'and stops once none is pending');
   // LG Calibration History: where each entry came from.
   lgCalHistoryLinks={'1dfile:x':{run_id:hdr.id,job:'HDR10 Filmmaker',created_at:1789496335,inferred:1}};
   lgCalHistoryCache=[{id:'1dfile:x',type:'1d',label:'x'},{id:'1dfile:y',type:'1d',label:'y',source_run:'gone-run'},{id:'1dfile:z',type:'1d',label:'z'}];
   const host=document.createElement('div');document.body.appendChild(host);lgRenderCalHistoryInto(host);
   const source=[...host.querySelectorAll('.lg-cal-hist-item')].map(el=>el.querySelector('.lg-cal-hist-source')?.textContent||'');
   check(source[0].startsWith('From run '+hdr.id+' (HDR10 Filmmaker, Sep 15)')&&source[0].includes('matched by time'),'a linked entry names its run, job and date: '+source[0]);
   check(source[1]==='From run gone-run','an entry whose run is gone still shows the recorded ID');
   check(source[2]==='','an entry with no recorded or matched run shows nothing');
   return 'titles, readiness label, multi-job, pending fallback, keyboard detail, kept open, artifact link, pending refresh, LG source line';
  },[hdr,check,multi,old],job);
  assert.deepEqual(errors,[]);console.log(JSON.stringify({status:'ok',checks}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
