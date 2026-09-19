// Regression: an automation-owned AutoCal worker must never raise the manual
// completion modal, spinner or toast. Seen live on 17 September 2026, when an
// SDR automation job's 3D LUT solve opened the manual download prompt over a
// running batch (the browser had adopted the run because it polls any worker
// reported as running).
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const ws=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-workspace.js'),'utf8');
const grab=name=>{const code=ws.match(new RegExp('(?:async )?function '+name+'\\([^]*?\\n\\}'))?.[0];assert.ok(code,name+' found');return code;};
const ctx={console,JSON,Math,Date,Number,String,Array,Object,setInterval:()=>1,clearInterval(){},setTimeout:()=>1};
vm.createContext(ctx);
vm.runInContext(grab('meterStatusAutomationOwned')+';this.owned=meterStatusAutomationOwned;',ctx);
assert.equal(ctx.owned({automation_worker_id:'run-0-abc'}),true,'a worker stamped with an automation attempt is automation-owned');
assert.equal(ctx.owned({automation_token:'tok'}),true,'so is one carrying the run token');
assert.equal(ctx.owned({status:'running'}),false,'a manual worker is not');
assert.equal(ctx.owned(null),false,'and neither is a missing status');
// The 3D poller must gate adoption, the spinner and the completion prompt on it.
const poll=grab('meterPollLg3dAutoCal');
assert.match(poll,/const automationOwned=meterStatusAutomationOwned\(r\);/,'the poller asks who owns the worker');
assert.match(poll,/const localActive=!automationOwned&&/,'an automation worker is never treated as locally tracked');
assert.match(poll,/if\(r\.status==='running'&&!meterLg3dAutoCalPolling&&!automationOwned\)/,'and the manual 1.5 s poller is not started for it');
assert.match(poll,/if\(!full3dActive&&!automationOwned&&r\.status==='running'\)/,'the build spinner is suppressed for it');
const completion=poll.slice(poll.indexOf("if(r.status==='complete')"));
assert.match(completion,/if\(!localActive\|\|meterAutoCalStopRequested\)/,'completion still returns early unless this browser tracked the run');
assert.ok(completion.indexOf('meterLutSolveDonePrompt')>completion.indexOf('if(!localActive'),'so the download prompt sits behind that guard');
// The 1D completion toast is gated too.
const grey=grab('meterPollAutoCal');
assert.match(grey,/if\(notify&&!meterStatusAutomationOwned\(r\)&&/,'the 1D completion toast is suppressed for automation workers');
// The measurement series the runner drives ends on the Automation card, so the
// workspace must not announce it. Seen live on 18 September 2026: "Series
// complete!" toasted over a running batch's Before readings.
const series=grab('meterPollSeries');
const done=series.slice(series.indexOf('meterSeriesBeepArmed=false;'));
assert.match(done,/if\(!meterStatusAutomationOwned\(r\)&&!document\.body\.classList\.contains\('pg-automation-calibration-observer'\)\)\s*\n?\s*toast\(r\.status==='complete'/,
 'the series completion toast is suppressed for an automation-owned series');
assert.ok(done.includes("'Series complete!'"),'a manual series still gets its toast');
console.log('PASS automation runs raise no manual AutoCal popups');
