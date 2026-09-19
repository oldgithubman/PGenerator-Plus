const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('usr/share/PGenerator/webui-workspace.js','utf8');
const helper=source.slice(source.indexOf('async function meterStopAndConfirm('),source.indexOf('function meterAutoCalRunEndPayload('));
async function run(responses){
 const calls=[];const label={};
 const ctx=vm.createContext({document:{getElementById:()=>label},Date,setTimeout:fn=>fn(),fetchJSON:async(path,options)=>{calls.push(path);if(!responses.length)throw Error('Unexpected request');const next=responses.shift();if(next instanceof Error)throw next;return next;}});
 vm.runInContext(helper,ctx);
 let error;try{await vm.runInContext('meterStopAndConfirm()',ctx)}catch(e){error=e}
 return {calls,label,error};
}
(async()=>{
 let r=await run([{status:'ok'},{status:'stopping'},{status:'stopped'}]);
 assert.ifError(r.error);assert.equal(r.calls.length,3);
 r=await run([{status:'error',message:'CAL_END rejected'}]);
 assert.match(r.error.message,/CAL_END rejected/);assert.equal(r.calls.length,1);
 r=await run([new Error('Network timeout')]);assert.match(r.error.message,/Network timeout/);
 r=await run([{status:'ok',run:{id:'batch'}},{run:{id:'batch',status:'stopping'}},{run:{id:'batch',status:'stopped'}}]);
 assert.ifError(r.error);assert.equal(r.calls[1],'/api/automation/runs/current');
 r=await run([{status:'ok',run:{id:'batch'}},{run:{id:'batch',status:'failed',failure:{message:'TV exit unconfirmed'}}}]);
 assert.match(r.error.message,/TV exit unconfirmed/);
 console.log('PASS stop confirmation waits for workers/batch and exposes cleanup/transport failures');
})().catch(e=>{console.error(e);process.exitCode=1});
