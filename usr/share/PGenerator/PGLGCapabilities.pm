package PGLGCapabilities;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Exporter qw(import);
use File::Basename ();
use File::Path qw(make_path);
use File::Spec ();
use Fcntl qw(:flock);
use JSON::PP ();
use Time::HiRes qw(time);

our @EXPORT_OK = qw(
 clear_lg_capability_cache
 lg_platform_token
 lg_recipe
 lg_normalize_setting_value
 lg_record_setting_observation
 lg_setting_contracts
 lg_setting_values_agree
 load_lg_library
 resolve_lg_capabilities
 lg_operation_contract
 lg_scoped_request_payload
 lg_panel_light_binding
 lg_settings_selection_plan
 lg_calibration_mode_contract
 lg_picture_mode_catalogue
 lg_picture_mode_record
 lg_best_settings_plan
 lg_setting_write_accepted
 lg_readback_unavailable_reason
 validate_lg_library
);

# Older JSON::PP on the Pi rejects scalar roots by default; profile merging
# clones scalar leaves as well as objects and arrays.
my $JSON = JSON::PP->new->utf8->canonical(1)->allow_nonref(1);
my %CACHE;

sub _default_root {
 return $ENV{'PGENERATOR_TV_PROFILE_ROOT'}
  || File::Spec->catdir(File::Basename::dirname(__FILE__),'tv');
}

sub clear_lg_capability_cache { %CACHE=(); return 1; }

sub _clone {
 my ($value)=@_;
 return $JSON->decode($JSON->encode($value));
}

sub _merge {
 my ($base,$overlay)=@_;
 return _clone($overlay) if(ref($base) ne 'HASH' || ref($overlay) ne 'HASH');
 my $out=_clone($base);
 foreach my $key (keys %{$overlay}) {
  if(ref($out->{$key}) eq 'HASH' && ref($overlay->{$key}) eq 'HASH') {
   $out->{$key}=_merge($out->{$key},$overlay->{$key});
  } else {
   $out->{$key}=_clone($overlay->{$key});
  }
 }
 return $out;
}

sub _read_json {
 my ($path,$errors)=@_;
 if(!-f $path) { push(@{$errors},"missing file: $path"); return undef; }
 open(my $fh,'<',$path) or do { push(@{$errors},"cannot read $path: $!"); return undef; };
 local $/;
 my $text=<$fh>;
 close($fh);
 my $value;
 eval { $value=$JSON->decode($text); 1 } or do {
  my $error=$@||'invalid JSON'; $error=~s/[\r\n]+/ /g;
  push(@{$errors},"invalid JSON in $path: $error");
  return undef;
 };
 if(ref($value) ne 'HASH') { push(@{$errors},"top level must be an object: $path"); return undef; }
 return $value;
}

sub _array_of_strings {
 my ($value)=@_;
 return 0 if(ref($value) ne 'ARRAY');
 foreach my $item (@{$value}) { return 0 if(!defined($item) || ref($item)); }
 return 1;
}

sub _validate_profile {
 my ($profile,$path,$source_ids,$ids,$errors)=@_;
 if(ref($profile) ne 'HASH') { push(@{$errors},"profile is not an object in $path"); return; }
 my $id=$profile->{'profile_id'}||'';
 push(@{$errors},"profile_id missing in $path") if($id eq '');
 push(@{$errors},"duplicate profile_id $id") if($id ne '' && $ids->{$id}++);
 push(@{$errors},"invalid priority for $id")
  if(!defined($profile->{'priority'}) || $profile->{'priority'} !~ /^\d+$/ || $profile->{'priority'} > 1000);
 push(@{$errors},"match must be an object for $id") if(ref($profile->{'match'}) ne 'HASH');
 push(@{$errors},"data must be an object for $id") if(ref($profile->{'data'}) ne 'HASH');
 my $evidence=$profile->{'evidence'};
 if(ref($evidence) ne 'ARRAY' || !@{$evidence}) {
  push(@{$errors},"evidence must be a non-empty array for $id");
 } else {
  foreach my $claim (@{$evidence}) {
   if(ref($claim) ne 'HASH' || !defined($claim->{'source_id'}) || !defined($claim->{'strength'})) {
    push(@{$errors},"invalid evidence entry for $id");
    next;
   }
   push(@{$errors},"unknown source_id $claim->{'source_id'} for $id")
    if(!$source_ids->{$claim->{'source_id'}});
  }
 }
 my $match=ref($profile->{'match'}) eq 'HASH' ? $profile->{'match'} : {};
 my %match_keys=map {$_=>1} qw(platform_tokens retail_series firmware_versions year_min year_max);
 push(@$errors,"unknown match field $_ for $id") for grep {!$match_keys{$_}} keys %$match;
 foreach my $key (qw(year_min year_max)) {
  push(@$errors,"invalid $key for $id") if(exists($match->{$key}) && (!defined($match->{$key}) || ref($match->{$key}) || $match->{$key} !~ /^\d{4}$/));
 }
 foreach my $key (qw(platform_tokens retail_series firmware_versions)) {
  push(@{$errors},"$key must be an array of strings for $id")
   if(exists($match->{$key}) && !_array_of_strings($match->{$key}));
 }
 foreach my $token (@{ref($match->{'platform_tokens'}) eq 'ARRAY' ? $match->{'platform_tokens'} : []}) {
  push(@{$errors},"invalid platform token $token for $id") if($token !~ /^W\d{2}[A-Z]$/);
 }
 my $settings=ref($profile->{'data'}) eq 'HASH' ? $profile->{'data'}{'settings'} : undef;
 my $modes=$profile->{data}{picture_modes};
 if(defined($modes)) {
  if(ref($modes) ne 'HASH') {push(@$errors,"picture_modes must be an object for $id");}
  else {for my $signal(keys %$modes) {
   if($signal !~ /^(?:sdr|hdr10|dv|hlg)$/ || ref($modes->{$signal}) ne 'HASH') {push(@$errors,"invalid picture-mode signal $signal for $id");next;}
   for my $name(keys %{$modes->{$signal}}) {
    my $row=$modes->{$signal}{$name};
    if(ref($row) ne 'HASH') {push(@$errors,"invalid picture-mode record $name for $id");next;}
    if(exists($row->{value})) {
     push(@$errors,"picture-mode record $name missing $_ in $id") for grep {!exists($row->{$_})} qw(label settings_key settings_value aliases offered selection readback calibration source_ids);
     push(@$errors,"picture-mode key and value differ for $name in $id") if(($row->{value}||'') ne $name);
    }
    for my $field(qw(value label settings_key settings_value)) {
     push(@$errors,"invalid picture-mode $field for $name in $id") if(exists($row->{$field}) && (!defined($row->{$field}) || ref($row->{$field}) || $row->{$field} eq ''));
    }
    push(@$errors,"invalid picture-mode aliases for $name in $id") if(exists($row->{aliases}) && !_array_of_strings($row->{aliases}));
    push(@$errors,"invalid picture-mode offered flag for $name in $id") if(exists($row->{offered}) && !JSON::PP::is_bool($row->{offered}));
    for my $operation(qw(selection readback calibration)) {
     next if(!exists($row->{$operation}));
     my $op=$row->{$operation};
     if(ref($op) ne 'HASH') {push(@$errors,"invalid picture-mode $operation for $name in $id");next;}
     push(@$errors,"invalid picture-mode $operation state for $name in $id") if(exists($op->{support_state}) && ($op->{support_state}||'') !~ /^(?:unknown|unsupported|inventory|supported|verified)$/);
     for my $field(qw(bank internal_mode)) {push(@$errors,"invalid picture-mode $field for $name in $id") if(exists($op->{$field}) && ref($op->{$field}));}
     push(@$errors,"calibratable picture mode requires a bank for $name in $id") if($operation eq 'calibration' && ($op->{support_state}||'') =~ /^(?:inventory|supported|verified)$/ && (!$op->{bank} || !$op->{internal_mode}));
     if($operation eq 'calibration' && $op->{bank} && $op->{internal_mode} && !ref($op->{bank}) && !ref($op->{internal_mode})) {
      (my $wire=$op->{internal_mode})=~s/^dolby_hdr_/dolby_/;
      push(@$errors,"inconsistent calibration wire namespace for $name in $id") if($wire ne $op->{bank});
     }
    }
    if(exists($row->{source_ids})) {
     if(!_array_of_strings($row->{source_ids})) {push(@$errors,"invalid picture-mode sources for $name in $id");}
     else {push(@$errors,"unknown picture-mode source $_ for $name in $id") for grep {!$source_ids->{$_}} @{$row->{source_ids}};}
    }
   }
  }}
 }
 my $operations=ref($profile->{data}) eq 'HASH' ? $profile->{data}{operations} : undef;
 if(defined($operations)) {
  if(ref($operations) ne 'HASH') {push(@$errors,"operations must be an object for $id")}
  else {
   foreach my $name (keys %$operations) {
    my $operation=$operations->{$name};
    push(@$errors,"invalid operation $name for $id") if(ref($operation) ne 'HASH'
     || ($operation->{support_state}||'') !~ /^(?:unknown|unsupported|inventory|supported|verified)$/);
   }
  }
 }
 if(ref($settings) eq 'HASH') {
  if(exists($settings->{best_available})) {
   my $policy=$settings->{best_available};
   if(ref($policy) ne 'HASH') { push(@$errors,"best_available must be an object for $id"); }
   else {
    push(@$errors,"invalid unverified_write_signals for $id")
     if(exists($policy->{unverified_write_signals}) && (!_array_of_strings($policy->{unverified_write_signals})
      || grep { !/^(?:sdr|hdr10|hlg|dv)$/ } @{$policy->{unverified_write_signals}}));
    for my $flag (qw(enabled manual_on_unavailable_read)) {
     push(@$errors,"invalid best_available $flag for $id")
      if(exists($policy->{$flag}) && !JSON::PP::is_bool($policy->{$flag}));
    }
   }
  }
  foreach my $group (qw(controls ddc_controls)) {
   next if(!exists($settings->{$group}));
   if(ref($settings->{$group}) ne 'HASH') {push(@{$errors},"$group must be an object for $id");next;}
   foreach my $key (keys %{$settings->{$group}}) {
    my $control=$settings->{$group}{$key};
    if(ref($control) ne 'HASH') {push(@{$errors},"invalid control $key for $id");next;}
    if(exists($control->{write})) {
     if(ref($control->{write}) ne 'HASH') {push(@$errors,"invalid write contract for $key in $id");next;}
     push(@$errors,"invalid allow_unverified_readback for $key in $id")
      if(exists($control->{write}{allow_unverified_readback}) && !JSON::PP::is_bool($control->{write}{allow_unverified_readback}));
    }
    my $schema=$control->{'value_schema'};
    next if(!defined($schema)); # partial overlays may only update routes
    if(ref($schema) ne 'HASH' || ($schema->{'type'}||'') !~ /^(?:unknown|string|integer|integer_or_string_integer|number|enum|integer_or_enum|integer_array|numeric_array|integer_or_array|enum_or_legacy_map)$/) {
     push(@{$errors},"invalid value schema for $key in $id");next;
    }
    push(@{$errors},"invalid numeric range for $key in $id")
     if(defined($schema->{'minimum'}) && defined($schema->{'maximum'}) && $schema->{'minimum'} > $schema->{'maximum'});
    push(@{$errors},"invalid enum values for $key in $id")
     if(exists($schema->{'known_values'}) && !_array_of_strings($schema->{'known_values'}));
   }
  }
 }
}

sub _builtin_conservative {
 return {
  runtime=>{
   reset_method=>'ddc_cal_identity', white_balance_channel=>'ddc_1d',
   picturemode_readable=>JSON::PP::false, readback_supported=>JSON::PP::false,
   hdr_tonemap=>JSON::PP::false, dv_mode=>'1d_only',
  },
  calibration=>{
   session=>{support_state=>'unknown'},
   one_d_lut=>{support_state=>'unknown',points_per_channel=>1024,channels=>3,value_minimum=>0,value_maximum=>32767},
   three_d_lut=>{support_state=>'unknown',grid_size=>undef,channels=>3,bit_depth=>12,value_minimum=>0,value_maximum=>4095,axis_order=>'R fastest, G middle, B slowest'},
   dolby_vision_configuration=>{support_state=>'unknown',format_generation=>undef},
  },
  settings=>{public_routes=>{read=>{support_state=>'unknown',picture_keys=>[]},write=>{support_state=>'unknown',picture_keys=>[]}}},
 };
}

sub load_lg_library {
 my ($root)=@_;
 $root=_default_root() if(!defined($root) || $root eq '');
 return $CACHE{$root} if($CACHE{$root});
 my @errors;
 my $sources_doc=_read_json(File::Spec->catfile($root,'sources.json'),\@errors);
 my $source_map=(ref($sources_doc) eq 'HASH' && ref($sources_doc->{'sources'}) eq 'HASH') ? $sources_doc->{'sources'} : {};
 my %source_ids=map { $_=>1 } keys %{$source_map};
 my $index_path=File::Spec->catfile($root,'lg','index.json');
 my $index=_read_json($index_path,\@errors);
 $index={} if(ref($index) ne 'HASH');
 push(@errors,'LG index schema_version must be 1') if(($index->{'schema_version'}||0) != 1);
 foreach my $key (qw(base profile_files recipe_files)) {
  push(@errors,"LG index missing $key") if(!exists($index->{$key}));
 }
 my $lg_root=File::Spec->catdir($root,'lg');
 my $base_path=File::Spec->catfile($lg_root,$index->{'base'}||'base/conservative.json');
 my $base_doc=_read_json($base_path,\@errors);
 my %ids;
 my $base_profile=(ref($base_doc) eq 'HASH') ? $base_doc->{'profile'} : undef;
 _validate_profile($base_profile,$base_path,\%source_ids,\%ids,\@errors);
 my @profiles;
 my %key_sets;
 foreach my $relative (@{ref($index->{'profile_files'}) eq 'ARRAY' ? $index->{'profile_files'} : []}) {
  my $path=File::Spec->catfile($lg_root,$relative);
  my $document=_read_json($path,\@errors);
  next if(ref($document) ne 'HASH');
  push(@errors,"schema_version must be 1 in $path") if(($document->{'schema_version'}||0) != 1);
  if(ref($document->{'key_sets'}) eq 'HASH') {
   foreach my $name (keys %{$document->{'key_sets'}}) {
    my $set=$document->{'key_sets'}{$name};
    if(!_array_of_strings($set)) { push(@errors,"invalid key set $name in $path"); next; }
    if(exists($key_sets{$name})) { push(@errors,"duplicate key set $name"); next; }
    $key_sets{$name}=_clone($set);
   }
  }
  if(ref($document->{'profiles'}) ne 'ARRAY') {
   push(@errors,"profiles must be an array in $path");
   next;
  }
  foreach my $profile (@{$document->{'profiles'}}) {
   _validate_profile($profile,$path,\%source_ids,\%ids,\@errors);
   push(@profiles,$profile);
  }
 }
 my @recipes;
 my %declared_modes;
 for my $profile (@profiles) {
  my $signals=$profile->{data}{picture_modes};next if(ref($signals) ne 'HASH');
  for my $signal(keys %$signals) {next if(ref($signals->{$signal}) ne 'HASH');for my $name(keys %{$signals->{$signal}}) {
   $declared_modes{"$signal/$name"}=1 if(ref($signals->{$signal}{$name}) eq 'HASH' && exists($signals->{$signal}{$name}{value}));
  }}
 }
 for my $profile (@profiles) {
  my $signals=$profile->{data}{picture_modes};next if(ref($signals) ne 'HASH');
  for my $signal(keys %$signals) {next if(ref($signals->{$signal}) ne 'HASH');for my $name(keys %{$signals->{$signal}}) {
   push(@errors,"picture-mode patch has no complete declaration: $signal/$name") if(!$declared_modes{"$signal/$name"});
  }}
 }
 my %recipe_ids;
 my %recipe_controls;
 foreach my $profile (sort {($a->{priority}||0)<=>($b->{priority}||0)} grep {ref($_) eq 'HASH'} @profiles) {
  next if(($profile->{profile_id}||'') !~ m{^lg/settings/});
  next if(ref($profile->{data}) ne 'HASH' || ref($profile->{data}{settings}) ne 'HASH');
  my $controls=$profile->{data}{settings}{controls};
  next if(ref($controls) ne 'HASH');
  foreach my $control (values %$controls) {
   $recipe_controls{$control->{wire_key}}=$control if(ref($control) eq 'HASH' && $control->{wire_key});
  }
 }
 foreach my $relative (@{ref($index->{'recipe_files'}) eq 'ARRAY' ? $index->{'recipe_files'} : []}) {
  my $path=File::Spec->catfile($lg_root,$relative);
  my $document=_read_json($path,\@errors);
  next if(ref($document) ne 'HASH');
  push(@errors,"schema_version must be 1 in $path") if(($document->{'schema_version'}||0) != 1);
  if(ref($document->{'recipes'}) ne 'ARRAY') { push(@errors,"recipes must be an array in $path"); next; }
  foreach my $recipe (@{$document->{'recipes'}}) {
   if(ref($recipe) ne 'HASH' || ($recipe->{'recipe_id'}||'') eq '' || ($recipe->{'signal'}||'') eq '' || ref($recipe->{'settings'}) ne 'ARRAY') {
    push(@errors,"invalid recipe in $path"); next;
   }
   my $id=$recipe->{'recipe_id'};
   push(@errors,"duplicate recipe_id $id") if($recipe_ids{$id}++);
   my $signal=_signal_name($recipe->{signal});
   push(@errors,"invalid recipe signal for $id") if($signal !~ /^(?:sdr|hdr10|dv)$/);
   my %recipe_keys;
   foreach my $setting (@{$recipe->{settings}}) {
    if(ref($setting) ne 'HASH' || !defined($setting->{wire_key}) || ref($setting->{wire_key})
       || $setting->{wire_key} !~ /^[A-Za-z][A-Za-z0-9_]*$/ || !exists($setting->{value})) {
     push(@errors,"invalid recipe setting for $id"); next;
    }
    my $key=$setting->{wire_key};
    push(@errors,"duplicate recipe setting $key for $id") if($recipe_keys{$key}++);
    my $control=$recipe_controls{$key};
    if(ref($control) ne 'HASH') {push(@errors,"undeclared recipe setting $key for $id");next;}
    push(@errors,"inapplicable recipe setting $key for $id")
     if(ref($control->{signals}) eq 'ARRAY' && !_contains_ci($control->{signals},$signal));
    my ($valid,$value,$error)=lg_normalize_setting_value($control,$setting->{value});
    push(@errors,"invalid recipe value $key for $id: $error") if(!$valid);
   }
   foreach my $claim (@{ref($recipe->{'evidence'}) eq 'ARRAY' ? $recipe->{'evidence'} : []}) {
    push(@errors,"unknown source_id $claim->{'source_id'} for $id")
     if(ref($claim) eq 'HASH' && !$source_ids{$claim->{'source_id'}||''});
   }
   push(@recipes,$recipe);
  }
 }
 my $valid=@errors ? 0 : 1;
 # Profile loading is atomic. A malformed reviewed file never produces a
 # partially merged capability set; callers receive the conservative base.
 @profiles=() if(!$valid);
 my $base=(ref($base_profile) eq 'HASH' && ref($base_profile->{'data'}) eq 'HASH')
  ? _clone($base_profile->{'data'}) : _builtin_conservative();
 my $library={
  valid=>$valid,
  errors=>\@errors,
  root=>$root,
  version=>$index->{'library_version'}||'invalid',
  index=>$index,
  sources=>$source_map,
  base_profile_id=>(ref($base_profile) eq 'HASH' ? ($base_profile->{'profile_id'}||'lg/base/conservative-v1') : 'lg/base/builtin-conservative-v1'),
  base=>$base,
  profiles=>\@profiles,
  key_sets=>\%key_sets,
  recipes=>\@recipes,
 };
 $CACHE{$root}=$library;
 return $library;
}

sub validate_lg_library {
 my ($root)=@_;
 clear_lg_capability_cache();
 my $library=load_lg_library($root);
 return { ok=>$library->{'valid'} ? JSON::PP::true : JSON::PP::false, errors=>_clone($library->{'errors'}), version=>$library->{'version'} };
}

sub lg_platform_token {
 my ($value)=@_;
 $value='' if(!defined($value) || ref($value));
 return 'W'.uc($1) if($value =~ /(?:^|_)W(\d{2}[A-Za-z])(?:_|$)/);
 return uc($1) if($value =~ /\b(W\d{2}[A-Za-z])\b/);
 return '';
}

sub _contains_ci {
 my ($array,$needle)=@_;
 return 0 if(ref($array) ne 'ARRAY');
 $needle='' if(!defined($needle));
 foreach my $value (@{$array}) { return 1 if(uc($value||'') eq uc($needle)); }
 return 0;
}

sub _normalized_identity {
 my ($identity)=@_;
 $identity={} if(ref($identity) ne 'HASH');
 my $platform=$identity->{'platform_model'}||$identity->{'model_name_internal'}||$identity->{'platform'}||'';
 my $token=lg_platform_token($platform);
 my $series=uc($identity->{'series'}||'');
 $series=uc($1) if($series eq '' && ($identity->{model_name}||'') =~ /^OLED\d{2,3}([A-Z][X1-5])(?:[A-Z0-9]*)$/i);
 my $firmware=$identity->{'software_version'}||$identity->{'firmware_version'}||'';
 $firmware=~s/^v//i;
 my $year=int($identity->{'platform_year'}||0);
 $year=2000+$1 if(!$year && $token =~ /^W(\d{2})[A-Z]$/);
 if(!$year && $series =~ /^[A-Z]([X1-5])$/) {
  my %years=(X=>2020,1=>2021,2=>2022,3=>2023,4=>2024,5=>2025);
  $year=$years{$1};
 }
 my $device_id=$identity->{'device_uuid'}||$identity->{'device_id'}||$identity->{'uuid'}||'';
 return { platform_model=>$platform, platform_token=>$token, retail_series=>$series, firmware_version=>$firmware, model_year=>$year, device_id=>$device_id };
}

sub _matches {
 my ($profile,$identity)=@_;
 my $match=$profile->{'match'}||{};
 return 0 if(ref($match) ne 'HASH');
 return 0 if(ref($match->{'platform_tokens'}) eq 'ARRAY' && !_contains_ci($match->{'platform_tokens'},$identity->{'platform_token'}));
 return 0 if(ref($match->{'retail_series'}) eq 'ARRAY' && !_contains_ci($match->{'retail_series'},$identity->{'retail_series'}));
 return 0 if(ref($match->{'firmware_versions'}) eq 'ARRAY' && !_contains_ci($match->{'firmware_versions'},$identity->{'firmware_version'}));
 return 0 if(defined($match->{'year_min'}) && $identity->{'model_year'} < int($match->{'year_min'}));
 return 0 if(defined($match->{'year_max'}) && $identity->{'model_year'} > int($match->{'year_max'}));
 return 1;
}

sub _expand_key_sets {
 my ($value,$sets)=@_;
 if(ref($value) eq 'HASH') {
  my %out;
  foreach my $key (keys %{$value}) { $out{$key}=_expand_key_sets($value->{$key},$sets); }
  if(defined($out{'picture_key_set'})) {
   my $name=$out{'picture_key_set'};
   $out{'picture_keys'}=_clone($sets->{$name}||[]);
  }
  return \%out;
 }
 if(ref($value) eq 'ARRAY') { return [map { _expand_key_sets($_,$sets) } @{$value}]; }
 return $value;
}

sub resolve_lg_capabilities {
 my ($identity,%options)=@_;
 my $library=load_lg_library($options{'root'});
 my $normalized=_normalized_identity($identity);
 my $effective=_clone($library->{'base'});
 my @applied=($library->{'base_profile_id'});
 my @evidence;
 my @matched=sort {
  ($a->{'priority'}||0) <=> ($b->{'priority'}||0)
   || ($a->{'profile_id'}||'') cmp ($b->{'profile_id'}||'')
 } grep { _matches($_,$normalized) } @{$library->{'profiles'}||[]};
 foreach my $profile (@matched) {
  $effective=_merge($effective,$profile->{'data'});
  push(@applied,$profile->{'profile_id'});
  push(@evidence,@{_clone($profile->{'evidence'}||[])});
 }
 $effective=_expand_key_sets($effective,$library->{'key_sets'});
 my $has_platform=grep { /^lg\/platform\// } @applied;
 my $has_firmware=grep { /^lg\/firmware\// } @applied;
 my $has_model=grep { /^lg\/model\// } @applied;
 my $status=$has_firmware ? 'exact_firmware' : $has_platform ? 'platform' : $has_model ? 'retail_model_fallback' : 'conservative';
 my @warnings;
 if($has_platform && ($effective->{'identity'}{'expected_platform_token'}||'') ne ''
    && ($effective->{'identity'}{'expected_platform_token'}||'') ne $normalized->{'platform_token'}) {
  push(@warnings,"Retail model suggests $effective->{'identity'}{'expected_platform_token'}, but the TV reports $normalized->{'platform_token'}; internal platform wins.");
 }
 push(@warnings,'Capability library failed validation; conservative data only.') if(!$library->{'valid'});
 my @recipe_ids;
 my @recipes;
 foreach my $recipe (@{$library->{'recipes'}||[]}) {
  my $applies=$recipe->{'applies_to'}||{};
  next if(defined($applies->{'model_year_min'}) && $normalized->{'model_year'} && $normalized->{'model_year'} < int($applies->{'model_year_min'}));
  next if(defined($applies->{'model_year_max'}) && $normalized->{'model_year'} && $normalized->{'model_year'} > int($applies->{'model_year_max'}));
  push(@recipe_ids,$recipe->{'recipe_id'});
  push(@recipes,_clone($recipe));
 }
 my $fingerprint={library_version=>$library->{'version'},identity=>$normalized,applied_profiles=>\@applied,data=>$effective};
 my $hash=sha256_hex($JSON->encode($fingerprint));
 my $short_identity=$normalized->{'platform_token'}||$normalized->{'retail_series'}||'unknown';
 my $profile_id='lg/effective/'.$short_identity.'/'.$status.'/'.$library->{'version'};
 return {
  schema_version=>1,
  library_version=>$library->{'version'},
  library_valid=>$library->{'valid'} ? JSON::PP::true : JSON::PP::false,
  library_errors=>_clone($library->{'errors'}),
  capability_profile_id=>$profile_id,
  capability_profile_hash=>$hash,
  match_status=>$status,
  platform_profile_applied=>$has_platform ? JSON::PP::true : JSON::PP::false,
  identity=>$normalized,
  applied_profiles=>\@applied,
  warnings=>\@warnings,
  available_recipes=>\@recipe_ids,
  recipes=>\@recipes,
  evidence=>\@evidence,
  data=>$effective,
 };
}

sub lg_panel_light_binding {
 my ($identity,$values,$contracts)=@_;
 $identity={} if(ref($identity) ne 'HASH');
 $values={} if(ref($values) ne 'HASH');
 $contracts={} if(ref($contracts) ne 'HASH');
 my @aliases=qw(backlight oledLight oledPixelBrightness);
 my @readable=grep {defined($values->{$_}) && !ref($values->{$_}) && $values->{$_}=~/^\d+(?:\.\d+)?$/} @aliases;
 my @writable=grep {($contracts->{$_}{write_decision}||'') !~ /^(?:blocked|not_applicable)$/} @readable;
 my $key=$writable[0]||$readable[0]||'';
 my $oled=($identity->{model_name}||'') =~ /OLED/i || ($identity->{generation_id}||'') =~ /_oled$/;
 return {id=>'panel_light',label=>$oled?'OLED Pixel Brightness':'Panel brightness',wire_key=>$key,
  aliases=>\@aliases,readable=>$key ne '' ? JSON::PP::true : JSON::PP::false,
  writable=>@writable ? JSON::PP::true : JSON::PP::false};
}

# Editor planning uses the same contracts as runtime writes. Reference values
# are targets, not copies of the TV's current settings or proof of a write.
sub _mode_token {my $s=lc($_[0]||'');$s=~s/[\s_-]+//g;return $s;}
sub _mode_aliases {
 my ($row)=@_;
 return grep {defined($_) && $_ ne ''} ($row->{value},$row->{settings_value},@{$row->{aliases}||[]},$row->{calibration}{bank},$row->{calibration}{internal_mode});
}
sub lg_picture_mode_catalogue {
 my ($identity,%options)=@_;
 my $profile=resolve_lg_capabilities($identity,(defined($options{root})?(root=>$options{root}):()));
 return {} if(!$profile->{library_valid});
 return _clone($profile->{data}{picture_modes}||{});
}
sub lg_picture_mode_record {
 my ($identity,%options)=@_;
 my $mode=$options{picture_mode}||'';
 my $signal=_signal_name($options{signal_mode}||($mode=~/^dolby/i?'dv':$mode=~/^hdr/i?'hdr10':'sdr'));
 my $rows=lg_picture_mode_catalogue($identity,%options)->{$signal}||{};
 return _find_picture_mode_record($rows,$mode);
}
sub _find_picture_mode_record {
 my ($rows,$mode)=@_;
 my @matches=grep {my $row=$_;grep {$_ eq $mode} _mode_aliases($row)} values %$rows;
 @matches=grep {my $row=$_;grep {_mode_token($_) eq _mode_token($mode)} _mode_aliases($row)} values %$rows if(!@matches);
 # A hidden legacy application token can share a native selector with a real
 # menu row. Exact internal tokens retain their identity; native reads prefer
 # the offered row. Two offered matches are ambiguous and fail closed.
 @matches=grep {$_->{offered}} @matches if(@matches>1);
 return @matches == 1 ? $matches[0] : undef; # Ambiguous aliases must never select a bank.
}
sub lg_calibration_mode_contract {
 my ($identity,%options)=@_;
 my $profile=resolve_lg_capabilities($identity,(defined($options{root})?(root=>$options{root}):()));
 my $mode=$options{picture_mode}||'';
 my $signal=_signal_name($options{signal_mode}||($mode=~/^dolby/i?'dv':$mode=~/^hdr/i?'hdr10':'sdr'));
 my $rows=$profile->{library_valid}?($profile->{data}{picture_modes}{$signal}||{}):{};
 my @eligible=grep {($_->{calibration}{support_state}||'') =~ /^(?:inventory|supported|verified)$/ && $_->{calibration}{bank}} values %$rows;
 my $record=_find_picture_mode_record($rows,$mode);
 my $allowed=$record && grep {$_->{value} eq $record->{value}} @eligible;
 my $alternatives=join(', ',map {$_->{label}} sort {$a->{label} cmp $b->{label}} grep {$_->{offered}} @eligible) || 'a reviewed SDR, HDR10 or Dolby Vision calibration mode';
 return {allowed=>$allowed?JSON::PP::true:JSON::PP::false,signal_mode=>$signal,picture_mode=>$mode,
  allowed_modes=>[map {_mode_aliases($_)} @eligible],alternatives=>$alternatives,
  catalogue=>[map {$rows->{$_}} sort keys %$rows],mode=>$record,
  message=>$allowed?'This mode is eligible for AutoCal; TV and settings support are checked before calibration.'
   :"No reviewed AutoCal calibration bank is available for this picture mode. Choose $alternatives, or turn AutoCal off and enable readings. The selected picture mode has not been changed.",
  capability_profile_hash=>$profile->{capability_profile_hash}};
}

sub lg_settings_selection_plan {
 my ($identity,$requested,$live,%context)=@_;
 $identity={} if(ref($identity) ne 'HASH');
 $requested={} if(ref($requested) ne 'HASH');
 $live={} if(ref($live) ne 'HASH');
 my $profile=resolve_lg_capabilities($identity,(defined($context{root})?(root=>$context{root}):()));
 my @aliases=qw(backlight oledLight oledPixelBrightness);
 my $matrix=lg_setting_contracts($identity,%context,keys=>[keys %$requested,@aliases]);
 my $known=$profile->{library_valid} && $profile->{platform_profile_applied};
 my (%automatic,%manual,%blocked);
 for my $key (sort keys %$requested) {
  next if(grep {$_ eq $key} @aliases);
  my $c=$matrix->{contracts}{$key}||{};
  my ($valid,$value,$error)=lg_normalize_setting_value($c,$requested->{$key});
  my $reason=!$known?'TV compatibility has not been identified':!$c->{declared}?'No declared TV setting contract':!$valid?$error:
   ($c->{write_decision}||'') =~ /^(?:blocked|not_applicable)$/?'Not writable in this signal or picture mode':
   ($c->{write_state}||'') eq 'mismatch_in_context'?'Previous write did not match readback':
   (!$c->{allow_unverified_readback} && (($c->{read_state}||'') eq 'unsupported_in_context' || ($c->{read_decision}||'') eq 'blocked' || lg_readback_unavailable_reason($live->{unsupported_picture_keys}{$key}||'')))?'Automatic readback is unavailable':undef;
  if(defined($reason)) {
   my $entry={value=>$requested->{$key},reason=>$reason};
   if($known && (!$valid || ($c->{write_decision}||'') =~ /^(?:blocked|not_applicable)$/)) {$blocked{$key}=$entry;}
   else {$manual{$key}=$entry;}
  } else {$automatic{$key}=$value;}
 }
 my $values=$live->{picture_settings}||{};
 my %native=map {$_=>1} @{$live->{supported_picture_keys}||[]};
 my %panel_values=map {$_=>$values->{$_}} grep {defined($values->{$_}) && (!$live->{virtual_picture_settings} || $native{$_}) && !exists($live->{unsupported_picture_keys}{$_})} @aliases;
 my $panel=lg_panel_light_binding($identity,\%panel_values,$matrix->{contracts});
 $panel->{wire_key}='' if(!$known);
 if(!$panel->{wire_key} && $known) {
  my $key=$profile->{data}{settings}{logical_controls}{panel_light}{preferred_wire_key}||'';
  my $c=$matrix->{contracts}{$key}||{};
  if($key && $c->{declared} && ($c->{write_decision}||'') !~ /^(?:blocked|not_applicable)$/) {
   $panel->{wire_key}=$key;$panel->{writable}=JSON::PP::true;$panel->{source}='tv_matrix';
  }
 }
 $panel->{source}||=$panel->{wire_key}?'native_readback':'unresolved';
 $panel->{target_available}=$panel->{wire_key} && $panel->{writable}
  && ($matrix->{contracts}{$panel->{wire_key}}{read_state}||'') ne 'unsupported_in_context'
  && !lg_readback_unavailable_reason($live->{unsupported_picture_keys}{$panel->{wire_key}}||'')
  && ($matrix->{contracts}{$panel->{wire_key}}{read_decision}||'') ne 'blocked' ? JSON::PP::true : JSON::PP::false;
 $panel->{writable}=JSON::PP::false if(!$known || (!$panel->{target_available} && !$matrix->{contracts}{$panel->{wire_key}}{allow_unverified_readback})
  || ($matrix->{contracts}{$panel->{wire_key}}{write_state}||'') eq 'mismatch_in_context');
 $panel->{target_available}=JSON::PP::false if(!$panel->{writable});
 return {known=>$known?JSON::PP::true:JSON::PP::false,model_name=>$identity->{model_name}||'',
  automatic=>\%automatic,manual=>\%manual,blocked=>\%blocked,panel_light=>$panel,
  calibration_mode=>lg_calibration_mode_contract($identity,%context),
  setting_contracts=>$matrix->{contracts},context=>$matrix->{context},capability_profile_hash=>$matrix->{capability_profile_hash}};
}

sub lg_scoped_request_payload {
 my ($path,$payload,$config)=@_;
 return $payload if(ref($payload) ne 'HASH' || ref($config) ne 'HASH'
  || ($path||'') !~ m{^/api/lg/(?:picture-settings(?:/|$)|(?:sdr|hdr|dv)-calman-reset$|(?:1d-dpg|3d-lut|hdr-tone-map|dv-profile)/|calibration-mode$)});
 my $copy={%$payload};
 my $input=$config->{tv_input}||'';
 if($input =~ /^hdmi[1-4](?:_pc)?$/) {
  $copy->{tv_input}=$input;
  $copy->{expected_tv_input}=$input;
 }
 my $profile=ref($config->{generation_profile}) eq 'HASH' ? $config->{generation_profile}
  : (ref($config->{preflight_generation_profile}) eq 'HASH' ? $config->{preflight_generation_profile} : {});
 my $hash=$profile->{capability_profile_hash}||'';
 $hash=$config->{capability_profile}{hash}||$hash if(ref($config->{capability_profile}) eq 'HASH');
 $copy->{expected_profile_hash}=$hash if($hash ne '');
 $copy->{signal_mode}=$config->{signal_mode}||$config->{signal_format}||'' if(!defined($copy->{signal_mode}) || $copy->{signal_mode} eq '');
 $copy->{picture_mode}=$config->{picture_mode}||'' if(!defined($copy->{picture_mode}) || $copy->{picture_mode} eq '');
 return $copy;
}

sub lg_operation_contract {
 my ($identity,$name,%options)=@_;
 my $profile=resolve_lg_capabilities($identity,%options);
 my $contract=_clone($profile->{data}{operations}{$name}||{support_state=>'unknown'});
 $contract->{support_state}='unsupported' if(!$profile->{library_valid});
 $contract->{capability_profile_id}=$profile->{capability_profile_id};
 $contract->{capability_profile_hash}=$profile->{capability_profile_hash};
 return $contract;
}

sub _signal_name {
 my ($signal)=@_;
 $signal=lc($signal||'');
 $signal=~s/[\s-]+/_/g;
 return 'dv' if($signal eq 'dolby_vision' || $signal eq 'dolbyvision');
 return 'hdr10' if($signal eq 'hdr' || $signal eq 'pq');
 return '' if($signal eq '');
 return $signal;
}

sub _context_value {
 my ($value)=@_;
 return '' if(!defined($value) || ref($value));
 $value="$value";
 $value=~s/^\s+|\s+$//g;
 return lc($value);
}

sub _normalized_context {
 my ($context)=@_;
 $context={} if(ref($context) ne 'HASH');
 return {
  category=>_context_value($context->{'category'}||'picture'),
  signal_mode=>_signal_name($context->{'signal_mode'}||$context->{'signal'}||''),
  picture_mode=>_context_value($context->{'picture_mode'}||$context->{'pictureMode'}),
  tv_input=>_context_value($context->{'tv_input'}||$context->{'input'}),
  control_channel=>$context->{'ddc_white_balance'} || ($context->{'control_channel'}||'') eq 'ddc' ? 'ddc' : 'native',
 };
}

sub _observation_root {
 my (%options)=@_;
 return $options{'store_root'} || $ENV{'PGENERATOR_LG_CAPABILITY_STORE'}
  || '/var/lib/PGenerator/lg/capabilities';
}

sub _observation_path {
 my ($identity,%options)=@_;
 my $normalized=_normalized_identity($identity);
 my $fingerprint=sha256_hex($JSON->encode({
  platform_token=>$normalized->{'platform_token'}||'',
  retail_series=>$normalized->{'retail_series'}||'',
  firmware_version=>$normalized->{'firmware_version'}||'',
  device_id=>$normalized->{'device_id'}||'',
 }));
 return File::Spec->catfile(_observation_root(%options),$fingerprint.'.json');
}

sub _read_observation_document {
 my ($identity,%options)=@_;
 my $path=_observation_path($identity,%options);
 return ({},$path) if(!-f $path);
 my @errors;
 my $document=_read_json($path,\@errors);
 return ({},$path) if(ref($document) ne 'HASH' || @errors || ($document->{'schema_version'}||0) != 1);
 return ($document,$path);
}

sub _context_observations {
 my ($identity,$context,%options)=@_;
 return {} if(!(_normalized_identity($identity)->{'device_id'}||''));
 my $complete=_normalized_context($context);
 return {} if(grep {($complete->{$_}||'') eq ''} qw(signal_mode picture_mode tv_input));
 my ($document)=_read_observation_document($identity,%options);
 my $normalized=_normalized_context($context);
 my $context_hash=sha256_hex($JSON->encode($normalized));
 my $entry=(ref($document->{'contexts'}) eq 'HASH') ? $document->{'contexts'}{$context_hash} : undef;
 return {} if(ref($entry) ne 'HASH' || ref($entry->{'context'}) ne 'HASH');
 # A hash collision is implausible, but an exact comparison also protects the
 # invariant that observations never leak between picture/signal/input slots.
 return {} if($JSON->encode($entry->{'context'}) ne $JSON->encode($normalized));
 return ref($entry->{'settings'}) eq 'HASH' ? _clone($entry->{'settings'}) : {};
}

sub lg_record_setting_observation {
 my ($identity,$context,$key,$operation,$result,%options)=@_;
 return {ok=>JSON::PP::false,error=>'invalid-observation'}
  if(ref($identity) ne 'HASH' || ref($context) ne 'HASH' || !defined($key) || ref($key)
     || $key eq '' || $operation !~ /^(?:read|write|verify|roundtrip)$/ || ref($result) ne 'HASH');
 return {ok=>JSON::PP::false,error=>'device-identity-unavailable'}
  if(!(_normalized_identity($identity)->{'device_id'}||''));
 my $complete=_normalized_context($context);
 return {ok=>JSON::PP::false,error=>'context-unconfirmed'}
  if((exists($context->{context_confirmed}) && !$context->{context_confirmed})
    || grep {($complete->{$_}||'') eq ''} qw(signal_mode picture_mode tv_input));
 my $root=_observation_root(%options);
 eval { make_path($root,{mode=>0755}) if(!-d $root); 1 }
  or return {ok=>JSON::PP::false,error=>'observation-store-unavailable',detail=>"$@"};
 my $path=_observation_path($identity,%options);
 my $lock_path=$path.'.lock';
 open(my $lock,'>>',$lock_path)
  or return {ok=>JSON::PP::false,error=>'observation-lock-unavailable',detail=>"$!"};
 if(!flock($lock,LOCK_EX)) {
  close($lock);
  return {ok=>JSON::PP::false,error=>'observation-lock-failed',detail=>"$!"};
 }
 my ($document)=_read_observation_document($identity,%options);
 my $normalized_identity=_normalized_identity($identity);
 my $normalized_context=_normalized_context($context);
 my $context_hash=sha256_hex($JSON->encode($normalized_context));
 $document={
  schema_version=>1,
  identity=>$normalized_identity,
  contexts=>{},
 } if(ref($document->{'contexts'}) ne 'HASH');
 $document->{'schema_version'}=1;
 $document->{'identity'}=$normalized_identity;
 $document->{'contexts'}={} if(ref($document->{'contexts'}) ne 'HASH');
 my $entry=$document->{'contexts'}{$context_hash};
 $entry={context=>$normalized_context,settings=>{}} if(ref($entry) ne 'HASH');
 $entry->{'context'}=$normalized_context;
 $entry->{'settings'}={} if(ref($entry->{'settings'}) ne 'HASH');
 $entry->{'settings'}{$key}={} if(ref($entry->{'settings'}{$key}) ne 'HASH');
 my $previous=$entry->{'settings'}{$key}{$operation};
 my $count=(ref($previous) eq 'HASH' ? int($previous->{'count'}||0) : 0)+1;
 my %record=(
  status=>_context_value($result->{'status'}||'unknown'),
  route=>_context_value($result->{'route'}),
  reason=>defined($result->{'reason'}) && !ref($result->{'reason'}) ? "$result->{'reason'}" : '',
  count=>$count,
  last_seen=>0+sprintf('%.3f',time()),
 );
 $record{'value_type'}=$result->{'value_type'} if(defined($result->{'value_type'}) && !ref($result->{'value_type'}));
 $entry->{'settings'}{$key}{$operation}=\%record;
 $document->{'contexts'}{$context_hash}=$entry;
 my $tmp=$path.'.tmp.'.$$;
 my $ok=eval {
  open(my $fh,'>',$tmp) or die "open: $!";
  print {$fh} JSON::PP->new->utf8->canonical(1)->pretty(1)->encode($document) or die "write: $!";
  close($fh) or die "close: $!";
  chmod(0644,$tmp);
  rename($tmp,$path) or die "rename: $!";
  1;
 };
 my $error=$@;
 unlink($tmp) if(!$ok && -e $tmp);
 flock($lock,LOCK_UN);
 close($lock);
 return $ok
  ? {ok=>JSON::PP::true,path=>$path,context_hash=>$context_hash}
  : {ok=>JSON::PP::false,error=>'observation-write-failed',detail=>"$error"};
}

sub _route_state_for_key {
 my ($route,$wire_key)=@_;
 return 'unknown' if(ref($route) ne 'HASH');
 my $state=$route->{'support_state'}||'unknown';
 return 'unsupported' if($state eq 'unsupported');
 my $keys=ref($route->{'picture_keys'}) eq 'ARRAY' ? $route->{'picture_keys'} : [];
 my $listed=_contains_ci($keys,$wire_key);
 if($state eq 'firmware_inventory') {
  return $listed ? 'inventory' : 'not_listed_in_firmware_inventory';
 }
 return $listed ? ($state eq 'unknown' ? 'inventory' : $state) : $state;
}

sub _control_for_key {
 my ($controls,$key)=@_;
 return undef if(ref($controls) ne 'HASH');
 return _clone($controls->{$key}) if(ref($controls->{$key}) eq 'HASH');
 foreach my $name (sort keys %{$controls}) {
  my $control=$controls->{$name};
  next if(ref($control) ne 'HASH');
  return _clone($control) if(lc($control->{'wire_key'}||'') eq lc($key));
  foreach my $alias (@{ref($control->{'aliases'}) eq 'ARRAY' ? $control->{'aliases'} : []}) {
   return _clone($control) if(lc($alias||'') eq lc($key));
  }
 }
 return undef;
}

# Shared policy: model-specific evidence is data in the matrix, never a model
# branch here. A refused read must not become an assertion that writes fail.
sub lg_readback_unavailable_reason {
 my ($reason)=@_;
 return 0 if(!defined($reason) || ref($reason)
  || $reason =~ /(?:timeout|timed out|socket|disconnect|permission|unauthori|authentication|\b40[13]\b|service unavailable|connection closed)/i);
 return $reason =~ /(?:not allowed|not support|unsupported|no value|no matched|(?:readback|settings?|controls?)\s+(?:is |are )?unavailable)/i ? 1 : 0;
}

sub lg_best_settings_plan {
 my ($identity,$requested,$response,%context)=@_;
 $requested={} if(ref($requested) ne 'HASH');
 $response={} if(ref($response) ne 'HASH');
 my $profile=resolve_lg_capabilities($identity,(defined($context{root}) ? (root=>$context{root}) : ()));
 my $policy=$profile->{data}{settings}{best_available}||{};
 my $plan={active=>JSON::PP::false,label=>$policy->{label}||'Best available settings',
  automatic=>_clone($requested),manual=>{},blocked=>{},unavailable=>{},capability_profile_hash=>$profile->{capability_profile_hash},
  context=>_normalized_context(\%context)};
 return $plan if(!$profile->{library_valid} || !$profile->{platform_profile_applied} || !$policy->{enabled}
  || ($response->{status}||'') ne 'ok' || ($context{category}||'picture') ne 'picture'
  || ($context{signal_mode}||'') !~ /^(?:sdr|hdr10|hlg|dv)$/
  || ($context{tv_input}||'') !~ /^hdmi[1-4](?:_pc)?$/
  || ($response->{current_input}||'') ne $context{tv_input});
 my $matrix=lg_setting_contracts($identity,%context,keys=>[keys %$requested]);
 my $values=$response->{picture_settings}||{};
 my %native=map {$_=>1} @{$response->{supported_picture_keys}||[]};
 my $unavailable=$response->{unsupported_picture_keys}||{};
 my $mode_native=defined($values->{pictureMode}) && (!$response->{virtual_picture_settings} || $native{pictureMode});
 if($mode_native && !lg_setting_values_agree({verify=>{comparator=>'picture_mode_semantic'}},$context{picture_mode},$values->{pictureMode})) {
  $plan->{context_error}='The TV reports a different picture mode; refresh readiness before applying settings.';
  return $plan;
 }
 if(!$mode_native && ($profile->{data}{runtime}{picturemode_readable}
    || !($response->{virtual_picture_settings} || $response->{picture_mode_read_forbidden}))) {
  $plan->{context_error}='Picture mode could not be confirmed under the TV matrix.';
  return $plan;
 }
 $plan->{active}=JSON::PP::true;
 for my $key (sort keys %$requested) {
  my $c=$matrix->{contracts}{$key}||{};
  my ($valid,undef,$error)=lg_normalize_setting_value($c,$requested->{$key},$values->{$key});
  my $write=$c->{write_decision}||'';
  if(!$valid || !$c->{declared} || $write eq 'blocked' || $write eq 'not_applicable') {
   $plan->{blocked}{$key}=$error||'No applicable supported write contract';next;
  }
  next if(exists($values->{$key}) && defined($values->{$key}) && !exists($unavailable->{$key})
   && (!$response->{virtual_picture_settings} || $native{$key}));
  my $reason=$unavailable->{$key}||'';
  next if(!lg_readback_unavailable_reason($reason));
  $plan->{unavailable}{$key}=$reason;
  next if($c->{allow_unverified_readback});
  if($policy->{manual_on_unavailable_read}) {
   my $value=ref($requested->{$key}) ? $JSON->encode($requested->{$key}) : "$requested->{$key}";
   $plan->{manual}{$key}={value=>_clone($requested->{$key}),reason=>$reason,
    message=>"Set $key to $value in the TV menu for $context{picture_mode} ($context{signal_mode}, $context{tv_input}); automatic readback is unavailable."};
   delete $plan->{automatic}{$key};
  }
 }
 return $plan;
}

sub lg_setting_write_accepted {
 my ($response,$key,$expected)=@_;
 return 0 if(ref($response) ne 'HASH' || ($response->{status}||'') ne 'ok');
 my $entry=ref($response->{setting_verification}) eq 'HASH' ? $response->{setting_verification}{$key} : undef;
 my $contract=ref($response->{setting_contracts}) eq 'HASH' ? $response->{setting_contracts}{$key} : undef;
 my $values=ref($response->{picture_settings}) eq 'HASH' ? $response->{picture_settings} : {};
 return 0 if(ref($entry) ne 'HASH' || ref($contract) ne 'HASH');
 return 0 if(!defined($expected) || !exists($entry->{expected}) || !%$contract
  || ($contract->{write_decision}||'') !~ /^(?:allowed|readback_preferred|verified_readback_required|preflight_and_verified_readback_required)$/
  || !lg_setting_values_agree($contract,$expected,$entry->{expected}));
 return 0 if(exists($entry->{observed}) && !lg_setting_values_agree($contract,$expected,$entry->{observed}));
 return 0 if(exists($values->{$key}) && !lg_setting_values_agree($contract,$expected,$values->{$key}));
 return (($response->{verification_state}||'') =~ /^(?:verified|acknowledged_unverified)$/
  && (exists($entry->{observed}) || exists($values->{$key}))) ? 1 : 0
  if(($entry->{status}||'') eq 'verified');
 return ($entry->{status}||'') eq 'acknowledged_unverified'
  && ($response->{verification_state}||'') eq 'acknowledged_unverified'
  && ($contract->{allow_unverified_readback} || (!$contract->{require_readback}
   && ($contract->{write}{route}||'') eq 'ddc_1d'))
  && ($contract->{write_decision}||'') !~ /^(?:blocked|not_applicable)$/ ? 1 : 0;
}

sub lg_setting_contracts {
 my ($identity,%options)=@_;
 $identity={} if(ref($identity) ne 'HASH');
 my $profile=resolve_lg_capabilities($identity,(defined($options{'root'}) ? (root=>$options{'root'}) : ()));
 my $settings=ref($profile->{'data'}{'settings'}) eq 'HASH' ? $profile->{'data'}{'settings'} : {};
 my $controls=ref($settings->{'controls'}) eq 'HASH' ? $settings->{'controls'} : {};
 my $routes=ref($settings->{'public_routes'}) eq 'HASH' ? $settings->{'public_routes'} : {};
 my $context=_normalized_context({
  category=>$options{'category'}, signal_mode=>$options{'signal_mode'},
  picture_mode=>$options{'picture_mode'}, tv_input=>$options{'tv_input'},
  ddc_white_balance=>$options{'ddc_white_balance'},
 });
 my $observations=_context_observations($identity,$context,
  (defined($options{'store_root'}) ? (store_root=>$options{'store_root'}) : ()));
 my @keys=@{ref($options{'keys'}) eq 'ARRAY' ? $options{'keys'} : []};
 @keys=sort map { $_->{'wire_key'}||() } values %{$controls} if(!@keys);
 my %seen;
 my %contracts;
 foreach my $key (@keys) {
  next if(!defined($key) || ref($key) || $key eq '' || $seen{$key}++);
  my $control=$context->{'category'} =~ /^picture(?:\$|$)/ ? _control_for_key($controls,$key) : undef;
  my $ddc_controls=$settings->{'ddc_controls'}||{};
  $control=_clone($ddc_controls->{$key}) if($options{'ddc_white_balance'} && ref($ddc_controls->{$key}) eq 'HASH');
  my $declared=defined($control) ? JSON::PP::true : JSON::PP::false;
  $control={
   wire_key=>$key,
   category=>$context->{'category'}||'picture',
   value_schema=>{type=>'unknown'},
   read=>{route=>'ssap.settings'},
   write=>{route=>'ssap.settings',require_readback=>JSON::PP::true},
   verify=>{comparator=>'scalar'},
  } if(!defined($control));
  my $wire_key=$control->{'wire_key'}||$key;
  my $signal_applies=1;
  if($context->{'signal_mode'} ne '' && ref($control->{'signals'}) eq 'ARRAY' && @{$control->{'signals'}}) {
   $signal_applies=_contains_ci($control->{'signals'},$context->{'signal_mode'});
  }
  my $read_state=_route_state_for_key($routes->{'read'},$wire_key);
  my $write_state=_route_state_for_key($routes->{'write'},$wire_key);
  ($read_state,$write_state)=('unknown','unknown') if($context->{'category'} !~ /^picture(?:\$|$)/);
  my $read_route=ref($control->{'read'}) eq 'HASH' ? ($control->{'read'}{'route'}||'ssap.settings') : 'ssap.settings';
  my $write_route=ref($control->{'write'}) eq 'HASH' ? ($control->{'write'}{'route'}||'ssap.settings') : 'ssap.settings';
  if($read_route eq 'ddc_state' || $write_route eq 'ddc_1d' || $write_route eq 'transport_metadata') {
   my $cal_state=$profile->{'data'}{'calibration'}{'one_d_lut'}{'support_state'}||'unknown';
   $read_state=$cal_state eq 'unsupported' ? 'unsupported' : $cal_state;
   $write_state=$cal_state eq 'unsupported' ? 'unsupported' : $cal_state;
  }
  my $observed=ref($observations->{$wire_key}) eq 'HASH' ? $observations->{$wire_key} : {};
  my $observed_read=ref($observed->{'read'}) eq 'HASH' ? $observed->{'read'}{'status'}||'' : '';
  my $observed_verify=ref($observed->{'verify'}) eq 'HASH' ? $observed->{'verify'}{'status'}||'' : '';
  $read_state='observed' if($observed_read eq 'supported' || $observed_read eq 'observed');
  $read_state='unsupported_in_context' if($observed_read eq 'unsupported');
  $write_state='verified_in_context' if($observed_verify eq 'verified');
  $write_state='mismatch_in_context' if($observed_verify eq 'mismatch');
  my ($read_decision,$write_decision)=('probe_required','preflight_and_verified_readback_required');
  if(!$signal_applies) {
   $read_decision=$write_decision='not_applicable';
  } elsif($read_state eq 'unsupported') {
   $read_decision='blocked';
  } elsif($read_state eq 'observed') {
   $read_decision='allowed';
  }
  if($signal_applies) {
   if($write_state eq 'unsupported') { $write_decision='blocked'; }
   elsif($write_state eq 'verified_in_context') { $write_decision='allowed'; }
   elsif($write_state eq 'inventory') { $write_decision='verified_readback_required'; }
   elsif($write_route eq 'ddc_1d' || $write_route eq 'transport_metadata') { $write_decision='verified_readback_required'; }
  }
  $read_decision='blocked' if(($control->{'read'}{'support_state'}||'') eq 'unsupported');
  $write_decision='blocked' if(($control->{'write'}{'support_state'}||'') eq 'unsupported' || !$profile->{'library_valid'});
  my $require_readback=JSON::PP::true;
  $require_readback=$control->{'write'}{'require_readback'} ? JSON::PP::true : JSON::PP::false
   if(ref($control->{'write'}) eq 'HASH' && exists($control->{'write'}{'require_readback'}));
  # Some reviewed 2020/2021 transports cannot return a trustworthy LUT.
  # Acknowledgement on those sets is explicitly not hardware verification.
  $require_readback=JSON::PP::false if($write_route eq 'ddc_1d' && $profile->{platform_profile_applied}
   && !$profile->{data}{runtime}{readback_supported});
  my $allow_unverified=$profile->{library_valid} && $profile->{platform_profile_applied}
   && $signal_applies && $context->{category} eq 'picture'
   && $write_decision ne 'blocked' && $control->{write}{allow_unverified_readback}
   && _contains_ci($profile->{data}{settings}{best_available}{unverified_write_signals}||[],$context->{signal_mode});
  $write_decision='readback_preferred' if($allow_unverified && $write_decision ne 'allowed');
  $contracts{$key}={
   key=>$key, wire_key=>$wire_key, declared=>$declared,
   category=>$control->{'category'}||$context->{'category'}||'picture',
   signals=>_clone($control->{'signals'}||[]), applies_to_signal=>$signal_applies ? JSON::PP::true : JSON::PP::false,
   value_schema=>_clone($control->{'value_schema'}||{type=>'unknown'}),
   read=>_clone($control->{'read'}||{route=>$read_route}),
   write=>_clone($control->{'write'}||{route=>$write_route}),
   verify=>_clone($control->{'verify'}||{comparator=>'scalar'}),
   read_state=>$read_state, write_state=>$write_state,
   read_decision=>$read_decision, write_decision=>$write_decision,
   require_readback=>$require_readback,
   allow_unverified_readback=>$allow_unverified ? JSON::PP::true : JSON::PP::false,
   observation=>_clone($observed),
   capability_profile_id=>$profile->{'capability_profile_id'},
   capability_profile_hash=>$profile->{'capability_profile_hash'},
  };
 }
 return {
  schema_version=>1,
  context=>$context,
  capability_profile_id=>$profile->{'capability_profile_id'},
  capability_profile_hash=>$profile->{'capability_profile_hash'},
  match_status=>$profile->{'match_status'},
  policy=>_clone($settings->{'policy'}||{}),
  contracts=>\%contracts,
 };
}

sub _canonical_enum_value {
 my ($schema,$value)=@_;
 return undef if(!defined($value) || ref($value));
 my $text="$value";
 $text=~s/^\s+|\s+$//g;
 my $aliases=ref($schema->{'aliases'}) eq 'HASH' ? $schema->{'aliases'} : {};
 foreach my $alias (keys %{$aliases}) {
  if(lc($alias) eq lc($text)) { $text=$aliases->{$alias}; last; }
 }
 foreach my $known (@{ref($schema->{'known_values'}) eq 'ARRAY' ? $schema->{'known_values'} : []}) {
  return $known if(lc($known) eq lc($text));
 }
 return $text if($schema->{'extensible'});
 return undef;
}

sub _number {
 my ($value)=@_;
 return undef if(!defined($value) || ref($value) || "$value" !~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$/);
 return 0+$value;
}

sub lg_normalize_setting_value {
 my ($contract,$value,$observed)=@_;
 return (0,undef,'setting contract is missing') if(ref($contract) ne 'HASH');
 my $schema=ref($contract->{'value_schema'}) eq 'HASH' ? $contract->{'value_schema'} : {};
 my $type=$schema->{'type'}||'unknown';
 if($type eq 'unknown') { return (1,_clone($value),undef); }
 if($type eq 'string') {
  return (0,undef,'value must be a string') if(!defined($value) || ref($value));
  my $text="$value";
  return (0,undef,'value is too short') if(length($text) < int($schema->{'minimum_length'}||0));
  return (1,$text,undef);
 }
 if($type eq 'integer' || $type eq 'integer_or_string_integer' || $type eq 'number') {
  my $number=_number($value);
  return (0,undef,'value must be numeric and match the declared type') if(!defined($number) || ($type ne 'number' && int($number) != $number));
  return (0,undef,"value is below $schema->{'minimum'}") if(defined($schema->{'minimum'}) && $number < $schema->{'minimum'});
  return (0,undef,"value is above $schema->{'maximum'}") if(defined($schema->{'maximum'}) && $number > $schema->{'maximum'});
  return (1,$type eq 'number' ? $number : int($number),undef);
 }
 if($type eq 'enum') {
  my $canonical=_canonical_enum_value($schema,$value);
  return defined($canonical) ? (1,$canonical,undef) : (0,undef,'value is not in the supported enum');
 }
 if($type eq 'integer_or_enum') {
  my $number=_number($value);
  if(defined($number) && int($number) == $number) {
   return (0,undef,"value is below $schema->{'minimum'}") if(defined($schema->{'minimum'}) && $number < $schema->{'minimum'});
   return (0,undef,"value is above $schema->{'maximum'}") if(defined($schema->{'maximum'}) && $number > $schema->{'maximum'});
   return (1,int($number),undef);
  }
  my $canonical=_canonical_enum_value($schema,$value);
  return defined($canonical) ? (1,$canonical,undef) : (0,undef,'value is neither a valid integer nor enum value');
 }
 if($type eq 'integer_or_array' && ref($value) ne 'ARRAY') {
  return lg_normalize_setting_value({%{$contract},value_schema=>{%{$schema},type=>'integer'}},$value);
 }
 if($type eq 'integer_array' || $type eq 'numeric_array' || $type eq 'integer_or_array') {
  return (0,undef,'value must be an array') if(ref($value) ne 'ARRAY');
  return (0,undef,'array has too few items') if(defined($schema->{'minimum_items'}) && @{$value} < $schema->{'minimum_items'});
  return (0,undef,'array has too many items') if(defined($schema->{'maximum_items'}) && @{$value} > $schema->{'maximum_items'});
  my @normalized;
  foreach my $item (@{$value}) {
   my $number=_number($item);
   return (0,undef,'array item does not match the declared numeric type') if(!defined($number) || ($type ne 'numeric_array' && int($number) != $number));
   return (0,undef,"array item is below $schema->{'minimum'}") if(defined($schema->{'minimum'}) && $number < $schema->{'minimum'});
   return (0,undef,"array item is above $schema->{'maximum'}") if(defined($schema->{'maximum'}) && $number > $schema->{'maximum'});
   push(@normalized,$type eq 'numeric_array' ? $number : int($number));
  }
  return (1,\@normalized,undef);
 }
 if($type eq 'enum_or_legacy_map') {
  if(ref($value) eq 'HASH') {
   my @map_keys=@{ref($schema->{'map_keys'}) eq 'ARRAY' ? $schema->{'map_keys'} : []};
   foreach my $map_key (@map_keys) {
    return (0,undef,"legacy map is missing $map_key") if(!exists($value->{$map_key}));
   }
   foreach my $map_key (keys %{$value}) {
    return (0,undef,"legacy map contains unexpected key $map_key") if(!_contains_ci(\@map_keys,$map_key));
   }
   my %normalized;
   foreach my $map_key (@map_keys) {
    my $canonical=_canonical_enum_value($schema,$value->{$map_key});
    return (0,undef,"legacy map value for $map_key is invalid") if(!defined($canonical));
    $normalized{$map_key}=$canonical;
   }
   return (1,\%normalized,undef);
  }
  my $canonical=_canonical_enum_value($schema,$value);
  return (0,undef,'value is not a supported range token') if(!defined($canonical));
  if(ref($observed) eq 'HASH' && ref($schema->{'map_keys'}) eq 'ARRAY') {
   my %preserved=%{$observed};
   foreach my $map_key (@{$schema->{'map_keys'}}) {
    return (0,undef,"observed legacy map is missing $map_key") if(!exists($preserved{$map_key}));
   }
   $preserved{'unknown'}=$canonical;
   return (1,\%preserved,undef);
  }
  return (1,$canonical,undef);
 }
 return (0,undef,"unsupported value schema type $type");
}

sub _active_legacy_value {
 my ($value)=@_;
 return $value->{'unknown'} if(ref($value) eq 'HASH' && exists($value->{'unknown'}));
 return $value;
}

sub lg_setting_values_agree {
 my ($contract,$expected,$observed)=@_;
 return 0 if(ref($contract) ne 'HASH' || !defined($observed));
 my $comparator=ref($contract->{'verify'}) eq 'HASH' ? ($contract->{'verify'}{'comparator'}||'scalar') : 'scalar';
 if($comparator eq 'enum_or_active_legacy_map') {
  $expected=_active_legacy_value($expected);
  $observed=_active_legacy_value($observed);
 }
 if($comparator eq 'numeric') {
  my $left=_number($expected); my $right=_number($observed);
  return 0 if(!defined($left) || !defined($right));
  my $tolerance=0+($contract->{'verify'}{'tolerance'}||0);
  return abs($left-$right) <= $tolerance ? 1 : 0;
 }
 if($comparator eq 'numeric_or_array' && ref($expected) ne 'ARRAY') {
  return lg_setting_values_agree({%{$contract},verify=>{%{$contract->{'verify'}||{}},comparator=>'numeric'}},$expected,$observed);
 }
 if($comparator eq 'numeric_array' || $comparator eq 'numeric_or_array') {
  return 0 if(ref($expected) ne 'ARRAY' || ref($observed) ne 'ARRAY' || @{$expected} != @{$observed});
  my $tolerance=0+($contract->{'verify'}{'tolerance'}||0);
  for(my $i=0;$i<@{$expected};$i++) {
   my $left=_number($expected->[$i]); my $right=_number($observed->[$i]);
   return 0 if(!defined($left) || !defined($right) || abs($left-$right) > $tolerance);
  }
  return 1;
 }
 if($comparator eq 'enum' || $comparator eq 'enum_or_active_legacy_map') {
  my $schema=$contract->{'value_schema'}||{};
  my $left=_canonical_enum_value($schema,$expected);
  my $right=_canonical_enum_value($schema,$observed);
  return defined($left) && defined($right) && lc("$left") eq lc("$right") ? 1 : 0;
 }
 if($comparator eq 'picture_mode_semantic') {
  return 0 if(ref($expected) || ref($observed));
  my $left=lc($expected||''); my $right=lc($observed||'');
  $left=~s/[^a-z0-9]//g; $right=~s/[^a-z0-9]//g;
  my %aliases=(technicolor=>'expert',technicolorexpert=>'expert',filmmakermode=>'filmmaker');
  $left=$aliases{$left}||$left; $right=$aliases{$right}||$right;
  for my $mode ($left,$right) {
   $mode =~ s/^dolbyvision/dolbyhdr/;
   $mode='dolbyhdrcinema' if($mode =~ /^dolbyhdr(?:filmmaker(?:mode)?|cinemadark)$/);
   $mode='dolbyhdrcinemabright' if($mode eq 'dolbyhdrcinemahome');
   $mode='normal' if($mode eq 'standard');
  }
  return $left ne '' && $left eq $right ? 1 : 0;
 }
 return $JSON->encode($expected) eq $JSON->encode($observed) ? 1 : 0 if(ref($expected) || ref($observed));
 return defined($expected) && defined($observed) && "$expected" eq "$observed" ? 1 : 0;
}

sub lg_recipe {
 my ($signal,%options)=@_;
 $signal=lc($signal||'');
 $signal='dolby_vision' if($signal eq 'dv' || $signal eq 'dolbyvision');
 $signal='hdr10' if($signal eq 'hdr');
 my $library=load_lg_library($options{'root'});
 foreach my $recipe (@{$library->{'recipes'}||[]}) {
  return _clone($recipe) if(($recipe->{'signal'}||'') eq $signal);
 }
 return undef;
}

1;
