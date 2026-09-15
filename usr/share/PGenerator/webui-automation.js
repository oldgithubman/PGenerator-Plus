var pgAutomation = {
 loaded:false,recipes:[],queues:[],queue:{name:'TV calibration queue',items:[]},selectedQueue:'',loadedQueueSnapshot:'',
 current:null,currentHistoryRunId:'',history:[],liveTimer:null,reportBusy:false,
 supportedKeys:[],supportedValues:{},pinnedKeys:[],supportedSignal:'',supportedPictureMode:'',
 editorTarget:'queue',editingQueueIndex:null,editingRecipe:null,editorEpoch:0,
 editorSettingsKey:'',editorSettingsDrafts:{},fillingEditor:false,gammaFollowsTarget:false,
 editingRunId:'',firstPending:0,busy:false,polling:false,tab:'queue',
 jobViews:{},followLive:true,liveSelection:null,logFollow:true,logNotices:[],logObserved:[]
};
const PG_AUTOMATION_SERIES=[['Grey','greyscale-21','Greyscale'],['Colors','colors-30','ColorChecker'],['Sats','saturations-24','Saturation']];
const PG_AUTOMATION_LABELS={deitp:'ΔE ITP',de2000:'ΔE2000',bt1886:'BT.1886 (2.4)','2.2':'Gamma 2.2','2.4':'Gamma 2.4',srgb:'sRGB',st2084:'ST 2084',hlg:'HLG',bt709:'BT.709',p3d65:'DCI-P3 / D65',bt2020:'BT.2020'};
const PG_AUTOMATION_REFERENCE_MODES=[
 {id:'dv-filmmaker',signal:'dv',mode:'dolbyVisionFilmMaker',name:'Dolby Vision Filmmaker'},
 {id:'dv-cinema',signal:'dv',mode:'dolbyVisionCinemaBright',name:'Dolby Vision Cinema Home'},
 {id:'hdr-filmmaker',signal:'hdr10',mode:'hdrFilmMaker',name:'HDR10 Filmmaker'},
 {id:'hdr-cinema',signal:'hdr10',mode:'hdrCinema',name:'HDR10 Cinema'},
 {id:'sdr-filmmaker',signal:'sdr',mode:'filmMaker',name:'SDR Filmmaker'},
 {id:'sdr-cinema',signal:'sdr',mode:'cinema',name:'SDR Cinema'}
];
// Adapt the reference's P1 TV and P6 PGenerator+ columns, not its Calman/G1 columns.
// Build fresh objects for each insertion: editing a queued copy never edits the template.
function pgAutomationReferenceItems(ids,context){
 const selected=new Set(ids),meter=context||{};
 const panelKey=['backlight','oledLight','oledPixelBrightness'].includes(meter.panel_key)?meter.panel_key:'backlight';
 return PG_AUTOMATION_REFERENCE_MODES.filter(mode=>selected.has(mode.id)).map(mode=>{
  const sdr=mode.signal==='sdr',hdr=mode.signal==='hdr10',dv=mode.signal==='dv';
  const gamma=sdr?(mode.id==='sdr-cinema'?'2.2':'bt1886'):'st2084',gamut=sdr?'bt709':'p3d65';
  const brightness=mode.id==='sdr-filmmaker'?95:100,range=dv?'2':'1';
  const settings={brightness:50,contrast:sdr?85:100,blackLevel:'auto',sharpness:0,color:50,tint:0,
   peakBrightness:sdr?'off':'high',dynamicContrast:'off',dynamicColor:'off',superResolution:'off',noiseReduction:'off',
   mpegNoiseReduction:'off',smoothGradation:'off',realCinema:'off',energySaving:'off',
   [panelKey]:brightness};
  // DV gamut/DTM belong to its decoder; do not pin generic HDR10 controls there.
  if(!dv)settings.colorGamut='auto';
  if(sdr)settings.gamma=pgAutomationTvGamma(gamma);
  if(hdr)settings.hdrDynamicToneMapping='off';
  return {
   name:mode.name,signal_format:mode.signal,picture_mode:mode.mode,tv_gamma_follows_target:sdr,
   template_id:'reference-settings-v5',template_mode:mode.id,
   manual_checks:['TruMotion: verify Off in the TV menu; this control is not available through the API.'],
   template_notes:'LG OLED starting settings. Check supported controls for this TV and mode. '+
    (sdr?'Fixed panel brightness; actual white is measured, not a promised 100-nit result. ':hdr?'Check Dynamic Tone Mapping is Off after reset. ':'DV gamut and tone mapping are decoder-managed. ')+
    'Check TruMotion, AI Brightness, Motion Eye Care, Expression Enhancer and ambient-light processing are Off where available; Near Black Detail 0. Real Cinema is Off for measurement; use On for 24p viewing afterwards. '+
    'Set generator resolution to 1080p24 and Pattern Delay to 0.75 s in Display Settings. Check HDR/DV metadata: maximum 1000, minimum 0.005, MaxCLL 1000, MaxFALL 400; DV transport Standard. These global settings are not applied by the queue.',
   // Keep calibration's own measurement/results, without three extra sweeps
   // on either side. Users may opt into those stages on a saved/custom copy.
   settings,stages:{pre_readings:false,calibration:true,post_readings:false,apply_all:true},
   pre_series:PG_AUTOMATION_SERIES.map(x=>x[1]),post_series:PG_AUTOMATION_SERIES.map(x=>x[1]),
   target_gamma:gamma,target_gamut:gamut,target_white:{x:.3127,y:.3290},target_luminance:100,
   target_delta_e:.5,delta_e_formula:'deitp',
   panel_light:{policy:'fixed',key:panelKey,fixed_value:brightness,target_luminance:100},
   calibration:{target_gamma:gamma,target_gamut:gamut,target_white:{x:.3127,y:.3290},target_luminance:100,
    target_delta_e:.5,delta_e_formula:'deitp',method:sdr?'hybrid':'matrix',profile_source:sdr?'hybrid3':'matrix',
    lattice_size:3,solve_cube_size:33,lattice_residuals:sdr,dark_detail:true,shadow_fix:hdr},
   // Keep acceptance disabled: the source does not specify HDR/DV maximum-patch limits.
   quality:{enabled:false,dE_formula:'deitp',limits:sdr?{'greyscale-21':{avg:2,max:3},'colors-30':{avg:2,max:3},'saturations-24':{avg:2,max:3}}:{}},
   display_type:'oled_generic',ccss_override:meter.ccss_override||'',observer:'1931_2',
   delay_ms:1000,patch_size:10,settle_seconds:8,refresh_rate:meter.refresh_rate||'',
   low_light:{enabled:true,mode:'a',trigger:1},
   patch_insert:true,patch_insert_time_enabled:true,patch_insert_time_frequency_ms:sdr?45000:5000,
   patch_insert_time_duration_ms:5000,patch_insert_time_level:25,patch_insert_patch_enabled:!sdr,
   patch_insert_patch_every:1,patch_insert_patch_duration_ms:1000,patch_insert_patch_level:10,
   display_use_case:'keep',color_format:dv?'0':'1',max_bpc:dv?8:10,colorimetry:sdr?'2':'9',
   ...(hdr?{primaries:'2',eotf:'2'}:{}),
   signal_range:range,pattern_signal_range:range,transport_signal_range:range,rgb_quant_range:range
  };
 });
}
function pgAutomationReferenceQueue(){
 const context={};
 // The panel-light aliases vary by TV. Prefer an already reported working control.
 if(typeof lgDisplayControlValues!=='undefined'){
  context.panel_key=['backlight','oledLight','oledPixelBrightness'].find(key=>lgDisplayControlValues[key]!=null);
 }
 if(typeof getCcssOverride==='function')context.ccss_override=getCcssOverride();
 if(typeof getMeterRefreshRate==='function')context.refresh_rate=getMeterRefreshRate();
 return {name:'Reference settings',items:pgAutomationReferenceItems(PG_AUTOMATION_REFERENCE_MODES.map(mode=>mode.id),context)};
}
function pgAutomationQueueName(name){return name==='ColoursTrue LG OLED plan'?'Reference settings':name;}
function pgAutomationLabel(value){const key=String(value==null?'':value);return PG_AUTOMATION_LABELS[key]||key;}
function pgAutomationSeriesLabel(key){const found=PG_AUTOMATION_SERIES.find(x=>x[1]===key);return found?found[2]:key;}
function pgAutomationFormatTime(iso){if(!iso)return '';const date=new Date(iso);return Number.isNaN(date.getTime())?String(iso):date.toLocaleString();}
function pgAutomationStateBadge(status){
 const badge=pgAutomationEl('State');if(!badge)return;
 badge.textContent=status.replace(/-/g,' ').replace(/^./,ch=>ch.toUpperCase());
 badge.style.color=status==='complete'?'var(--green)':['starting','checking','running','stopping','completing'].includes(status)?'var(--accent)':['paused','interrupted','complete-with-warnings'].includes(status)?'var(--orange)':['failed','blocked'].includes(status)?'var(--red)':'var(--text2)';
}
function pgAutomationEscape(value){return String(value==null?'':value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));}
function pgAutomationClone(value){return value==null?value:JSON.parse(JSON.stringify(value));}
function pgAutomationEl(id){return document.getElementById('pgAutomation'+id);}
function pgAutomationValue(id,fallback){const el=pgAutomationEl(id);return el&&el.value!==''?el.value:fallback;}
function pgAutomationChecked(id){return !!(pgAutomationEl(id)&&pgAutomationEl(id).checked);}
function pgAutomationStageEnabled(stages,key){
 return stages?.[key]==null?!['pre_readings','post_readings'].includes(key):!!stages[key];
}
function pgAutomationNotice(message,error){
 const level=error==='warning'?'warning':error?'error':'info';error=level==='error';
 if(message){pgAutomation.logNotices.push({time:Date.now()/1000,level,message,source:'Browser'});pgAutomation.logNotices=pgAutomation.logNotices.slice(-100);pgAutomationRenderActivity();}
 const el=pgAutomationEl('Notice');if(!el)return;
 el.textContent=message||'';el.style.display=message?'block':'none';el.style.color=error?'var(--red)':level==='warning'?'var(--orange)':'var(--text2)';
 el.setAttribute('role',error?'alert':'status');
 if(error){pgAutomation.lastProblem=message;pgAutomationRenderProgress();}
 if(pgAutomationEl('Editor').open)pgAutomationEl('EditorError').textContent=error?(message||''):'';
}
async function pgAutomationRequest(path,body,timeout){
 const opts={_quiet:true,_timeoutMs:timeout||30000};
 if(body!==undefined){opts.method='POST';opts.headers={'Content-Type':'application/json'};opts.body=JSON.stringify(body);}
 const result=await fetchJSON('/api/automation/'+path,opts);
 if(!result)throw new Error('The generator did not respond. Refresh to check its state before retrying.');
 if(result.status==='error')throw new Error(result.message||'Automation request failed');
 return result;
}
function pgAutomationSnapshot(source){
 const item=pgAutomationClone(source)||{};
 delete item.warmup_minutes;
 delete item.settings_recovery;
 ['readiness','setting_contracts','generation_profile','capability_profile','best_available_settings','best_available_write_ack','tv_input','worker_status','started_at','completed_at'].forEach(key=>delete item[key]);
 pgAutomationUpgradeReference(item);
 ['item_number','status','checkpoints','checkpoint','checkpoint_status','active_stage','stage_started_at','failure','warnings','recheck','hazards','hazard_capabilities','hazard_restore','device_identity','fault_injected','drift_recovery_attempts','drift_recovery_pending','series','apply-all','panel-light'].forEach(key=>delete item[key]);
 return item;
}
function pgAutomationUpgradeReference(item){
 if(!/^(reference-settings-v[123]|colourstrue-six-modes-v1)$/.test(item.template_id||''))return;
 item.settings=item.settings||{};
 if(item.settings.truMotionMode==='off')delete item.settings.truMotionMode;
 if(item.signal_format==='hdr10'&&!Object.hasOwn(item.settings,'hdrDynamicToneMapping'))item.settings.hdrDynamicToneMapping='off';
 item.manual_checks=['TruMotion: verify Off in the TV menu; this control is not available through the API.'];item.template_id='reference-settings-v3';
}
function pgAutomationSaveDraft(){
 try{localStorage.setItem('pgen.automation.queueDraft',JSON.stringify({queue:pgAutomation.queue,editingRunId:pgAutomation.editingRunId,firstPending:pgAutomation.firstPending,selectedQueue:pgAutomation.selectedQueue,loadedQueueSnapshot:pgAutomation.loadedQueueSnapshot}));}
 catch(e){pgAutomationNotice('Browser draft storage is unavailable. Use Save queue to keep edits on the Pi before refreshing.', 'warning');}
 const ready=pgAutomationEl('Readiness');if(ready)ready.innerHTML='';
}
function pgAutomationModes(signal){
 if(typeof lgPictureModesForSignal==='function')return lgPictureModesForSignal(signal).map(mode=>typeof mode==='string'?mode:Array.isArray(mode)?mode[0]:(mode.value||mode.id));
 return signal==='dv'?['dolbyVisionCinemaBright','dolbyVisionFilmMaker']:signal==='sdr'?['cinema','filmMaker','expert1','expert2']:['hdrCinema','hdrFilmMaker'];
}
function pgAutomationModeLabel(mode,signal){
 if(typeof lgPictureModesForSignal==='function'){
  const found=lgPictureModesForSignal(signal).find(x=>x[0]===mode||x.value===mode||x.id===mode);
  if(found)return found.label||found[1]||mode;
 }
 return mode||'Choose a picture mode';
}
function pgAutomationModesChanged(){
 const signal=pgAutomationValue('Signal','sdr'),select=pgAutomationEl('PictureMode'),prior=select.value;
 const modes=pgAutomationModes(signal).filter(Boolean);
 select.innerHTML=modes.map(mode=>'<option value="'+pgAutomationEscape(mode)+'">'+pgAutomationEscape(pgAutomationModeLabel(mode,signal))+'</option>').join('');
 if(modes.includes(prior))select.value=prior;
 else select.value=modes.find(mode=>/filmmaker/i.test(mode))||modes[0]||'';
 pgAutomationModeChanged();
}
function pgAutomationModeChanged(){
 if(pgAutomation.fillingEditor)return;
 const key=pgAutomationValue('Signal','sdr')+':'+pgAutomationValue('PictureMode','');
 if(key===pgAutomation.editorSettingsKey)return;
 if(pgAutomation.editorSettingsKey){
  const [oldSignal,oldMode]=pgAutomation.editorSettingsKey.split(':');
  if(pgAutomationValue('RecipeName','')===pgAutomationModeLabel(oldMode,oldSignal))pgAutomationEl('RecipeName').value=pgAutomationModeLabel(pgAutomationValue('PictureMode',''),pgAutomationValue('Signal','sdr'));
  try{Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());}catch(e){}
  pgAutomation.editorSettingsDrafts[pgAutomation.editorSettingsKey]={values:pgAutomationClone(pgAutomation.supportedValues),pins:[...pgAutomation.pinnedKeys],gamma:pgAutomationValue('Gamma','bt1886'),gammaFollowsTarget:pgAutomation.gammaFollowsTarget,
   manualSettings:pgAutomationClone(pgAutomation.manualSettings||{}),panel:{key:pgAutomationValue('PanelKey',''),policy:pgAutomationValue('PanelPolicy','fixed'),fixed_value:pgAutomationValue('PanelValue',100),target_luminance:pgAutomationValue('PanelTarget',100)}};
 }
 pgAutomation.editorEpoch++;pgAutomation.editorSettingsKey=key;
 const draft=pgAutomation.editorSettingsDrafts[key];
 pgAutomationApplyPictureDefaults(draft);
}
// Same settings factory as the reference queue; never copy a live TV's values
// implicitly or mutate saved jobs simply by opening their editor.
function pgAutomationPictureDefaults(signal,mode,panelKey){
 const canonical=value=>String(value||'').replace(/[\s_-]/g,'').toLowerCase();
 const modes=PG_AUTOMATION_REFERENCE_MODES.filter(x=>x.signal===signal);
 const match=modes.find(x=>canonical(x.mode)===canonical(mode))||modes.find(x=>/filmmaker/.test(x.id));
 if(!match)return {settings:{},panel_light:{key:panelKey||'backlight',policy:'fixed',fixed_value:100,target_luminance:100}};
 return pgAutomationReferenceItems([match.id],{panel_key:panelKey})[0];
}
function pgAutomationApplyPictureDefaults(draft,reference){
 const defaults=pgAutomationPictureDefaults(pgAutomationValue('Signal','sdr'),pgAutomationValue('PictureMode',''),pgAutomationValue('PanelKey','backlight'));
 const panel=draft?.panel||defaults.panel_light;
 pgAutomation.supportedKeys=[];pgAutomation.supportedSignal='';pgAutomation.supportedPictureMode='';
 pgAutomation.supportedValues=pgAutomationClone(draft?.values||defaults.settings);
 pgAutomation.pinnedKeys=draft?[...draft.pins]:Object.keys(defaults.settings);
 pgAutomationEl('Gamma').value=draft?.gamma||defaults.target_gamma||'hlg';
 pgAutomation.gammaFollowsTarget=draft?!!draft.gammaFollowsTarget:!!defaults.tv_gamma_follows_target;
 pgAutomation.settingsPlan=null;pgAutomation.manualSettings=pgAutomationClone(draft?.manualSettings||{});
 pgAutomationEl('PanelKey').value=panel.key;
 pgAutomationRenderSettingsEditor();
 pgAutomationEl('PanelKey').value=panel.key;
 pgAutomationEl('PanelPolicy').value=panel.policy;
 pgAutomationEl('PanelValue').value=panel.fixed_value;
 pgAutomationEl('PanelTarget').value=panel.target_luminance;
 pgAutomationUpdateEditor();
 pgAutomationResolveSettingsPlan();
}
function pgAutomationResetPictureDefaults(){
 pgAutomation.editorEpoch++;
 pgAutomationApplyPictureDefaults(null,true);
}
function pgAutomationSignalDefaults(){
 const signal=pgAutomationValue('Signal','sdr');
 if(signal!=='sdr')pgAutomationEl('Gamma').value=signal==='hlg'?'hlg':'st2084';
 pgAutomationEl('Gamut').value=signal==='sdr'?'bt709':'p3d65';
 if(signal!=='sdr')pgAutomationEl('PanelPolicy').value='fixed';
 pgAutomationEl('Method').value=signal==='hdr10'?'matrix':'hybrid3';
 if(signal==='dv'){
  pgAutomationEl('UseCase').value='keep';pgAutomationEl('ColorFormat').value='0';pgAutomationEl('Range').value='2';pgAutomationEl('BitDepth').value='8';
 }else{
  if(pgAutomationValue('UseCase','keep')==='keep'){
   pgAutomationEl('ColorFormat').value='1';pgAutomationEl('Range').value='1';pgAutomationEl('BitDepth').value='10';
  }
  pgAutomationUseCaseChanged(true);
 }
 if(signal==='hlg')pgAutomationEl('Cal').checked=false;
 pgAutomationDisplayTypeChanged();
 pgAutomationUpdateEditor();
}
function pgAutomationUseCaseChanged(outputOnly){
 const choice=pgAutomationValue('UseCase','keep'),signal=pgAutomationValue('Signal','sdr');
 const mapping=typeof METER_AUTOCAL_USECASE_OUTPUT!=='undefined'?METER_AUTOCAL_USECASE_OUTPUT:{pc:{color_format:'0',rgb_quant_range:'2',max_bpc:'10'},tv:{color_format:'1',rgb_quant_range:'1',max_bpc:'10'},console:{color_format:'0',rgb_quant_range:'2',max_bpc:'10'}};
 const config=mapping[choice];
 if(config&&signal!=='dv'){
  pgAutomationEl('ColorFormat').value=config.color_format;pgAutomationEl('Range').value=config.rgb_quant_range;pgAutomationEl('BitDepth').value=config.max_bpc;
  if(signal==='sdr'&&!outputOnly){pgAutomationEl('Gamma').value=choice==='tv'?'bt1886':'2.2';pgAutomationGammaChanged();}
 }
}
// LG's picture API uses enum tokens, not the labels shown in the TV menu.
function pgAutomationTvGamma(target){return {'1.9':'low','2.2':'medium','2.4':'high1',bt1886:'high2','BT.1886':'high2'}[target]||'';}
function pgAutomationGammaChanged(){
 if(pgAutomationValue('Signal','sdr')==='sdr'&&pgAutomation.gammaFollowsTarget){
  const value=pgAutomationTvGamma(pgAutomationValue('Gamma','bt1886'));
  const input=document.querySelector('[data-pg-automation-key="gamma"]'),pin=document.querySelector('[data-pg-automation-pin="gamma"]');
  pgAutomation.pinnedKeys=pgAutomation.pinnedKeys.filter(key=>key!=='gamma');
  const unavailable=pgAutomation.settingsPlan?.manual?.gamma||pgAutomation.settingsPlan?.blocked?.gamma;
  if(value){pgAutomation.supportedValues.gamma=value;if(!unavailable)pgAutomation.pinnedKeys.push('gamma');if(input)input.value=value;}
  if(pgAutomation.manualSettings?.gamma){if(value)pgAutomation.manualSettings.gamma.value=value;else delete pgAutomation.manualSettings.gamma;pgAutomationRenderManualSettings();}
  if(input)input.disabled=!value||!!unavailable;
  if(pin)pin.checked=!!value&&!unavailable;
  pgAutomationUpdateSettingsStatus();
 }
 pgAutomationUpdateEditor();
}
function pgAutomationSettingChanged(key){
 if(key==='gamma'){pgAutomation.gammaFollowsTarget=false;pgAutomationUpdateEditor();}
}
function pgAutomationPopulateMeterChoices(dtype,ccss){
 const copy=(id,sourceId,value,fallback)=>{
  const select=pgAutomationEl(id),source=document.getElementById(sourceId);
  select.innerHTML=source?source.innerHTML:fallback;
  select.querySelectorAll('option[value="custom_editor"]').forEach(x=>x.remove());
  if(!Array.from(select.options).some(x=>x.value===value))select.add(new Option(value||'Auto (technology default)',value));
  select.value=value;
 };
 copy('DisplayType','meterDisplayType',dtype||'lcd','<option value="lcd">LCD</option><option value="oled_generic">WOLED</option>');
 copy('Ccss','meterCcssProfile',ccss||'','<option value="">Auto (technology default)</option><option value="none">No correction</option>');
 pgAutomationDisplayHelp();
}
function pgAutomationDisplayHelp(){
 const dtype=pgAutomationEl('DisplayType'),oled=/oled|wrgb/i.test(dtype.value+' '+(dtype.selectedOptions[0]?.textContent||'')),hdr=pgAutomationValue('Signal','sdr')!=='sdr';
 pgAutomationEl('DisplayHelp').textContent=oled?'OLED: 10% window. Changing panel technology applies wizard conditioning: '+(hdr?'5 s':'45 s')+' interval, 5 s at 25%'+(hdr?', plus a 1 s / 10% insertion every patch.':'.'):'LCD / QNED: 10% window on black (10% APL), with pattern insertion off. Meter profile is captured for this item only.';
}
function pgAutomationDisplayTypeChanged(){
 const dtype=pgAutomationEl('DisplayType'),oled=/oled|wrgb/i.test(dtype.value+' '+(dtype.selectedOptions[0]?.textContent||'')),hdr=pgAutomationValue('Signal','sdr')!=='sdr';
 pgAutomationEl('PatchSize').value=10;
 Object.assign(pgAutomation.editingRecipe,{
  patch_insert:oled,patch_insert_time_enabled:oled,patch_insert_time_frequency_ms:hdr?5000:45000,
  patch_insert_time_duration_ms:5000,patch_insert_time_level:25,patch_insert_patch_enabled:oled&&hdr,
  patch_insert_patch_every:1,patch_insert_patch_duration_ms:1000,patch_insert_patch_level:10
 });
 pgAutomationDisplayHelp();
}
function pgAutomationSetPanelPolicy(policy){pgAutomationEl('PanelPolicy').value=policy;pgAutomationUpdateEditor();}
function pgAutomationModeEligibility(){
 const candidate=pgAutomation.settingsPlan?.calibration_mode;
 const contract=candidate&&candidate.signal_mode===pgAutomationValue('Signal','sdr')?candidate:null;
 const blocked=!!contract&&!contract.allowed&&pgAutomationChecked('Cal');
 const select=pgAutomationEl('PictureMode');
 const token=value=>String(value||'').replace(/[\s_-]/g,'').toLowerCase();
 const allowed=new Set((contract?.allowed_modes||[]).map(token));
 // Preserve a saved unknown token rather than silently selecting a preset.
 if(Array.isArray(contract?.catalogue)){
  const selected=select.value;
  const rows=contract.catalogue.filter(row=>row.offered||[row.value,row.settings_value,...(row.aliases||[])].some(value=>token(value)===token(selected)));
  const options=rows.map(row=>{
   const value=[row.value,row.settings_value,...(row.aliases||[])].some(value=>token(value)===token(selected))?selected:row.value;
   const option=new Option(row.label,value);option.dataset.modeLabel=row.label;return option;
  });
  if(selected&&!options.some(option=>option.value===selected))options.unshift(new Option(selected,selected));
  select.replaceChildren(...options);select.value=selected;
 }
 Array.from(select.options).forEach(option=>{
  option.dataset.modeLabel||=option.textContent;
  const readingsOnly=!!contract&&!allowed.has(token(option.value));
  option.disabled=readingsOnly&&pgAutomationChecked('Cal');
  option.textContent=option.dataset.modeLabel+(readingsOnly?' — readings only':'');
 });
 const message=blocked?pgAutomationModeLabel(select.value,pgAutomationValue('Signal','sdr'))+': '+contract.message
  :contract&&!contract.allowed?'This mode is available for readings, not AutoCal.':contract?.message||'';
 pgAutomationEl('ModeEligibility').textContent=message;
 select.setAttribute('aria-invalid',blocked?'true':'false');
 pgAutomationEl('EditorSave').disabled=!!pgAutomation.planPending||!!pgAutomation.planError||blocked;
 pgAutomationEl('EditorSave').title=blocked?message:'';
 let footer=pgAutomationEl('ModeSaveHelp');
 if(!footer){footer=document.createElement('p');footer.id='pgAutomationModeSaveHelp';footer.className='auto-muted';footer.style.cssText='flex-basis:100%;margin:0';pgAutomationEl('EditorSave').parentElement.prepend(footer);}
 footer.textContent=pgAutomation.planPending?'Checking TV compatibility — required before saving. You can continue editing while this runs.'
  :pgAutomation.planError?'TV compatibility check failed. Review the error above and retry before saving.'
  :blocked?message:'';
 footer.hidden=!footer.textContent;
 pgAutomationEl('EditorSave').setAttribute('aria-describedby','pgAutomationModeSaveHelp');
 pgAutomationRenderCompatibilityStatus(blocked?message:'');
 return blocked?message:'';
}
function pgAutomationRenderCompatibilityStatus(modeBlockMessage){
 const panel=pgAutomationEl('Compatibility');if(!panel)return;
 const plan=pgAutomation.settingsPlan;
 let state='required',label='Check required',detail='Required before saving. Connect your TV, then check which controls this job can use.',action='Check TV compatibility';
 if(pgAutomation.planPending){
  state='checking';label='Checking…';action='Checking compatibility…';
  detail='Required before saving. Reading the connected TV and matching its controls to this job. Keep the TV connected; you can continue editing.';
 }else if(pgAutomation.planError){
  state='error';label='Check failed — action needed';action='Retry compatibility check';
  detail=pgAutomation.planError+' Keep your TV connected, then retry. This check must complete before you can save.';
 }else if(plan){
  const limited=!plan.known||Object.keys(plan.manual||{}).length>0||Object.keys(plan.blocked||{}).length>0;
  state=modeBlockMessage?'error':limited?'limited':'checked';
  label=modeBlockMessage?'Action needed':limited?'Checked — review limits':'Checked';action='Refresh TV compatibility';
  const context=(plan.model_name||'Connected TV')+' · '+pgAutomationValue('Signal','sdr').toUpperCase()+' · '+pgAutomationModeLabel(pgAutomationValue('PictureMode',''),pgAutomationValue('Signal','sdr'))+'. ';
  detail=context+(modeBlockMessage?modeBlockMessage
   :!plan.known?'No reviewed TV profile matched. Only conservative controls are available; review the limitations under TV Settings.'
   :limited?'Compatibility checked. Review manual steps and unavailable controls under TV Settings.'
   :plan.live_context_matches?'Compatibility checked in the current TV mode. Settings will be verified again when the job runs.'
   :'Settings selected from the TV matrix. Live checks will run after the job selects its signal and picture mode.');
 }
 panel.dataset.state=state;
 // Do not re-announce unchanged status on every unrelated form edit.
 const setText=(id,value)=>{const el=pgAutomationEl(id);if(el.textContent!==value)el.textContent=value;};
 setText('CompatibilityState',label);setText('CompatibilityDetail',detail);setText('CompatibilityButton',action);
 pgAutomationEl('CompatibilityButton').disabled=!!pgAutomation.planPending;
}
function pgAutomationSelectSettings(all){
 document.querySelectorAll('[data-pg-automation-pin]').forEach(el=>{
  const key=el.getAttribute('data-pg-automation-pin');
  if(el.disabled||all&&pgAutomation.supportedValues[key]==null)return;
  el.checked=all;pgAutomationTogglePin(el);
 });
}
function pgAutomationSettingMetadata(key){
 if(key==='gamma')return {key,label:'TV Gamma (setup)',type:'select',options:['low','medium','high1','high2'],labels:{low:'Gamma 1.9',medium:'Gamma 2.2',high1:'Gamma 2.4',high2:'BT.1886'}};
 if(typeof LG_DISPLAY_CONTROL_ITEMS!=='undefined')return LG_DISPLAY_CONTROL_ITEMS.find(item=>item.key===key)||{key,label:key,type:'text'};
 return {key,label:key,type:'text'};
}
function pgAutomationSettingCandidates(){
 const keys=typeof LG_DISPLAY_CONTROL_KEYS!=='undefined'?LG_DISPLAY_CONTROL_KEYS.slice():['brightness','contrast','backlight','oledLight','oledPixelBrightness','energySaving'];
 const signal=pgAutomationValue('Signal','sdr');
 return keys.filter(key=>!(key==='hdrDynamicToneMapping'&&signal!=='hdr10')&&!(key==='colorGamut'&&signal==='dv')&&!(key==='gamma'&&signal!=='sdr'));
}
function pgAutomationSettingValue(value){return value==null?'':typeof value==='object'?JSON.stringify(value):String(value);}
function pgAutomationRenderSettingsEditor(){
 const editor=pgAutomationEl('SettingsEditor');
 const pinned=pgAutomation.pinnedKeys||[];
 const checked=pgAutomation.supportedKeys.length>0;
 const keys=Array.from(new Set([...(checked?pgAutomation.supportedKeys:pgAutomationSettingCandidates()),...pinned]));
  editor.innerHTML=keys.filter(key=>!['backlight','oledLight','oledPixelBrightness'].includes(key)).map(key=>{
   const unavailable=pgAutomation.settingsPlan?.manual?.[key]||pgAutomation.settingsPlan?.blocked?.[key];
   const meta=pgAutomationSettingMetadata(key),raw=pgAutomation.supportedValues[key],value=pgAutomationSettingValue(key==='gamma'?(pgAutomationTvGamma(raw)||raw):raw),pin=pinned.includes(key);
   let input;
   const attrs=' data-pg-automation-key="'+pgAutomationEscape(key)+'" onchange="pgAutomationSettingChanged(this.dataset.pgAutomationKey)"'+(pin?'':' disabled');
   if(meta.type==='select'&&Array.isArray(meta.options)){
    const options=meta.options.slice();if(value&&!options.includes(value))options.unshift(value);
    input='<select'+attrs+'>'+options.map(option=>'<option value="'+pgAutomationEscape(option)+'"'+(String(option)===value?' selected':'')+'>'+pgAutomationEscape(meta.labels?.[option]||option)+'</option>').join('')+'</select>';
   }else{
    input='<input'+attrs+' type="'+(meta.type==='number'?'number':'text')+'"'+(meta.min!=null?' min="'+meta.min+'"':'')+(meta.max!=null?' max="'+meta.max+'"':'')+' value="'+pgAutomationEscape(value)+'">';
   }
   return '<div class="field"><label><input type="checkbox" data-pg-automation-pin="'+pgAutomationEscape(key)+'"'+(pin?' checked':'')+(unavailable?' disabled':'')+' onchange="pgAutomationTogglePin(this)"> '+pgAutomationEscape(meta.label||key)+'</label>'+input+(unavailable?'<span class="auto-muted">'+pgAutomationEscape(unavailable.reason)+'</span>':'')+'</div>';
  }).join('');
 pgAutomationUpdateSettingsStatus();
 pgAutomationRenderPanelKeyOptions();
 pgAutomationEl('SelectAllSettings').disabled=!keys.some(key=>pgAutomation.supportedValues[key]!=null);
 pgAutomationEl('SelectAllSettings').title='Pin every control with a configured value; blank controls are left unchanged';
}
function pgAutomationUpdateSettingsStatus(){
 const count=pgAutomation.pinnedKeys.filter(key=>!['backlight','oledLight','oledPixelBrightness'].includes(key)).length;
 pgAutomationEl('SettingsStatus').textContent=count+' picture controls pinned · '+(pgAutomation.settingsPlan?'TV-matrix selection for '+(pgAutomation.settingsPlan.model_name||'unidentified TV')+'. Writes are verified at run time.':pgAutomation.supportedKeys.length?'TV values read for '+pgAutomationModeLabel(pgAutomation.supportedPictureMode,pgAutomation.supportedSignal)+'.':'Reference values prepared; TV compatibility must be checked.');
}
function pgAutomationTogglePin(el){
 const key=el.getAttribute('data-pg-automation-pin');
 pgAutomationSettingChanged(key);
 pgAutomation.pinnedKeys=pgAutomation.pinnedKeys.filter(x=>x!==key);
 if(el.checked)pgAutomation.pinnedKeys.push(key);
 const input=Array.from(document.querySelectorAll('[data-pg-automation-key]')).find(x=>x.getAttribute('data-pg-automation-key')===key);
 if(input)input.disabled=!el.checked;
 pgAutomationUpdateSettingsStatus();
}
function pgAutomationRenderPanelKeyOptions(){
 const panel=pgAutomation.settingsPlan?.panel_light;
 pgAutomationEl('PanelBinding').textContent=panel?.wire_key?panel.label:'TV control not yet identified';
 pgAutomationEl('PanelBindingHelp').textContent=panel?.wire_key?(panel.target_available?(panel.source==='native_readback'?'Confirmed by TV readback.':'Selected from the TV matrix; live readback is required before target adjustment.'):'Automatic luminance targeting is unavailable because this control cannot be read back. Set panel brightness manually or use a supported fixed write.'):'Connect your TV, then refresh compatibility. No API alias needs to be selected.';
}
async function pgAutomationResolveSettingsPlan(){
 if(typeof fetchJSON!=='function')return;
 const epoch=pgAutomation.editorEpoch,request=(pgAutomation.planRequest||0)+1;
 pgAutomation.planRequest=request;pgAutomation.planPending=true;pgAutomation.planError='';
 pgAutomationEl('EditorSave').disabled=true;pgAutomationEl('PanelBinding').textContent='Checking TV compatibility…';
 pgAutomationEl('KeysButton').disabled=true;pgAutomationUpdateEditor();
 try{
  Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());
  const result=await fetchJSON('/api/automation/settings-plan',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({signal_mode:pgAutomationValue('Signal','sdr'),picture_mode:pgAutomationValue('PictureMode',''),settings:pgAutomation.supportedValues}),_quiet:true,_timeoutMs:60000});
  if(epoch!==pgAutomation.editorEpoch||request!==pgAutomation.planRequest)return;
  if(result?.status!=='ok')throw new Error(result?.message||'Connect the TV and refresh compatibility before saving.');
  // Filter the current selection, not the selection at request time. Edits made
  // during the read remain intact; a refresh never copies live TV values.
  Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());
  pgAutomation.settingsPlan=result;
  const intended=Array.from(new Set([...pgAutomation.pinnedKeys,...Object.keys(pgAutomation.manualSettings||{})]));
  pgAutomation.manualSettings=Object.fromEntries(intended.filter(key=>result.manual?.[key]).map(key=>[key,{...result.manual[key],value:pgAutomation.supportedValues[key]}]));
  pgAutomation.pinnedKeys=intended.filter(key=>Object.hasOwn(result.automatic||{},key));
  const panel=result.panel_light||{};
  pgAutomationEl('PanelKey').value=panel.writable?panel.wire_key||'':'';
  pgAutomationRenderManualSettings();
  pgAutomationRenderSettingsEditor();
 }catch(e){
  if(epoch!==pgAutomation.editorEpoch||request!==pgAutomation.planRequest)return;
  pgAutomation.planError=e.message;pgAutomationEl('PanelBinding').textContent='TV compatibility unavailable';
  pgAutomationEl('PanelBindingHelp').textContent=e.message+' Refresh TV compatibility to retry.';
 }finally{
  if(epoch===pgAutomation.editorEpoch&&request===pgAutomation.planRequest){pgAutomation.planPending=false;pgAutomationEl('EditorSave').disabled=!!pgAutomation.planError;pgAutomationEl('KeysButton').disabled=false;pgAutomationUpdateEditor();}
 }
}
function pgAutomationRenderManualSettings(){
 const manual=Object.entries(pgAutomation.manualSettings||{}).map(([key,entry])=>'Set '+(pgAutomationSettingMetadata(key).label||key)+' to '+pgAutomationSettingValue(entry.value)+' in the TV menu ('+entry.reason+').');
 const blocked=Object.entries(pgAutomation.settingsPlan?.blocked||{}).map(([key,entry])=>(pgAutomationSettingMetadata(key).label||key)+': '+entry.reason+'.');
 const panel=pgAutomation.settingsPlan?.panel_light;
 if(panel&&!panel.writable)manual.push('Set '+panel.label+' manually to '+pgAutomationValue('PanelValue',100)+'; automatic panel adjustment is unavailable.');
 pgAutomationEl('ManualSettings').textContent=[...manual,...blocked].join(' ');
}
function pgAutomationReadSettingsEditor(){
 const values={};
 pgAutomation.pinnedKeys.forEach(key=>{if(pgAutomation.supportedValues[key]!=null)values[key]=pgAutomation.supportedValues[key];});
 document.querySelectorAll('[data-pg-automation-key]').forEach(input=>{
  const key=input.getAttribute('data-pg-automation-key');
  if(!pgAutomation.pinnedKeys.includes(key)){delete values[key];return;}
  if(input.value==='')throw new Error('Enter a value for '+key+' or unpin it.');
  const meta=pgAutomationSettingMetadata(key);
  if(meta.type==='number'&&(!Number.isFinite(Number(input.value))||Number(input.value)<meta.min||Number(input.value)>meta.max))throw new Error(meta.label+' must be between '+meta.min+' and '+meta.max+'.');
  const original=pgAutomation.supportedValues[key];
  if(original&&typeof original==='object'&&/^[\[{]/.test(input.value.trim())){
   try{values[key]=JSON.parse(input.value);}catch(e){throw new Error('Invalid structured value for '+key);}
  }else values[key]=meta.type==='number'||typeof original==='number'&&Number.isFinite(Number(input.value))?Number(input.value):input.value;
 });
 return values;
}
async function pgAutomationLoadSupportedKeys(){
 const signal=pgAutomationValue('Signal','sdr'),pictureMode=pgAutomationValue('PictureMode',''),epoch=pgAutomation.editorEpoch;
 const button=pgAutomationEl('KeysButton');button.disabled=true;button.textContent='Reading Controls…';
 try{
  const prior=pgAutomationReadSettingsEditor();
  const panelBefore=['PanelKey','PanelPolicy','PanelValue','PanelTarget'].map(id=>pgAutomationValue(id,''));
  const candidates=pgAutomationSettingCandidates();
  const result=await fetchJSON('/api/lg/picture-settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keys:[...candidates,'pictureMode'],picture_mode:pictureMode,signal_mode:signal,category:'picture',include_current_input:true}),_quiet:true,_timeoutMs:60000});
  if(epoch!==pgAutomation.editorEpoch||signal!==pgAutomationValue('Signal','sdr')||pictureMode!==pgAutomationValue('PictureMode',''))return;
  if(!result||result.status==='error')throw new Error(result?.message||'Could not read TV controls. Check the TV connection.');
  if(JSON.stringify(prior)!==JSON.stringify(pgAutomationReadSettingsEditor())||JSON.stringify(panelBefore)!==JSON.stringify(['PanelKey','PanelPolicy','PanelValue','PanelTarget'].map(id=>pgAutomationValue(id,''))))throw new Error('Settings changed while the TV was being read. Your edits were kept; use TV settings again if you want to replace them.');
  const current=result.picture_settings||result.settings||{};
  const canonical=value=>String(typeof lgPictureModeCanonicalValue==='function'?lgPictureModeCanonicalValue(value):value).replace(/[\s_-]/g,'').toLowerCase();
  if(current.pictureMode&&canonical(current.pictureMode)!==canonical(pictureMode))throw new Error('The TV reported a different picture mode. Select '+pgAutomationModeLabel(pictureMode,signal)+' on the TV before using its settings. Prepared values were kept.');
  const values=Object.fromEntries(Object.entries(current).filter(([key,value])=>candidates.includes(key)&&value!=null&&!(typeof value==='string'&&!value.trim())&&!result.unsupported_picture_keys?.[key]&&(!result.virtual_picture_settings||(result.supported_picture_keys||[]).includes(key))));
  if(!Object.keys(values).length)throw new Error('The TV returned no readable picture controls. Prepared values were kept.');
  pgAutomation.supportedKeys=Array.from(new Set([...(result.supported_picture_keys||[]),...Object.keys(values)])).filter(key=>candidates.includes(key));
  // Keep unread values available for deliberate manual selection, not as
  // automatic writes. A read limitation alone does not prove a write is unsafe.
  const removed=Object.keys(prior).filter(key=>!Object.hasOwn(values,key));
  const writable=Object.keys(values).filter(key=>!['blocked','not_applicable'].includes(result.setting_contracts?.[key]?.write_decision));
  pgAutomation.supportedKeys=Array.from(new Set([...candidates,...Object.keys(values)]));
  pgAutomation.supportedValues=Object.assign({},pgAutomation.supportedValues,prior,values);
  pgAutomation.pinnedKeys=writable;
  pgAutomation.manualSettings={};
  pgAutomation.gammaFollowsTarget=false;
  pgAutomation.supportedSignal=signal;pgAutomation.supportedPictureMode=pictureMode;
  const panelKey=result.logical_controls?.panel_light?.wire_key||pgAutomation.settingsPlan?.panel_light?.wire_key||pgAutomationValue('PanelKey','');
  if(panelKey&&writable.includes(panelKey)){pgAutomationEl('PanelKey').value=panelKey;pgAutomationEl('PanelValue').value=values[panelKey];}
  else pgAutomationEl('PanelKey').value='';
  pgAutomationRenderSettingsEditor();
  pgAutomationEl('PanelKey').value=panelKey&&writable.includes(panelKey)?panelKey:'';
  pgAutomationUpdateEditor();
  await pgAutomationResolveSettingsPlan();
  const reasons=removed.map(key=>key+': '+(result.unsupported_picture_keys?.[key]?'TV readback unavailable':'no native value returned')).join('; ');
  pgAutomationNotice(writable.length+' readable controls copied. '+removed.length+' unread pins removed'+(reasons?' ('+reasons+')':'')+'. You can explicitly select write-only controls; the TV matrix decides whether to write them or require a manual check. No TV settings were changed.');
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;button.textContent='Use TV Settings';}
}
function pgAutomationUpdateEditor(){
 pgAutomationModeEligibility();
 const signal=pgAutomationValue('Signal','sdr'),cal=pgAutomationChecked('Cal')&&signal!=='hlg',post=pgAutomationChecked('Post');
 const sdr=signal==='sdr',dv=signal==='dv',hdr=signal==='hdr10',hlg=signal==='hlg';
 const show=(id,value)=>{pgAutomationEl(id).style.display=value?'':'none';};
 pgAutomationEl('Cal').disabled=hlg;
 if(hlg)pgAutomationEl('Cal').checked=false;
 pgAutomationEl('ApplyAll').disabled=!cal;
 pgAutomationEl('QualitySection').style.display=post?'':'none';
 pgAutomationEl('Sweeps').style.display=post||pgAutomationChecked('Pre')?'':'none';
 pgAutomationEl('PanelTarget').disabled=!sdr||!cal;
 pgAutomationEl('PanelTargetRadio').disabled=pgAutomation.planPending||!!pgAutomation.planError||!!pgAutomation.settingsPlan&&!pgAutomation.settingsPlan.panel_light?.target_available;
 pgAutomationEl('PanelPolicy').querySelector('option[value="target"]').disabled=signal!=='sdr'||!cal;
 if(!sdr||!cal)pgAutomationEl('PanelPolicy').value='fixed';
 const target=pgAutomationValue('PanelPolicy','fixed')==='target';
 pgAutomationEl('PanelFixed').checked=!target;pgAutomationEl('PanelTargetRadio').checked=target;
 pgAutomationEl('PanelSlider').value=pgAutomationEl('PanelValue').value;
 show('PanelTargetChoice',sdr&&cal);show('PanelFixedField',!target);show('PanelTargetField',target);
 show('OutputSection',!dv);show('WorkflowOptions',cal&&!hlg);show('OneDSection',cal&&!hlg);
 show('VolumeFields',sdr&&cal);show('ShadowFixField',hdr&&cal);
 show('LatticeSizeField',pgAutomationValue('Method','hybrid3')==='lattice');
 show('CubeSizeField',cal&&!dv&&!hlg);show('ResidualsField',sdr&&cal&&pgAutomationValue('Method','hybrid3')!=='matrix');
 pgAutomationEl('Method').disabled=!cal||hdr||dv||hlg;
 pgAutomationEl('ShadowFix').disabled=!cal||signal!=='hdr10';
 pgAutomationEl('Residuals').disabled=!cal||dv||hdr||hlg||pgAutomationValue('Method','hybrid3')==='matrix';
 pgAutomationEl('CubeSize').disabled=!cal||signal==='dv';
 pgAutomationEl('Gamma').disabled=hdr||dv||hlg;
 Array.from(pgAutomationEl('Gamma').options).forEach(option=>{option.hidden=sdr?['st2084','hlg'].includes(option.value):option.value!==(hlg?'hlg':'st2084');});
 if(!sdr)pgAutomationEl('Gamma').value=hlg?'hlg':'st2084';
 pgAutomationEl('ColorFormat').disabled=dv;pgAutomationEl('Range').disabled=dv;pgAutomationEl('BitDepth').disabled=dv;
 pgAutomationEl('WorkflowHelp').textContent=hlg?'HLG supports before/after measurements. The existing LG AutoCal workers support SDR, HDR10 and Dolby Vision, not HLG calibration.':!cal?'Measurements only: apply this item’s settings, then capture selected sweeps. No calibration reset or LUT upload.':dv?'Before readings → reset greyscale → HDR greyscale / 1D LUT → Dolby Vision panel profile upload → after readings. No 3D LUT.':hdr?'Before readings → reset greyscale and 3D LUT → HDR greyscale / 1D LUT → HDR10 matrix 3D LUT → after readings.':'Before readings → reset and reapply settings → set and measure 100% white → greyscale / 1D LUT → color 3D LUT → after readings.';
 pgAutomationEl('GammaHeading').textContent=sdr?'Gamma Target':'Calibration and Verification Targets';
 pgAutomationEl('GammaHelp').textContent=sdr?'The 1D LUT is calibrated to this curve; after readings use the same target. TV Gamma is a separate setup control, bypassed after a 1D LUT upload. '+(pgAutomation.gammaFollowsTarget?(pgAutomationValue('Gamma','')==='srgb'?'LG has no sRGB menu preset, so TV Gamma is not pinned.':'The prepared TV Gamma follows this target; editing or unpinning TV Gamma overrides that link.'):'Your TV Gamma override is kept separately. Restore Reference Defaults to link it to the target again.'):hlg?'HLG measurements use the HLG transfer function.':(dv?'Dolby Vision uses pinned RGB Full 8-bit transport and its dedicated map modes. ':'')+'Greyscale calibrates in Gamma 2.2; before/after readings use ST 2084 (PQ). Peak luminance is measured by the HDR worker.';
 pgAutomationEl('LuminanceHelp').textContent=!cal?'Only fixed TV controls are applied; no luminance-target loop is run.':sdr?(target?'Adjusts panel light to this setup target, then captures the actual 100% white. ':'Keeps this fixed control value, then measures its actual 100% white. ')+'Like the manual wizard, the setup white sets the 1D reference and SDR headroom. The final calibrated white can be lower (the wizard notes roughly 15%); this is not a guaranteed post-cal luminance target.':'Fixed panel light is preserved through calibration. HDR10 and Dolby Vision skip the SDR luminance loop and use the measured native peak.';
 const method=pgAutomationValue('Method','hybrid3');
 pgAutomationEl('LutHelp').textContent=dv?'Builds and uploads a measured Dolby Vision panel profile. Dark Detail applies to the greyscale pass; no color-cube or shadow-fix options.':hdr?'Matrix 3D LUT profiling and 33³ upload, followed by the HDR tone-mapping handoff.':(typeof meterLg3dProfilingExplain==='function'&&method!=='ramp'?meterLg3dProfilingExplain(method):'Color profiling followed by a 33³ TV LUT upload.');
}
function pgAutomationNumber(id,fallback,min,max){
 const value=Number(pgAutomationValue(id,fallback));
 if(!Number.isFinite(value)||value<min||value>max)throw new Error((pgAutomationEl(id)?.labels?.[0]?.textContent||id)+' must be between '+min+' and '+max+'.');
 return value;
}
function pgAutomationRecipeFromForm(){
 if(pgAutomation.planPending||pgAutomation.planError)throw new Error(pgAutomation.planError||'Wait for the TV compatibility check to finish.');
 const admission=pgAutomation.settingsPlan?.calibration_mode;
 if(pgAutomationChecked('Cal')&&admission&&!admission.allowed)throw new Error(admission.message);
 const recipe=pgAutomationSnapshot(pgAutomation.editingRecipe),signal=pgAutomationValue('Signal','sdr'),settings=pgAutomationReadSettingsEditor();
 const stages={pre_readings:pgAutomationChecked('Pre'),calibration:pgAutomationChecked('Cal'),post_readings:pgAutomationChecked('Post'),apply_all:pgAutomationChecked('Cal')&&pgAutomationChecked('ApplyAll')};
 if(!stages.pre_readings&&!stages.calibration&&!stages.post_readings)throw new Error('Enable at least one stage.');
 if(signal==='hlg'&&stages.calibration)throw new Error('HLG supports measurements only; use SDR, HDR10 or Dolby Vision for LG AutoCal.');
 const pre=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('Series'+x[0])).map(x=>x[1]);
 const post=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('PostSeries'+x[0])).map(x=>x[1]);
 if(stages.pre_readings&&!pre.length||stages.post_readings&&!post.length)throw new Error('Select a sweep for each enabled readings stage.');
 const panelKey=pgAutomationValue('PanelKey',''),policy=pgAutomationValue('PanelPolicy','fixed');
 if(policy==='target'&&(signal!=='sdr'||!stages.calibration||!panelKey))throw new Error('Target luminance requires SDR AutoCal and a supported panel-light control.');
 if(policy==='target'&&pgAutomation.settingsPlan&&!pgAutomation.settingsPlan.panel_light?.target_available)throw new Error('Target luminance requires readable panel brightness. Use fixed brightness and the manual TV checks for this model.');
 const panelValue=pgAutomationNumber('PanelValue',signal==='sdr'?80:100,0,100);
 ['backlight','oledLight','oledPixelBrightness'].forEach(key=>delete settings[key]);
 if(panelKey&&policy==='fixed')settings[panelKey]=panelValue;
 const target=pgAutomationNumber('PanelTarget',100,1,10000),formula=pgAutomationValue('Formula','deitp');
 const limits={};
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{const prefix='Quality'+(suffix==='Grey'?'':suffix);limits[key]={avg:pgAutomationNumber(prefix+'Avg',2,0,10000),max:pgAutomationNumber(prefix+'Max',5,0,10000)};});
 const white={x:pgAutomationNumber('WhiteX',.3127,.01,.9),y:pgAutomationNumber('WhiteY',.329,.01,.9)};
 if(white.x+white.y>=1)throw new Error('White point x + y must be below 1.');
 Object.assign(recipe,{
  name:pgAutomationValue('RecipeName','Automation item'),signal_format:signal,picture_mode:pgAutomationValue('PictureMode',''),
  settings,stages,pre_series:pre,post_series:post,tv_gamma_follows_target:signal==='sdr'&&pgAutomation.gammaFollowsTarget,
  target_luminance:target,target_gamma:pgAutomationValue('Gamma','bt1886'),target_gamut:pgAutomationValue('Gamut','bt709'),
  target_delta_e:pgAutomationNumber('Delta',.5,.1,100),delta_e_formula:formula,target_white:white,
  display_use_case:signal==='dv'?'keep':pgAutomationValue('UseCase','keep'),color_format:signal==='dv'?'0':pgAutomationValue('ColorFormat','0'),
  eotf:signal==='sdr'?'0':signal==='hlg'?'3':'2',primaries:signal==='sdr'?'0':signal==='dv'?'1':'2',colorimetry:signal==='sdr'?'2':'9',
  panel_light:{policy,key:panelKey,fixed_value:panelValue,target_luminance:target},
  quality:{enabled:stages.post_readings&&pgAutomationChecked('Quality'),dE_formula:formula,limits},
  patch_size:pgAutomationNumber('PatchSize',10,1,100),delay_ms:pgAutomationNumber('Delay',1000,0,30000),
  settle_seconds:pgAutomationNumber('Settle',8,0,600),
  signal_range:pgAutomationValue('Range','2'),pattern_signal_range:pgAutomationValue('Range','2'),
  transport_signal_range:pgAutomationValue('Range','2'),rgb_quant_range:pgAutomationValue('Range','2'),
  max_bpc:signal==='dv'?8:pgAutomationNumber('BitDepth',10,8,10),display_type:pgAutomationValue('DisplayType','lcd'),ccss_override:pgAutomationValue('Ccss','')
 });
 if(signal==='dv')recipe.signal_range=recipe.pattern_signal_range=recipe.transport_signal_range=recipe.rgb_quant_range='2';
 const previous=recipe.reference_manual_checks||[];
 recipe.reference_manual_checks=Object.entries(pgAutomation.manualSettings||{}).map(([key,entry])=>'Set '+(pgAutomationSettingMetadata(key).label||key)+' to '+pgAutomationSettingValue(entry.value)+' in the TV menu for '+recipe.picture_mode+' ('+signal+'). '+entry.reason+'.');
 if(pgAutomation.settingsPlan?.panel_light&&!pgAutomation.settingsPlan.panel_light.writable)recipe.reference_manual_checks.push('Set '+pgAutomation.settingsPlan.panel_light.label+' manually to '+panelValue+' for '+recipe.picture_mode+' ('+signal+'). Automatic panel adjustment is unavailable.');
 recipe.reference_manual_settings=pgAutomationClone(pgAutomation.manualSettings||{});
 recipe.manual_checks=[...(recipe.manual_checks||[]).filter(text=>!previous.includes(text)),...recipe.reference_manual_checks];
 const source=signal==='hdr10'?'matrix':pgAutomationValue('Method','hybrid3'),method=source.startsWith('hybrid')?'hybrid':source;
 const size=source==='hybrid9'?9:source==='hybrid5'?5:source==='hybrid3'?3:Number(pgAutomationValue('LatticeSize',5));
 const oldCal=recipe.calibration||{};
 recipe.calibration=Object.assign({},recipe.calibration||{},{
  target_gamma:recipe.target_gamma,target_gamut:recipe.target_gamut,target_luminance:target,target_delta_e:recipe.target_delta_e,delta_e_formula:formula,target_white:white,
  method,profile_source:source,lattice_size:size,solve_cube_size:Number(pgAutomationValue('CubeSize',17)),
  lattice_residuals:signal==='sdr'&&pgAutomationChecked('Residuals'),dark_detail:stages.calibration&&pgAutomationChecked('DarkDetail'),shadow_fix:signal==='hdr10'&&pgAutomationChecked('ShadowFix')
 });
 // A deliberately changed profile must not retain a previous expanded cube.
 const oldSource=oldCal.profile_source||(oldCal.method==='hybrid'?'hybrid'+(oldCal.lattice_size||5):oldCal.method);
 if(oldSource!==source||Number(oldCal.lattice_size||5)!==size)delete recipe.calibration.lattice_patches;
 return recipe;
}
function pgAutomationFillRecipe(recipe){
 recipe=recipe||{};pgAutomation.editorEpoch++;pgAutomation.editingRecipe=pgAutomationClone(recipe);
 pgAutomation.settingsPlan=null;pgAutomation.manualSettings=pgAutomationClone(recipe.reference_manual_settings||{});pgAutomation.planPending=false;pgAutomation.planError='';
 pgAutomationEl('ManualSettings').textContent='';pgAutomationEl('EditorSave').disabled=false;
 pgAutomation.fillingEditor=true;pgAutomation.editorSettingsDrafts={};pgAutomation.editorSettingsKey='';
 pgAutomation.gammaFollowsTarget=!!recipe.tv_gamma_follows_target;
 pgAutomation.supportedKeys=[];pgAutomation.supportedSignal='';pgAutomation.supportedPictureMode='';
 const set=(id,value)=>{pgAutomationEl(id).value=value==null?'':value;},check=(id,value)=>{pgAutomationEl(id).checked=!!value;};
 const cal=recipe.calibration||{},panel=recipe.panel_light||{},stages=recipe.stages||{};
 set('RecipeName',recipe.name||'SDR Filmmaker');set('Signal',recipe.signal_format||'sdr');pgAutomationModesChanged();
 const mode=recipe.picture_mode||pgAutomationModes(recipe.signal_format||'sdr')[0];
 if(!Array.from(pgAutomationEl('PictureMode').options).some(x=>x.value===mode))pgAutomationEl('PictureMode').add(new Option(mode,mode));
 set('PictureMode',mode);pgAutomationModeChanged();
 pgAutomation.supportedValues=pgAutomationClone(recipe.settings||{});pgAutomation.pinnedKeys=Object.keys(recipe.settings||{});
 Object.entries(pgAutomation.manualSettings).forEach(([key,entry])=>{if(!Object.hasOwn(pgAutomation.supportedValues,key))pgAutomation.supportedValues[key]=entry.value;});
 if(Array.isArray(recipe.supported_picture_keys)&&recipe.supported_picture_keys.length){pgAutomation.supportedKeys=recipe.supported_picture_keys.filter(key=>pgAutomationSettingCandidates().includes(key));pgAutomation.supportedSignal=recipe.signal_format;pgAutomation.supportedPictureMode=mode;}
 pgAutomationRenderSettingsEditor();
 ['Pre','Cal','Post','ApplyAll'].forEach((id,index)=>{const key=['pre_readings','calibration','post_readings','apply_all'][index];check(id,pgAutomationStageEnabled(stages,key));});
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{
  check('Series'+suffix,(recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  check('PostSeries'+suffix,(recipe.post_series||recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  const limit=recipe.quality?.limits?.[key]||{},prefix='Quality'+(suffix==='Grey'?'':suffix);
  set(prefix+'Avg',limit.avg??2);set(prefix+'Max',limit.max??5);
 });
 check('Quality',recipe.quality?.enabled);
 set('PanelPolicy',panel.policy||'fixed');set('PanelKey',panel.key||'');pgAutomationRenderPanelKeyOptions();
 set('PanelValue',panel.fixed_value??panel.value??80);set('PanelTarget',panel.target_luminance??recipe.target_luminance??100);
 set('Gamma',recipe.target_gamma||cal.target_gamma||(recipe.signal_format==='sdr'?'bt1886':recipe.signal_format==='hlg'?'hlg':'st2084'));
 set('Gamut',recipe.target_gamut||cal.target_gamut||(recipe.signal_format==='sdr'?'bt709':'p3d65'));
 set('Delta',cal.target_delta_e??recipe.target_delta_e??.5);set('Formula',cal.delta_e_formula||recipe.delta_e_formula||'deitp');
 set('WhiteX',cal.target_white?.x??recipe.target_white?.x??.3127);set('WhiteY',cal.target_white?.y??recipe.target_white?.y??.329);
 const source=cal.profile_source||(cal.method==='hybrid'?'hybrid'+(cal.lattice_size||5):cal.method)||'hybrid3';
 set('Method',recipe.signal_format==='hdr10'?'matrix':source);set('LatticeSize',cal.lattice_size||5);set('CubeSize',cal.solve_cube_size||17);
 check('Residuals',cal.lattice_residuals??true);check('DarkDetail',cal.dark_detail);check('ShadowFix',cal.shadow_fix);
 set('PatchSize',recipe.patch_size??10);set('Delay',recipe.delay_ms??1000);set('Settle',recipe.settle_seconds??8);
 set('UseCase',recipe.display_use_case||'keep');set('ColorFormat',recipe.signal_format==='dv'?'0':recipe.color_format||'0');
 set('Range',recipe.signal_format==='dv'?'2':recipe.signal_range||'2');set('BitDepth',recipe.signal_format==='dv'?8:recipe.max_bpc||10);
 pgAutomationPopulateMeterChoices(recipe.display_type||'lcd',recipe.ccss_override||'');
 check('SaveAsRecipe',false);pgAutomationUpdateEditor();
 pgAutomation.editorSettingsKey=pgAutomationValue('Signal','sdr')+':'+mode;pgAutomation.fillingEditor=false;
}
function pgAutomationOpenEditor(target,recipe,index){
 pgAutomation.editorTarget=target||'queue';pgAutomation.editingQueueIndex=index==null?null:index;
 pgAutomationFillRecipe(recipe);
 pgAutomationEl('EditorTitle').textContent=target==='recipe'?'Configure Saved Recipe':index==null?'Add Queue Item':'Configure Item '+(index+1);
 pgAutomationEl('EditorSave').textContent=target==='recipe'?'Save Recipe':index==null?'Add to Queue':'Save Item';
 pgAutomationEl('SaveAsRecipeLabel').style.display=target==='recipe'?'none':'';
 pgAutomationEl('EditorError').textContent='';
 pgAutomationEl('Editor').showModal();
 pgAutomationEl('Editor').scrollTop=0;
 pgAutomationResolveSettingsPlan();
}
function pgAutomationCancelEditor(){pgAutomation.editorEpoch++;pgAutomationEl('Editor').close();pgAutomation.editingQueueIndex=null;}
function pgAutomationNewRecipe(target){
 let measurement={};
 try{
  measurement={display_type:typeof getEffectiveDisplayType==='function'?getEffectiveDisplayType():'lcd',
   ccss_override:typeof getCcssOverride==='function'?getCcssOverride():'',
   delay_ms:typeof meterDelayMs==='function'?meterDelayMs():1000,patch_size:typeof getMeterPatchSize==='function'?getMeterPatchSize():10,
   refresh_rate:typeof getMeterRefreshRate==='function'?getMeterRefreshRate():'',
   low_light:typeof meterLowLightReadState==='function'?meterLowLightReadState():{},
   ...(typeof meterPatternInsertionPayload==='function'?meterPatternInsertionPayload():{})};
 }catch(e){}
 const mode=pgAutomationModes('sdr').find(x=>/filmmaker/i.test(x))||'cinema';
 const defaults=pgAutomationPictureDefaults('sdr',mode,'backlight');
 pgAutomationOpenEditor(target||'queue',{...measurement,display_use_case:'tv',color_format:'1',signal_range:'1',max_bpc:10,name:pgAutomationModeLabel(mode,'sdr'),signal_format:'sdr',picture_mode:mode,settings:defaults.settings,target_gamma:defaults.target_gamma,tv_gamma_follows_target:!!defaults.tv_gamma_follows_target,panel_light:defaults.panel_light,manual_checks:defaults.manual_checks});
 pgAutomation.supportedValues=pgAutomationClone(defaults.settings);pgAutomationRenderSettingsEditor();
 pgAutomationDisplayTypeChanged();
}
async function pgAutomationSaveRecipe(){
 const button=pgAutomationEl('EditorSave');if(button.disabled)return;button.disabled=true;
 try{
  const item=pgAutomationRecipeFromForm();
  if(pgAutomation.editorTarget==='recipe'||pgAutomationChecked('SaveAsRecipe')){
   const saved=pgAutomationClone(item);if(pgAutomation.editorTarget!=='recipe')delete saved.id;
   await pgAutomationRequest('recipes',{recipe:saved});
  }
  if(pgAutomation.editorTarget!=='recipe'){
   if(pgAutomation.editingQueueIndex!=null)pgAutomation.queue.items[pgAutomation.editingQueueIndex]=item;
   else pgAutomation.queue.items.push(item);
   pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
  }
  pgAutomationCancelEditor();pgAutomationNotice(pgAutomation.editorTarget==='recipe'?'Recipe saved':'Queue item saved');await pgAutomationRefresh();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;if(pgAutomationEl('Editor').open)pgAutomationModeEligibility();}
}
function pgAutomationItemSummary(item){
 const signal=item.signal_format||'sdr',cal=item.calibration||{},stages=item.stages||{},panel=item.panel_light||{};
 const enabled=key=>pgAutomationStageEnabled(stages,key);
 const pills=[signal==='dv'?'Dolby Vision':signal.toUpperCase(),pgAutomationModeLabel(item.picture_mode,signal)];
 if(enabled('pre_readings'))pills.push('Before: '+(item.pre_series||PG_AUTOMATION_SERIES).length+' sweeps');
 if(enabled('calibration'))pills.push(signal==='dv'?'1D LUT + DV profile':'1D LUT + '+(signal==='hdr10'?'matrix':cal.profile_source||cal.method||'hybrid')+' 3D LUT');
 if(enabled('calibration')&&enabled('apply_all'))pills.push('All inputs');
 if(enabled('post_readings'))pills.push('After: '+(item.post_series||PG_AUTOMATION_SERIES).length+' sweeps');
 const settings=Object.entries(item.settings||{}).map(([key,value])=>pgAutomationSettingMetadata(key).label+' '+pgAutomationSettingValue(value));
 if(panel.key&&!Object.prototype.hasOwnProperty.call(item.settings||{},panel.key)&&panel.policy!=='target')settings.push(pgAutomationSettingMetadata(panel.key).label+' '+(panel.fixed_value??80));
 const targets=[];
 if(enabled('calibration'))targets.push('1D LUT ΔE '+(cal.target_delta_e??item.target_delta_e??.5)+' ('+pgAutomationLabel(cal.delta_e_formula||item.delta_e_formula||'deitp')+')');
 targets.push(signal==='sdr'?(panel.policy==='target'?'Setup white target '+(panel.target_luminance??item.target_luminance??100)+' nits':'Fixed panel light; setup white measured at run time'):'Measured peak luminance');
 targets.push(pgAutomationLabel(item.target_gamma||cal.target_gamma||(signal==='sdr'?'bt1886':'st2084')));targets.push(pgAutomationLabel(item.target_gamut||cal.target_gamut||(signal==='sdr'?'bt709':'p3d65')));
 return '<div class="auto-pills">'+pills.map(x=>'<span class="auto-pill">'+pgAutomationEscape(x)+'</span>').join('')+'</div><div class="auto-muted">'+targets.map(pgAutomationEscape).join(' · ')+'</div><div class="auto-muted auto-pin-summary"><strong>TV settings</strong>'+(settings.length?'<ul>'+settings.map(value=>'<li>'+pgAutomationEscape(value)+'</li>').join('')+'</ul>':'<p>No explicit pins; default hazard controls applied</p>')+'</div>'+(item.template_notes?'<details class="auto-muted"><summary>Setup notes</summary><p>'+pgAutomationEscape(item.template_notes)+'</p></details>':'');
}
function pgAutomationRenderRecipeList(){
 const list=pgAutomationEl('RecipeList'),select=pgAutomationEl('RecipeSelect'),prior=select.value;
 select.innerHTML='<option value="">Choose a saved recipe…</option>'+pgAutomation.recipes.map((recipe,i)=>'<option value="'+i+'">'+pgAutomationEscape(recipe.name)+'</option>').join('');
 if(prior)select.value=prior;
 list.innerHTML=pgAutomation.recipes.length?pgAutomation.recipes.map((recipe,i)=>'<div class="auto-item"><span></span><div><strong>'+pgAutomationEscape(recipe.name)+'</strong>'+pgAutomationItemSummary(recipe)+'</div><div class="auto-actions"><button class="btn btn-sm btn-secondary" onclick="pgAutomationEditRecipe('+i+')">Edit</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDuplicateRecipe('+i+')">Duplicate</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDeleteRecipe('+i+')">Delete</button></div></div>').join(''):'<div class="auto-empty">No recipes saved yet. Create one, or save a queue item as a recipe.</div>';
}
function pgAutomationEditRecipe(index){pgAutomationOpenEditor('recipe',pgAutomation.recipes[index]);}
function pgAutomationDuplicateRecipe(index){const copy=pgAutomationSnapshot(pgAutomation.recipes[index]);delete copy.id;copy.name+=' (copy)';pgAutomationOpenEditor('recipe',copy);}
async function pgAutomationDeleteRecipe(index){
 const recipe=pgAutomation.recipes[index];if(!recipe||!confirm('Delete saved recipe “'+recipe.name+'”? Queued copies remain.'))return;
 try{await pgAutomationRequest('recipes/delete',{id:recipe.id});await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationQueueAdd(){
 const value=pgAutomationValue('RecipeSelect','');if(value===''){pgAutomationNotice('Choose a saved recipe or use Add item.',true);return;}
 const recipe=pgAutomation.recipes[Number(value)];if(!recipe)return;
 pgAutomation.queue.items.push(pgAutomationSnapshot(recipe));pgAutomationSaveDraft();pgAutomationRenderQueue();
}
function pgAutomationQueueLocked(index){
 if(!pgAutomation.editingRunId)return false;
 const run=pgAutomation.current?.run;
 const first=run?.id===pgAutomation.editingRunId?Math.max(pgAutomation.firstPending,Number(run.active_item??-1)+1):pgAutomation.firstPending;
 return index<first;
}
function pgAutomationQueueDirty(){return JSON.stringify(pgAutomation.queue)!==pgAutomation.loadedQueueSnapshot;}
function pgAutomationJobSummary(item){
 const signal=item.signal_format||'sdr',cal=item.calibration||{},stages=item.stages||{},steps=[];
 const enabled=key=>pgAutomationStageEnabled(stages,key);
 if(enabled('pre_readings'))steps.push('Before readings');
 if(enabled('calibration'))steps.push(signal==='dv'?'1D LUT + DV profile':signal==='hdr10'?'1D LUT + Matrix 3D LUT':'1D LUT + '+(cal.profile_source||cal.method||'Hybrid')+' 3D LUT');
 if(enabled('post_readings'))steps.push('After readings');
 return '<div class="auto-job-summary">'+pgAutomationEscape((signal==='dv'?'Dolby Vision':signal.toUpperCase())+' · '+pgAutomationModeLabel(item.picture_mode,signal))+'<br>'+pgAutomationEscape(steps.join(' → ')||'Settings only')+'</div>';
}
function pgAutomationRenderQueue(){
 pgAutomationDragCancel?.();
 pgAutomation.queue.items.forEach(pgAutomationUpgradeReference);
 pgAutomation.queue.name=pgAutomationQueueName(pgAutomation.queue.name);
 if(!pgAutomationEl('QueueDialog').open)pgAutomationEl('QueueName').value=pgAutomation.queue.name||'TV calibration queue';
 pgAutomationEl('QueueCount').textContent=pgAutomation.queue.items.length;
 const count=pgAutomation.queue.items.length,dirty=pgAutomationQueueDirty(),reference=pgAutomation.selectedQueue==='reference-settings';
 pgAutomationEl('JobsHeading').textContent=count+' job'+(count===1?'':'s')+' in '+(pgAutomation.queue.name||'New queue');
 pgAutomationEl('QueueSaveState').textContent=pgAutomation.editingRunId?'Editing pending jobs':reference?(dirty?'Reference copy · unsaved changes':'Reference settings · copy this queue to make your own'):pgAutomation.queue.id?(dirty?'Unsaved changes':'Saved queue'):'Not saved yet';
 const save=pgAutomationEl('SaveQueueButton');save.textContent=reference?'Copy queue':pgAutomation.queue.id?'Save changes':'Save queue';save.disabled=!!pgAutomation.editingRunId||(!reference&&!!pgAutomation.queue.id&&!dirty);
 pgAutomationRenderSavedQueues();
 pgAutomationEl('QueueContext').textContent=pgAutomation.editingRunId?'Editing pending items for '+pgAutomation.editingRunId+'. Active and completed items are locked.':'';
 pgAutomationEl('SavePendingButton').style.display=pgAutomation.editingRunId?'':'none';
 pgAutomationEl('StartButton').style.display=pgAutomation.editingRunId?'none':'';
 pgAutomationEl('QueueItems').innerHTML=pgAutomation.queue.items.length?pgAutomation.queue.items.map((item,i)=>{
  const locked=pgAutomationQueueLocked(i);
  return '<div class="auto-item" data-queue-index="'+i+'"><div><span class="auto-number">'+(i+1)+'</span>'+(locked?'':'<button type="button" class="auto-reorder" aria-label="Reorder job '+(i+1)+': '+pgAutomationEscape(item.name)+'" title="Drag to reorder; arrow keys move up or down" onpointerdown="pgAutomationDragStart(event,'+i+')" onkeydown="pgAutomationReorderKey(event,'+i+')">⠿</button>')+'</div><div><strong>'+pgAutomationEscape(item.name||'Job '+(i+1))+'</strong>'+pgAutomationJobSummary(item)+'<details class="auto-job-details"><summary>Settings and targets</summary>'+pgAutomationItemSummary(item)+'</details></div><div class="auto-actions">'+(locked?'<span class="auto-muted">'+pgAutomationEscape(item.status||'Locked')+'</span>':'<button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueEdit('+i+')">Configure</button><details class="auto-menu"><summary aria-label="Actions for job '+(i+1)+'">More</summary><div class="auto-menu-panel"><button class="btn btn-sm btn-secondary" '+(i===0||pgAutomationQueueLocked(i-1)?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',-1)">Move up</button><button class="btn btn-sm btn-secondary" '+(i===pgAutomation.queue.items.length-1||pgAutomationQueueLocked(i+1)?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',1)">Move down</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueDuplicate('+i+')">Duplicate job</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueRemove('+i+')">Remove job</button></div></details>')+'</div></div>';
 }).join(''):'<div class="auto-empty"><strong>No jobs in this queue</strong><p class="auto-muted">Add a job below, or select another queue above to see its jobs.</p></div>';
}
function pgAutomationQueueEdit(index){if(!pgAutomationQueueLocked(index))pgAutomationOpenEditor('queue',pgAutomation.queue.items[index],index);}
function pgAutomationQueueDuplicate(index){const copy=pgAutomationSnapshot(pgAutomation.queue.items[index]);delete copy.id;copy.name+=' (copy)';pgAutomation.queue.items.splice(index+1,0,copy);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueRemove(index){if(pgAutomationQueueLocked(index))return;pgAutomation.queue.items.splice(index,1);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueMove(index,delta){
 const target=index+delta;
 if(!Number.isInteger(index)||!Number.isInteger(target)||index<0||index>=pgAutomation.queue.items.length||target<0||target>=pgAutomation.queue.items.length||index===target||pgAutomationQueueLocked(index)||pgAutomationQueueLocked(target))return;
 const item=pgAutomation.queue.items.splice(index,1)[0];pgAutomation.queue.items.splice(target,0,item);pgAutomationSaveDraft();pgAutomationRenderQueue();
 pgAutomationEl('ReorderStatus').textContent=item.name+' moved to job '+(target+1)+'. '+(pgAutomation.editingRunId?'Save Pending Changes to apply this order.':'Order saved in this draft.');
 return true;
}
function pgAutomationReorderKey(event,index){
 if(!['ArrowUp','ArrowDown'].includes(event.key))return;
 event.preventDefault();event.stopPropagation();const delta=event.key==='ArrowUp'?-1:1;
 if(pgAutomationQueueMove(index,delta))pgAutomationEl('QueueItems').querySelector('[data-queue-index="'+(index+delta)+'"] .auto-reorder')?.focus();
}
function pgAutomationDragStart(event,index){
 if(event.button!==0||pgAutomationQueueLocked(index))return;
 event.preventDefault();event.stopPropagation();pgAutomationDragCancel();
 const handle=event.currentTarget,queue=pgAutomation.queue,items=queue.items.slice(),row=handle.closest('[data-queue-index]');
 let slot=null,dragging=false;
 const clear=()=>pgAutomationEl('QueueItems').querySelectorAll('[data-drop]').forEach(el=>delete el.dataset.drop);
 const move=e=>{
  if(e.pointerId!==event.pointerId)return;
  if(!dragging&&Math.hypot(e.clientX-event.clientX,e.clientY-event.clientY)<5)return;
  dragging=true;row.classList.add('auto-dragging');clear();slot=null;
  const hit=document.elementFromPoint(e.clientX,e.clientY)?.closest('#pgAutomationQueueItems [data-queue-index]');
  if(hit){const target=Number(hit.dataset.queueIndex);if(!pgAutomationQueueLocked(target)){const after=e.clientY>hit.getBoundingClientRect().top+hit.getBoundingClientRect().height/2;slot=target+Number(after);hit.dataset.drop=after?'after':'before';}}
  if(e.clientY<70)window.scrollBy(0,-25);else if(e.clientY>innerHeight-70)window.scrollBy(0,25);
 };
 const cleanup=()=>{clear();row.classList.remove('auto-dragging');document.removeEventListener('pointermove',move);document.removeEventListener('pointerup',up);document.removeEventListener('pointercancel',cancel);document.removeEventListener('keydown',key);window.removeEventListener('blur',cleanup);if(handle.hasPointerCapture?.(event.pointerId))handle.releasePointerCapture(event.pointerId);pgAutomation.dragCancel=null;};
 const up=e=>{if(e.pointerId!==event.pointerId)return;const target=slot==null?null:slot-(slot>index?1:0);cleanup();if(dragging&&target!=null&&queue===pgAutomation.queue&&items.length===queue.items.length&&items.every((item,i)=>item===queue.items[i]))pgAutomationQueueMove(index,target-index);};
 const cancel=e=>{if(e.pointerId===event.pointerId)cleanup();};
 const key=e=>{if(e.key==='Escape'){e.preventDefault();cleanup();}};
 pgAutomation.dragCancel=cleanup;handle.setPointerCapture?.(event.pointerId);
 document.addEventListener('pointermove',move);document.addEventListener('pointerup',up);document.addEventListener('pointercancel',cancel);document.addEventListener('keydown',key);window.addEventListener('blur',cleanup);
}
function pgAutomationDragCancel(){pgAutomation.dragCancel?.();}
function pgAutomationNewQueue(){
 pgAutomationNameQueue('new');
}
function pgAutomationSaveSelectedQueue(){if(pgAutomation.queue.id&&!pgAutomation.editingRunId)pgAutomationQueueSave();else pgAutomationNameQueue('copy');}
function pgAutomationNameQueue(action){
 if(pgAutomation.editingRunId){pgAutomationNotice('Save pending changes before creating or renaming a queue.',true);return;}
 pgAutomation.queueNameAction=action;
 pgAutomationEl('QueueMenu').open=false;
 pgAutomationEl('QueueDialogTitle').textContent=action==='new'?'New queue':action==='copy'?'Copy queue':'Rename queue';
 pgAutomationEl('QueueName').value=action==='new'?'':(pgAutomation.queue.name||'TV calibration queue')+(action==='copy'?' (copy)':'');
 pgAutomationEl('QueueDialogHelp').textContent=action==='new'?'Create a saved queue, then add its jobs.':action==='copy'?'Save an independent copy of all '+pgAutomation.queue.items.length+' jobs. The original queue stays unchanged.':'Change the name of this queue. Its jobs stay together.';
 pgAutomationEl('QueueDialogError').textContent='';pgAutomationEl('QueueDialog').showModal();pgAutomationEl('QueueName').focus();
}
async function pgAutomationSubmitQueueName(){
 const button=pgAutomationEl('QueueDialogSave'),name=pgAutomationValue('QueueName','').trim();if(!name||button.disabled)return;
 const action=pgAutomation.queueNameAction;
 if(action==='new'&&pgAutomation.queue.items.length&&pgAutomationQueueDirty()&&!confirm('Create a new queue and leave these unsaved changes? Save or copy this queue first to keep them.'))return;
 button.disabled=true;
 try{
  const queue=action==='new'?{name,items:[]}:pgAutomationClone(pgAutomation.queue);queue.name=name;
  if(action==='copy'||action==='new')delete queue.id;
  queue.items=queue.items.map(pgAutomationSnapshot);
  const result=await pgAutomationRequest('queues',{queue});
  pgAutomation.queue={...queue,id:result.queue.id};pgAutomation.selectedQueue='saved:'+result.queue.id;pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);pgAutomation.editingRunId='';pgAutomation.firstPending=0;
  pgAutomation.queues=pgAutomation.queues.filter(q=>q.id!==result.queue.id).concat([pgAutomationClone(pgAutomation.queue)]);
  pgAutomationEl('QueueDialog').close();pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationNotice('Queue saved');await pgAutomationRefresh();
 }catch(e){pgAutomationEl('QueueDialogError').textContent=e.message;}
 finally{button.disabled=false;}
}
async function pgAutomationQueueSave(){
 if(pgAutomation.queueSaving)return;pgAutomation.queueSaving=true;
 const source=pgAutomation.queue,queue=pgAutomationClone({...source,items:source.items.map(pgAutomationSnapshot)});
 try{
  const result=await pgAutomationRequest('queues',{queue});
  if(pgAutomation.queue===source){pgAutomation.queue.id=result.queue.id;pgAutomation.selectedQueue='saved:'+result.queue.id;pgAutomation.loadedQueueSnapshot=JSON.stringify({...queue,id:result.queue.id});pgAutomationSaveDraft();}
  pgAutomationNotice('Queue saved');await pgAutomationRefresh();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.queueSaving=false;}
}
function pgAutomationRenderSavedQueues(){
 const select=pgAutomationEl('SavedQueueSelect');
 const option=(key,name,count)=>{
  const current=key===pgAutomation.selectedQueue,dirty=current&&pgAutomationQueueDirty();
  return '<option value="'+pgAutomationEscape(key)+'">'+pgAutomationEscape(current?pgAutomation.queue.name||name:name)+' · '+(current?pgAutomation.queue.items.length:count)+' jobs'+(dirty?' · unsaved':'')+'</option>';
 };
 select.innerHTML=(!pgAutomation.selectedQueue?option('',pgAutomation.queue.name||'New queue',pgAutomation.queue.items.length):'')+option('reference-settings','Reference settings',6)+pgAutomation.queues.map(queue=>option('saved:'+queue.id,pgAutomationQueueName(queue.name),(queue.items||[]).length)).join('');
 if(pgAutomation.selectedQueue&&pgAutomation.selectedQueue!=='reference-settings'&&!pgAutomation.queues.some(queue=>'saved:'+queue.id===pgAutomation.selectedQueue))select.innerHTML=option('',pgAutomation.queue.name||'Unsaved queue',pgAutomation.queue.items.length)+select.innerHTML;
 select.value=pgAutomation.selectedQueue==='reference-settings'||pgAutomation.queues.some(queue=>'saved:'+queue.id===pgAutomation.selectedQueue)?pgAutomation.selectedQueue:'';
 pgAutomationQueueSelectionChanged();
}
function pgAutomationQueueSelectionChanged(load){
 if(load){
  if(pgAutomationValue('SavedQueueSelect',''))pgAutomationLoadQueue();
  else{pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationSaveDraft();}
 }
 const value=pgAutomationValue('SavedQueueSelect',''),button=pgAutomationEl('DeleteQueueButton');
 if(button)button.disabled=value===''||value==='reference-settings';
 const reload=pgAutomationEl('ReloadQueueButton');if(reload)reload.disabled=value==='';
}
function pgAutomationLoadQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=value==='reference-settings'?pgAutomationReferenceQueue():pgAutomation.queues.find(queue=>'saved:'+queue.id===value);if(!queue)return;
 const changed=pgAutomation.editingRunId||JSON.stringify(pgAutomation.queue)!==pgAutomation.loadedQueueSnapshot;
 if(pgAutomation.queue.items.length&&changed&&!confirm('Replace this draft with queue “'+pgAutomationQueueName(queue.name)+'”? Save your current queue first to keep its edits.')){
  pgAutomationEl('SavedQueueSelect').value=pgAutomation.selectedQueue;pgAutomationQueueSelectionChanged();return;
 }
 pgAutomation.queue=pgAutomationClone(queue);pgAutomation.queue.name=pgAutomationQueueName(pgAutomation.queue.name);pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.selectedQueue=value;pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationQueueSelectionChanged();
 pgAutomationNotice('Queue loaded. Configure, reorder or remove items before starting.');
}
async function pgAutomationDeleteQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=pgAutomation.queues.find(queue=>'saved:'+queue.id===value);
 if(!queue||!confirm('Delete saved queue “'+pgAutomationQueueName(queue.name)+'”? Run history remains.'))return;
 try{await pgAutomationRequest('queues/delete',{id:queue.id});if(pgAutomation.queue.id===queue.id){delete pgAutomation.queue.id;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationSaveDraft();}await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationStageLabel(stage){
 if(stage==='greyscale-settings-verified')return 'Checking TV settings after 1D calibration';
 if(stage==='volume-settings-verified')return 'Checking TV settings after profile / LUT upload';
 return {'readiness':'Checking TV and meter','job-readiness':'Checking this job’s devices and picture mode','item-started':'Checking this job before measurements','tv-setup-verified':'Applying TV settings','pre-readings-done':'Before readings','reset-and-reapply-verified':'Resetting calibration and reapplying settings','panel-light-settled':'Setting 100% white luminance','greyscale-done':'Calibrating the 1D LUT','volume-done':'3D LUT / Dolby Vision profiling','session-closed':'Closing calibration','apply-all-done':'Applying calibration to all inputs','post-readings-done':'After readings','item-complete':'Saving job results'}[stage]||String(stage||'').replace(/-/g,' ');
}
function pgAutomationIssueText(issue){
 const raw=typeof issue==='string'?issue:issue?.message||'';
 if(/Driver error while executing the command/i.test(raw))return 'The TV rejected a calibration command. Let cleanup finish, confirm the intended signal and picture mode, then retry readiness. If it repeats, reconnect the TV and include the saved command details in the report. The TV-side cause is not yet known.';
 if(typeof issue==='string'){
  const unverified=issue.match(/^([a-z][a-z0-9-]*)-unverified$/);
  return unverified?pgAutomationStageLabel(unverified[1])+': verification incomplete. See the job’s recorded checks for details.':issue;
 }
 let message=issue.message||issue.code||issue.name;
 if(/-key-/.test(issue.name||'')&&/is not supported by the LG TV/.test(message||''))message=message.replace(/ \(matrix:.*?\)/g,'').replace(/: .+?\. Configure/,'. Configure');
 return (issue.item_number!=null?'Job '+(Number(issue.item_number)+1)+': ':'')+[pgAutomationStageLabel(issue.stage),message].filter(Boolean).join(' · ');
}
function pgAutomationFailureChecks(item,index){
 const checks=item?.failure?.stage==='job-readiness'?(item.readiness?.checks||[]).filter(check=>!check.ok&&check.level!=='warning'):[];
 return checks.length?checks.map(check=>({...check,item_number:index??check.item_number})):item?.failure?[{...item.failure,item_number:index}]:[];
}
function pgAutomationFailureHtml(run){
 const checks=(run?.items||[]).flatMap((item,index)=>pgAutomationFailureChecks(item,index));
 const issues=checks.length?checks:run?.failure?[run.failure]:[];
 if(checks.length&&run.failure&&!(run.items||[]).some(item=>item.failure?.stage===run.failure.stage&&item.failure?.message===run.failure.message))issues.push(run.failure);
 if(!issues.length)return '';
 return '<details open style="color:var(--red)"><summary>Problems requiring attention ('+issues.length+')</summary><ul class="auto-readiness-problems">'+issues.map(issue=>'<li>'+pgAutomationEscape(pgAutomationIssueText(issue))+'</li>').join('')+'</ul></details>'
  +'<details><summary>Technical details</summary><pre style="white-space:pre-wrap;overflow-wrap:anywhere">'+pgAutomationEscape(JSON.stringify({failure:run.failure,checks},null,2))+'</pre></details>';
}
function pgAutomationResuming(run){return run?.status==='starting'||(run?.status==='running'&&run.active_stage==='readiness');}
function pgAutomationTerminal(run){return /^(complete(-with-warnings)?|stopped|failed)$/.test(run?.status||'');}
function pgAutomationLogScroll(){
 const box=pgAutomationEl('Log');if(!box)return;
 if(!box.clientHeight)return; // Hidden workspaces cannot express scroll intent.
 pgAutomation.logFollow=box.scrollHeight-box.clientHeight-box.scrollTop<24;
 pgAutomationEl('LogFollowing').textContent=pgAutomation.logFollow?'Following latest':'Scroll paused';
}
function pgAutomationLogLatest(){
 pgAutomationEl('Activity').open=true;pgAutomation.logFollow=true;
 const box=pgAutomationEl('Log');box.scrollTop=box.scrollHeight;pgAutomationEl('LogFollowing').textContent='Following latest';
}
function pgAutomationRenderActivity(){
 const box=pgAutomationEl('Log');if(!box)return;
 const historical=pgAutomation.tab==='history'&&pgAutomation.historyActivity;
 const current=pgAutomation.current||{},pre=historical?null:pgAutomation.pendingChecks||current.preflight;
 const preActive=pre&&['checking','blocked','failed','interrupted'].includes(pre.status);
 const run=historical?.run||(preActive&&pgAutomationTerminal(current.run)?null:current.run);
 const scope=historical?'history:'+run.id:run?.id||pre?.id||'idle';
 if(pgAutomation.logScope!==scope){
  pgAutomation.logScope=scope;pgAutomation.logObserved=[];pgAutomation.logSignature=null;pgAutomation.logFollow=true;
  // Opening the log is a user choice. Polling, history selection and failed
  // readiness must not repeatedly expand it above the queue.
 }
 const activity=historical?historical.activity||{}:pgAutomation.pendingChecks&&current.preflight?.id!==pgAutomation.pendingChecks.id?{}:current.activity||{};
 const entries=[...(activity.entries||[])];
 if(!historical){
  // Runner/startup events are the durable source of progress. Only record
  // browser connection failures here; repeating sampled worker status hides
  // the useful events and creates a second, misleading event timestamp.
  const message=pgAutomation.statusError||'';
  const last=pgAutomation.logObserved.at(-1);
  if(message&&last?.message!==message)pgAutomation.logObserved.push({time:Date.now()/1000,level:pgAutomation.statusError?'error':'info',message,source:'Observed in browser'});
  pgAutomation.logObserved=pgAutomation.logObserved.slice(-100);
  entries.push(...pgAutomation.logObserved,...pgAutomation.logNotices);
 }
 const timestamp=entry=>typeof entry.time==='number'?entry.time*1000:Date.parse(entry.time)||0;
 entries.sort((a,b)=>timestamp(a)-timestamp(b));
 const signature=JSON.stringify([scope,entries,activity.truncated]);if(signature===pgAutomation.logSignature){
  // First render can happen while the workspace is hidden (zero layout size).
  // Follow when it becomes visible, even if no new line has arrived yet.
  if(pgAutomation.logFollow&&box.clientHeight)box.scrollTop=box.scrollHeight;
  return;
 }
 pgAutomation.logSignature=signature;
 const top=box.scrollTop,follow=pgAutomation.logFollow;
 const rows=entries.slice(-500);
 box.innerHTML=rows.length?rows.map(entry=>'<div data-level="'+(['error','warning','ok'].includes(entry.level)?entry.level:'info')+'"><time>'+pgAutomationEscape(entry.time?pgAutomationFormatTime(typeof entry.time==='number'?entry.time*1000:entry.time):'Time not recorded')+'</time> · '+pgAutomationEscape(entry.source||'Activity')+(entry.item_number!=null?' · Job '+(Number(entry.item_number)+1):'')+' · '+pgAutomationEscape(entry.message)+'</div>').join(''):'No activity yet.';
 box.scrollTop=follow?box.scrollHeight:top;
 pgAutomationEl('LogCount').textContent='· '+rows.length+' entries';
 pgAutomationEl('LogContext').textContent=(historical?'History · ':'')+(run?.queue_name||pre?.queue_name||'Startup checks and batch output');
 pgAutomationEl('LogFollowing').textContent=follow?'Following latest':'Scroll paused';
 pgAutomationEl('LogLimit').textContent=activity.truncated||entries.length>500?'Showing recent output (up to 500 entries and the latest 64 KiB of runner output). Full runner log remains saved with the run.':'Saved startup checks and runner output survive refresh. Browser observations are kept only while this page is open.';
}
async function pgAutomationClearLastRun(){
 const run=pgAutomationCurrentRun();if(!pgAutomationTerminal(run))return;
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/control/clear',{});
  pgAutomation.lastProblem='';pgAutomationNotice(result.message);await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationDismissReadiness(button){
 const pre=pgAutomation.current?.preflight;
 if(!pre?.id||pgAutomation.pendingChecks||pre.status==='checking')return;
 if(button)button.disabled=true;
 try{
  const result=await pgAutomationRequest('readiness/dismiss',{request_id:pre.id});
  pgAutomation.dismissedCheck={id:result.dismissed,started_at:pre.started_at};
  if(pgAutomation.current?.preflight?.id===result.dismissed){
   pgAutomation.current.preflight=null;pgAutomation.lastProblem='';pgAutomationEl('Readiness').innerHTML='';pgAutomationNotice('');
   pgAutomationRenderLiveRun(pgAutomation.current.run,pgAutomation.current.execution);
   pgAutomationEl('ReadinessButton').focus();
  }
  await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{if(button)button.disabled=false;}
}
function pgAutomationEstimateText(run,now){
 if(!run)return '';
 if(run.status==='paused')return 'Time estimate paused';
 if(run.status!=='running')return '';
 if(pgAutomation.statusError||run.heartbeat_age>60)return 'Time estimate unavailable — waiting for live progress';
 const eta=run.time_estimate,at=now??Date.now()/1000;
 if(!eta)return 'Estimating time remaining…';
 if(Number(eta.active_item)!==Number(run.active_item)||eta.stage!==run.active_stage)return 'Estimating time remaining…';
 const age=at-Number(eta.calculated_at),seconds=Number(eta.remaining_seconds);
 const duration=value=>{
  let minutes=Math.max(1,Math.ceil(value/60));if(minutes>=10)minutes=Math.ceil(minutes/5)*5;
  const hours=Math.floor(minutes/60),rest=minutes%60;
  return hours?hours+'h'+(rest?' '+rest+'m':''):minutes+'m';
 };
 if(eta.batch_unknown_stages!=null){
  if(!Number.isFinite(age)||age<0||age>180)return 'Updating time estimate…';
  const range=value=>{
   if(!Number.isFinite(Number(value))||Number(value)<=0)return '';
   // Only time the current stage consumes can count down; unknown stages
   // cannot consume the estimate for future work while we wait for evidence.
   const elapsed=Number(eta.stage_remaining_seconds)>0?age:0;
   const low=duration(Math.max(60,Number(value)*.75-elapsed));
   const high=duration(Math.max(60,Number(value)*1.5-elapsed));
   return '~'+low+(low===high?'':'–'+high);
  };
  const job=range(eta.job_remaining_seconds),batch=range(eta.batch_known_seconds);
  const parts=[job?'Current job: '+job+(eta.job_unknown_stages>0?' + untimed stages':' remaining'):'Current job: collecting stage timings'];
  parts.push(batch?'Batch: '+batch+(eta.batch_unknown_stages>0?' of timed work ('+eta.known_stages+'/'+eta.remaining_stages+' remaining stages estimated)':' remaining'):'Batch: collecting stage timings');
  if(eta.approximate_history)parts.push('Uses similar-job timings');
  return parts.join(' · ');
 }
 if(eta.scope==='unknown'||!['batch','stage','pass'].includes(eta.scope))return 'Estimating time remaining…';
 if(!Number.isFinite(age)||!Number.isFinite(seconds)||seconds<=0||age<0||age>180)return 'Updating time estimate…';
 const upper=seconds*1.5-age;
 if(upper<=0)return 'Updating time estimate…';
 const lower=duration(Math.max(60,seconds*.75-age)),higher=duration(upper);
 return (eta.scope==='batch'?'Estimated batch remaining: ':'Estimated current '+eta.scope+': ')+'~'+lower+(lower===higher?'':'–'+higher)
  +(eta.scope==='batch'?'':' · Batch estimate still learning');
}
function pgAutomationRunWarnings(run){
 return [...new Set([...(run?.warnings||[]).map(pgAutomationIssueText),...(run?.items||[]).flatMap((item,index)=>(item.warnings||[]).map(w=>pgAutomationIssueText({message:pgAutomationIssueText(w),item_number:index})))].filter(Boolean))];
}
function pgAutomationRunWarningsHtml(run){
 const warnings=pgAutomationRunWarnings(run);
 return warnings.length?'<details class="auto-run-warnings"><summary>'+warnings.length+' recorded warning'+(warnings.length===1?'':'s')+'</summary><ul>'+warnings.map(w=>'<li>'+pgAutomationEscape(w)+'</li>').join('')+'</ul></details>':'';
}
function pgAutomationRenderProgress(){
 const box=pgAutomationEl('Progress');if(!box)return;
 const run=pgAutomation.current?.run;
 const server=pgAutomation.current?.preflight;
 const pre=pgAutomation.pendingChecks&&server?.id!==pgAutomation.pendingChecks.id?pgAutomation.pendingChecks:server;
 const preActive=pre&&['checking','blocked','failed','interrupted'].includes(pre.status);
 const showRun=run&&(!preActive||['running','starting','stopping','completing','paused','interrupted'].includes(run.status));
 if(showRun&&pgAutomationTerminal(run)){
  box.style.display='';box.dataset.error=String(run.status==='failed'||!!pgAutomation.statusError);box.setAttribute('role',run.status==='failed'?'alert':'status');
  box.innerHTML='<strong>Last batch '+pgAutomationEscape(run.status.replace(/-/g,' '))+' · '+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Calibration queue')+'</strong><p class="auto-muted">No calibration is running. Jobs and results are saved in History.</p>'
   +(run.status==='failed'?pgAutomationFailureHtml(run):'')
   +(pgAutomation.statusError?'<p>'+pgAutomationEscape(pgAutomation.statusError)+'</p>':'')
   +pgAutomationRunWarningsHtml(run)
   +'<button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationClearLastRun()">Clear last batch</button>';
  return;
 }
 let title='',message='',issues=[],completed=0,total=0,error=false;
 if(showRun){
  const items=run.items||[],index=run.active_item==null?-1:Number(run.active_item);total=items.length;
  completed=items.filter(item=>/^complete(?:-with-warnings)?$/.test(item.status)).length;
  title=(index>=0?'Job '+(index+1)+' of '+total+': '+(items[index]?.name||''):(run.queue_name||'Queue'))+' · '+run.status;
  message=[pgAutomationStageLabel(run.active_stage),run.worker_status?.current_name,run.worker_status?.message].filter(Boolean).join(' · ');
  if(run.worker_status?.total_steps)message+=' · Patch '+(run.worker_status.current_step||0)+' / '+run.worker_status.total_steps;
  if(run.stage_started_at&&['running','starting','stopping','completing'].includes(run.status))message+=' · '+Math.max(0,Math.floor(Date.now()/1000-run.stage_started_at))+' s in this stage';
  if(run.failure){
   error=true;
   // The runner saves the same stage failure on both the job and the run.
   // Attach its job context before deduplication, retaining separate causes.
   const itemFailure=items[index]?.failure;
   const sameFailure=itemFailure&&pgAutomationIssueText({...run.failure,item_number:null})===pgAutomationIssueText({...itemFailure,item_number:null});
   issues.push(sameFailure?{...run.failure,item_number:index}:run.failure);
  }
  items.forEach((item,i)=>{if(item.failure){if(pgAutomationResuming(run))issues.push({message:'Previous attempt: '+pgAutomationIssueText(item.failure),item_number:i});else{error=true;issues.push({...item.failure,item_number:i});}}(item.warnings||[]).forEach(w=>issues.push({message:pgAutomationIssueText(w),item_number:i,level:'warning'}));});
  error=error||['failed','interrupted'].includes(run.status);
  if(error&&!issues.length)issues.push({message:'Run '+run.status+'. Open Live Run or History for its saved checkpoints.'});
  if(run.heartbeat_age>60&&['running','starting','stopping','completing'].includes(run.status))issues.push({message:'No runner heartbeat for '+run.heartbeat_age+' seconds. Progress is unconfirmed; do not start a second run.'});
 }else if(pre){
  total=pre.total_items||0;completed=(pre.items||[]).filter(item=>item.status==='checked').length;
  title=pre.status==='checking'?'Checking '+(pre.active_item==null?'TV and meter':'job '+(Number(pre.active_item)+1)+' of '+total):pre.status==='ready'?'Last readiness check passed':pre.status==='started'?'Launching calibration runner':'Last readiness check did not pass';
  message=(pre.queue_name?pre.queue_name+' · ':'')+(pre.message||'')+(pre.elapsed_seconds!=null?' · '+pre.elapsed_seconds+' s elapsed':'');
  issues=pre.issues||[];error=['blocked','failed','interrupted'].includes(pre.status)||issues.some(issue=>issue.level==='error');
 }else if(!pgAutomation.lastProblem&&!pgAutomation.statusError){box.style.display='none';return;}
 if(pgAutomation.statusError){error=true;issues=[{message:pgAutomation.statusError},...issues];}
 if(pgAutomation.lastProblem){error=true;issues=[{message:pgAutomation.lastProblem},...issues];}
 if(showRun&&!pgAutomationResuming(run)&&(run.items||[]).some(item=>item.failure?.stage==='job-readiness'&&item.readiness?.checks?.length)){
  const checks=(run.items||[]).flatMap((item,index)=>pgAutomationFailureChecks(item,index));
  if(checks.length)issues=[...checks,...issues.filter(issue=>issue.level==='warning')];
 }
 box.style.display='';box.dataset.error=String(error);box.setAttribute('role',error?'alert':'status');
 const unique=[...new Set(issues.map(pgAutomationIssueText).filter(Boolean))];
 box.innerHTML='<strong>'+pgAutomationEscape(title||(error?'Automation needs attention':'Automation'))+'</strong><div class="auto-muted">'+pgAutomationEscape(message)+'</div>'
  +(total?'<progress aria-label="'+(showRun?'Completed jobs':'Validated queue configurations')+'" value="'+completed+'" max="'+total+'"></progress><div class="auto-muted auto-progress-footer"><span>'+completed+' / '+total+' '+(showRun?'jobs complete':'queue configurations validated; TV settings checked per job')+'</span>'
   +(showRun?'<span data-automation-eta title="Rough estimate from live patch pace and comparable saved stage timings. Recalculated every two minutes and when the stage changes. Calibration speed varies; the range is not a guarantee.">'+pgAutomationEscape(pgAutomationEstimateText(run))+'</span>':'')+'</div>':'')
  +(unique.length?'<details '+(error?'open':'')+'><summary>'+(error?'Problems requiring attention':'Warnings and manual checks')+' ('+unique.length+')</summary><div class="auto-issues">'+unique.map(text=>'<p class="auto-muted"'+(issues.some(issue=>pgAutomationIssueText(issue)===text&&issue.level==='warning')?' data-level="warning"':'')+'>'+pgAutomationEscape(text)+'</p>').join('')+'</div></details>':'')
  +(!showRun&&pre?.id&&['ready','blocked','failed','interrupted'].includes(pre.status)?'<p class="auto-muted">This is a saved check result, not an active calibration lock. After correcting the issue, check again or dismiss this result. Dismissing does not bypass future safety checks.</p><button id="pgAutomationDismissReadiness" type="button" class="btn btn-sm btn-secondary" onclick="pgAutomationDismissReadiness(this)">Dismiss previous check</button>':'');
}
function pgAutomationBeginChecks(intent){
 const id='ui-'+Date.now()+'-'+Math.random().toString(36).slice(2,10);
 pgAutomation.lastProblem='';pgAutomation.statusError='';
 pgAutomation.pendingChecks={id,status:'checking',intent,queue_name:pgAutomation.queue.name,total_items:pgAutomation.queue.items.length,message:'Waiting for the generator to begin startup checks. No calibration has started.',items:[]};
 pgAutomationRenderProgress();pgAutomationRenderActivity();pgAutomationPollLive();return id;
}
function pgAutomationRenderReadiness(result){
 const box=pgAutomationEl('Readiness');if(!result){box.textContent='Readiness request failed';return;}
 const checks=[...(result.checks||[])].sort((a,b)=>Number(a.ok)-Number(b.ok));
 const problems=checks.filter(check=>!check.ok);
 box.innerHTML='<p class="auto-muted">'+pgAutomationEscape(result.message||'Readiness')+' · '+checks.length+' checks. See the activity log for details.</p>'
  +(problems.length?'<ul class="auto-readiness-problems">'+problems.map(check=>'<li data-level="'+(check.level==='warning'?'warning':'error')+'">'+pgAutomationEscape(pgAutomationIssueText(check))+'</li>').join('')+'</ul>':'');
 pgAutomation.current={...pgAutomation.current,activity:{entries:checks.map(check=>({...check,source:'Startup check',level:check.ok?'ok':check.level||'error'}))}};pgAutomationRenderActivity();
 box.scrollIntoView({block:'nearest'});
}
async function pgAutomationReadiness(){
 if(pgAutomation.pendingChecks||pgAutomation.busy||pgAutomation.current?.preflight?.status==='checking')return;
 if(!pgAutomation.queue.items.length){pgAutomationNotice('Add a job before checking readiness. No device checks were started.');return;}
 const button=pgAutomationEl('ReadinessButton');button.disabled=true;button.textContent='Checking TV and Meter…';
 const request_id=pgAutomationBeginChecks('readiness');
 try{pgAutomationRenderReadiness(await pgAutomationRequest('readiness',{scope:'preview',items:pgAutomation.queue.items,queue_name:pgAutomation.queue.name,request_id},300000));}catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.pendingChecks=null;button.disabled=false;button.textContent='Check Readiness';await pgAutomationPollLive();}
}
async function pgAutomationStart(){
 if(pgAutomation.busy||pgAutomation.pendingChecks||pgAutomation.current?.preflight?.status==='checking')return;if(!pgAutomation.queue.items.length){pgAutomationNotice('Add a job before running the queue. No calibration was started.');return;}
 pgAutomation.busy=true;pgAutomationEl('StartButton').disabled=true;pgAutomationEl('StartButton').textContent='Checking and Starting…';
 pgAutomationSaveDraft();
 const request_id=pgAutomationBeginChecks('start');
 try{
  const result=await pgAutomationRequest('runs/start',{queue:pgAutomation.queue,request_id},300000);
  if(!result.run_id){pgAutomationRenderReadiness(result);throw new Error(result.message||'Batch did not start');}
  pgAutomationNotice('Batch started');await pgAutomationRefresh();pgAutomationTab('live');
 }catch(e){pgAutomationNotice(e.message+' No new run is confirmed. Check the status above before retrying.',true);}
 finally{pgAutomation.pendingChecks=null;pgAutomation.busy=false;pgAutomationEl('StartButton').disabled=false;pgAutomationEl('StartButton').textContent='Run queue';await pgAutomationPollLive();}
}
function pgAutomationCurrentRun(){return pgAutomation.current?.run||null;}
async function pgAutomationControl(action){
 const run=pgAutomationCurrentRun();if(!run)return;
 try{const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/control/'+action,{},300000);if(result.ready===0){pgAutomationRenderReadiness(result);pgAutomationTab('queue');throw new Error(result.message);}if(result.run){pgAutomation.current={...pgAutomation.current,run:result.run};pgAutomationRenderLiveRun(result.run,pgAutomation.current.execution);}pgAutomationNotice(result.message);await pgAutomationPollLive();}catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationLoadActiveQueue(){
 const run=pgAutomationCurrentRun();if(!run){pgAutomationNotice('No active batch to edit.',true);return;}
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/edit');
  pgAutomation.queue={name:run.queue_name,items:result.items};pgAutomation.editingRunId=run.id;pgAutomation.firstPending=result.first_pending;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationRenderSavedQueues();
  pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
 }catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationEditActiveQueue(){
 if(!pgAutomation.editingRunId)return;
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(pgAutomation.editingRunId)+'/edit',{first_pending:pgAutomation.firstPending,items:pgAutomation.queue.items.slice(pgAutomation.firstPending)});
  pgAutomationNotice(result.warning?'Pending changes saved. '+result.warning:'Pending changes saved',result.warning?'warning':false);await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message+' Reload pending items if the batch has advanced.',true);}
}
function pgAutomationRenderLiveRun(run,execution){
 pgAutomationSyncCalibrationView(run);
 pgAutomationRenderActivity();
 const pre=pgAutomation.current?.preflight,checking=pgAutomation.pendingChecks||pre?.status==='checking';
 const status=run?.status||(checking?'checking':'idle');pgAutomationStateBadge(status);pgAutomationRenderProgress();
 const occupied=checking||['starting','running','paused','interrupted','stopping','completing'].includes(run?.status);
 pgAutomationEl('StartButton').disabled=!!(occupied||pgAutomation.busy);
 pgAutomationEl('ReadinessButton').disabled=!!(occupied||pgAutomation.pendingChecks);
 const reason=checking?'Readiness checks are in progress.':occupied?'The previous batch is '+run.status+'. Open Live Run to resume it or Stop it before starting a new queue.':pgAutomation.busy?'A start request is in progress.':'';
 for(const id of ['StartButton','ReadinessButton'])pgAutomationEl(id).title=reason;
 const blocker=pgAutomationEl('ActionBlocker');
 if(blocker){blocker.hidden=!reason;blocker.innerHTML=pgAutomationEscape(reason)+(occupied&&!checking?' <button type="button" class="btn btn-sm btn-secondary" onclick="pgAutomationTab(\'live\')">Open Live Run</button>':'');}
 pgAutomationEl('PauseButton').disabled=status!=='running';pgAutomationEl('ResumeButton').disabled=!['paused','interrupted'].includes(status);
 pgAutomationEl('StopButton').disabled=!['starting','running','paused','interrupted','stopping','completing'].includes(status);
 const live=pgAutomationEl('Live');
 if(!run){live.innerHTML='<div class="auto-empty">'+(checking?'Checking TV/meter availability and queue configuration. Each job checks its own TV settings after selecting its signal and picture mode.':pre&&['blocked','failed','interrupted'].includes(pre.status)?'Calibration has not started. Resolve the startup problems shown above, then retry.':'No active batch. Completed and stopped runs are in History.')+'</div>';pgAutomationEl('LiveDetail').innerHTML='';delete pgAutomation.jobViews.live;return;}
 const terminal=pgAutomationTerminal(run),active=run.active_item!=null?Number(run.active_item):-1,items=run.items||[],worker=terminal?{}:run.worker_status||{};
 if(terminal){
  live.innerHTML='<h3>Last batch · '+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Batch')+'</h3><p class="auto-muted">'+pgAutomationEscape(status.replace(/-/g,' '))+' · Nothing is running. Results remain available below and in History.</p>'
   +pgAutomationRunWarningsHtml(run)
   +items.map((item,i)=>pgAutomationJobButton(item,i,'live',run.id,false)).join('');
  if(pgAutomation.tab==='live')pgAutomationSyncLiveDetail(run);return;
 }
  live.innerHTML='<h3>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Batch')+' · '+pgAutomationEscape(status)+'</h3>'
  +'<p class="auto-muted">'+(active>=0?'Job '+(active+1)+' of '+items.length+' · ':'')+pgAutomationEscape(pgAutomationStageLabel(run.active_stage||'Between stages'))+'</p>'
  +'<p>'+pgAutomationEscape(worker.current_name||worker.message||'')+(worker.total_steps?' · '+Number(worker.current_step||0)+' / '+Number(worker.total_steps):'')+'</p>'
  +pgAutomationFailureHtml(run)
  +(['starting','running','completing','stopping'].includes(status)&&run.heartbeat_age!=null&&run.heartbeat_age>60?'<p style="color:var(--orange)">No heartbeat for '+Number(run.heartbeat_age)+' s. If the runner has stopped, the next status check marks this run interrupted.</p>':'')
  +'<p class="auto-muted">Saved checkpoint: '+pgAutomationEscape(run.checkpoint||'none')+' · Heartbeat '+pgAutomationEscape(run.heartbeat_age==null?'pending':run.heartbeat_age+'s ago')+'</p>'
  +items.map((item,i)=>pgAutomationJobButton(item,i,'live',run.id,i===active)).join('');
 if(pgAutomation.tab==='live')pgAutomationSyncLiveDetail(run);
}
async function pgAutomationPollLive(){
 if(pgAutomation.polling)return;pgAutomation.polling=true;
 try{
  const result=await fetchJSON('/api/automation/runs/current',{_quiet:true,_timeoutMs:8000});
  if(result&&result.status!=='error'){
   if(pgAutomation.dismissedCheck&&result.preflight?.id===pgAutomation.dismissedCheck.id&&result.preflight?.started_at===pgAutomation.dismissedCheck.started_at&&result.preflight?.status!=='checking')result.preflight=null;
   if(pgAutomation.current?.preflight?.id&&!result.preflight&&!pgAutomation.pendingChecks)pgAutomationEl('Readiness').innerHTML='';
   pgAutomation.statusError='';pgAutomation.current=result;pgAutomationRenderLiveRun(result.run,result.execution);
  }
  else{pgAutomation.statusError='Cannot refresh run status. Showing the last known state; progress is unconfirmed. Do not start another run.';pgAutomationRenderProgress();}
 }catch(e){pgAutomation.statusError='Run status connection failed: '+e.message+'. Showing the last known state.';pgAutomationRenderProgress();
 }finally{
  pgAutomationRenderActivity();
  pgAutomationSyncCalibrationView(pgAutomation.current?.run);
  pgAutomation.polling=false;
  if(pgAutomation.liveTimer)clearTimeout(pgAutomation.liveTimer);
  // Poll fast while a runner should be alive or the Live tab is showing;
  // otherwise a slow poll keeps the header badge honest about a batch started
  // from another browser (and gives the daemon its dead-runner check).
  const status=pgAutomation.current?.run?.status||'';
  const fast=pgAutomation.pendingChecks||pgAutomation.current?.preflight?.status==='checking'||pgAutomation.tab==='live'||['starting','running','completing','stopping'].includes(status);
  pgAutomation.liveTimer=setTimeout(()=>{pgAutomation.liveTimer=null;pgAutomationPollLive();},fast?3000:30000);
 }
}
function pgAutomationHistorySummary(run,index){
 return '<div class="auto-history-row"><div><strong>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Automation queue')+'</strong><small>'+pgAutomationEscape(pgAutomationFormatTime(run.created_at_iso)||run.id||'')+' · '+pgAutomationEscape((run.status||'').replace(/-/g,' '))+'</small>'+(run.status==='complete-with-warnings'?'<p class="auto-warning-note">Completed with warnings. Open the run for details.</p>':'')+(run.failure?'<p style="color:var(--red)">'+pgAutomationEscape(pgAutomationIssueText(run.failure))+'</p>':'')+'</div><div class="auto-actions"><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationOpenHistory('+index+')">Open</button><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationDeleteRun('+index+')">Delete</button></div></div>';
}

function pgAutomationRenderHistoryList(){
 const el=document.getElementById('pgAutomationHistoryList');
 if(el)el.innerHTML=(pgAutomation.historyError?'<p role="alert">'+pgAutomationEscape(pgAutomation.historyError)+' <button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationRefresh()">Retry</button></p>':'')
  +(pgAutomation.history.length?pgAutomation.history.map(pgAutomationHistorySummary).join(''):pgAutomation.historyError?'':'No automation history.');
}

async function pgAutomationOpenHistory(index){
 const summary=pgAutomation.history[index];
 if(!summary)return;
 const request=pgAutomation.historyRequest=(pgAutomation.historyRequest||0)+1;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(summary.id),{_quiet:true,_timeoutMs:30000});
 if(request!==pgAutomation.historyRequest)return;
 const run=result&&result.run;
 if(!run){pgAutomationNotice((result&&result.message)||'Unable to load automation history',true);return;}
 pgAutomation.currentHistoryRunId=run.id||summary.id||'';
 pgAutomation.historyActivity={run,activity:result.activity||{}};pgAutomationRenderActivity();
 const detail=document.getElementById('pgAutomationHistoryDetail');
 if(!detail)return;
 delete pgAutomation.jobViews.history;
 detail.innerHTML='<h3>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Automation queue')+' · '+pgAutomationEscape((run.status||'').replace(/-/g,' '))+'</h3>'
  +pgAutomationRunWarningsHtml(run)
  +pgAutomationFailureHtml(run)
  +'<button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationRecoverQueue()">Copy this run to an editable queue</button><p class="auto-muted">Recovers the jobs saved on the Pi, including failed runs. Does not resume or start calibration.</p>'
  +(Array.isArray(run.hazard_restore_failures)&&run.hazard_restore_failures.length?'<div style="color:var(--red);margin-bottom:8px">TV protections were not restored: '+pgAutomationEscape(run.hazard_restore_failures.map(x=>typeof x==='string'?x:(x.key||'')+(x.message?' ('+x.message+')':'')).join(', '))+'. Check the TV\'s energy saving, screen saver and power-off settings.</div>':'')
  +'<div class="auto-job-layout"><div id="pgAutomationHistoryJobs">'+(run.items||[]).map((item,i)=>pgAutomationJobButton(item,i,'history',run.id,false)).join('')+'</div><aside id="pgAutomationHistoryJobDetail" class="auto-job-detail" aria-label="Selected historical job details"></aside></div>';
 if(run.items?.length)pgAutomationSelectJob('history',run.id,0);
}
async function pgAutomationRecoverQueue(){
 const run=pgAutomation.historyActivity?.run;if(!Array.isArray(run?.items)||!run.items.length)return;
 if(pgAutomation.queue.items.length&&!confirm('Replace the current draft with a copy of this run? Save your draft first if you want to keep it.'))return;
 const before=JSON.stringify(pgAutomation.queue);
 let result;
 try{result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/queue');if(!Array.isArray(result.queue?.items))throw new Error('Saved queue is unavailable.');if(before!==JSON.stringify(pgAutomation.queue))throw new Error('Your draft changed while loading. Retry recovery to replace it.');}
 catch(e){pgAutomationNotice(e.message,true);return;}
 pgAutomation.queue={name:pgAutomationQueueName(result.queue.name)||'Recovered queue',items:result.queue.items.map(pgAutomationSnapshot)};
 pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';
 pgAutomationSaveDraft();pgAutomationRenderSavedQueues();pgAutomationRenderQueue();pgAutomationTab('queue');
 pgAutomationNotice('Jobs recovered from the Pi. Review and Save queue to keep a named copy. Nothing has started.');
}

function pgAutomationJobButton(item,index,view,runId,active){
 const selected=pgAutomation.jobViews[view];
 const status=pgAutomationJobStatus(item,view==='live'?pgAutomation.current?.run?.status:null);
 return '<button type="button" class="auto-job-pick '+(active?'auto-run-current':'')+'" data-job-index="'+index+'" aria-pressed="'+!!(selected?.runId===runId&&selected.index===index)+'" '+(active?'aria-current="step"':'')+' onclick="pgAutomationSelectJob(\''+view+'\',\''+pgAutomationEscape(runId)+'\','+index+')"><strong>'+(index+1)+'. '+pgAutomationEscape(item.name||'Job')+'</strong><small>'+pgAutomationEscape(status)+(active?' · Current job':'')+'</small>'+(item.failure?'<small>'+pgAutomationEscape(pgAutomationIssueText(item.failure))+'</small>':'')+'</button>';
}
function pgAutomationJobStatus(item,runStatus){return item.status==='running'&&['paused','interrupted','stopped','failed'].includes(runStatus)?runStatus:item.status||'queued';}
function pgAutomationJobFailureHtml(item){
 if(!item?.failure)return '';
 if(item.failure.message)return pgAutomationFailureHtml({items:[item],failure:item.failure});
 const cancelled=item.status==='stopped'&&item.failure.status==='interrupted'&&!item.failure.message&&!item.failure.error_code;
 return '<p style="color:var('+(cancelled?'--text2':'--red')+')">'+(cancelled?'Stopped during ':'')+pgAutomationEscape(pgAutomationIssueText(item.failure))+'</p>';
}
function pgAutomationSyncLiveDetail(run){
 if(!run?.items?.length)return;
 if(pgAutomation.liveSelection?.runId!==run.id){pgAutomation.followLive=true;pgAutomation.liveSelection=null;}
 const index=pgAutomation.followLive?Math.max(0,Math.min(Number(run.active_item??0),run.items.length-1)):pgAutomation.liveSelection.index;
 pgAutomationShowJob('live',run.id,index);
}
function pgAutomationSelectJob(view,runId,index){
 if(view==='live'){pgAutomation.followLive=false;pgAutomation.liveSelection={runId,index};}
 pgAutomationShowJob(view,runId,index,true);
}
function pgAutomationBackToLive(){pgAutomation.followLive=true;pgAutomationSyncLiveDetail(pgAutomation.current?.run);}
function pgAutomationJobTarget(view){return pgAutomationEl(view==='calibration'?'CalibrationDetail':view==='live'?'LiveDetail':'HistoryJobDetail');}
function pgAutomationCalibrationOccupied(run){return !!run&&['starting','running','paused','interrupted','stopping','completing'].includes(run.status);}
function pgAutomationOpenRun(){
 if(typeof pgSelectDesktopWorkspace==='function')pgSelectDesktopWorkspace('automation');
 pgAutomationTab('live');
 pgAutomationBackToLive();
 document.getElementById('automationCard')?.scrollIntoView({behavior:'smooth',block:'start'});
 const live=pgAutomationEl('Live'),run=pgAutomation.current?.run,index=Math.max(0,Math.min(Number(run?.active_item||0),(run?.items?.length||1)-1));
 (live?.querySelector('[aria-current="step"]')||live?.querySelector('[data-job-index="'+index+'"]')||document.querySelector('[data-auto-tab="live"]'))?.focus({preventScroll:true});
}
function pgAutomationSyncCalibrationView(run){
 const card=pgAutomationEl('CalibrationCard'),meter=document.getElementById('meterCard');
 if(!card||!meter)return;
 const occupied=pgAutomationCalibrationOccupied(run);
 if(occupied){
  if(!pgAutomation.calibrationObserver){pgAutomation.meterWasInert=meter.inert;}
  pgAutomation.calibrationObserver=run.id;
 }
 if(!run||pgAutomation.calibrationObserver!==run.id){pgAutomationReleaseCalibrationView(true);return;}
 card.style.display='';meter.inert=true;document.body.classList.add('pg-automation-calibration-observer');
 const badge=pgAutomationEl('CalibrationBadge');
 badge.dataset.state=run.status;
 badge.textContent='Automation '+({running:'active',starting:'starting',paused:'paused',interrupted:'interrupted',stopping:'stopping',completing:'finishing',complete:'complete','complete-with-warnings':'complete with warnings',stopped:'stopped',failed:'failed'}[run.status]||run.status)+' · Read-only';
 const index=Math.max(0,Math.min(Number(run.active_item??0),(run.items?.length||1)-1)),item=run.items?.[index],worker=pgAutomationTerminal(run)?{}:run.worker_status||{};
 const terminal=pgAutomationTerminal(run),esc=pgAutomationEscape;
 const stage=terminal?({stopped:'Run stopped',failed:'Run failed',complete:'Run complete','complete-with-warnings':'Run complete with warnings'}[run.status]||'Saved results'):pgAutomationStageLabel(run.active_stage||'Preparing job');
 const held=['paused','interrupted'].includes(run.status);
 const detail=[held?(run.status==='paused'?'Paused':'Interrupted'):null,stage,!terminal&&worker.current_name,!terminal&&worker.total_steps?(held?'Last patch ':'Patch ')+Number(worker.current_step||0)+' / '+worker.total_steps:null].filter(Boolean).join(' · ');
 const progress='<div class="auto-observer-eyebrow">Job '+(index+1)+' of '+(run.items?.length||0)+(terminal?' · Saved results':'')+'</div><h3 class="auto-observer-title">'+esc(item?.name||'Preparing job')+'</h3><p class="auto-observer-stage">'+esc(detail)+'</p>'+(!terminal&&worker.message?'<p class="auto-observer-activity">'+(held?'Last activity: ':'')+esc(worker.message)+'</p>':'');
 const progressEl=pgAutomationEl('CalibrationProgress');if(progressEl.innerHTML!==progress)progressEl.innerHTML=progress;
 pgAutomationEl('CalibrationHelp').textContent=pgAutomation.statusError|| ({complete:'Saved results for this completed run.','complete-with-warnings':'Measurements saved. Review the warnings in Automation.',stopped:'Run stopped. Saved measurements may be partial.',failed:'Run failed. Any saved measurements may be partial.',paused:'Batch paused. Resume or stop the run in Automation.',interrupted:'Batch interrupted. Review the run in Automation before continuing.'}[run.status]||'Read-only view of the active batch. Manage the run in Automation.');
 pgAutomationEl('CalibrationRelease').style.display=occupied?'none':'';
 if(typeof pgSyncDesktopPanels==='function')pgSyncDesktopPanels();
 const state=pgAutomation.jobViews.calibration;
 if(state&&(state.stage!==run.active_stage||state.runStatus!==run.status)){
  state.data=null;state.graphSignature=null;state.lastFetch=0;state.stage=run.active_stage;
  pgAutomationJobTarget('calibration').querySelector('[data-job-graphs]').textContent='Waiting for measurements from '+pgAutomationStageLabel(run.active_stage||'the next stage')+'.';
 }
 if(item&&card.getClientRects().length){
  pgAutomationShowJob('calibration',run.id,index);
  if(pgAutomation.jobViews.calibration){pgAutomation.jobViews.calibration.stage=run.active_stage;pgAutomation.jobViews.calibration.runStatus=run.status;}
 }
}
function pgAutomationReleaseCalibrationView(force=false){
 if(!force&&pgAutomationCalibrationOccupied(pgAutomation.current?.run))return;
 const card=pgAutomationEl('CalibrationCard'),meter=document.getElementById('meterCard');
 if(card)card.style.display='none';
 if(meter&&pgAutomation.calibrationObserver)meter.inert=!!pgAutomation.meterWasInert;
 pgAutomation.calibrationObserver=null;delete pgAutomation.jobViews.calibration;
 document.body.classList.remove('pg-automation-calibration-observer');
 if(typeof pgSyncDesktopPanels==='function')pgSyncDesktopPanels();
}
function pgAutomationShowJob(view,runId,index,force=false){
 const target=pgAutomationJobTarget(view);if(!target)return;
 let state=pgAutomation.jobViews[view];
 if(!state||state.runId!==runId||state.index!==index){
  state={runId,index,showBefore:true,showAfter:true,lastFetch:0};pgAutomation.jobViews[view]=state;
  target.innerHTML='<div class="auto-toolbar" data-job-nav></div><div data-job-meta>Loading job details…</div><div data-job-error role="status"></div><div data-job-settings></div><div data-job-toggles></div><div data-job-measurement role="status"></div><div data-job-graphs></div>';
 }
 const list=view==='calibration'?null:pgAutomationEl(view==='live'?'Live':'HistoryJobs');
 list?.querySelectorAll('[data-job-index]').forEach(button=>button.setAttribute('aria-pressed',String(Number(button.dataset.jobIndex)===index)));
 const saved=view!=='live'||pgAutomationTerminal(pgAutomation.current?.run);
 target.querySelector('[data-job-nav]').innerHTML=view==='live'&&!saved&&!pgAutomation.followLive?'<button class="btn btn-sm btn-primary" onclick="pgAutomationBackToLive()">Back to live job</button>':'<span class="auto-muted">'+(saved?'Saved job results':'Following live job')+'</span>';
 if(!state.loading&&(force||Date.now()-state.lastFetch>(view==='calibration'?2500:10000)))pgAutomationFetchJob(view,state);
}
async function pgAutomationFetchJob(view,state){
 state.loading=true;state.lastFetch=Date.now();
 try{
  const data=await fetchJSON('/api/automation/runs/'+encodeURIComponent(state.runId)+'/jobs/'+state.index,{_quiet:true,_timeoutMs:15000});
  if(pgAutomation.jobViews[view]!==state)return;
  if(!data||data.status!=='ok')throw new Error(data?.message||'No job details returned');
  if(view==='calibration'&&data.active_stage!==pgAutomation.current?.run?.active_stage)return;
  state.data=data;
  const target=pgAutomationJobTarget(view),item=data.item;
  const measurement=target.querySelector('[data-job-measurement]');
  if(measurement){
   const snap=data.live?.snapshot,retry=snap?.measurement_retry;
   const timestamps=(snap?.readings||[]).filter(r=>!r.null_read).map(r=>Number(r.timestamp)).filter(t=>Number.isFinite(t)&&t>0);
   measurement.style.color=retry?'var(--orange)':'';
   measurement.textContent=retry?'Retrying invalid measurement · '+(snap.message||retry.reason)+'. Graphs retain the last measurements.':snap?[snap.message,timestamps.length?'Last valid measurement '+new Date(Math.max(...timestamps)*1000).toLocaleTimeString():null].filter(Boolean).join(' · '):'';
  }
  target.querySelector('[data-job-error]').textContent='';
  const meta=target.querySelector('[data-job-meta]'),configExpanded=meta.querySelector('details')?.open;
  meta.innerHTML=(view==='calibration'?'':'<h3>'+pgAutomationEscape(item.name||'Job '+(state.index+1))+'</h3><p class="auto-muted">'+pgAutomationEscape(pgAutomationJobStatus(item,data.run_status))+' · Results updated '+new Date(data.fetched_at*1000).toLocaleTimeString()+'</p>')+pgAutomationJobFailureHtml(item)+'<details><summary>Configured settings and targets</summary>'+pgAutomationItemSummary(item)+'</details>';
  if(configExpanded)meta.querySelector('details').open=true;
  const settings=target.querySelector('[data-job-settings]'),expanded=settings.querySelector('details')?.open;
  const manualChecks=[...new Set([...(item.manual_checks||[]),...(data.readiness_issues||[]).map(issue=>issue.message).filter(Boolean)])];
  settings.innerHTML=pgAutomationApplyAllNote(item)+pgAutomationSettingsEvidence(data.checks||[],{...item,manual_checks:manualChecks});
  if(expanded&&settings.querySelector('details'))settings.querySelector('details').open=true;
  const before=(data.snapshots||[]).some(s=>s.phase==='pre'&&s.snapshot?.readings?.length)||(data.live?.phase==='pre'&&data.live.snapshot?.readings?.length);
  target.querySelector('[data-job-toggles]').innerHTML=(before?'<label><input type="checkbox" '+(state.showBefore?'checked':'')+' onchange="pgAutomationGraphToggle(\''+view+'\',\'showBefore\',this.checked)"> Before</label> ':'')+'<label><input type="checkbox" '+(state.showAfter?'checked':'')+' onchange="pgAutomationGraphToggle(\''+view+'\',\'showAfter\',this.checked)"> '+(/^complete/.test(item.status||'')?'Final':'Latest / after')+'</label>';
  await pgAutomationRenderJobGraphs(view,state);
 }catch(e){if(pgAutomation.jobViews[view]===state)pgAutomationJobTarget(view).querySelector('[data-job-error]').textContent=state.data?'Unable to refresh job details: '+e.message+'. Any displayed results are the last received, not confirmed current.':'Unable to load job details: '+e.message+'. No measurements have been loaded for this job. The next status check will retry.';}
 finally{state.loading=false;}
}
function pgAutomationApplyAllNote(item){
 const apply=item?.['apply-all'];
 if(apply?.outcome!=='sent-unconfirmed'||!apply.confirmation_unavailable)return '';
 return '<p class="auto-muted">Apply to All Inputs sent — confirmation unavailable on this TV.</p>';
}
function pgAutomationSettingReason(check){
 if(check.reason)return String(check.reason)+(check.error_code?' ('+check.error_code+')':'');
 if(check.result==='expected-calibration-state')return 'Expected LG calibration state: Auto requested for setup, Wide reported after calibration. Retained for diagnostics; no gamut rewrite is required.';
 if(check.result==='lut-managed')return 'The uploaded calibration LUT controls this setting; the requested menu value is retained as the pre-calibration setup.';
 if(check.result==='readback-warning')return 'LG reported Wide for requested Auto. Continuing with a warning; the two values are not confirmed equivalent.';
 if(check.verified)return 'TV readback matched at this check.';
 if(check.result==='apply-failed')return 'Setting write failed; this older record did not save the driver reason.';
 if(check.result==='unverifiable')return 'Readback could not be verified. This older record does not say whether the control was unsupported or unavailable in this mode. Check the TV menu.';
 if(check.observed==null)return 'No TV-reported value was saved. The reason was not recorded; this does not prove the write failed.';
 return 'TV-reported value differs from the requested value.';
}
function pgAutomationCheckStage(check){
 const key=check.point||check.checkpoint||check.stage||'';
 if(key==='dv-profile-before-upload')return 'After Dolby Vision profile measurements, before upload';
 if(/^3d-processing-transition-\d+$/.test(key))return 'After calibration transition, before further measurements';
 if(key==='resume-profile-baseline')return 'Saved 1D and unity baseline restored before profile retry';
 if(key.endsWith('-mode'))return 'Picture mode confirmation before settings · '+(key.slice(0,-5));
 const boundary=key.match(/^c([678])(?:-(confirm|repair|stable))?$/);
 if(boundary)return ({6:'After 1D calibration',7:'After profile / LUT upload, before calibration exit',8:'After calibration exit'})[boundary[1]]+({confirm:' · fresh confirmation',repair:' · targeted repair',stable:' · stability check'}[boundary[2]]||'');
 return ({c1:'TV setup',c4:'After reset and reapply',c5:'White luminance setup','c5-panel-iteration':'Adjusting panel light',c8:'After calibration closes','c8-recovery':'Reapplying settings after drift',c9:'After apply to all inputs',c10:'Before after-readings'})[key]||pgAutomationStageLabel(key)||'Stage not recorded';
}
function pgAutomationSettingsEvidence(checks,item){
 const value=v=>v==null?'Not returned':typeof v==='object'?JSON.stringify(v):String(v),esc=pgAutomationEscape;
 const label=c=>c.result==='expected-calibration-state'?'Expected calibration state':c.result==='lut-managed'?'LUT-managed':c.result==='readback-warning'?'Warning — LG gamut readback':c.verified?'Verified':c.result==='apply-failed'?'Failed to apply':c.result==='unverifiable'||c.observed==null?'Could not verify':'Readback mismatch';
 const stage=c=>[pgAutomationCheckStage(c),c.timestamp?pgAutomationFormatTime(typeof c.timestamp==='number'?c.timestamp*1000:c.timestamp):c.at?pgAutomationFormatTime(c.at):''].filter(Boolean).join(' · ');
 const latest=new Map();checks.forEach(c=>latest.set((c.category||'picture')+':'+c.key,c));
 const isManaged=c=>c.result==='lut-managed'||c.result==='expected-calibration-state';
 const managed=[...latest.values()].filter(isManaged);
 const problems=[...latest.values()].filter(c=>!c.verified&&!isManaged(c));
 const manual=(item.manual_checks||[]).map(c=>'<p class="auto-muted">Manual check: '+esc(typeof c==='string'?c:c.message||c.key||'Check in the TV menu')+'</p>').join('');
 return '<h4>TV settings verification</h4><p class="auto-muted">Saved readbacks at the stages shown—not a fresh read of the TV.</p>'+manual+
  managed.map(c=>'<p class="auto-muted"><strong>'+esc(c.key)+' · '+label(c)+'</strong><br>Requested: '+esc(value(c.expected))+' · TV reported: '+esc(value(c.observed))+'<br>'+esc(pgAutomationSettingReason(c))+'<br><small>'+esc(stage(c))+'</small></p>').join('')+
  (checks.length?(problems.length?problems.map(c=>'<div class="auto-setting-problem"><strong>'+esc(c.key)+' · '+label(c)+'</strong><div>Requested: '+esc(value(c.expected))+' · TV reported: '+esc(value(c.observed))+'</div><div>'+esc(pgAutomationSettingReason(c))+'</div><small>'+esc(stage(c))+'</small></div>').join(''):managed.length?'<p>Other recorded settings matched at their latest check.</p>':'<p>All recorded settings matched at their latest check.</p>'):'<p class="auto-muted">No settings verification has been recorded for this job.</p>')+
  (checks.length?'<details><summary>All setting checks ('+checks.length+')</summary><div class="auto-settings-table"><table><thead><tr><th>Setting</th><th>Requested</th><th>TV reported</th><th>Result / reason</th><th>Checked at</th></tr></thead><tbody>'+checks.map(c=>'<tr><td>'+esc(c.key)+'</td><td>'+esc(value(c.expected))+'</td><td>'+esc(value(c.observed))+'</td><td>'+label(c)+' — '+esc(pgAutomationSettingReason(c))+'</td><td>'+esc(stage(c))+'</td></tr>').join('')+'</tbody></table></div></details>':'');
}
function pgAutomationGraphToggle(view,key,value){const state=pgAutomation.jobViews[view];if(!state)return;state[key]=value;state.graphSignature=null;pgAutomationRenderJobGraphs(view,state);}
function pgAutomationGraphGroup(key){return /^grey/.test(key)?'greyscale':/^colors/.test(key)?'colors':/^saturations/.test(key)?'saturations':key;}
function pgAutomationGraphSnapshot(entry,item){
 const saved=entry.snapshot||{},cal=item.calibration||{};
 const signal=saved.signal_mode||item.signal_format;
 const calibration=entry.phase==='calibration';
 const snap={...saved,signal_mode:signal,
  target_gamma:saved.target_gamma||(calibration&&(signal==='dv'||entry.key==='grey'&&signal==='hdr10')?'2.2':item.target_gamma||cal.target_gamma),
  target_gamut:saved.target_gamut||item.target_gamut||cal.target_gamut,
  delta_e_formula:saved.delta_e_formula||item.delta_e_formula||cal.delta_e_formula,
  target_white:saved.target_white||item.target_white||cal.target_white};
 // Legacy worker snapshots omitted these fields. Recover from THIS job's
 // frozen recipe, never the currently running job or manual output controls.
 for(const key of ['color_format','max_bpc','signal_range','pattern_signal_range','transport_signal_range','max_luma']){
  if(snap[key]==null)snap[key]=item[key]??cal[key];
 }
 snap.signal_range??=item.rgb_quant_range;
 // Sparse legacy recipes use the runner's documented defaults. Flag the
 // assumption rather than silently using today's unrelated output settings.
 snap.transport_context_inferred=!!saved.transport_context_inferred||
  signal!=='dv'&&(snap.color_format==null||snap.max_bpc==null||snap.signal_range==null);
 snap.color_format??='0';
 snap.max_bpc??=signal==='dv'?8:10;
 snap.signal_range??='2';
 snap.pattern_signal_range??=snap.signal_range;
 snap.transport_signal_range??=snap.signal_range;
 if(signal==='dv'){
  snap.dv_map_mode=saved.dv_map_mode||(calibration?'2':'1');
  snap.color_format??='0';snap.max_bpc??=8;snap.signal_range??='2';
  snap.transport_signal_range??='2';
 }
 if(entry.key==='dv-profile'){
  // The actual profile worker saves measured xyY in steps, not readings.
  // This is native-panel characterisation, not a ColorChecker accuracy test.
  if(!snap.readings?.length)snap.readings=(saved.steps||[]).filter(st=>st&&st.luminance!=null&&Number.isFinite(Number(st.luminance))&&Number(st.luminance)>=0)
   .map(st=>({...st,series_type:'colors',signal_mode:'dv'}));
  snap.cache_key='lg-dv-profile';
 }
 if(entry.key==='3d'){
  snap.cache_key=(saved.method||cal.method)==='matrix'?'lg-3d-matrix-profile':'lg-3d-lattice-profile-automation';
 }
 if(entry.key==='grey'){snap.type='greyscale';snap.points=snap.points||26;}
 if(entry.key==='3d'||entry.key==='dv-profile'){snap.type='colors';snap.points=snap.points||snap.readings?.length||5;}
 return snap;
}
function pgAutomationCalibrationSnapshots(data){
 const snapshots=data.snapshots||[];
 if(['complete','complete-with-warnings','failed','stopped'].includes(data.run_status)){
  return snapshots.filter(s=>s.phase==='post'||s.phase==='calibration');
 }
 const stage=data.active_stage,phase=stage==='pre-readings-done'?'pre':stage==='post-readings-done'?'post':stage==='greyscale-done'||stage==='volume-done'?'calibration':null;
 const key=stage==='greyscale-done'?'grey':stage==='volume-done'?(data.item?.signal_format==='dv'?'dv-profile':'3d'):null;
 const live=phase&&data.live?.phase===phase&&(!key||data.live.key===key)?{...data.live,isLive:true}:null;
 // Keep earlier results on the page as saved measurements, never as live data.
 // A pre-sweep belongs here only while it is the active measurement.
 const saved=snapshots.filter(s=>s.phase==='post'||s.phase==='calibration');
 const hasLive=live&&pgAutomationGraphSnapshot(live,data.item).readings?.length;
 return [...saved.filter(s=>!(hasLive&&s.phase===live.phase&&s.key===live.key)),...(hasLive?[live]:[])];
}
async function pgAutomationRenderJobGraphs(view,state){
 if(!state.data)return;
 if(pgAutomation.reportBusy){pgAutomation.pendingJobGraphs||={};pgAutomation.pendingJobGraphs[view]=state;return;}
 const target=pgAutomationJobTarget(view)?.querySelector('[data-job-graphs]');if(!target)return;
 const data=state.data,item=data.item,entries=[];
 const observer=view==='calibration';
 const live=data.live?{...data.live,snapshot:pgAutomationGraphSnapshot(data.live,item),isLive:true}:null;
 const sources=observer?pgAutomationCalibrationSnapshots(data):(data.snapshots||[]).filter(s=>!(live?.snapshot?.readings?.length&&s.key===live.key&&s.phase===live.phase));
 if(!observer&&live?.snapshot?.readings?.length)sources.push(live);
 const groupOrder={greyscale:0,'3d':1,'dv-profile':1,colors:2,saturations:3};
 const phaseOrder={pre:0,calibration:1,post:2};
 const snapshots=sources.map(s=>({...s,snapshot:pgAutomationGraphSnapshot(s,item)})).sort((a,b)=>
  ((groupOrder[pgAutomationGraphGroup(a.key)]??4)-(groupOrder[pgAutomationGraphGroup(b.key)]??4))||
  (String(pgAutomationGraphGroup(a.key)).localeCompare(String(pgAutomationGraphGroup(b.key))))||
  ((phaseOrder[a.phase]??3)-(phaseOrder[b.phase]??3))||String(a.key).localeCompare(String(b.key)));
 const hasAfterGrey=snapshots.some(s=>s.phase==='post'&&pgAutomationGraphGroup(s.key)==='greyscale'&&s.snapshot?.readings?.length);
 snapshots.forEach(s=>{
  if(hasAfterGrey&&s.phase==='calibration'&&s.key==='grey')return;
  if(!s.snapshot?.readings?.length||(s.phase==='pre'?!state.showBefore:!state.showAfter))return;
  const snap=s.snapshot;
  const label=s.phase==='pre'?(s.isLive?'Before (measuring)':'Before'):s.phase==='post'?(s.isLive?'After (measuring)':'After'):s.isLive?'Live calibration':'Saved calibration';
  entries.push({title:label+' · '+(s.key==='grey'?'1D LUT':s.key==='3d'?'3D LUT':s.key==='dv-profile'?'Dolby Vision profile':pgAutomationSeriesLabel(s.key)),snapshot:snap});
 });
 // Render at least as wide as the destination, including the source card's
 // padding. The shared canvas renderer handles display pixel density/zoom.
 const renderWidth=Math.max(1100,Math.ceil(target.offsetWidth)+80);
 const signature=JSON.stringify([entries,renderWidth,window.devicePixelRatio||1,typeof pgDesktopZoom==='number'?pgDesktopZoom:1]);if(signature===state.graphSignature)return;
 if(!entries.length){target.innerHTML='<p class="auto-muted">'+(observer?'No measurements for the current stage yet. '+pgAutomationEscape(pgAutomationStageLabel(data.active_stage||'Between stages'))+'. Previous-stage graphs are not shown as live.':!state.showBefore&&!state.showAfter?'Select a comparison to show graphs.':'No measured graph data is available for this selection yet.')+'</p>';state.graphSignature=signature;return;}
 if(typeof meterFullAutoCalBuildSnapshotReportSections!=='function'){target.textContent='The calibration chart renderer is unavailable. Reload the page to load it.';return;}
 pgAutomation.reportBusy=true;
 const previousWidth=document.body.style.getPropertyValue('--automation-report-width');
 document.body.style.setProperty('--automation-report-width',renderWidth+'px');
 document.body.classList.add('pg-automation-report-render');
 try{
  const html=await meterFullAutoCalBuildSnapshotReportSections(entries);
  if(pgAutomation.jobViews[view]===state&&state.data===data){
   target.innerHTML=html;state.graphSignature=signature;
   target.querySelectorAll('.report-section-title').forEach(title=>{title.setAttribute('role','heading');title.setAttribute('aria-level','4');});
   target.querySelectorAll('.report-table-wrap').forEach(table=>{const detail=document.createElement('details'),summary=document.createElement('summary');summary.textContent='Measured values';table.before(detail);detail.append(summary,table);});
  }
 }catch(e){if(pgAutomation.jobViews[view]===state)target.textContent='Unable to draw measurements: '+e.message;}
 finally{
  document.body.classList.remove('pg-automation-report-render');pgAutomation.reportBusy=false;
  if(previousWidth)document.body.style.setProperty('--automation-report-width',previousWidth);
  else document.body.style.removeProperty('--automation-report-width');
  const pending=pgAutomation.pendingJobGraphs||{};pgAutomation.pendingJobGraphs={};
  Object.entries(pending).forEach(([nextView,nextState])=>{if(pgAutomation.jobViews[nextView]===nextState)pgAutomationRenderJobGraphs(nextView,nextState);});
 }
}

// Rebuild snapshots after a window/screen change, even if measurements have
// not changed. Reuse saved job data; resizing must never make device requests.
if(typeof window!=='undefined')window.addEventListener('resize',()=>{
 clearTimeout(pgAutomation.graphResizeTimer);
 pgAutomation.graphResizeTimer=setTimeout(()=>{
  Object.entries(pgAutomation.jobViews||{}).forEach(([view,state])=>{
   const target=pgAutomationJobTarget(view);
   if(target&&target.getBoundingClientRect().width>0)pgAutomationRenderJobGraphs(view,state);
  });
 },200);
});

function pgAutomationHistoryItemHtml(item,index){
 const apply=item&&item['apply-all'];
 const quality=item&&item.quality;
 const panel=item&&item['panel-light'];
 const warningList=Array.isArray(item&&item.warnings)?item.warnings:[];
 const details=[pgAutomationEscape(item&&item.status||''),((item&&item.checkpoints)||[]).filter(x=>x&&x.status==='done').length+' checkpoints'];
 if(warningList.length)details.push(warningList.length+' warnings: '+pgAutomationEscape(warningList.map(w=>typeof w==='string'?pgAutomationIssueText(w):[w.code,w.series,w.message].filter(Boolean).join(': ')).join(', ')));
 if(apply)details.push(apply.outcome==='sent-unconfirmed'&&apply.confirmation_unavailable?'Apply to All Inputs sent — confirmation unavailable on this TV.':'Apply to all: '+pgAutomationEscape(apply.outcome||apply.status||'unverified'));
 if(quality&&quality.warnings&&quality.warnings.length)details.push('Quality limits: '+quality.warnings.length+' miss'+(quality.warnings.length===1?'':'es'));
 if(panel&&panel.warning)details.push(pgAutomationEscape(panel.warning));
 const base=item&&item.item_number!=null?item.item_number:index;
 const qualityRows=quality?.enabled?Object.entries(quality.series||{}).map(([key,result])=>'<tr><td>'+pgAutomationEscape(pgAutomationSeriesLabel(key))+'</td><td>'+(result.average==null?'Unavailable':Number(result.average).toFixed(2))+'</td><td>'+(result.maximum==null?'Unavailable':Number(result.maximum).toFixed(2))+'</td><td>'+(result.passed==null?'Unverified':result.passed?'Pass':'Limit missed')+'</td></tr>').join(''):'';
 return '<div style="padding:12px 0;border-top:1px solid var(--border)"><strong>Item '+(index+1)+': '+pgAutomationEscape(item&&item.name||item&&item.picture_mode||'')+'</strong>'+pgAutomationItemSummary(item)+'<p style="color:var(--text2)">'+details.join(' · ')+'</p>'+pgAutomationJobFailureHtml(item)+(qualityRows?'<table><thead><tr><th>Sweep</th><th>Average ΔE</th><th>Maximum ΔE</th><th>Quality</th></tr></thead><tbody>'+qualityRows+'</tbody></table>':'')+'<div class="btn-row" style="margin-top:8px"><a class="btn btn-sm btn-secondary" href="/api/automation/runs/'+encodeURIComponent(pgAutomation.currentHistoryRunId||'')+'/artifact/items/'+base+'/settings-checks.ndjson" target="_blank" rel="noopener">Settings Checks</a></div></div>';
}

async function pgAutomationBuildHistoryReport(run){
 const target=document.getElementById('pgAutomationHistoryReport');
 if(!target||typeof meterFullAutoCalBuildSnapshotReportSections!=='function')return;
 if(pgAutomation.reportBusy){pgAutomation.pendingHistoryRun=run;return;}
 pgAutomation.reportBusy=true;
 const entries=[];
 const runId=String(run&&run.id||pgAutomation.currentHistoryRunId||'');
 const seriesRequests=[];
 (run.items||[]).forEach((item,index)=>{
  const calibration=item&&item.calibration||{};
  const grey=calibration['grey-state'];
  if(grey&&Array.isArray(grey.readings)&&grey.readings.length)entries.push({title:'Item '+(index+1)+' Calibration Greyscale',snapshot:grey});
  const volume=calibration['3d-state'];
  if(volume&&Array.isArray(volume.readings)&&volume.readings.length)entries.push({title:'Item '+(index+1)+' 3D LUT measurements',snapshot:{...volume,type:'colors',points:volume.readings.length,signal_mode:item.signal_format,target_gamma:item.target_gamma}});
  ['pre','post'].forEach(stage=>{
   if(item.stages&&item.stages[stage+'_readings']!=null&&!item.stages[stage+'_readings'])return;
   (item[stage+'_series']||['greyscale-21','colors-30','saturations-24']).forEach(key=>{
    seriesRequests.push({
     title:'Item '+(index+1)+' '+(stage==='pre'?'Pre-Cal ':'Post-Cal ')+key,
     path:'/api/automation/runs/'+encodeURIComponent(runId)+'/artifact/items/'+index+'/'+stage+'/'+key+'.json'
    });
   });
  });
 });
 try{
  const snapshots=await Promise.all(seriesRequests.map(request=>fetchJSON(request.path,{_quiet:true,_timeoutMs:30000})));
  seriesRequests.forEach((request,index)=>entries.push({title:request.title,snapshot:snapshots[index]||null}));
  if(pgAutomation.currentHistoryRunId!==runId)return;
  // The shared renderer snapshots real canvases. Give its hidden workspace a
  // layout off-screen without navigating away from Automation or touching TV state.
  document.body.classList.add('pg-automation-report-render');
  let html;
  try{html=await meterFullAutoCalBuildSnapshotReportSections(entries);}
  finally{document.body.classList.remove('pg-automation-report-render');}
  if(pgAutomation.currentHistoryRunId===runId)target.innerHTML=html||'<div style="color:var(--text2)">No graph data was saved for this run.</div>';
 }catch(e){target.innerHTML='<div style="color:var(--red)">Unable to render saved graphs: '+pgAutomationEscape(e.message||e)+'</div>';}
 finally{pgAutomation.reportBusy=false;if(pgAutomation.pendingHistoryRun){const pending=pgAutomation.pendingHistoryRun;pgAutomation.pendingHistoryRun=null;pgAutomationBuildHistoryReport(pending);}}
}

async function pgAutomationDeleteRun(index){
 const run=pgAutomation.history[index];
 if(!run||!confirm('Delete this run and its saved results? This cannot be undone.'))return;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to delete run',true);return;}
 const detail=document.getElementById('pgAutomationHistoryDetail');if(detail)detail.innerHTML='';
 await pgAutomationRefresh();
}

function pgAutomationTabKey(event){
 const tabs=[...document.querySelectorAll('#automationCard [data-auto-tab]')],current=tabs.indexOf(event.target);
 if(current<0||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
 event.preventDefault();
 const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(current+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;
 pgAutomationTab(tabs[next].dataset.autoTab);tabs[next].focus();
}
function pgAutomationTab(tab){
 pgAutomationDragCancel();
 ['recipes','queue','live','history'].forEach(name=>{const el=document.getElementById('pgAutomationTab'+name.charAt(0).toUpperCase()+name.slice(1));if(el)el.style.display=name===tab?'':'none';});
 pgAutomation.tab=tab;
 pgAutomationRenderActivity();
 document.querySelectorAll('[data-auto-tab]').forEach(el=>{const selected=el.getAttribute('data-auto-tab')===tab;el.setAttribute('aria-selected',String(selected));el.tabIndex=selected?0:-1;});
 if(tab==='history')pgAutomationRefresh();
 if(tab==='live')pgAutomationPollLive();
}

async function pgAutomationRefresh(){
 // The live poll owns run state. Do not hold it behind history loading or
 // overwrite a newer poll with the result of an older bulk refresh.
 pgAutomationPollLive();
 if(pgAutomation.refreshing)return pgAutomation.refreshing;
 const pending=(async()=>{
 const responses=await Promise.all([
  fetchJSON('/api/automation/recipes',{_quiet:true,_timeoutMs:5000}),
  fetchJSON('/api/automation/queues',{_quiet:true,_timeoutMs:5000}),
  // Saved manifests can take longer than a live-status poll on the Pi.
  fetchJSON('/api/automation/runs',{_quiet:true,_timeoutMs:30000})
 ]);
 if(responses[0]&&Array.isArray(responses[0].recipes))pgAutomation.recipes=responses[0].recipes;
 if(responses[1]&&Array.isArray(responses[1].queues))pgAutomation.queues=responses[1].queues;
 if(responses[2]&&responses[2].status!=='error'&&Array.isArray(responses[2].runs)){
  pgAutomation.history=responses[2].runs;pgAutomation.historyError='';
 }else pgAutomation.historyError='Cannot load saved runs. Any results shown below are from the last successful refresh.';
 pgAutomationRenderRecipeList();
 pgAutomationRenderSavedQueues();
 pgAutomationRenderQueue();
 pgAutomationRenderHistoryList();
 })();
 pgAutomation.refreshing=pending;
 try{await pending;}finally{if(pgAutomation.refreshing===pending)pgAutomation.refreshing=null;}
}

function pgAutomationInit(){
 if(pgAutomation.loaded)return;pgAutomation.loaded=true;
 try{const saved=JSON.parse(localStorage.getItem('pgen.automation.queueDraft')||'null');if(saved&&Array.isArray(saved.queue?.items)){pgAutomation.queue=saved.queue;pgAutomation.editingRunId=saved.editingRunId||'';pgAutomation.firstPending=saved.firstPending||0;pgAutomation.selectedQueue=saved.selectedQueue||'';pgAutomation.loadedQueueSnapshot=saved.loadedQueueSnapshot||'';}}catch(e){}
 pgAutomationRenderQueue();pgAutomationRenderRecipeList();pgAutomationRenderSavedQueues();
 pgAutomationRefresh();pgAutomationTab('queue');pgAutomationPollLive();
}
setTimeout(pgAutomationInit,0);
