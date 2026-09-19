const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../../usr/share/PGenerator');
const html = fs.readFileSync(path.join(root, 'webui-automation.html'), 'utf8');
const select={value:'reference-settings',innerHTML:''},deleteButton={disabled:false};
let allowReplace=true;
const confirmations=[];
const saved = {};
const context = vm.createContext({
 document:{querySelectorAll:() => [], getElementById:id => id==='pgAutomationSavedQueueSelect'?select:id==='pgAutomationDeleteQueueButton'?deleteButton:null},
 localStorage:{setItem:(key,value) => {saved[key]=JSON.parse(value);}},
 setTimeout:() => {},
 // In-app confirmation (P11) is answered through its test hook.
 pgAutomationConfirmOverride:message=>{confirmations.push(message);return allowReplace;},
 fetchJSON:() => {throw new Error('Loading reference settings must not contact the TV or start a run');},
 getCcssOverride:() => 'my-panel.ccss', getMeterRefreshRate:() => '24',
});
vm.runInContext(fs.readFileSync(path.join(root, 'webui-automation.js'), 'utf8'), context);
vm.runInContext(`
 let lgDisplayControlValues={oledLight:0};
 pgAutomationRenderQueue=function(){};
 pgAutomationTab=function(){};
 pgAutomationNotice=function(message,error){lastNotice={message,error};};
`, context);
const evaluate = code => JSON.parse(JSON.stringify(vm.runInContext(code, context)));
assert.doesNotMatch(html,/colourstrue|built-in template|data-pg-automation-template/i,'no branded template panel remains');
vm.runInContext('pgAutomationRenderSavedQueues()', context);
assert.match(select.innerHTML,/<option value="reference-settings">Reference settings · 6 jobs<\/option>/);
assert.equal(deleteButton.disabled,true,'reference option cannot be deleted');
select.value='reference-settings';
vm.runInContext('pgAutomationQueueSelectionChanged(true)', context);
assert.equal(evaluate('pgAutomation.queue.name'),'Reference settings');
assert.equal(confirmations.length,0,'an empty draft loads directly');
const items = evaluate('pgAutomation.queue.items');
assert.deepEqual(items.map(x=>x.picture_mode), ['dolbyVisionFilmMaker','dolbyVisionCinemaBright','hdrFilmMaker','hdrCinema','filmMaker','cinema']);
assert.equal(items[3].name,'HDR10 Cinema','reference names the actual supported memory slot');
assert.deepEqual(items.map(x=>x.target_gamma), ['st2084','st2084','st2084','st2084','bt1886','2.2']);
assert.deepEqual(items.map(x=>x.settings.gamma), [undefined,undefined,undefined,undefined,'high2','medium'], 'reference TV Gamma pins use the LG enums for BT.1886 and 2.2, only for SDR');
assert.deepEqual(items.map(x=>x.tv_gamma_follows_target), [false,false,false,false,true,true], 'only SDR links setup TV Gamma to its LUT target');
for (const item of items) {
 assert.equal(item.panel_light.key, 'oledLight', 'a reported zero is still a working panel control');
 assert.equal(item.ccss_override, 'my-panel.ccss', 'the selected correction is inherited');
 assert.equal(item.target_delta_e, .5, 'all six reference jobs default to a 0.5 delta-E target');
 assert.equal(item.stages.calibration, true);
 assert.equal(item.stages.pre_readings, false, 'reference jobs omit separate baseline sweeps');
 assert.equal(item.stages.post_readings, false, 'reference jobs omit separate after sweeps');
 assert.equal(item.stages.apply_all, true, 'reference jobs apply the result to all inputs');
 assert.equal(item.calibration.dark_detail, true, 'reference jobs include Dark Detail');
 assert.equal(item.quality.enabled, false, 'unconfirmed quality gates are not enabled');
 assert.equal(item.calibration.target_gamma, item.target_gamma);
 assert.equal(item.calibration.target_gamut, item.target_gamut);
 assert.equal(item.calibration.target_delta_e, item.target_delta_e);
 assert.deepEqual(item.calibration.target_white, item.target_white);
 if (item.signal_format === 'dv') {
  assert.equal(item.color_format, '0');
  assert.equal(item.max_bpc, 8);
  assert.equal(item.rgb_quant_range, '2');
  assert.equal(item.settings.colorGamut, undefined, 'DV decoder gamut is not pinned');
  assert.equal(item.settings.hdrDynamicToneMapping, undefined, 'DV does not inherit the HDR10 tone-mapping control');
 } else {
  assert.equal(item.color_format, '1');
  assert.equal(item.max_bpc, 10);
  assert.equal(item.rgb_quant_range, '1');
 }
 if (item.signal_format === 'hdr10') {
  assert.equal(item.settings.hdrDynamicToneMapping, 'off');
  assert.equal(item.calibration.method, 'matrix');
  assert.equal(item.calibration.shadow_fix, true);
 } else assert.equal(item.calibration.shadow_fix, false);
 if (item.signal_format === 'sdr') {
  assert.equal(item.calibration.profile_source, 'hybrid3');
  assert.equal(item.settings.contrast, 85);
  assert.equal(item.settings.peakBrightness, 'off');
 }
 // 19 Sep 2026: SDR gets the same grey-field insertion as HDR and DV.
 assert.equal(item.patch_insert_patch_enabled, true, item.name+' inserts a grey field before every patch');
 assert.equal(item.patch_insert_time_frequency_ms, 5000, item.name+' inserts the 25% field every 5 s');
}
{
 // A saved SDR job that still carries the old SDR defaults is lifted on load;
 // one set by hand to anything else keeps its values.
 const lifted=evaluate('pgAutomationSnapshot({signal_format:"sdr",name:"Old SDR",patch_insert_patch_enabled:false,patch_insert_time_frequency_ms:45000})');
 assert.equal(lifted.patch_insert_patch_enabled, true, 'legacy SDR insertion is lifted');
 assert.equal(lifted.patch_insert_time_frequency_ms, 5000, 'legacy SDR time insertion is lifted');
 const custom=evaluate('pgAutomationSnapshot({signal_format:"sdr",name:"Custom SDR",patch_insert_patch_enabled:false,patch_insert_time_frequency_ms:30000})');
 assert.equal(custom.patch_insert_patch_enabled, false, 'a hand-set SDR insertion is kept');
 assert.equal(custom.patch_insert_time_frequency_ms, 30000, 'a hand-set SDR frequency is kept');
 const hdr=evaluate('pgAutomationSnapshot({signal_format:"hdr10",name:"HDR",patch_insert_patch_enabled:false,patch_insert_time_frequency_ms:45000})');
 assert.equal(hdr.patch_insert_patch_enabled, false, 'non-SDR jobs are not touched');
}
assert.deepEqual(saved['pgen.automation.queueDraft'].queue.items, items, 'the added plan survives draft reload');
assert.deepEqual(items.map(x=>x.panel_light.fixed_value), [100,100,100,100,95,100]);
vm.runInContext(`
 pgAutomation.queue.items[0].settings.contrast=12;
 pgAutomation.queue.items[0].calibration.target_white.x=.4;
 pgAutomation.queue.items[0].pre_series.pop();
 pgAutomation.editingRunId='existing-run';pgAutomation.firstPending=6;
`, context);
(async()=>{
allowReplace=false;
await vm.runInContext('pgAutomationLoadQueue()', context);
assert.equal(evaluate('pgAutomation.queue.items.length'), 6, 'cancel preserves existing queue items');
assert.equal(evaluate('pgAutomation.queue.items[0].settings.contrast'), 12, 'existing edits are preserved');
assert.equal(evaluate('pgAutomation.editingRunId'), 'existing-run', 'pending-edit context is preserved');
assert.equal(evaluate('pgAutomation.firstPending'), 6);
const fresh=evaluate('pgAutomationReferenceItems(["dv-filmmaker","sdr-cinema"])');
assert.equal(fresh[0].settings.contrast, 100, 'queued edits cannot mutate built-ins');
assert.equal(fresh[0].calibration.target_white.x, .3127);
assert.equal(fresh[0].pre_series.length, 3);
assert.equal(fresh[0].panel_light.key, 'backlight', 'offline default uses the existing runner panel key');
allowReplace=true;
await vm.runInContext('pgAutomationLoadQueue()', context);
assert.deepEqual(evaluate('pgAutomation.queue.items'),items,'loading again creates six fresh ordinary items');
assert.equal(evaluate('pgAutomation.editingRunId'),'','loading a draft exits pending-run editing');
assert.equal(evaluate('pgAutomation.firstPending'),0);
assert.equal(vm.runInContext('pgAutomation.queue.id',context),undefined,'reference is saved as a new queue, never over another saved queue');
select.value='';
await vm.runInContext('pgAutomationLoadQueue()', context);
assert.equal(evaluate('pgAutomation.queue.items.length'),6,'empty selection leaves queue unchanged');
assert.deepEqual(evaluate('pgAutomationReferenceItems(["unknown"])'), []);
vm.runInContext('pgAutomation.queues=[{id:"saved-id",name:"My saved queue",items:[{name:"Custom item"}]}]',context);
select.value='saved:saved-id';
const beforeCleanSwitch=confirmations.length;
await vm.runInContext('pgAutomationQueueSelectionChanged(true)',context);
assert.equal(deleteButton.disabled,false,'ordinary saved queues remain deletable');
assert.equal(evaluate('pgAutomation.queue.id'),'saved-id','ordinary saved queues still load');
assert.equal(confirmations.length,beforeCleanSwitch,'an unchanged loaded queue switches without a confirmation');
assert.equal(saved['pgen.automation.queueDraft'].selectedQueue,'saved:saved-id','selected queue survives draft persistence');
vm.runInContext('pgAutomation.queues.unshift({id:"other-id",name:"Other saved queue",items:[]});pgAutomationRenderSavedQueues()',context);
assert.equal(select.value,'saved:saved-id','refresh keeps the same queue selected when list order changes');
assert.equal(evaluate('pgAutomation.queue.items[0].name'),'Custom item','refresh does not reload or replace queue items');
vm.runInContext('pgAutomation.queue.items[0].name="Unsaved edit"',context);
allowReplace=false;select.value='reference-settings';
await vm.runInContext('pgAutomationQueueSelectionChanged(true)',context);
assert.equal(select.value,'saved:saved-id','cancel restores selector to the displayed queue');
assert.equal(evaluate('pgAutomation.queue.items[0].name'),'Unsaved edit','cancel preserves edited items');
assert.equal(deleteButton.disabled,false,'cancel restores saved-queue actions');
allowReplace=true;select.value='reference-settings';
await vm.runInContext('pgAutomationQueueSelectionChanged(true)',context);
assert.equal(evaluate('pgAutomation.queue.items.length'),6,'confirming a selection replaces items immediately');
assert.equal(deleteButton.disabled,true,'reference selection disables deletion');
assert.match(html,/onchange="pgAutomationQueueSelectionChanged\(true\)"/,'actual dropdown change invokes queue loading');
assert.equal(evaluate('pgAutomationQueueName("ColoursTrue LG OLED plan")'),'Reference settings','old default names display neutrally');
assert.equal(evaluate('pgAutomationQueueName("My saved queue")'),'My saved queue','custom names are preserved');
const custom=evaluate('(()=>{const item={template_id:"reference-settings-v2",signal_format:"sdr",stages:{pre_readings:true,calibration:true,post_readings:true}};pgAutomationUpgradeReference(item);return item;})()');
assert.equal(custom.template_id,'reference-settings-v3');
assert.equal(custom.stages.pre_readings,true,'an explicitly configured saved copy keeps its optional baseline');
assert.equal(custom.stages.post_readings,true,'an explicitly configured saved copy keeps its optional after sweep');
assert.equal(custom.settings.gamma,undefined,'legacy saved copies do not gain an unrequested gamma pin');
const gammaOverride=evaluate('pgAutomationSnapshot({...pgAutomationReferenceItems(["sdr-filmmaker"])[0],settings:{gamma:"medium"},tv_gamma_follows_target:false})');
assert.equal(gammaOverride.settings.gamma,'medium','copying a reference-derived job preserves its explicit TV Gamma override');
assert.equal(gammaOverride.tv_gamma_follows_target,false);
const savedHome=evaluate('pgAutomationSnapshot({template_id:"reference-settings-v3",signal_format:"hdr10",picture_mode:"hdrCinemaBright",name:"My HDR Home"})');
assert.equal(savedHome.picture_mode,'hdrCinemaBright','existing saved Home jobs are not silently remapped to a different memory slot');
assert.equal(savedHome.name,'My HDR Home');
console.log(JSON.stringify(items));
})().catch(error=>{console.error(error);process.exit(1);});
