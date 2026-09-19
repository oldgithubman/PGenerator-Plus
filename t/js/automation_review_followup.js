const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const elements=new Map();
const element=id=>{if(!elements.has(id))elements.set(id,{style:{},dataset:{},innerHTML:'',setAttribute(){}});return elements.get(id);};
const c=vm.createContext({document:{getElementById:element,querySelectorAll:()=>[]},setTimeout(){},Date,console});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8'),c);
const render=state=>{c.fixture=state;vm.runInContext('pgAutomation.current=fixture;pgAutomationRenderProgress()',c);return element('pgAutomationProgress').innerHTML;};
const now=Date.now()/1000;
const check={id:'check-1',status:'ready',verification_state:'limited',total_items:3,
 items:[{status:'checked'},{status:'checked-limited'},{status:'checked-limited'}],
 progress_done:12,progress_total:12,message:'Limited verification; confirm picture mode manually',
 issues:[{level:'warning',message:'Picture mode cannot be read independently'}],started_at:now-30,completed_at:now};
let html=render({preflight:check});
assert.match(html,/3 of 3 jobs checked/,'limited jobs count in saved preflight');
assert.match(html,/Picture mode cannot be read independently/,'the reduced verification remains visible');
assert.doesNotMatch(html,/jobs complete/,'a readiness check is not a completed calibration');
html=render({run:{id:'run-1',status:'running',active_stage:'queue-preflight',active_item:null,items:[{}, {}, {}],
 preflight_result:{total_items:3,jobs:check.items},created_at:now-40,stage_started_at:now-30}});
assert.match(html,/3 of 3 jobs checked/,'live whole-queue checks use preflight job results, not calibration status');
assert.doesNotMatch(html,/0 of 3 jobs complete/,'preflight never displays a stale calibration completion counter');
html=render({preflight:{...check,status:'blocked',items:[{status:'checked-limited'},{status:'blocked'},{status:'unchecked'}]}});
assert.match(html,/1 of 3 jobs checked/,'blocked and unchecked jobs are not counted');
// Exercise the real settings renderer with hostile catalogue metadata: even
// bundled numeric limits must be escaped in their HTML attribute context.
vm.runInContext(`
 pgAutomation.settingsPlan=null;pgAutomation.supportedKeys=['brightness'];
 pgAutomation.supportedValues={brightness:50};pgAutomation.pinnedKeys=['brightness'];
 pgAutomationSettingMetadata=()=>({type:'number',min:'0" onfocus="bad',max:'100" data-injected="yes'});
 pgAutomationUpdateSettingsStatus=()=>{};pgAutomationRenderPanelKeyOptions=()=>{};
 pgAutomationRenderSettingsEditor();
`,c);
html=element('pgAutomationSettingsEditor').innerHTML;
assert.match(html,/min="0&quot; onfocus=&quot;bad"/);
assert.doesNotMatch(html,/min="0" onfocus="/);
assert.match(html,/max="100&quot; data-injected=&quot;yes"/);
console.log(JSON.stringify({ok:true,checks:'limited readiness counts, live preflight, blocked jobs and attribute escaping'}));
