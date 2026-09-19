// Regression for PR 14 test report P6: report renders must not write series
// data to browser storage, and a full quota frees disposable series entries
// instead of failing forever (and taking queue drafts down with it).
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const app=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-app.js'),'utf8');
const automation=fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/webui-automation.js'),'utf8');
const grab=(source,name)=>{const code=source.match(new RegExp('function '+name+'\\([^]*?\\n\\}'))?.[0];assert.ok(code,name+' found');return code;};
function storage(limit){
 const data=new Map();
 const used=()=>[...data].reduce((n,[k,v])=>n+k.length+v.length,0);
 return {data,
  get length(){return data.size;},
  key(i){return [...data.keys()][i]??null;},
  getItem(k){return data.has(k)?data.get(k):null;},
  setItem(k,v){v=String(v);const before=data.has(k)?k.length+data.get(k).length:0;if(used()-before+k.length+v.length>limit){const e=new Error('quota');e.name='QuotaExceededError';throw e;}data.set(k,v);},
  removeItem(k){data.delete(k);},
 };
}
function context(limit){
 const ctx={localStorage:storage(limit),console:{warn(){}},meterSeriesCacheBootId:'boot2',meterActiveSeriesKey:'',
  meterSeriesCache:{},METER_SERIES_CACHE_SCHEMA:2,
  meterSeriesCacheNormalizeEntry:s=>({schema:2,body:s.body}),meterSeriesSnapshotCanRestore:()=>true};
 vm.createContext(ctx);
 vm.runInContext('let meterSeriesCacheDirtyKeys=new Set();let meterSeriesCachePersistSuspended=0;'
  +['meterSeriesCacheKey','meterSeriesCacheScopeKey','meterSeriesCacheEntryStorageKey','meterLegacySeriesCacheKeys','meterDropLegacySeriesCaches','meterSeriesCacheReclaimSpace','meterStorageQuotaError','meterPersistSeriesCache'].map(n=>grab(app,n)).join('\n')
  +';this.dirty=()=>meterSeriesCacheDirtyKeys;this.suspend=n=>{meterSeriesCachePersistSuspended=n;};',ctx);
 return ctx;
}
const big='x'.repeat(900);
{
 const ctx=context(100000);
 ctx.meterSeriesCache={a:{body:big,updated_at:1}};ctx.dirty().add('a');ctx.suspend(1);
 ctx.meterPersistSeriesCache();
 assert.equal(ctx.localStorage.length,0,'nothing is written while a report render has persistence suspended');
 assert.ok(ctx.dirty().has('a'),'the change stays pending until persistence resumes');
 ctx.suspend(0);ctx.meterPersistSeriesCache();
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.a'),'and is written once it does');
}
{
 const ctx=context(4000);
 ctx.localStorage.setItem('pgen.meter.boot1.seriesCache.v2.entry.old',big);
 ctx.localStorage.setItem('pgen.meter.boot1.seriesCache.v2.index','{"schema":2,"entries":{"old":1}}');
 ctx.localStorage.setItem('pgen.automation.queueDraft','{"queue":1}');
 ctx.meterSeriesCache={a:{body:big,updated_at:5},b:{body:big,updated_at:6},c:{body:big,updated_at:7}};
 ['a','b','c'].forEach(k=>ctx.dirty().add(k));
 ctx.meterPersistSeriesCache();
 assert.equal(ctx.localStorage.getItem('pgen.meter.boot1.seriesCache.v2.entry.old'),null,'a full quota first evicts series data from an earlier boot');
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.c'),'then the pending entries are written');
 assert.equal(ctx.dirty().size,0,'and nothing is left pending');
 assert.equal(ctx.localStorage.getItem('pgen.automation.queueDraft'),'{"queue":1}','non-series data is never evicted');
}
{
 // Round 5 (live finding): version-1 blobs are merged into the v2 store on the
 // first boot-id read and never read again, but they are megabytes each and
 // used to hold the whole quota, so every later write failed.
 const ctx=context(4000);
 ctx.localStorage.setItem('pgen.meter.boot1.seriesCache',big+big);
 ctx.localStorage.setItem('pgen.meter.seriesCache','{"legacy":1}');
 ctx.localStorage.setItem('pgen.meter.boot2.seriesCache.v2.entry.keep',big);
 ctx.localStorage.setItem('pgen.automation.queueDraft','{"queue":1}');
 assert.equal(ctx.meterLegacySeriesCacheKeys().length,2,'both version-1 blobs are recognised');
 assert.equal(ctx.meterSeriesCacheReclaimSpace([]),2,'a full quota drops the superseded version-1 blobs first');
 assert.equal(ctx.localStorage.getItem('pgen.meter.boot1.seriesCache'),null,'the scoped version-1 blob is gone');
 assert.equal(ctx.localStorage.getItem('pgen.meter.seriesCache'),null,'the unscoped version-1 blob is gone');
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.keep'),'current series data is kept');
 assert.equal(ctx.localStorage.getItem('pgen.automation.queueDraft'),'{"queue":1}','non-series data is untouched');
}
{
 // The blobs are dropped as soon as migration has persisted everything, so a
 // browser that never hits the quota also stops carrying them.
 const ctx=context(100000);
 vm.runInContext(`let meterSeriesCacheBootId='';meterSeriesCache={};
  const meterReadSeriesCacheV2=()=>null;
  const meterSeriesKeyIsIccWorkflow=()=>false;
  const meterSeriesSnapshotContainsIccWorkflow=()=>false;
  const meterSeriesSnapshotWithoutModeVariants=s=>s;
  const meterSeriesSnapshotSignalMode=()=>'sdr';
  const meterSeriesSnapshotForMode=()=>null;
  const meterStoreSeriesSnapshot=(key,snap)=>{meterSeriesCache[key]=snap;};
  const meterUpdateSeriesCacheUi=()=>{};
  let persisted=0;
  meterPersistSeriesCache=()=>{persisted++;meterSeriesCacheDirtyKeys.clear();};
  ${grab(app,'meterSetSeriesCacheBootId')}
  this.setBoot=meterSetSeriesCacheBootId;this.cacheKeys=()=>Object.keys(meterSeriesCache);this.persists=()=>persisted;`,ctx);
 ctx.localStorage.setItem('pgen.meter.boot9.seriesCache',JSON.stringify({old:{body:'x',updated_at:1}}));
 ctx.localStorage.setItem('pgen.meter.seriesCache',JSON.stringify({older:{body:'y',updated_at:1}}));
 ctx.setBoot('boot9');
 assert.equal(ctx.cacheKeys().sort().join(','),'old,older','both version-1 blobs are migrated into the live cache');
 assert.equal(ctx.persists(),1,'and written to the v2 store');
 assert.equal(ctx.localStorage.getItem('pgen.meter.boot9.seriesCache'),null,'the scoped blob is dropped after migration');
 assert.equal(ctx.localStorage.getItem('pgen.meter.seriesCache'),null,'and the unscoped one too');
 // Live case: the blobs hold only entries the merge discards, so nothing is
 // migrated. They are still dead weight and must go.
 ctx.localStorage.setItem('pgen.meter.boot9.seriesCache',JSON.stringify({}));
 ctx.localStorage.setItem('pgen.meter.seriesCache',JSON.stringify({}));
 vm.runInContext('meterSeriesCacheBootId="";meterSeriesCache={};',ctx);
 ctx.setBoot('boot9');
 assert.equal(ctx.cacheKeys().length,0,'nothing survives the merge');
 assert.equal(ctx.localStorage.getItem('pgen.meter.boot9.seriesCache'),null,'the empty version-1 blob is dropped anyway');
 assert.equal(ctx.localStorage.getItem('pgen.meter.seriesCache'),null,'and so is the unscoped one');
}
{
 // Round 3: before the boot is known, another scope may be this boot's data.
 const ctx=context(100000);ctx.meterSeriesCacheBootId='';
 ctx.localStorage.setItem('pgen.meter.boot7.seriesCache.v2.entry.live',big);
 ctx.localStorage.setItem('pgen.meter.boot7.seriesCache.v2.index','{"schema":2,"entries":{"live":1}}');
 assert.equal(ctx.meterSeriesCacheReclaimSpace([]),0,'nothing is reclaimed while the boot is unknown');
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot7.seriesCache.v2.entry.live'),'so a series that may belong to this boot survives');
 ctx.meterSeriesCacheBootId='   ';
 ctx.meterSeriesCacheReclaimSpace([]);
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot7.seriesCache.v2.entry.live'),'a blank boot id counts as unknown too');
 ctx.meterSeriesCacheBootId='boot8';
 assert.equal(ctx.meterSeriesCacheReclaimSpace([]),2,'once the boot is known the earlier boot is disposable');
}
{
 const ctx=context(4200);
 const index={schema:2,entries:{}};
 ['old1','old2','keep','active'].forEach((k,i)=>{ctx.localStorage.setItem('pgen.meter.boot2.seriesCache.v2.entry.'+k,big);index.entries[k]=i+1;});
 ctx.localStorage.setItem('pgen.meter.boot2.seriesCache.v2.index',JSON.stringify(index));
 ctx.meterActiveSeriesKey='active';
 ctx.meterSeriesCache={fresh:{body:big,updated_at:9}};ctx.dirty().add('fresh');
 ctx.meterPersistSeriesCache();
 assert.equal(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.old1'),null,'the oldest entries of this boot are evicted when nothing else is left');
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.active'),'the active series is never evicted');
 assert.ok(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.entry.fresh'),'and the new entry fits');
 assert.ok(!JSON.parse(ctx.localStorage.getItem('pgen.meter.boot2.seriesCache.v2.index')).entries.old1,'evicted entries leave the index');
}
{
 // The queue draft reclaims series space before giving up.
 const ctx=context(3000);
 ctx.localStorage.setItem('pgen.meter.boot1.seriesCache.v2.entry.old',big.repeat(2));
 const notices=[];
 Object.assign(ctx,{pgAutomation:{queue:{name:'Q',items:[{name:'Job '+'y'.repeat(900)}]},editingRunId:'',firstPending:0,selectedQueue:'',loadedQueueSnapshot:''},
  pgAutomationNotice:(m,l)=>notices.push(m),pgAutomationEl:()=>null});
 vm.runInContext(grab(automation,'pgAutomationSaveDraft'),ctx);
 ctx.pgAutomationSaveDraft();
 assert.ok(ctx.localStorage.getItem('pgen.automation.queueDraft'),'the draft is saved after series space is reclaimed');
 assert.equal(notices.length,0,'without warning that draft storage is unavailable');
}
console.log('PASS series cache quota: suspended report persistence, earlier-boot and oldest eviction, draft retry');
