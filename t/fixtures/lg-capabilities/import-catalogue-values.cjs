// Emits a profile document for review; does not modify the library.
// node t/fixtures/lg-capabilities/import-catalogue-values.cjs /path/to/catalogue-docs
const fs=require('fs'),path=require('path');
const docs=process.argv[2];
if(!docs)throw new Error('Supply the directory containing available_settings_*.md');
const root=path.resolve(__dirname,'../../../usr/share/PGenerator/tv/lg');
const catalogues=JSON.parse(fs.readFileSync(path.join(root,'firmware/known-oled-catalogues.json')));
const profiles=[];
for(const profile of catalogues.profiles){
 const model=profile.match.retail_series[0];
 const source=fs.readFileSync(path.join(docs,'available_settings_'+model+'.md'),'utf8');
 const block=source.match(/##### `"picture"` category - available non-trivial values\s+```json\s*([\s\S]*?)```/);
 if(!block)throw new Error('No value catalogue found for '+model);
 const values=JSON.parse(block[1]),controls={};
 const keys=new Set([...Object.keys(values)].filter(key=>
  (catalogues.key_sets[profile.data.settings.public_routes.read.picture_key_set]||[]).includes(key)
  ||(catalogues.key_sets[profile.data.settings.public_routes.write.picture_key_set]||[]).includes(key)));
 // Values catalogued via Luna are still useful type evidence even when the
 // public read/write lists are small. They never promote transport support.
 for(const key of ['brightness','contrast','backlight','color','tint','gamma','energySaving','colorTemperature','blackLevel','sharpness'])keys.add(key);
 for(const key of [...keys].sort()){
  if(key==='pictureMode'||key==='blackLevel')continue; // selector aliases / legacy object handled by common contracts
  const value=values[key];let schema,comparator;
  if(Array.isArray(value)&&value.every(x=>typeof x==='string'||typeof x==='number')){
   schema={type:'enum',known_values:value,extensible:false};comparator='enum';
  }else if(value&&Number.isFinite(value.min)&&Number.isFinite(value.max)){
   schema={type:'integer',minimum:value.min,maximum:value.max};comparator='numeric';
   if(/^(whiteBalance(Red|Green|Blue)(10pt)?|adjustingLuminance(10pt)?)$/.test(key)){
    schema.type='integer_or_array';schema.minimum_items=1;schema.maximum_items=26;comparator='numeric_or_array';
   }
  }else continue;
  controls[key]={wire_key:key,category:'picture',value_schema:schema,
   read:{route:'ssap.settings'},write:{route:'ssap.settings',require_readback:true},
   verify:{comparator,tolerance:0.1}};
 }
 profiles.push({profile_id:profile.profile_id+'/values',priority:60,match:profile.match,
  data:{settings:{controls}},evidence:[{source_id:'lg-firmware-settings-catalogues',strength:'firmware_inventory',
   scope:model+' exact firmware picture value catalogue. Value types do not prove live transport support.'}]});
}
process.stdout.write(JSON.stringify({schema_version:1,profiles},null,2)+'\n');
