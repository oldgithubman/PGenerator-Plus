const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../../usr/share/PGenerator');
const context = vm.createContext({
 document:{querySelectorAll:() => [], getElementById:() => null},
 localStorage:{setItem:() => {}, getItem:() => null},
 setTimeout:() => {},
 fetchJSON:() => {throw new Error('snapshotting a job must not contact the Pi');},
});
vm.runInContext(fs.readFileSync(path.join(root, 'webui-automation.js'), 'utf8'), context);
// A job copied from History carries merged run evidence next to its recipe.
const source={
 name:'Copied job',signal_format:'sdr',status:'complete',
 calibration:{target_gamma:'bt1886',reset:{responses:new Array(50).fill({picture_reset:{status:'ok'}})},'grey-state':{data:[1]},
  '3d-state':{x:1},'dv-profile-state':{x:1},'dv-profile-measurements':{x:1},'dv-profile-upload':{x:1}},
 series:{pre:{}},'apply-all':{verified:true},'panel-light':{value:80},
};
context.source=source;
const item=JSON.parse(JSON.stringify(vm.runInContext('pgAutomationSnapshot(source)', context)));
assert.equal(item.calibration.target_gamma,'bt1886','recipe calibration survives');
for (const key of ['reset','grey-state','3d-state','dv-profile-state','dv-profile-measurements','dv-profile-upload']) {
 assert.equal(Object.hasOwn(item.calibration,key),false,`calibration/${key} evidence is not carried into the draft`);
}
for (const key of ['series','apply-all','panel-light','status']) {
 assert.equal(Object.hasOwn(item,key),false,`${key} evidence is not carried into the draft`);
}
assert.ok(source.calibration.reset,'the source object is not mutated');
console.log(JSON.stringify({ok:true,bytes:JSON.stringify(item).length}));
