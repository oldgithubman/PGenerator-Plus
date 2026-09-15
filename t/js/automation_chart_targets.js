const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
const app=fs.readFileSync(path.join(root,'webui-app.js'),'utf8');
const workspace=fs.readFileSync(path.join(root,'webui-workspace.js'),'utf8');
const elements={meterTargetGamma:{id:'meterTargetGamma',value:'bt1886',options:[{textContent:'BT.1886 (2.4)'}],selectedIndex:0}};
let target='2.2',mode='sdr',power=false,pq=false,fail=false;
const observed=[];
const context={window:{},document:{getElementById:id=>elements[id]},meterGreyChartTargetGammaSelection:()=>context.window._meterSnapshotReportTargetGamma||target,
 meterHdrAutoCalUsesPowerGammaChartMath:()=>power,meterGreyChartUsesPqTarget:()=>pq,
 meterChartIsHlg:()=>mode==='hlg',meterChartIsDv:()=>mode==='dv',meterChartBt2390Enabled:()=>false,
 meterActiveSeriesKey:null,_selectedColorReadingName:null,_colorDetailPinned:false,meterCurrentPatchStep:null,meterSelectedThumbIre:null,
 meterSeriesCache:{},meterFullAutoCalCloneValue:x=>JSON.parse(JSON.stringify(x)),meterSeriesSnapshotHasReadings:()=>true,
 meterRecoverSeries:s=>{observed.push(elements.meterTargetGamma.value);target=s.target_gamma||elements.meterTargetGamma.value;},
 meterPrepareCurrentSeriesForReport:async()=>{if(fail)throw new Error('test render failure');},
 meterBuildCurrentSeriesReportSection:()=>context.meterTargetGammaLabel(),meterPersistSeriesCache:()=>{}};
vm.createContext(context);
vm.runInContext(app.match(/function meterTargetGammaLabel\([^]*?\n\}/)[0],context);
vm.runInContext(workspace.match(/async function meterFullAutoCalBuildSnapshotReportSections\([^]*?\n\}/)[0],context);
(async()=>{
 assert.equal(context.meterTargetGammaLabel(),'Gamma 2.2','legend follows resolved target, not stale selector');
 for(const [gamma,label] of [['2.4','Gamma 2.4'],['bt1886','BT.1886'],['srgb','sRGB']]){target=gamma;assert.equal(context.meterTargetGammaLabel(),label);}
 mode='hdr10';pq=true;assert.equal(context.meterTargetGammaLabel(),'PQ');
 power=true;assert.equal(context.meterTargetGammaLabel(),'Gamma 2.2');power=false;
 mode='hlg';assert.equal(context.meterTargetGammaLabel(),'HLG');mode='sdr';pq=false;
 const entry=gamma=>({snapshot:{target_gamma:gamma,readings:[{Y:100}]}});
 assert.equal(await context.meterFullAutoCalBuildSnapshotReportSections([entry('2.2'),entry('2.4'),entry(null)]),'Gamma 2.2Gamma 2.4BT.1886');
 assert.deepEqual(observed,['2.2','2.4','bt1886'],'each snapshot installs its own gamma, missing context uses original selection');
 assert.equal(elements.meterTargetGamma.value,'bt1886','manual selection restored');
 assert.equal(context.window._meterSnapshotReportTargetGamma,undefined,'report gamma scope is released');
 context.meterPrepareCurrentSeriesForReport=async()=>{elements.meterTargetGamma.value='bt1886';if(fail)throw new Error('test render failure');};
 assert.equal(await context.meterFullAutoCalBuildSnapshotReportSections([entry('2.2')]),'Gamma 2.2','startup selector restoration cannot retarget an in-flight report');
 fail=true;await assert.rejects(context.meterFullAutoCalBuildSnapshotReportSections([entry('2.2')]),/test render failure/);
 assert.equal(elements.meterTargetGamma.value,'bt1886','manual selection restored after renderer failure');
 assert.equal(context.window._meterSnapshotReportTargetGamma,undefined,'report gamma scope released after failure');
 vm.runInContext(app.match(/function meterGreyTargetGammaSelection\([^]*?\n\}/)[0],context);
 context.window._meterSnapshotReportTargetGamma='2.2';
 assert.equal(context.meterGreyTargetGammaSelection(),'2.2','production selector gives the report target priority over mutable UI');
 console.log('PASS automation chart targets: labels, per-snapshot gamma, HDR/HLG and restoration');
})().catch(e=>{console.error(e);process.exitCode=1;});
