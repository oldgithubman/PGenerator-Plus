// Offline UI fixture for cmux and regression tests. No Pi/TV requests or writes.
// Run directly to serve it on an ephemeral loopback port.
const fs=require('fs'),path=require('path'),http=require('http');
const root=path.resolve(__dirname,'../..');
const read=name=>fs.readFileSync(path.join(root,'usr/share/PGenerator',name),'utf8');
const script=read('webui-automation.js').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'');
const html=`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
${read('webui-theme.css')}
body{margin:16px;background:#101016;color:#eee;font:14px system-ui}button,select{font:inherit;padding:7px;border-radius:5px;background:#292937;color:#eee;border:1px solid #555;cursor:pointer}.card{max-width:1200px;margin:auto;padding:16px;border:1px solid #444;border-radius:8px}.field label{display:block}h2{margin:0}p{line-height:1.5}dialog:not([open]){display:none}.auto-toolbar select{max-width:100%}
</style></head><body><p>LOCAL PREVIEW — sample output only. No connection to the TV. Queue edits stay in this preview.</p>${read('webui-automation.html')}<script>${script}</script><script>
pgAutomationSaveDraft=()=>{};
pgAutomationRequest=async()=>{throw new Error('Local preview: device operations disabled');};
fetchJSON=async()=>{throw new Error('Local preview: no device connection');};
pgAutomationPollLive=async()=>{};
pgAutomationRefresh=async()=>{};
pgAutomation.queue=pgAutomationReferenceQueue();pgAutomation.selectedQueue='reference-settings';pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);
pgAutomation.current={preflight:{id:'preview',status:'ready',queue_name:'Reference settings',message:'Startup checks passed',total_items:6,items:Array.from({length:6},()=>({status:'checked'}))},activity:{entries:Array.from({length:90},(_,i)=>({time:1789297200+i,source:'Startup check',level:i===43?'warning':'ok',message:i===43?'TruMotion cannot be read back: verify Off in the TV menu.':'TV setting verified for sample control '+(i+1),item_number:i%6}))}};
pgAutomationRenderQueue();pgAutomationEl('Activity').open=true;pgAutomationRenderLiveRun(null);pgAutomationTab('queue');
</script></body></html>`;
module.exports=html;
if(require.main===module){const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html);});server.listen(0,'127.0.0.1',()=>console.log('Preview: http://127.0.0.1:'+server.address().port));}
