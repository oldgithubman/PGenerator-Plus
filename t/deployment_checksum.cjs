// Read-only SHA-256 audit of packaged appliance files. Device configuration,
// first-boot markers, mounted runtime commands and host-generated files stay local.
const fs=require('fs'),path=require('path'),crypto=require('crypto'),{spawnSync}=require('child_process');
const root=path.resolve(__dirname,'..'),files=[];
const excluded=new Set(['etc/PGenerator/PGenerator.conf','etc/BiasiLinux/BiasiLinux.FirstBoot','var/lib/PGenerator/operations.txt']);
function walk(relative){
 if(excluded.has(relative)||relative.startsWith('var/lib/PGenerator/running/')||relative.startsWith('var/lib/PGenerator/tmp/'))return;
 const stat=fs.lstatSync(path.join(root,relative));
 if(stat.isDirectory())for(const name of fs.readdirSync(path.join(root,relative))){if(!['.DS_Store','__pycache__','.gitkeep'].includes(name))walk(relative+'/'+name)}
 else if(stat.isFile()&&!relative.endsWith('.bak'))files.push(relative);
}
['etc','lib','usr','var'].forEach(walk);
const quote=s=>"'"+s.replace(/'/g,"'\\''")+"'";
const command='sha256sum -- '+files.map(file=>quote('/'+file)).join(' ');
const result=spawnSync('ssh',['-o','BatchMode=yes','-o','ConnectTimeout=5','-o','HostKeyAlias=pgenerator.local','pgen',command],{encoding:'utf8',maxBuffer:4*1024*1024});
if(result.error||![0,1].includes(result.status))throw new Error('Checksum SSH failed: '+(result.error?.message||result.stderr||result.status));
const actual=new Map(result.stdout.trim().split('\n').filter(Boolean).map(line=>{const match=line.match(/^([a-f0-9]{64})\s+(.+)$/);if(!match)throw new Error('Invalid checksum response');return [match[2],match[1]]}));
const missing=files.filter(file=>!actual.has('/'+file));
const mismatches=files.filter(file=>actual.has('/'+file)&&crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')!==actual.get('/'+file));
console.log(JSON.stringify({checked:files.length,missing,mismatches,excluded:'Device configuration, first-boot marker, runtime commands, .DS_Store, __pycache__, .gitkeep, local .bak files'}));
if(missing.length||mismatches.length||result.status)process.exitCode=1;
