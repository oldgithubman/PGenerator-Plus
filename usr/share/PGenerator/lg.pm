#
# LG webOS TV helpers
#

use JSON::PP ();
use PGAutomation ();
use PGCalibrationLog ();
use File::Path qw(make_path remove_tree);
use Fcntl qw(:flock);
use IO::Select ();
use IO::Socket::INET ();
use MIME::Base64 ();
use Socket qw(inet_aton sockaddr_in);
# threads::shared degrades to no-ops when the loading process never loaded
# threads, so this is safe for any single-threaded consumer of this file.
use threads::shared;
use PGLGVerification qw(verify_lg_panel_light);
use PGLGCapabilities qw(lg_record_setting_observation);

# Serializes synchronous LG helper conversations across the WebUI's worker
# threads (see lg_helper_run). One TV, one conversation at a time.
my $_lg_helper_gate :shared = 0;

our $PGAC_LOADED = 0;
eval { require '/usr/share/PGenerator/PGAutoCalRun.pm'; $PGAC_LOADED = 1; 1 };

my $_LG_CEC_LG_DEVICE_CACHE={};
my $_LG_CEC_LG_DEVICE_CACHE_TIME=0;

###############################################
#                 LG Paths                     #
###############################################
sub lg_data_dir (@) {
 return "$var_dir/lg";
}

sub lg_clients_file (@) {
 return &lg_data_dir()."/clients.json";
}

sub lg_pin_sessions_dir (@) {
 return &lg_data_dir()."/pin-sessions";
}

sub lg_pin_session_dir (@) {
 my $token=shift;
 $token="" if(!defined($token));
 return &lg_pin_sessions_dir()."/$token";
}

sub lg_pin_state_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/state.json";
}

sub lg_pin_input_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/pin.txt";
}

sub lg_pin_log_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/helper.log";
}

sub lg_automation_execution_file (@) {
 my $base=$ENV{"PGEN_AUTOMATION_DIR"}||"/var/lib/PGenerator/automation";
 return $base."/execution.json";
}

sub lg_picture_settings_cache_path (@) {
 return &lg_data_dir()."/last-picture-settings.json";
}

sub lg_read_picture_settings_cache (@) {
 my $path=&lg_picture_settings_cache_path();
 return {} if(!open(my $fh,"<:raw",$path));
 my $raw="";
 { local $/; $raw=<$fh>//""; }
 close($fh);
 my $cache=eval { JSON::PP::decode_json($raw) };
 return (ref($cache) eq "HASH") ? $cache : {};
}

# Remember the last live picture-settings answer served over HTTP, merged per
# control, so the browser can be answered from it while automation owns the TV.
sub lg_picture_cache_context (@) {
 my ($result,$request)=@_;
 $request={} if(ref($request) ne 'HASH');
 my $settings=ref($result->{picture_settings}) eq 'HASH' ? $result->{picture_settings} : {};
 my $mode=$settings->{pictureMode}||$result->{active_picture_mode}||'';
 my $matrix=ref($result->{settings_matrix}) eq 'HASH' ? $result->{settings_matrix} : {};
 $mode=$matrix->{observed_picture_mode}||$matrix->{context}{picture_mode}||'' if(!$mode && $matrix->{context_confirmed});
 # Never use a requested selector as proof that an unrelated partial read
 # belongs to that mode. Missing context is a cache miss, not a merge key.
 return undef if(!$mode || $result->{virtual_picture_settings});
 my $profile=$result->{generation_profile}{capability_profile_hash}||'';
 my $input=$result->{current_input}||'';
 return undef if(!$profile || !$input);
 my $signal=$mode=~/^dolby/i ? 'dv' : $mode=~/^hdr/i ? 'hdr10' : 'sdr';
 $signal='hlg' if($signal eq 'hdr10' && ($request->{signal_mode}||'') eq 'hlg');
 return {ip=>$result->{ip}||'',profile=>$profile,input=>$input,mode=>lc($mode),signal=>$signal,
  category=>$request->{category}||'picture'};
}

sub lg_remember_picture_settings (@) {
 my ($json,$body)=@_;
 my $result=eval { JSON::PP::decode_json($json||'') };
 return 0 if(ref($result) ne 'HASH' || ($result->{status}||'') ne 'ok' || ref($result->{picture_settings}) ne 'HASH');
 my $request=eval { JSON::PP::decode_json($body||'{}') };
 my $context=&lg_picture_cache_context($result,$request);
 # An unscoped/virtual response must not leave an old coherent snapshot
 # labelled as current. Retain history but clear the current pointer.
 my ($ok)=PGAutomation::with_lock(&lg_picture_settings_cache_path(),sub {
  my ($store)=@_;$store={} if(ref($store) ne 'HASH' || ($store->{schema_version}||0)!=2);
  $store->{schema_version}=2;$store->{contexts}||={};
  if(!$context){delete $store->{current};return $store;}
  my $id=PGAutomation::encode_json($context);
  my $cache=$store->{contexts}{$id}||={context=>$context,picture_settings=>{},read_at=>{}};
  foreach my $key (keys %{$result->{picture_settings}}) {
   $cache->{picture_settings}{$key}=$result->{picture_settings}{$key};
   $cache->{read_at}{$key}=time();
  }
  foreach my $key (qw(current_input generation_profile lg_generation virtual_picture_settings)) {
   $cache->{$key}=$result->{$key} if(exists($result->{$key}));
  }
  my $width=ref($result->{supported_picture_keys}) eq 'ARRAY' ? scalar(@{$result->{supported_picture_keys}}) : 0;
  if($width>=($cache->{capability_width}||0)) {
   $cache->{capability_width}=$width;
   foreach my $key (qw(supported_picture_keys unsupported_picture_keys setting_contracts logical_controls)) {
    $cache->{$key}=$result->{$key} if(exists($result->{$key}));
   }
  }
  $cache->{updated_at}=time();$store->{current}=$id;
  my @old=sort {($store->{contexts}{$b}{updated_at}||0)<=>($store->{contexts}{$a}{updated_at}||0)} grep {$_ ne $id} keys %{$store->{contexts}};
  delete @{$store->{contexts}}{@old[31..$#old]} if(@old>31);
  return $store;
 });
 return $ok;
}

# Browser polling is read-only and cannot queue behind an active TV command.
# Partial reads may merge only inside the same device/input/signal/mode/category.
sub lg_browser_picture_settings_while_automation (@) {
 my ($body)=@_;
 my $stored=PGAutomation::read_state(&lg_automation_execution_file());
 return '' if($stored->{state} eq 'missing');
 return &lg_encode_json({status=>'error',error_code=>'automation-state-unreadable',message=>'Automation ownership is unreadable; live TV reads are deferred.'}) if($stored->{state} ne 'ok');
 my $execution=$stored->{value};my $status=$execution->{status}||'';
 return '' if($status!~/^(?:starting|running|completing|stopping)$/);
 my $payload=eval {JSON::PP::decode_json($body||'{}')};$payload={} if(ref($payload) ne 'HASH');
 my $token=$payload->{automation_token}||'';
 return '' if($token ne '' && $token eq ($execution->{token}||''));
 my $store=&lg_read_picture_settings_cache();
 my $cache=($store->{schema_version}||0)==2 ? $store->{contexts}{$store->{current}||''} : undef;
 my $cache_present=ref($cache) eq 'HASH' ? 1 : 0;
 my $context=ref($cache) eq 'HASH' ? $cache->{context}||{} : {};
 my %request_fields=(picture_mode=>'mode',tv_input=>'input',signal_mode=>'signal',category=>'category');
 my $matches=ref($cache) eq 'HASH';
 for my $key (keys %request_fields) {
  next if(!defined($payload->{$key}) || $payload->{$key} eq '');
  $matches=0 if(lc($payload->{$key}) ne lc($context->{$request_fields{$key}}||''));
 }
 $cache={} if(!$matches);
 my $known=$cache->{picture_settings}||{};
 my $keys=$payload->{keys};$keys=[sort keys %$known] if(ref($keys) ne 'ARRAY' || !@$keys);
 my %settings=map {exists($known->{$_}) ? ($_=>$known->{$_}) : ()} @$keys;
 return &lg_encode_json({status=>'ok',cached=>&lg_json_true(),automation_active=>&lg_json_true(),
  run_id=>$execution->{run_id}||'',picture_settings=>\%settings,cache_context_available=>&lg_json_bool($matches),cache_present=>&lg_json_bool($cache_present),
  (map {exists($cache->{$_}) ? ($_=>$cache->{$_}) : ()} qw(current_input generation_profile lg_generation virtual_picture_settings supported_picture_keys unsupported_picture_keys setting_contracts logical_controls)),
  cached_at=>$cache->{updated_at}||0,read_at=>$cache->{read_at}||{},
  message=>$matches ? 'Values from the last read in this TV/input/signal/picture-mode context; automation owns the TV.'
   : 'No coherent cached values for this context. Live reads are deferred while automation owns the TV.'});
}

sub lg_automation_guard_json (@) {
 my ($body)=@_;
 my $execution_file=&lg_automation_execution_file();
 my $stored=PGAutomation::read_state($execution_file);
 return "" if($stored->{state} eq 'missing');
 return &lg_encode_json({status=>'error',error_code=>'automation-state-unreadable',
  message=>'Automation ownership cannot be read; device writes are blocked until recovery state is restored'})
  if($stored->{state} ne 'ok');
 my $execution=$stored->{value};
 my $status=$execution->{status}||"";
 return &lg_encode_json({status=>'error',error_code=>'automation-state-unreadable',message=>'Automation ownership has an invalid status'})
  if($status !~ /^(?:starting|running|paused|stopping|completing|interrupted|complete(?:-with-warnings)?|failed|stopped)$/);
 return "" if($status ne "starting" && $status ne "running"
  && $status ne "paused" && $status ne "stopping" && $status ne "completing" && $status ne "interrupted");
 my $payload=eval { JSON::PP::decode_json($body||"") };
 $payload={} if(ref($payload) ne "HASH");
 my $token=$payload->{automation_token}||"";
 if($token ne "" && $token eq ($execution->{token}||"")) {
  my $id=$execution->{run_id}||"";
  if(!$payload->{automation_cleanup} && $id=~/\A[A-Za-z0-9._-]+\z/ && $id ne "." && $id ne "..") {
   my $base=$ENV{PGEN_AUTOMATION_DIR}||"/var/lib/PGenerator/automation";
   my $control;
   if(open(my $fh,"<:raw","$base/runs/$id/control.json")) {local $/;$control=eval {JSON::PP::decode_json(<$fh>)};close($fh);}
   return &lg_encode_json({status=>"error",error_code=>"automation-stopping",message=>"Automation is stopping; pending TV changes were cancelled"})
    if(ref($control) eq "HASH" && ($control->{request}||"") eq "stop");
  }
  return "";
 }
 my $run_id=$execution->{run_id}||"current run";
 return &lg_encode_json({
  status => "error",
  error_code => "automation-active",
  message => "Automation queue is active ($run_id). Stop or finish it before starting a guided LG or meter operation.",
  run_id => $run_id,
 });
}

# Scoped categories look like "picture$hdmi1.filmMaker.2d.x". Keep the dollar
# escaped inside the class: an unescaped "$_" there interpolates the current
# topic and silently drops the dollar, downgrading every scoped category.
sub lg_picture_category_or_default (@) {
 my ($category)=@_;
 return "picture" if(!defined($category) || $category eq "" || $category !~ /\A[A-Za-z0-9\$_.-]{1,200}\z/);
 return $category;
}

sub lg_helper_path (@) {
 return "/usr/sbin/pgenerator-lg";
}

sub lg_shell_quote (@) {
 my $text=shift;
 $text="" if(!defined($text));
 $text =~ s/'/'"'"'/g;
 return "'$text'";
}

###############################################
#              LG JSON Helpers                #
###############################################
sub lg_json_true (@) {
 return JSON::PP::true;
}

sub lg_json_false (@) {
 return JSON::PP::false;
}

sub lg_json_bool (@) {
 my $value=shift;
 return $value ? &lg_json_true() : &lg_json_false();
}

sub lg_decode_json (@) {
 my $raw=shift;
 return {} if(!defined($raw) || $raw eq "");
 my $data={};
 eval { $data=JSON::PP::decode_json($raw); 1; } or return {};
 return (ref($data) eq "HASH") ? $data : {};
}

sub lg_encode_json (@) {
 my $data=shift;
 return JSON::PP::encode_json($data);
}

# Helper responses carry the WebOS client key so the daemon can persist a
# newly paired connection. The browser never needs that credential. Redact it
# recursively at the public API boundary while retaining client_key_present.
sub lg_public_api_json (@) {
 my $raw=shift;
 return $raw if(!defined($raw) || $raw eq "");
 my $decoded=eval { JSON::PP::decode_json($raw) };
 # Fail CLOSED: an undecodable body must never pass through raw -- leaking
 # the pairing key is the one failure this boundary exists to prevent. The
 # envelope is a fixed literal on purpose; echoing any part of $raw would
 # leak what it was written to contain.
 return '{"status":"error","message":"LG response could not be prepared for the public API"}' if(!defined($decoded));
 my $redact;
 $redact=sub {
  my ($value)=@_;
  if(ref($value) eq "HASH") {
   delete($value->{"client_key"});
   delete($value->{"client-key"});
   delete($value->{"clientKey"});
   $redact->($_) foreach(values(%{$value}));
  } elsif(ref($value) eq "ARRAY") {
   $redact->($_) foreach(@{$value});
  }
 };
 $redact->($decoded);
 return JSON::PP::encode_json($decoded);
}

###############################################
#             LG Persistence                  #
###############################################
sub lg_ensure_data_dir (@) {
 my $dir=&lg_data_dir();
 return 1 if(-d $dir);
 eval { make_path($dir); 1; };
 return (-d $dir) ? 1 : 0;
}

sub lg_load_clients (@) {
 my $file=&lg_clients_file();
 return {} if(!-f $file);
 return &lg_decode_json(&read_from_file($file));
}

sub lg_save_clients (@) {
 my $clients=shift;
 $clients={} if(ref($clients) ne "HASH");
 return 0 if(!&lg_ensure_data_dir());
 my $file=&lg_clients_file();
 # Checked write instead of the global write_file(), which ignores every
 # open/print/rename error: this store carries the held-calibration-session
 # flag, and lg_prepare_held_calibration_mode's fail-closed gate is dead
 # code if a full or read-only filesystem can "succeed" silently here.
 my $tmp="$file.tmp";
 my $fh;
 return 0 if(!open($fh,">",$tmp));
 my $written=(print $fh &lg_encode_json($clients));
 $written=0 if(!close($fh));
 if(!$written) { unlink($tmp); return 0; }
 if(!rename($tmp,$file)) { unlink($tmp); return 0; }
 # &sync() lives in command.pm; both load into main (no package decls) and
 # PGeneratord.pl loads command.pm before lg.pm. A test loading lg.pm alone
 # must stub main::sync before calling this.
 &sync();
 return 1;
}

sub lg_generate_token (@) {
 return sprintf("%x%x%x",time(),$$,int(rand(0x7fffffff)));
}

sub lg_load_pin_state (@) {
 my $token=shift;
 return {} if(!defined($token) || $token eq "");
 my $file=&lg_pin_state_file($token);
 return {} if(!-f $file);
 return &lg_decode_json(&read_from_file($file));
}

sub lg_clear_pin_session_files (@) {
 my $token=shift;
 return 1 if(!defined($token) || $token eq "");
 my $dir=&lg_pin_session_dir($token);
 return 1 if(!-d $dir);
 eval { remove_tree($dir); 1; };
 return (!-d $dir) ? 1 : 0;
}

sub lg_save_pin_session_meta (@) {
 my ($clients,$meta)=@_;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 if(ref($meta) eq "HASH") {
  $clients->{"pin_pairing"}=$meta;
 } else {
  delete($clients->{"pin_pairing"});
 }
 return &lg_save_clients($clients);
}

sub lg_reconcile_pin_pairing (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 my $meta=$clients->{"pin_pairing"};
 return ($clients,{}) if(ref($meta) ne "HASH");
 my $token=$meta->{"token"}||"";
 return ($clients,{}) if($token eq "");
 my $state=&lg_load_pin_state($token);
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "pending") {
  $state->{"token"}=$token if(($state->{"token"}||"") eq "");
  return ($clients,$state);
 }
 my $manual_ip=$clients->{"manual_ip"}||"";
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip);
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return ($updated,{});
 }
 my $failure="";
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "error") {
  $failure=$state->{"message"}||"LG PIN pairing failed.";
 } elsif(time() - int($meta->{"started_at"}||0) > 240) {
  $failure="LG PIN pairing timed out. Start PIN Pairing again.";
 }
 if($failure ne "") {
  delete($clients->{"pin_pairing"});
  $clients->{"last_error"}=$failure;
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
 }
 return ($clients,{});
}

# Forget a single saved TV. $target_ip selects which set (by its device-list
# IP) to forget; when empty - or when it matches the active/flat set - the
# active TV is forgotten. Every OTHER set's key in the per-TV keyring is kept,
# so forgetting one TV can no longer wipe the rest (this no longer unlinks the
# whole store).
sub lg_clear_pairing (@) {
 my ($target_ip)=@_;
 $target_ip="" if(!defined($target_ip));
 my $clients=&lg_load_clients();
 my $pin_pairing=$clients->{"pin_pairing"};
 if(ref($pin_pairing) eq "HASH" && ($pin_pairing->{"token"}||"") ne "") {
  &lg_clear_pin_session_files($pin_pairing->{"token"});
 }
 delete($clients->{"pin_pairing"});

 my ($act_uuid,$act_mac)=&lg_device_identity($clients);
 my $act_ip=$clients->{"ip"}||"";

 # Decide which set to forget: the active TV (matched by its stable identity)
 # when no target IP is given or the target is the active set; otherwise the
 # keyring entry whose last-known IP matches the selected list row.
 my ($t_uuid,$t_mac)=("","");
 my $forget_active=0;
 if($target_ip eq "" || ($act_ip ne "" && $target_ip eq $act_ip)) {
  ($t_uuid,$t_mac)=($act_uuid,$act_mac);
  $forget_active=1;
 } else {
  if(ref($clients->{"devices"}) eq "ARRAY") {
   foreach my $e (@{$clients->{"devices"}}) {
    next if(ref($e) ne "HASH");
    if(($e->{"last_ip"}||"") eq $target_ip) {
     ($t_uuid,$t_mac)=(lc($e->{"uuid"}||""),lc($e->{"mac"}||""));
     last;
    }
   }
  }
  $forget_active=1 if($t_uuid ne "" && $act_uuid ne "" && $t_uuid eq $act_uuid);
  $forget_active=1 if($t_mac ne "" && $act_mac ne "" && $t_mac eq $act_mac);
 }

 # Drop the matching keyring entry (by identity).
 if(ref($clients->{"devices"}) eq "ARRAY" && ($t_uuid ne "" || $t_mac ne "")) {
  @{$clients->{"devices"}}=grep {
   !(ref($_) eq "HASH" &&
     (($t_uuid ne "" && lc($_->{"uuid"}||"") eq $t_uuid) ||
      ($t_mac ne "" && lc($_->{"mac"}||"") eq $t_mac)))
  } @{$clients->{"devices"}};
 }

 # If the forgotten set is the active one, clear its flat connection fields.
 # manual_ip and the rest of the keyring are intentionally preserved.
 if($forget_active) {
  foreach my $k ("client_key","client-key","ip","name","model_name",
                 "software_version","transport","hello_info","system_info",
                 "software_info","last_seen","calibration_mode",
                 "calibration_picture_mode","disconnected","disconnected_at",
                 "last_written_picture_mode","last_written_picture_mode_at",
                 "last_error") {
   delete($clients->{$k});
  }
 }

 delete($clients->{"devices"}) if(ref($clients->{"devices"}) eq "ARRAY" && !@{$clients->{"devices"}});

 return &lg_save_clients($clients);
}

###############################################
#              LG Data Helpers                #
###############################################
sub lg_valid_ipv4 (@) {
 my $ip=shift;
 return 0 if(!defined($ip) || $ip eq "");
 return 0 if($ip !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
 foreach my $octet ($1,$2,$3,$4) {
  return 0 if($octet < 0 || $octet > 255);
 }
 return 1;
}

sub lg_normalize_pairing_mode (@) {
 my $mode=uc(shift||"PIN");
 return $mode if($mode =~ /^(PIN|COMBINED|LGSWITCH-PIN)$/);
 return "PIN";
}

sub lg_primary_client (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 if((($clients->{"client_key"}||"") ne "") || (($clients->{"ip"}||"") ne "") || (($clients->{"model_name"}||"") ne "") || (($clients->{"name"}||"") ne "")) {
  return $clients;
 }
 foreach my $key ("devices","clients") {
  next if(ref($clients->{$key}) ne "ARRAY");
  foreach my $entry (@{$clients->{$key}}) {
   next if(ref($entry) ne "HASH");
   my $client_key=$entry->{"client_key"}||$entry->{"client-key"}||"";
   my $ip=$entry->{"ip"}||"";
   next if($client_key eq "" && $ip eq "");
   return $entry;
  }
 }
 return {};
}

sub lg_client_key_present (@) {
 my $clients=shift;
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return $client_key ne "" ? 1 : 0;
}

sub lg_clients_disconnected (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 return ($clients->{"disconnected"} && &lg_client_key_present($clients)) ? 1 : 0;
}

sub lg_mark_disconnected (@) {
 my $clients=&lg_load_clients();
 my $pin_pairing=$clients->{"pin_pairing"};
 if(ref($pin_pairing) eq "HASH" && ($pin_pairing->{"token"}||"") ne "") {
  &lg_clear_pin_session_files($pin_pairing->{"token"});
 }
 delete($clients->{"pin_pairing"});
 $clients->{"disconnected"}=&lg_json_true();
 $clients->{"disconnected_at"}=time();
 # A power-cycle or unplug drops the WebSocket and lands here.
 # last_written_picture_mode is only trustworthy while the session that wrote
 # it is still up: after a disconnect the panel may have been switched by
 # remote or come back in a different mode, and on a set that cannot report
 # its mode this record is the preflight guard's only evidence. Tie its
 # lifetime to the connection.
 delete($clients->{"last_written_picture_mode"});
 delete($clients->{"last_written_picture_mode_at"});
 return &lg_save_clients($clients);
}

sub lg_cec_status (@) {
 my $raw="";
 eval { $raw=&webui_cec("status"); 1; };
 return &lg_decode_json($raw);
}

###############################################
#        TV Power Gate (CEC-backed)           #
###############################################
# A powered-off LG panel does not refuse TCP connections, it silently drops
# the SYNs, so a helper spawn against it runs to its outer "timeout Ns"
# wrapper instead of failing fast. Those spawns are synchronous backticks
# (lg_helper_run) executed on the daemon's single WebUI request thread, so
# each one freezes the entire WebUI for the full wrapper. The read-only state
# polls are the common case -- the AutoCal panels re-sync every ~30s whether
# or not anyone is calibrating -- so we short-circuit those when CEC already
# knows the panel is in standby.
#
# Everything here FAILS OPEN. A missing, stale, unparseable or "unknown"
# reading, no CEC on this box, or a calibration in flight all fall through to
# the normal helper path. A CEC problem must never make a reachable TV look
# unreachable.

# CEC power state is cached in a file by the WebUI's own /api/cec/status path
# (webui_cec_power_cache_write). We read the FILE rather than webui.pm's
# $_cec_cache / $_cec_last_power_query lexicals on purpose: those are plain
# "my" variables, so under Perl ithreads any handler running on a different
# thread gets its own private copy and the reading silently vanishes. The
# file is the only representation shared across threads.
$LG_CEC_POWER_CACHE_FILE="/tmp/pgenerator-cec-power.json";
# Oldest reading we will gate on. The CEC status path refreshes the file at
# most once per $_CEC_POWER_QUERY_THROTTLE (15s) while a browser is polling;
# beyond this we treat it as stale and let the request through.
$LG_TV_OFF_GATE_MAX_AGE=90;

sub lg_cec_power_state_cached (@) {
 my $max_age=shift;
 $max_age=$LG_TV_OFF_GATE_MAX_AGE if(!defined($max_age) || $max_age <= 0);
 return "" if(!-f $LG_CEC_POWER_CACHE_FILE);
 my $mtime=(stat($LG_CEC_POWER_CACHE_FILE))[9]||0;
 return "" if(!$mtime);
 return "" if((time() - $mtime) > $max_age);
 my $json="";
 if(open(my $fh,"<",$LG_CEC_POWER_CACHE_FILE)) { local $/; $json=<$fh>; close($fh); }
 return "" if(!defined($json) || $json eq "");
 my ($power)=($json =~ /"tv_power"\s*:\s*"([^"]*)"/);
 return "" if(!defined($power));
 $power=lc($power);
 $power=~s/^\s+//;
 $power=~s/\s+$//;
 return $power;
}

sub lg_calibration_run_active (@) {
 # Never gate while a calibration or meter run is in flight: those paths
 # drive the TV themselves and may legitimately be mid-wake, and a stale
 # CEC reading must not be allowed to interrupt them.
 foreach my $state_file ("/tmp/meter_lg_autocal.json","/tmp/meter_lg_3d_autocal.json") {
  next if(!-f $state_file);
  my $json="";
  if(open(my $fh,"<",$state_file)) { local $/; $json=<$fh>; close($fh); }
  next if(!defined($json) || $json eq "");
  return 1 if($json=~/"status"\s*:\s*"running"/);
 }
 # An open meter session means a read is in progress or imminent.
 return 1 if(-f "/tmp/meter_session.pid");
 return 0;
}

sub lg_tv_powered_off (@) {
 # True ONLY on a fresh, unambiguous "the panel is in standby" reading.
 # "powering-on"/"powering-off" are transitional -- the TV may answer at any
 # moment -- so they are deliberately not gated.
 my $power=&lg_cec_power_state_cached();
 return 0 if($power eq "");
 return 1 if($power eq "standby" || $power eq "off");
 return 0;
}

sub lg_tv_off_gate (@) {
 # Returns an error hashref to short-circuit a READ-ONLY state poll, or
 # undef to proceed exactly as before. Callers must only use this for polls
 # that merely observe TV state. Control actions (wake/power, pairing, input
 # switching) and the whole calibration path must never be gated: those are
 # user-initiated and are allowed to spend the time, and some of them are
 # what turns the TV back on.
 my $what=shift;
 $what="read TV state" if(!defined($what) || $what eq "");
 return undef if(&lg_calibration_run_active());
 return undef if(!&lg_tv_powered_off());
 return {
  status   => "error",
  message  => "LG TV is powered off (CEC reports standby). Turn the TV on to $what.",
  tv_off   => &lg_json_true(),
  tv_power => "standby",
 };
}

sub lg_detect_from_cec (@) {
 my $cec=shift;
 return 0 if(ref($cec) ne "HASH");
 my $osd_name=lc($cec->{"osd_name"}||"");
 return 1 if($osd_name =~ /\blg\b/);
 return 0;
}

sub lg_boot_id (@) {
 my $path="/proc/sys/kernel/random/boot_id";
 return "" if(!open(my $fh,"<",$path));
 my $id=<$fh>;
 close($fh);
 chomp($id);
 $id=~s/[^A-Za-z0-9-]//g;
 return $id;
}

sub lg_cec_vendor_is_lg (@) {
 my $vendor=lc(shift||"");
 $vendor=~s/^0x//;
 $vendor=~s/[^0-9a-f]//g;
 return ($vendor eq "00e091") ? 1 : 0;
}

sub lg_clean_cec_name (@) {
 my $name=shift;
 $name="" if(!defined($name));
 $name=~s/[\x00-\x1f\x7f]+//g;
 $name=~s/^\s+|\s+$//g;
 return $name;
}

sub lg_cec_lg_device (@) {
 return {};
}

sub lg_input_from_cec (@) {
 my $cec=&lg_cec_status();
 return "" if(ref($cec) ne "HASH");
 my $phys=$cec->{"phys_addr"}||"";
 return "hdmi$1" if($phys =~ /^([1-4])(?:\.|$)/);
 return "";
}

sub lg_discovery_hosts (@) {
 return ("lgwebostv.local","LGwebOSTV.local");
}

sub lg_mdns_encode_name (@) {
 my $name=shift;
 $name=lc($name||"");
 return "" if($name eq "");
 my $out="";
 foreach my $label (split(/\./,$name)) {
  return "" if($label eq "" || length($label) > 63);
  $out.=chr(length($label)).$label;
 }
 return $out."\0";
}

sub lg_mdns_read_name (@) {
 my ($packet,$offset,$depth)=@_;
 $depth=int($depth||0);
 return ("",$offset) if($offset < 0 || $offset >= length($packet) || $depth > 10);
 my $name="";
 my $pos=$offset;
 my $next=$offset;
 my $jumped=0;
 while($pos < length($packet)) {
  my $len=ord(substr($packet,$pos,1));
  $pos++;
  if($len == 0) {
   $next=$pos if(!$jumped);
   last;
  }
  if(($len & 0xC0) == 0xC0) {
   return ("",$offset) if($pos >= length($packet));
   my $pointer=(($len & 0x3F) << 8) | ord(substr($packet,$pos,1));
   $pos++;
   my ($suffix)=&lg_mdns_read_name($packet,$pointer,$depth + 1);
   $name.="." if($name ne "" && $suffix ne "");
   $name.=$suffix;
   $next=$pos if(!$jumped);
   $jumped=1;
   last;
  }
  return ("",$offset) if($pos + $len > length($packet));
  my $label=substr($packet,$pos,$len);
  $pos+=$len;
  $name.="." if($name ne "");
  $name.=$label;
  $next=$pos if(!$jumped);
 }
 return (lc($name),$next);
}

sub lg_mdns_parse_ipv4 (@) {
 my ($packet,$wanted_name)=@_;
 return "" if(!defined($packet) || length($packet) < 12 || !defined($wanted_name) || $wanted_name eq "");
 my (undef,$flags,$qdcount,$ancount,$nscount,$arcount)=unpack("n6",substr($packet,0,12));
 return "" if(($flags & 0x8000) == 0);
 my $offset=12;
 for(my $i=0;$i<$qdcount;$i++) {
  my (undef,$next)=&lg_mdns_read_name($packet,$offset,0);
  return "" if($next <= $offset || $next + 4 > length($packet));
  $offset=$next + 4;
 }
 my $records=$ancount + $nscount + $arcount;
 for(my $i=0;$i<$records;$i++) {
  my ($name,$next)=&lg_mdns_read_name($packet,$offset,0);
  return "" if($next <= $offset || $next + 10 > length($packet));
  $offset=$next;
  my ($type,$class,$ttl,$rdlength)=unpack("nnNn",substr($packet,$offset,10));
  $offset+=10;
  return "" if($offset + $rdlength > length($packet));
  if(lc($name) eq lc($wanted_name) && $type == 1 && ($class & 0x7FFF) == 1 && $rdlength == 4) {
   return join('.',unpack('C4',substr($packet,$offset,4)));
  }
  $offset+=$rdlength;
 }
 return "";
}

sub lg_mdns_lookup_host (@) {
 my ($host,$timeout)=@_;
 $host=lc($host||"");
 return "" if($host eq "");
 $timeout=1.2 if(!defined($timeout) || $timeout <= 0);
 my $socket=IO::Socket::INET->new(
  Proto => 'udp',
  LocalPort => 0,
  ReuseAddr => 1,
 );
 return "" if(!$socket);
 my $target=inet_aton("224.0.0.251");
 if(!$target) {
  close($socket);
  return "";
 }
 my $packet=pack("n6",0,0,1,0,0,0).&lg_mdns_encode_name($host).pack("nn",1,0x8001);
 if($packet eq "") {
  close($socket);
  return "";
 }
 send($socket,$packet,0,sockaddr_in(5353,$target));
 my $select=IO::Select->new($socket);
 my $deadline=time() + $timeout;
 while(time() < $deadline) {
  my $remaining=$deadline - time();
  last if($remaining <= 0);
  my @ready=$select->can_read($remaining);
  next if(!@ready);
  my $response="";
  recv($socket,$response,1500,0);
  my $ip=&lg_mdns_parse_ipv4($response,$host);
  if(&lg_valid_ipv4($ip)) {
   close($socket);
   return $ip;
  }
 }
 close($socket);
 return "";
}

sub lg_autodetect_info (@) {
 my ($clients,$force_refresh)=@_;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 $force_refresh=$force_refresh ? 1 : 0;
 my $cached_ip=$clients->{"auto_ip"}||"";
 my $cached_host=$clients->{"auto_host"}||"";
 my $cached_at=int($clients->{"auto_detected_at"}||0);
 my $rejected_ip=$clients->{"auto_rejected_ip"}||"";
 my $rejected_at=int($clients->{"auto_rejected_at"}||0);
 if(!$force_refresh && &lg_valid_ipv4($cached_ip) && $cached_at > 0 && (time() - $cached_at) < 60) {
  return { ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
 }
 if(!$force_refresh && &lg_valid_ipv4($rejected_ip) && $rejected_at > 0 && (time() - $rejected_at) < 120) {
  return {};
 }
 foreach my $host (&lg_discovery_hosts()) {
  my $ip=&lg_mdns_lookup_host($host,1.2);
  next if(!&lg_valid_ipv4($ip));
  if(!$force_refresh && $ip eq $rejected_ip && $rejected_at > 0 && (time() - $rejected_at) < 120) {
   next;
  }
  my $probe=&lg_probe_device($ip);
  if(ref($probe) ne "HASH" || ($probe->{"status"}||"") ne "ok" || !$probe->{"is_lg_tv"}) {
   delete($clients->{"auto_ip"});
   delete($clients->{"auto_host"});
   delete($clients->{"auto_detected_at"});
   $clients->{"auto_rejected_ip"}=$ip;
   $clients->{"auto_rejected_host"}=lc($host);
   $clients->{"auto_rejected_at"}=time();
   &lg_save_clients($clients);
   next;
  }
  $clients->{"auto_ip"}=$ip;
  $clients->{"auto_host"}=lc($host);
  $clients->{"auto_detected_at"}=time();
  delete($clients->{"auto_rejected_ip"});
  delete($clients->{"auto_rejected_host"});
  delete($clients->{"auto_rejected_at"});
  &lg_save_clients($clients);
  return { ip => $ip, host => lc($host), source => "mdns-hostname" };
 }
 if(&lg_valid_ipv4($cached_ip)) {
  return { ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
 }
 return {};
}

sub lg_scan_add_device (@) {
 my ($devices,$seen,$ip,$source,$name,$model)=@_;
 return if(ref($devices) ne "ARRAY" || ref($seen) ne "HASH" || !&lg_valid_ipv4($ip));
 return if($seen->{$ip});
 $seen->{$ip}=1;
 $name="" if(!defined($name));
 $model="" if(!defined($model));
 push(@{$devices},{
  ip => $ip,
  source => $source||"scan",
  name => $name,
  model_name => $model,
  label => ($name ne "" ? $name : ($model ne "" ? $model : "LG WebOS TV"))." ($ip)",
 });
}

my $_LG_PROBE_CACHE={};

sub lg_probe_device (@) {
 my $ip=shift;
 return {} if(!&lg_valid_ipv4($ip));
 return $_LG_PROBE_CACHE->{$ip} if(ref($_LG_PROBE_CACHE->{$ip}) eq "HASH");
 my $result=&lg_helper_run({
  action => "probe",
  ip => $ip,
  connect_timeout => 1,
 });
 $_LG_PROBE_CACHE->{$ip}=$result;
 return $result;
}

sub lg_scan_add_probe_device (@) {
 my ($devices,$seen,$ip,$source,$name,$model)=@_;
 return if(ref($devices) ne "ARRAY" || ref($seen) ne "HASH" || !&lg_valid_ipv4($ip));
 return if($seen->{$ip});
 my $probe=&lg_probe_device($ip);
 return if(ref($probe) ne "HASH" || ($probe->{"status"}||"") ne "ok" || !$probe->{"is_lg_tv"});
 $name=$probe->{"name"}||$name||"";
 $model=$probe->{"model_name"}||$model||"";
 &lg_scan_add_device($devices,$seen,$ip,$source,$name,$model);
}

sub lg_ipv4_to_int (@) {
 my $ip=shift;
 return undef if(!&lg_valid_ipv4($ip));
 my @p=split(/\./,$ip);
 return (($p[0]<<24) | ($p[1]<<16) | ($p[2]<<8) | $p[3]);
}

sub lg_int_to_ipv4 (@) {
 my $value=shift;
 return join(".",(($value>>24)&255),(($value>>16)&255),(($value>>8)&255),($value&255));
}

sub lg_local_broadcasts (@) {
 my @broadcasts=();
 my %seen=();
 my $raw=`ip -o -4 addr show scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip,$prefix,$brd)=($line =~ /\binet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)(?:\s+brd\s+(\d+\.\d+\.\d+\.\d+))?/);
  next if(!&lg_valid_ipv4($ip));
  if(&lg_valid_ipv4($brd||"")) {
   next if($seen{$brd}++);
   push(@broadcasts,$brd);
   next;
  }
  next if(!defined($prefix) || $prefix < 16 || $prefix > 30);
  my $addr=&lg_ipv4_to_int($ip);
  next if(!defined($addr));
  my $mask=(0xffffffff << (32-$prefix)) & 0xffffffff;
  my $broadcast=($addr & $mask) | ((~$mask) & 0xffffffff);
  my $brd_ip=&lg_int_to_ipv4($broadcast);
  next if($seen{$brd_ip}++);
  push(@broadcasts,$brd_ip);
 }
 return @broadcasts;
}

sub lg_prime_neighbor_table (@) {
 return;
 foreach my $broadcast (&lg_local_broadcasts()) {
  next if(!&lg_valid_ipv4($broadcast));
  `timeout 2 ping -b -c 1 -W 1 $broadcast >/dev/null 2>&1`;
 }
}

sub lg_neighbor_ips (@) {
 my %ips=();
 my $raw=`ip -4 neigh show 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip)=($line =~ /^(\d+\.\d+\.\d+\.\d+)\s+/);
  next if(!&lg_valid_ipv4($ip));
  next if($line =~ /\b(?:FAILED|INCOMPLETE)\b/i);
  next if($line !~ /\b(?:REACHABLE|DELAY|PROBE)\b/i);
  $ips{$ip}=1;
 }
 $raw=`timeout 1 arp -an 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  next if($line !~ /\b(?:REACHABLE|DELAY|PROBE)\b/i);
  my ($ip)=($line =~ /\((\d+\.\d+\.\d+\.\d+)\)/);
  $ips{$ip}=1 if(&lg_valid_ipv4($ip));
 }
 return sort(keys(%ips));
}

sub lg_webos_port_open (@) {
 my $ip=shift;
 return 0 if(!&lg_valid_ipv4($ip));
 foreach my $port (3000,3001) {
  my $sock=IO::Socket::INET->new(
   PeerHost => $ip,
   PeerPort => $port,
   Proto => 'tcp',
   Timeout => 0.22,
  );
  if($sock) {
   close($sock);
   return $port;
  }
 }
 return 0;
}

sub lg_ssdp_devices (@) {
 my @devices=();
 my %seen=();
 my $sock=IO::Socket::INET->new(
  Proto => "udp",
  PeerAddr => "239.255.255.250",
  PeerPort => 1900,
  Timeout => 0.4,
 );
 return \@devices if(!$sock);
 my @st=(
  "urn:lge-com:service:webos-second-screen:1",
  "urn:lge-com:device:webos:1",
  "ssdp:all",
 );
 foreach my $st (@st) {
  my $msg="M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: $st\r\n\r\n";
  eval { $sock->send($msg); 1; };
 }
 my $select=IO::Select->new($sock);
 my $deadline=time()+2;
 while(time() < $deadline) {
  my $remaining=$deadline-time();
  $remaining=0.1 if($remaining < 0.1);
  my @ready=$select->can_read($remaining);
  last if(!@ready);
  my $buf="";
  my $peer=$sock->recv($buf,4096);
  next if(!defined($buf) || $buf eq "");
  my $lc=lc($buf);
  next if($lc !~ /(lge|webos|lg electronics|second-screen)/);
  my $ip="";
  if($buf =~ /^LOCATION:\s*https?:\/\/(\d+\.\d+\.\d+\.\d+)(?::\d+)?\//im) {
   $ip=$1;
  } elsif(defined($peer)) {
   my ($port,$addr)=sockaddr_in($peer);
   $ip=join(".",unpack("C4",$addr)) if(defined($addr));
  }
  next if(!&lg_valid_ipv4($ip) || $seen{$ip}++);
  my $name="LG WebOS TV";
  if($buf =~ /^SERVER:\s*(.+)$/im) {
   my $server=$1;
   $server=~s/\r//g;
   if($server =~ /(webos[^\s;]*)/i) { $name="LG WebOS TV"; }
  }
  push(@devices,{ ip => $ip, source => "ssdp", name => $name, model_name => "" });
 }
 close($sock);
 return \@devices;
}

sub lg_default_lan_subnets (@) {
 my @subnets=();
 my %seen=();
 my $route=`ip route show default 2>/dev/null | head -n 1`;
 my ($iface)=($route =~ /\bdev\s+(\S+)/);
 return @subnets if(!defined($iface) || $iface eq "");
 my $raw=`ip -o -4 addr show dev $iface scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip,$prefix)=($line =~ /\binet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/);
  next if(!&lg_valid_ipv4($ip) || !defined($prefix));
  next if($prefix != 24);
  my @p=split(/\./,$ip);
  my $base=join(".",@p[0..2]);
  next if($seen{$base}++);
  push(@subnets,{ iface => $iface, base => $base, self => $ip });
 }
 return @subnets;
}

sub lg_webos_port_sweep_devices (@) {
 my @devices=();
 my %seen=();
 foreach my $subnet (&lg_default_lan_subnets()) {
  next if(ref($subnet) ne "HASH");
  my $base=$subnet->{"base"}||"";
  next if($base !~ /^\d+\.\d+\.\d+$/);
  my $script='for i in $(seq 1 254); do (ip='.$base.'.$i; timeout 0.35 bash -c "echo >/dev/tcp/$ip/3000" >/dev/null 2>&1 && echo "$ip 3000"; timeout 0.35 bash -c "echo >/dev/tcp/$ip/3001" >/dev/null 2>&1 && echo "$ip 3001")& done; wait';
  my $cmd="timeout 5 bash -c ".&lg_shell_quote($script)." 2>/dev/null";
  my $raw=`$cmd`;
  foreach my $line (split(/\n/,$raw)) {
   my ($ip,$port)=($line =~ /^(\d+\.\d+\.\d+\.\d+)\s+(300[01])$/);
   next if(!&lg_valid_ipv4($ip) || $seen{$ip}++);
   push(@devices,{ ip => $ip, source => "webos-sweep:$port", name => "LG WebOS TV", model_name => "" });
  }
 }
 return \@devices;
}

# Append every TV with a stored pairing key -- online or not, no
# reachability probe. The operator must be able to see (and forget) a
# saved pairing immediately, without waiting for network discovery. The
# active flat set is also in the keyring (upserted on connect), so
# %seen dedupes it.
sub lg_add_saved_pairing_devices (@) {
 my ($devices,$seen,$clients)=@_;
 return if(ref($devices) ne "ARRAY" || ref($seen) ne "HASH");
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 my $client=&lg_primary_client($clients);
 my $stored_name=$client->{"name"}||$client->{"model_name"}||"";
 if((($clients->{"client_key"}||$clients->{"client-key"}||"") ne "") && &lg_valid_ipv4($clients->{"ip"}||"")) {
  &lg_scan_add_device($devices,$seen,$clients->{"ip"},"paired-saved",$stored_name,$client->{"model_name"}||"");
  $devices->[-1]{"saved"}=1 if(@{$devices});
 }
 if(ref($clients->{"devices"}) eq "ARRAY") {
  foreach my $entry (@{$clients->{"devices"}}) {
   next if(ref($entry) ne "HASH");
   next if(($entry->{"client_key"}||$entry->{"client-key"}||"") eq "");
   my $eip=$entry->{"last_ip"}||"";
   next if(!&lg_valid_ipv4($eip) || $seen->{$eip});
   &lg_scan_add_device($devices,$seen,$eip,"saved-pairing",$entry->{"name"}||$entry->{"model_name"}||"Saved LG TV",$entry->{"model_name"}||"");
   $devices->[-1]{"saved"}=1 if(@{$devices});
  }
 }
}

# Instant saved-pairings list for the display card: no probes, no
# sweep, returns in milliseconds. The card renders this first so saved
# TVs are visible immediately; the full scan then merges in whatever
# discovery finds.
sub lg_scan_saved_devices (@) {
 my @devices=();
 my %seen=();
 &lg_add_saved_pairing_devices(\@devices,\%seen,undef);
 return {
  status => "ok",
  devices => \@devices,
  count => scalar(@devices),
  saved_only => 1,
  message => @devices ? "Saved LG TV pairings." : "No saved LG TV pairings.",
 };
}

sub lg_scan_devices (@) {
 $_LG_PROBE_CACHE={};
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 my $client=&lg_primary_client($clients);
 my @devices=();
 my %seen=();
 my $stored_name=$client->{"name"}||$client->{"model_name"}||"";
 &lg_add_saved_pairing_devices(\@devices,\%seen,$clients);
 # Overall time budget: the daemon serves HTTP requests from a single
 # loop, so an unbounded sweep (80 neighbor probes with TVs powered
 # off) wedges the whole WebUI for minutes. Saved pairings are already
 # in the list; discovery gets ~10s and returns whatever it found.
 my $scan_deadline=time()+10;
 &lg_scan_add_probe_device(\@devices,\%seen,$clients->{"manual_ip"}||"","saved",$stored_name,$client->{"model_name"}||"");
 &lg_scan_add_probe_device(\@devices,\%seen,$client->{"ip"}||"","paired",$stored_name,$client->{"model_name"}||"");
 my $auto=&lg_autodetect_info($clients,1);
 &lg_scan_add_probe_device(\@devices,\%seen,$auto->{"ip"}||"",$auto->{"source"}||"mdns","LG WebOS TV","");
 foreach my $device (@{&lg_webos_port_sweep_devices()}) {
  next if(ref($device) ne "HASH");
  last if(time() > $scan_deadline);
  &lg_scan_add_probe_device(\@devices,\%seen,$device->{"ip"}||"",$device->{"source"}||"webos-sweep",$device->{"name"}||"LG WebOS TV",$device->{"model_name"}||"");
 }
 &lg_prime_neighbor_table();
 my $count=0;
 foreach my $ip (&lg_neighbor_ips()) {
  last if($count > 80);
  last if(time() > $scan_deadline);
  next if($seen{$ip});
  my $port=&lg_webos_port_open($ip);
  next if(!$port);
  $count++;
  &lg_scan_add_probe_device(\@devices,\%seen,$ip,"webos:$port","LG WebOS TV","");
 }
 if(&lg_valid_ipv4($auto->{"ip"}||"") && !$seen{$auto->{"ip"}}) {
  delete($clients->{"auto_ip"});
  delete($clients->{"auto_host"});
  delete($clients->{"auto_detected_at"});
  &lg_save_clients($clients);
 }
 return {
  status => "ok",
  devices => \@devices,
  count => scalar(@devices),
  message => @devices ? "LG TV scan complete." : "No LG WebOS TVs were found on the network scan.",
 };
}

# First-load LG discovery runs in its own daemon thread. The HTTP server can
# continue serving meter/chart requests while network probes are in flight;
# the browser only polls the small result file written here.
sub lg_startup_scan_paths (@) {
 return ("/tmp/pgenerator-lg-startup-scan.running","/tmp/pgenerator-lg-startup-scan.json");
}

sub lg_startup_scan_prepare (@) {
 my ($running,$result)=&lg_startup_scan_paths();
 unlink($running);
 unlink($result);
 if(open(my $fh,">",$running)) { print $fh time()."\n"; close($fh); }
}

sub lg_startup_scan_worker (@) {
 my ($running,$result_file)=&lg_startup_scan_paths();
 # Let renderer and USB meter initialization get their first turn before the
 # network sweep begins. This thread never owns the WebUI listening socket.
 sleep(2);
 my $result=eval { &lg_scan_devices() };
 if(ref($result) ne "HASH") {
  $result={status=>"error",devices=>[],message=>"Automatic LG TV scan failed"};
 }
 my $tmp=$result_file.".".threads->tid();
 if(open(my $fh,">",$tmp)) {
  print $fh &lg_encode_json($result);
  close($fh);
  rename($tmp,$result_file);
 }
 unlink($running);
}

sub lg_startup_scan_status (@) {
 my ($running,$result_file)=&lg_startup_scan_paths();
 if(-f $running) {
  my $age=time()-((stat($running))[9]||0);
  return &lg_encode_json({status=>"running",running=>JSON::PP::true}) if($age < 90);
  unlink($running);
 }
 if(-f $result_file) {
  my $raw="";
  if(open(my $fh,"<",$result_file)) { local $/; $raw=<$fh>; close($fh); }
  my $decoded=eval { JSON::PP::decode_json($raw) };
  return &lg_encode_json($decoded) if(ref($decoded) eq "HASH");
 }
 return &lg_encode_json({status=>"idle",running=>JSON::PP::false,devices=>[]});
}

sub lg_target_ip (@) {
 my ($payload,$clients)=@_;
 $payload={} if(ref($payload) ne "HASH");
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 my $body_ip=$payload->{"ip"}||"";
 return $body_ip if(&lg_valid_ipv4($body_ip));
 my $stored_ip=$clients->{"ip"}||"";
 return $stored_ip if(&lg_valid_ipv4($stored_ip));
 my $manual_ip=$clients->{"manual_ip"}||"";
 return $manual_ip if(&lg_valid_ipv4($manual_ip));
 my $auto=&lg_autodetect_info($clients,1);
 my $auto_ip=$auto->{"ip"}||"";
 return $auto_ip if(&lg_valid_ipv4($auto_ip));
 return "";
}

sub lg_helper_run (@) {
 my @args=@_;
 local $PGCalibrationLog::CONTEXT=PGCalibrationLog::child_context($PGCalibrationLog::CONTEXT);
 my $action=ref($args[0]) eq 'HASH' ? $args[0]{action}||'unknown' : 'unknown';
 my $started=PGCalibrationLog::monotonic();
 PGCalibrationLog::event('Daemon','helper-queued',{action=>$action});
 my $result=eval { &lg_helper_run_impl(@args) }; my $error=$@;
 PGCalibrationLog::event('Daemon','helper-end',{action=>$action,elapsed_ms=>PGCalibrationLog::elapsed_ms($started),
  status=>$error?'exception':ref($result) eq 'HASH'?$result->{status}||'unknown':'invalid-response',
  ($error?(error=>$error):())});
 die $error if $error;
 return $result;
}

sub lg_helper_run_impl (@) {
 my $gate_started=PGCalibrationLog::monotonic();
 # Single-flight gate for synchronous TV helper conversations. With the
 # per-device WebUI lanes, lg_* subs can be reached from more than one worker
 # thread (the tv lane, plus direct calls such as the autocal-start CEC
 # check), and two concurrent SSAP conversations against the one TV were
 # never possible before the lanes split. The lock restores the old ordering
 # without affecting anything that does not talk to the TV. It is a no-op in
 # single-threaded loaders of this file.
 lock($_lg_helper_gate);
 my $gate_ms=PGCalibrationLog::elapsed_ms($gate_started);
 my $request=shift;
 $request={} if(ref($request) ne "HASH");
 my $helper=&lg_helper_path();
 return { status => "error", message => "LG WebOS helper is not installed" } if(!-x $helper);
 my $timeout=&lg_helper_timeout($request);
 $request={%$request,helper_timeout=>$timeout,calibration_trace=>PGCalibrationLog::context($PGCalibrationLog::CONTEXT)};
 PGCalibrationLog::event('Daemon','helper-start',{action=>$request->{action},gate_wait_ms=>$gate_ms,timeout_s=>$timeout});
 my $payload=MIME::Base64::encode_base64(&lg_encode_json($request),"");
 my $cmd="timeout ${timeout}s env PGEN_LG_REQUEST_B64=".&lg_shell_quote($payload)." ".&lg_shell_quote($helper)." 2>&1";
 my ($raw,$exit_status)=&lg_helper_exec($cmd);
 my $result=&lg_decode_json($raw);
 # The G3 refuses new websocket connections for 20-30 s now and then,
 # typically just after a picture-mode or signal change; three jobs died on
 # it on 16 Sep 2026. A connect refusal means nothing reached the TV, so
 # one more attempt after a short pause is safe for every action except
 # pairing, where the operator is waiting on the TV prompt.
 if(ref($result) eq "HASH" && ($result->{"status"}||"") eq "error"
    && ($result->{"message"}||"") =~ /Unable to connect to LG WebOS TV/
    && ($request->{"action"}||"") !~ /pair|register/i && !$request->{"no_connect_retry"}) {
  PGCalibrationLog::event('Daemon','helper-retry',{action=>$request->{action},attempt=>2,reason=>'connection refused',delay_s=>3});
  &lg_helper_connect_pause();
  ($raw,$exit_status)=&lg_helper_exec($cmd);
  my $retried=&lg_decode_json($raw);
  if(ref($retried) eq "HASH" && ($retried->{"status"}||"") ne "") {
   $retried->{"connect_retried"}=1;
   $result=$retried;
  }
 }
 if(ref($result) eq "HASH" && ($result->{"status"}||"") ne "") {
    return $result;
 }
 if($exit_status == 124 || $exit_status == 137) {
  return { status => "error", message => &lg_helper_timeout_message($request,$timeout) };
 }
 $raw =~ s/[\r\n]+/ /g;
 $raw =~ s/\s+/ /g;
 $raw =~ s/^\s+//;
 $raw =~ s/\s+$//;
 $raw="LG helper execution failed" if($raw eq "");
 return { status => "error", message => $raw };
}

sub lg_helper_exec (@) {
 my ($cmd)=@_;
 my $started=PGCalibrationLog::monotonic();
 my $raw=`$cmd`;
 my $exit=$? >> 8;
 PGCalibrationLog::event('Daemon','helper-process',{elapsed_ms=>PGCalibrationLog::elapsed_ms($started),exit_code=>$exit});
 return ($raw,$exit);
}

sub lg_helper_connect_pause (@) { sleep(3); }

sub lg_helper_timeout (@) {
 my $request=shift;
 $request={} if(ref($request) ne "HASH");
 my $override=int($request->{"helper_timeout"}||0);
 return $override if($override > 0);
 my $action=$request->{"action"}||"";
 if($action eq "picture_set") {
  my $settings=$request->{"settings"};
  if(ref($settings) eq "HASH" && (ref($settings->{"whiteBalanceRed"}) eq "ARRAY" || ref($settings->{"whiteBalanceGreen"}) eq "ARRAY" || ref($settings->{"whiteBalanceBlue"}) eq "ARRAY")) {
   return 150;
  }
  return 45;
 }
 return 180 if($action eq "3d_lut_probe" || $action eq "3d_lut_upload" || $action eq "3d_lut_reset");
 return 130 if($action eq "picture_reset");
 return 60 if($action eq "picture_apply_all_inputs");
 return 45 if($action eq "panel_protection");
 return 75 if($action eq "calibration_mode" || $action eq "hdr_tone_map_upload" || $action eq "hdr_calman_reset" || $action eq "1d_dpg_read");
 return 80 if($action eq "1d_dpg_upload");
 return 60 if($action eq "picture_get");
 return 90;
}

sub lg_helper_timeout_message (@) {
 my ($request,$timeout)=@_;
 $request={} if(ref($request) ne "HASH");
 my $action=$request->{"action"}||"";
 if($action eq "picture_set") {
  my $settings=$request->{"settings"};
  my @keys=(ref($settings) eq "HASH") ? keys(%{$settings}) : ();
  return "LG TV did not finish the picture-mode change within ${timeout}s." if(scalar(@keys) == 1 && $keys[0] eq "pictureMode");
  return "LG TV did not finish the white-balance write within ${timeout}s." if(grep { ref($settings->{$_}) eq "ARRAY" } @keys);
  return "LG TV did not finish writing ".scalar(@keys)." picture control".(scalar(@keys) == 1 ? "" : "s")." within ${timeout}s.";
 }
 return "LG TV did not finish the 3D LUT command within ${timeout}s." if($action eq "3d_lut_probe" || $action eq "3d_lut_upload" || $action eq "3d_lut_reset");
 return "LG TV did not finish the HDR tone-map upload within ${timeout}s." if($action eq "hdr_tone_map_upload");
 return "LG TV did not finish the HDR20 1D DPG upload within ${timeout}s." if($action eq "1d_dpg_upload");
 return "LG TV did not finish the HDR20 1D DPG readback within ${timeout}s." if($action eq "1d_dpg_read");
 return "LG TV did not finish the HDR calibration reset within ${timeout}s." if($action eq "hdr_calman_reset");
 return "LG TV did not finish the picture-mode reset within ${timeout}s." if($action eq "picture_reset");
 return "LG TV did not finish Apply to All Inputs within ${timeout}s." if($action eq "picture_apply_all_inputs");
 return "LG TV did not answer the picture-settings request within ${timeout}s." if($action eq "picture_get");
 return "LG TV command timed out after ${timeout}s.";
}

sub lg_helper_start_async (@) {
 my ($request,$log_file)=@_;
 $request={} if(ref($request) ne "HASH");
 my $helper=&lg_helper_path();
 return 0 if(!-x $helper);
 my $payload=MIME::Base64::encode_base64(&lg_encode_json($request),"");
 my $cmd="nohup env PGEN_LG_REQUEST_B64=".&lg_shell_quote($payload)." ".&lg_shell_quote($helper)." >".&lg_shell_quote($log_file)." 2>&1 </dev/null & echo \$!";
 my $pid=`$cmd`;
 $pid=~s/\D+//g;
 return int($pid||0);
}

sub lg_pin_pair_start (@) {
 my ($ip,$manual_ip,$pairing_mode)=@_;
 $pairing_mode=&lg_normalize_pairing_mode($pairing_mode);
 my $clients=&lg_load_clients();
 ($clients,my $pending)=&lg_reconcile_pin_pairing($clients);
 if(ref($pending) eq "HASH" && ($pending->{"status"}||"") eq "pending") {
  return &lg_status_response("ok",$pending->{"message"}||"LG TV is waiting for pairing confirmation.",{ %{$pending}, pin_pairing_pending => &lg_json_true(), prompt_style => ($pending->{"prompt_style"}||"controller-pin"), pairing_mode => ($pending->{"pairing_mode"}||"PIN"), paired => &lg_json_false(), client_key_present => &lg_json_false() });
 }
 my $token=&lg_generate_token();
 my $dir=&lg_pin_session_dir($token);
 eval { make_path($dir); 1; };
 return &lg_status_response("error","Unable to prepare LG PIN pairing storage.",{}) if(!-d $dir);
 my $prompt_style=($pairing_mode eq "PIN") ? "controller-pin" : "mixed-prompt";
 my $client_key="";
 my $pid=&lg_helper_start_async({
  action => "connect_pin_wait",
  ip => $ip,
  client_key => $client_key,
  pairing_type => $pairing_mode,
  connect_timeout => 5,
  pair_timeout => 55,
  pin_wait_timeout => 150,
  state_file => &lg_pin_state_file($token),
  pin_file => &lg_pin_input_file($token),
  token => $token,
 },&lg_pin_log_file($token));
 $clients->{"pin_pairing"}={ token => $token, ip => $ip, pairing_mode => $pairing_mode, started_at => time(), pid => $pid };
 &lg_save_clients($clients);
 my $state={};
 for(my $i=0;$i<40;$i++) {
  $state=&lg_load_pin_state($token);
  last if(ref($state) eq "HASH" && ($state->{"status"}||"") ne "");
  select(undef,undef,undef,0.25);
 }
 if($pid <= 0 && (ref($state) ne "HASH" || ($state->{"status"}||"") eq "")) {
  delete($clients->{"pin_pairing"});
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("error","Unable to start LG PIN pairing.",{});
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip || $ip);
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("ok",$state->{"message"}||"LG TV connected using PIN pairing.",$state);
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "error") {
  delete($clients->{"pin_pairing"});
  $clients->{"last_error"}=$state->{"message"}||"LG PIN pairing failed.";
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("error",$state->{"message"}||"LG PIN pairing failed.",$state);
 }
 $state={
  status => "pending",
   message => ($pairing_mode eq "PIN")
    ? "LG TV should now be showing a PIN. Enter it below and click Submit PIN to finish pairing."
    : "LG TV should now be showing a pairing prompt or PIN. Accept it on the TV, or enter the PIN below if one appears.",
  pin_pairing_pending => &lg_json_true(),
   prompt_style => $prompt_style,
   pairing_mode => $pairing_mode,
  token => $token,
  ip => $ip,
 } if(ref($state) ne "HASH" || !%{$state});
 return &lg_status_response("ok",$state->{"message"},$state);
}

sub lg_pin_pair_submit (@) {
 my ($pin,$manual_ip)=@_;
 my $clients=&lg_load_clients();
 ($clients,my $pending)=&lg_reconcile_pin_pairing($clients);
 my $meta=$clients->{"pin_pairing"};
 return &lg_status_response("error","Start PIN Pairing before submitting the TV PIN.",{}) if(ref($meta) ne "HASH");
 my $token=$meta->{"token"}||"";
 return &lg_status_response("error","Start PIN Pairing before submitting the TV PIN.",{}) if($token eq "");
 return &lg_status_response("error","Enter the numeric PIN currently shown on the LG TV.",{}) if($pin !~ /^\d{4,8}$/);
 return &lg_status_response("error","LG PIN pairing is no longer waiting for a PIN. Start it again.",{}) if(ref($pending) ne "HASH" || ($pending->{"status"}||"") ne "pending");
 &write_file(&lg_pin_input_file($token).".tmp",&lg_pin_input_file($token),$pin."\n",1);
 my $state={};
 for(my $i=0;$i<240;$i++) {
  $state=&lg_load_pin_state($token);
  last if(ref($state) eq "HASH" && ($state->{"status"}||"") ne "pending" && ($state->{"status"}||"") ne "");
  select(undef,undef,undef,0.25);
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip || $meta->{"ip"}||"");
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("ok",$state->{"message"}||"LG TV connected using PIN pairing.",$state);
 }
 my $message="LG PIN pairing did not complete. Start PIN Pairing again.";
 $message=$state->{"message"} if(ref($state) eq "HASH" && ($state->{"message"}||"") ne "");
 delete($clients->{"pin_pairing"});
 $clients->{"last_error"}=$message;
 &lg_save_clients($clients);
 &lg_clear_pin_session_files($token);
 return &lg_status_response("error",$message,$state);
}

# Per-TV client-key ring.
#
# Each LG WebOS set has a stable deviceUUID (hello payload) and device_id MAC
# (getCurrentSWInformation). We key saved client keys on those so switching
# between several TVs reuses each set's key instead of overwriting a single
# shared key and forcing a re-pair on every switch. The keyring lives in
# $clients->{"devices"} (an array of { uuid, mac, client_key, name,
# model_name, software_version, last_ip, last_seen }); the flat top-level
# fields stay as the "active" TV mirror for the WebUI and backward compat.

# Extract (uuid, mac) - both lower-cased - from a connect/probe result or a
# stored client hash (checks hello_info/software_info and top-level fallbacks).
sub lg_device_identity (@) {
 my $src=shift;
 return ("","") if(ref($src) ne "HASH");
 my $hello=ref($src->{"hello_info"}) eq "HASH" ? $src->{"hello_info"} : {};
 my $sw=ref($src->{"software_info"}) eq "HASH" ? $src->{"software_info"} : {};
 my $uuid=$hello->{"deviceUUID"}||$src->{"deviceUUID"}||$src->{"uuid"}||"";
 my $mac=$sw->{"device_id"}||$src->{"device_id"}||$src->{"mac"}||"";
 return (lc($uuid||""),lc($mac||""));
}

# Find the keyring entry for a TV by uuid (preferred) or mac. Returns the
# entry hashref (live, editable) or undef.
sub lg_keyring_find (@) {
 my ($clients,$uuid,$mac)=@_;
 return undef if(ref($clients) ne "HASH" || ref($clients->{"devices"}) ne "ARRAY");
 $uuid=lc($uuid||""); $mac=lc($mac||"");
 return undef if($uuid eq "" && $mac eq "");
 foreach my $e (@{$clients->{"devices"}}) {
  next if(ref($e) ne "HASH");
  return $e if($uuid ne "" && lc($e->{"uuid"}||"") eq $uuid);
 }
 foreach my $e (@{$clients->{"devices"}}) {
  next if(ref($e) ne "HASH");
  return $e if($mac ne "" && lc($e->{"mac"}||"") eq $mac);
 }
 return undef;
}

# Saved client key for a TV identity, or "" if none stored.
sub lg_keyring_client_key (@) {
 my ($clients,$uuid,$mac)=@_;
 my $entry=&lg_keyring_find($clients,$uuid,$mac);
 return (ref($entry) eq "HASH") ? ($entry->{"client_key"}||"") : "";
}

# Insert or update a keyring entry. Only stores when we have an identity to key
# on and a real client key. Mutates and returns $clients.
sub lg_keyring_upsert (@) {
 my ($clients,$fields)=@_;
 return $clients if(ref($clients) ne "HASH" || ref($fields) ne "HASH");
 my ($uuid,$mac)=(lc($fields->{"uuid"}||""),lc($fields->{"mac"}||""));
 return $clients if($uuid eq "" && $mac eq "");
 return $clients if(($fields->{"client_key"}||"") eq "");
 $clients->{"devices"}=[] if(ref($clients->{"devices"}) ne "ARRAY");
 my $entry=&lg_keyring_find($clients,$uuid,$mac);
 if(!defined $entry) { $entry={}; push(@{$clients->{"devices"}},$entry); }
 $entry->{"uuid"}=$uuid if($uuid ne "");
 $entry->{"mac"}=$mac if($mac ne "");
 foreach my $k ("client_key","name","model_name","software_version") {
  $entry->{$k}=$fields->{$k} if(defined($fields->{$k}) && $fields->{$k} ne "");
 }
 $entry->{"last_ip"}=$fields->{"ip"} if(($fields->{"ip"}||"") ne "");
 $entry->{"last_seen"}=time();
 return $clients;
}

sub lg_update_connect_metadata (@) {
 my ($result,$manual_ip)=@_;
 my $clients=&lg_load_clients();
 $manual_ip="" if(!defined($manual_ip));
 if($manual_ip ne "") {
    $clients->{"manual_ip"}=$manual_ip;
 }
 if(ref($result) ne "HASH") {
    &lg_save_clients($clients);
    return $clients;
 }
 if(($result->{"status"}||"") eq "ok") {
    my $ip=$result->{"ip"}||$manual_ip||"";
    $clients->{"ip"}=$ip if($ip ne "");
    $clients->{"client_key"}=$result->{"client_key"} if(($result->{"client_key"}||"") ne "");
    $clients->{"name"}=$result->{"name"} if(($result->{"name"}||"") ne "");
    $clients->{"model_name"}=$result->{"model_name"} if(($result->{"model_name"}||"") ne "");
    $clients->{"software_version"}=$result->{"software_version"} if(($result->{"software_version"}||"") ne "");
    $clients->{"transport"}=$result->{"transport"} if(($result->{"transport"}||"") ne "");
    $clients->{"hello_info"}=$result->{"hello_info"} if(ref($result->{"hello_info"}) eq "HASH");
    $clients->{"system_info"}=$result->{"system_info"} if(ref($result->{"system_info"}) eq "HASH");
    $clients->{"software_info"}=$result->{"software_info"} if(ref($result->{"software_info"}) eq "HASH");
    $clients->{"last_seen"}=time();
    # Remember this set's key under its own identity so switching TVs never
    # forces a re-pair of a previously paired set.
    my ($id_uuid,$id_mac)=&lg_device_identity($result);
    &lg_keyring_upsert($clients,{
     uuid => $id_uuid,
     mac => $id_mac,
     client_key => $result->{"client_key"}||"",
     name => $result->{"name"}||"",
     model_name => $result->{"model_name"}||"",
     software_version => $result->{"software_version"}||"",
     ip => $ip,
    });
    delete($clients->{"disconnected"});
    delete($clients->{"disconnected_at"});
    delete($clients->{"last_error"});
 } else {
    $clients->{"last_error"}=$result->{"message"}||"LG connection failed";
 }
 &lg_save_clients($clients);
 return $clients;
}

sub lg_status_response (@) {
 my ($status,$message,$extra)=@_;
 my $payload=&lg_status_data($message);
 $payload->{"status"}=$status if(defined($status) && $status ne "");
 if(ref($extra) eq "HASH") {
    foreach my $key (keys(%{$extra})) {
     next if($key eq "status" || $key eq "message");
     $payload->{$key}=$extra->{$key};
    }
 }
 if($payload->{"pin_pairing_pending"}) {
    $payload->{"paired"}=&lg_json_false();
    $payload->{"client_key_present"}=&lg_json_false();
 }
 return $payload;
}

sub lg_status_data (@) {
 my $message_override=shift;
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 my $manual_ip=$clients->{"manual_ip"}||"";
 my $stored_ip=$client->{"ip"}||"";
 my $has_saved_tv=(($client_key ne "") || ($manual_ip ne "") || ($stored_ip ne "")) ? 1 : 0;
 my $auto={};
 if($has_saved_tv) {
  my $cached_ip=$clients->{"auto_ip"}||"";
  my $cached_host=$clients->{"auto_host"}||"";
  if(&lg_valid_ipv4($cached_ip)) {
   $auto={ ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
  }
 } else {
  $auto=&lg_autodetect_info($clients,0);
 }
 my $auto_ip=$auto->{"ip"}||"";
 my $auto_host=$auto->{"host"}||"";
 my $stored_name=$client->{"name"}||$client->{"model_name"}||"";
 my $model_name=$client->{"model_name"}||"";
 my $software_version=$client->{"software_version"}||"";
 my $transport=$client->{"transport"}||"";
 my $last_error=$client->{"last_error"}||$clients->{"last_error"}||"";
 my $last_seen=$client->{"last_seen"}||"";
 my $calibration_mode=$clients->{"calibration_mode"} ? 1 : 0;
 my $calibration_picture_mode=$clients->{"calibration_picture_mode"}||"";
 my $cec=&lg_cec_status();
 my $osd_name=$cec->{"osd_name"}||"";
 my $cec_tv_name=($model_name ne "" || $stored_name ne "" || $auto_ip ne "" || $manual_ip ne "" || $stored_ip ne "") ? "LG TV" : "";
 my $cec_tv_vendor="";
 my $detected=&lg_detect_from_cec($cec);
 my $pin_pending=(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") ? 1 : 0;
 my $paired=($client_key ne "" && !$pin_pending) ? 1 : 0;
 my $disconnected=($clients->{"disconnected"} && $paired) ? 1 : 0;
 my $connected=($paired && !$disconnected) ? 1 : 0;
 my $supported=($detected || $paired || $stored_ip ne "" || $manual_ip ne "" || $auto_ip ne "") ? 1 : 0;
 my $detection_source=$auto_ip ne "" ? ($auto->{"source"}||"mdns-hostname") : ($detected ? ($cec_tv_vendor ne "" ? "cec-vendor" : "cec-osd-name") : "manual-only");
 my $message=$message_override;

 if(!defined($message) || $message eq "") {
    if($pin_pending) {
     $message=$pin_state->{"message"}||"LG TV should now be showing a PIN. Enter it below and click Submit PIN to finish pairing.";
    } elsif($disconnected) {
     $message="LG TV is disconnected. Connect will reuse the saved key without another PIN.";
    } elsif($paired && $stored_name ne "") {
     $message="Stored LG WebOS pairing is ready for $stored_name. Click Connect to reconnect or refresh TV info.";
  } elsif($paired) {
     $message="Stored LG WebOS pairing is available. Click Connect to refresh the connection.";
    } elsif($stored_ip ne "") {
     $message="LG TV IP is saved. Click Pair With PIN if no saved key is available.";
    } elsif($auto_ip ne "") {
     $message="LG TV was auto-detected from $auto_host at $auto_ip.";
    } elsif($detected) {
     $message="CEC currently looks like an LG TV. Enter the TV IP to start WebOS pairing.";
  } else {
     $message="Enter the LG TV IP, or let PGenerator try lgwebostv.local on your network.";
  }
  if(!$detected && $auto_ip eq "") {
     $message.=" CEC auto-detection is still limited to the local OSD name until vendor/model data is exposed.";
  }
 }

 return {
  status => "ok",
    supported => &lg_json_bool($supported),
  detected => &lg_json_bool($detected || $auto_ip ne ""),
  detection_limited => ($auto_ip ne "") ? &lg_json_false() : &lg_json_true(),
  detection_source => $detection_source,
  paired => &lg_json_bool($paired),
  connected => &lg_json_bool($connected),
  disconnected => &lg_json_bool($disconnected),
      pair_prompted => $pin_pending ? &lg_json_true() : &lg_json_false(),
      prompt_style => $pin_pending ? ($pin_state->{"prompt_style"}||"controller-pin") : "tv-prompt",
   pairing_mode => $pin_pending ? ($pin_state->{"pairing_mode"}||"PIN") : "",
   client_key_present => &lg_json_bool(($client_key ne "") && !$pin_pending),
   disconnected_at => $clients->{"disconnected_at"}||"",
   pin_pairing_pending => &lg_json_bool($pin_pending),
   pin_pairing_ip => $pin_state->{"ip"}||"",
  cec_osd_name => $osd_name,
  cec_tv_name => $cec_tv_name,
  cec_tv_vendor => $cec_tv_vendor,
  tv_power => $cec->{"tv_power"}||"",
  phys_addr => $cec->{"phys_addr"}||"",
  log_addr => $cec->{"log_addr"}||"",
  manual_ip => $manual_ip,
  stored_ip => $stored_ip,
   auto_ip => $auto_ip,
   auto_host => $auto_host,
  stored_name => $stored_name,
    model_name => $model_name,
    software_version => $software_version,
    transport => $transport,
    calibration_mode => &lg_json_bool($calibration_mode),
  calibration_picture_mode => $calibration_picture_mode,
    boot_id => &lg_boot_id(),
    last_error => $last_error,
    last_seen => $last_seen,
  message => $message,
 };
}

sub lg_picture_default_keys (@) {
 return [
  "pictureMode",
  "whiteBalanceMethod",
  "whiteBalancePoint",
  "whiteBalanceIre",
  "whiteBalanceIre10pt",
  "whiteBalanceCodeValue",
  "whiteBalanceCodeValue10pt",
  "whiteBalanceLuminance",
  "whiteBalanceColorTemperature",
  "colorTemperature",
  "whiteBalanceRed",
  "whiteBalanceGreen",
  "whiteBalanceBlue",
  "whiteBalanceRed10pt",
  "whiteBalanceGreen10pt",
  "whiteBalanceBlue10pt",
  "whiteBalanceRedGain",
  "whiteBalanceGreenGain",
  "whiteBalanceBlueGain",
  "whiteBalanceRedOffset",
  "whiteBalanceGreenOffset",
  "whiteBalanceBlueOffset",
  "oledLight",
  "backlight",
  "adjustingLuminance",
  "adjustingLuminance10pt"
 ];
}

sub lg_picture_diagnostic_keys (@) {
 my @keys=(@{&lg_picture_default_keys()},
  "brightness","contrast","blackLevel","blackLevelAdjust",
  "oledPixelBrightness","peakBrightness","color","colorDepth","tint",
  "sharpness","hSharpness","vSharpness","gamma","colorGamut",
  "energySaving","dynamicContrast","dynamicColor","localDimming",
  "noiseReduction","mpegNoiseReduction","smoothGradation","superResolution",
  "realCinema","eyeComfortMode","blackFrameInsertion","truMotionMode",
  "deJudder","deBlur"
 );
 my %seen;
 return [grep { !$seen{$_}++ } @keys];
}

sub lg_picture_needs_repair (@) {
 my $result=shift;
 return 0 if(ref($result) ne "HASH");
 return 0 if(($result->{"error_code"}||"") eq "lg-calibration-permission");
 return 0 if($result->{"ddc_1d_lut"} && (($result->{"message"}||"") =~ /CAL_START returned 401/i));
 return 1 if(($result->{"needs_repair"}||0));
 return 1 if(($result->{"error_code"}||"") eq "insufficient-permissions");
 my $message=$result->{"message"}||"";
 return ($message =~ /insufficient permissions/i) ? 1 : 0;
}

# Persist the held-CAL_START flag (and its picture mode) in the client store.
# A full AutoCal deliberately holds CAL_START open across its greyscale,
# 3D-LUT and tone-map stages, so the flag must survive a dead worker or
# socket; lg_clear_stale_calibration_mode_for_reset sends CAL_END first when
# it is still "on". Skips the write when nothing changed: the greyscale
# solver uploads a DPG on every inner iteration.
sub lg_store_calibration_mode_state (@) {
 my ($clients,$active,$picture_mode)=@_;
 return 0 if(ref($clients) ne "HASH");
 $picture_mode="" if(!defined($picture_mode));
 my $stored_mode=$clients->{"calibration_picture_mode"}||"";
 return 1 if((($clients->{"calibration_mode"})?1:0) == ($active?1:0)
  && (!$active || $picture_mode eq "" || $picture_mode eq $stored_mode));
 $clients->{"calibration_mode"}=$active ? &lg_json_true() : &lg_json_false();
 if($active) {
  $clients->{"calibration_picture_mode"}=$picture_mode if($picture_mode ne "");
 } else {
  delete($clients->{"calibration_picture_mode"});
 }
 return &lg_save_clients($clients);
}

# Before an endpoint can open CAL_START and deliberately leave it held for a
# later stage, persist that intent. If the write then fails midway, terminal
# cleanup and the next Reset still know that CAL_END may be required.
sub lg_prepare_held_calibration_mode (@) {
 my ($clients,$keep,$already_active,$picture_mode)=@_;
 return undef if(!$keep || $already_active);
 return undef if(&lg_store_calibration_mode_state($clients,1,$picture_mode||""));
 return {
  status => "error",
  error_code => "lg-calibration-state-not-persisted",
  message => "Unable to record the LG calibration session before starting the TV write.",
 };
}

sub lg_record_calibration_mode_result (@) {
 my ($clients,$result,$active,$fallback_picture_mode)=@_;
 return $result if(ref($result) ne "HASH");
 # A write accepted on its helper socket with an unconfirmed CAL_END remains
 # durably held. A later helper connection must not issue a fallback CAL_END
 # that could revert the accepted write.
 if(($result->{"error_code"}||"") eq "lg-calibration-end-unconfirmed") {
  my $picture_mode=$result->{"calibration_picture_mode"}
   || $result->{"active_picture_mode"}
   || $fallback_picture_mode
   || "";
  &lg_store_calibration_mode_state($clients,1,$picture_mode);
  $result->{"calibration_mode"}=&lg_json_true();
  $result->{"calibration_session_unconfirmed"}=&lg_json_true();
  $result->{"calibration_picture_mode"}=$picture_mode if($picture_mode ne "");
  return $result;
 }
 return $result if(($result->{"status"}||"") ne "ok");
 # A reset that opened its own CAL_START but could not confirm the matching
 # CAL_END reports this key: the TV may still hold that session, so the
 # persisted flag must survive for the stuck-session recovery paths.
 return $result if(!$active && $result->{"calibration_session_unconfirmed"});
 my $picture_mode=$result->{"calibration_picture_mode"}
  || $result->{"active_picture_mode"}
  || $fallback_picture_mode
  || "";
 &lg_store_calibration_mode_state($clients,$active,$picture_mode);
 $result->{"calibration_mode"}=$active ? &lg_json_true() : &lg_json_false();
 $result->{"calibration_picture_mode"}=$picture_mode if($active && $picture_mode ne "");
 return $result;
}

sub lg_autocal_worker_running (@) {
 # $strict picks the fail direction when a liveness check itself dies:
 # guards protecting an irreversible action (apply-to-all-inputs) pass 1 so
 # unknown blocks; the reset path leaves it unset so unknown cannot lock the
 # operator out of their own recovery route.
 my ($strict)=@_;
 foreach my $name (qw(webui_meter_lg_autocal_running webui_meter_lg_3d_autocal_running webui_meter_lg_dv_profile_running)) {
  no strict 'refs';
  next if(!defined(&{"main::$name"}));
  my $running=eval { &{"main::$name"}() };
  return 1 if($@ && $strict);
  return 1 if($running);
 }
 return 0;
}

# Clear a persisted held session before the picture / HDR / DV / SDR reset
# actions. Never end a session while an AutoCal worker is genuinely alive;
# that would interrupt a valid cross-stage commit. A rejected cleanup does NOT
# block the reset: the TV may already have dropped the session (power cycle),
# and the reset's own CAL_START/CAL_END is the authority. The flag is only
# cleared once that reset succeeds, so a genuinely stuck driver keeps
# surfacing through the reset's error path (see lg_hdr_calman_reset_workflow).
sub lg_clear_stale_calibration_mode_for_reset (@) {
 my ($clients,$ip,$client_key,$picture_mode,$signal_mode)=@_;
 return undef if(ref($clients) ne "HASH" || !$clients->{"calibration_mode"});
 if(&lg_autocal_worker_running()) {
  return {
   status => "error",
   message => "LG Auto Cal is still running. Stop it before resetting the picture mode.",
   calibration_mode => &lg_json_true(),
   error_code => "lg-calibration-session-active",
  };
 }
 my $cleanup=&lg_helper_run({
  action => "calibration_mode",
  ip => $ip,
  client_key => $client_key,
  enable => 0,
  picture_mode => $picture_mode||$clients->{"calibration_picture_mode"}||"",
  signal_mode => $signal_mode||"",
  helper_timeout => 75,
  connect_timeout => 5,
 });
 if(ref($cleanup) ne "HASH" || ($cleanup->{"status"}||"") ne "ok") {
  my $detail=(ref($cleanup) eq "HASH" ? ($cleanup->{"message"}||"") : "")
   || "the TV did not acknowledge CAL_END";
  return {
   status => "ok",
   message => "The previous LG calibration session could not be closed ($detail); continuing with the reset.",
   stale_calibration_mode => &lg_json_true(),
   stale_calibration_mode_cleared => &lg_json_false(),
   error_code => "lg-calibration-session-stuck",
   cleanup_response => $cleanup,
  };
 }
 &lg_store_calibration_mode_state($clients,0,"");
 $cleanup->{"stale_calibration_mode_cleared"}=&lg_json_true();
 return $cleanup;
}

###############################################
#              LG API Helpers                 #
###############################################
sub webui_lg_status_json (@) {
 my $message=shift;
 return &lg_encode_json(&lg_status_response("ok",$message,{}));
}

sub webui_lg_manual_ip (@) {
 lock($_lg_helper_gate);
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $ip=$payload->{"ip"}||"";
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($ip ne "" && !&lg_valid_ipv4($ip));
 my $clients=&lg_load_clients();
 if($ip eq "") {
  delete($clients->{"manual_ip"});
 } else {
  $clients->{"manual_ip"}=$ip;
 }
 return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 my $message=($ip eq "") ? "LG TV IP cleared." : "LG TV IP saved.";
 return &webui_lg_status_json($message);
}

sub webui_lg_forget (@) {
 lock($_lg_helper_gate);
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $target_ip=(ref($payload) eq "HASH") ? ($payload->{"ip"}||"") : "";
 $target_ip="" if($target_ip ne "" && !&lg_valid_ipv4($target_ip));
 return &lg_encode_json({ status => "error", message => "Unable to clear stored LG pairing" }) if(!&lg_clear_pairing($target_ip));
 return &webui_lg_status_json("Stored LG pairing cleared for the selected TV.");
}

sub webui_lg_disconnect (@) {
 lock($_lg_helper_gate);
 return &lg_encode_json({ status => "error", message => "Unable to disconnect LG TV" }) if(!&lg_mark_disconnected());
 return &webui_lg_status_json("LG TV disconnected. Saved pairing is kept for the next Connect.");
}

sub webui_lg_pin_pair_start (@) {
 lock($_lg_helper_gate);
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 my $manual_ip=$payload->{"ip"}||"";
 my $pairing_mode=&lg_normalize_pairing_mode($payload->{"pairing_mode"}||$payload->{"pairingType"}||"PIN");
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($manual_ip ne "" && !&lg_valid_ipv4($manual_ip));
 if($manual_ip ne "") {
  $clients->{"manual_ip"}=$manual_ip;
  return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 }
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json(&lg_status_response("error","Enter and save the LG TV IP before starting PIN pairing.",{})) if($ip eq "");
 my $result=&lg_pin_pair_start($ip,$manual_ip || $ip,$pairing_mode);
 return &lg_encode_json($result);
}

sub webui_lg_pin_pair_submit (@) {
 lock($_lg_helper_gate);
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $pin=$payload->{"pin"}||"";
 $pin =~ s/\D+//g;
 my $clients=&lg_load_clients();
 my $manual_ip=$clients->{"manual_ip"}||"";
 my $result=&lg_pin_pair_submit($pin,$manual_ip);
 return &lg_encode_json($result);
}

sub webui_lg_connect (@) {
 lock($_lg_helper_gate);
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 my $manual_ip=$payload->{"ip"}||"";
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($manual_ip ne "" && !&lg_valid_ipv4($manual_ip));
 if($manual_ip ne "") {
  $clients->{"manual_ip"}=$manual_ip;
  return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 }
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json(&lg_status_response("error","Enter and save the LG TV IP before connecting.",{})) if($ip eq "");
 # Identify which set is at this IP (hello-only, no pairing prompt) so we can
 # reuse that set's saved client key from the per-TV keyring. This is what lets
 # the user switch between several paired TVs without re-pairing each time. If
 # the probe fails (TV unreachable, etc.) we fall back to the active/flat key
 # and the original behaviour.
 my $client_key="";
 my $probe_identified=0;
 my $probe=&lg_helper_run({ action => "probe", ip => $ip, connect_timeout => 5 });
 if(ref($probe) eq "HASH" && ($probe->{"status"}||"") eq "ok") {
  my ($p_uuid,$p_mac)=&lg_device_identity($probe);
  $probe_identified=1 if(($p_uuid||"") ne "" || ($p_mac||"") ne "");
  $client_key=&lg_keyring_client_key($clients,$p_uuid,$p_mac);
 }
 # Only borrow the active/flat key when the probe could not tell us WHICH TV
 # is at this IP. Handing TV A's key to TV B makes the TV fall back to a
 # prompt pairing ("press OK"), and a prompt-paired key comes back without
 # access to the picture keys, so picture modes stop working. With no key the
 # helper reports needs_pin_pairing instead and the WebUI runs PIN pairing.
 if($client_key eq "" && !$probe_identified) {
  my $client=&lg_primary_client($clients);
  $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 }
 my $result=&lg_helper_run({
  action => "connect",
  ip => $ip,
  client_key => $client_key,
  connect_timeout => 5,
  pair_timeout => 55,
 });
 &lg_update_connect_metadata($result,$manual_ip || $ip);
 return &lg_encode_json(&lg_status_response($result->{"status"}||"error",$result->{"message"}||"LG connection failed",$result));
}

sub webui_lg_scan (@) {
 return &lg_encode_json(&lg_scan_devices());
}

sub webui_lg_calibration_mode (@) {
 my $body=shift;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $payload=&lg_decode_json($body);
 my $enabled=$payload->{"enabled"} ? 1 : 0;
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before changing calibration mode." });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing calibration mode." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing calibration mode." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing calibration mode." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "calibration_mode",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  enable => $enabled,
  picture_mode => !$enabled && $payload->{current_picture_mode} ? "" : $payload->{"picture_mode"}||"",
  signal_mode => !$enabled && $payload->{current_picture_mode} ? "" : $payload->{"signal_mode"}||"",
  connect_timeout => 5,
 });
 if(($result->{"status"}||"") eq "ok") {
  $clients=&lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip);
  &lg_calmode_trace("calmode_endpoint: enabled=$enabled picture_mode=".($payload->{"picture_mode"}||"")); # TEMP DEBUG CALMODE
  $clients->{"calibration_mode"}=$enabled ? &lg_json_true() : &lg_json_false();
  if($enabled) {
   $clients->{"calibration_picture_mode"}=$result->{"calibration_picture_mode"}||$result->{"active_picture_mode"}||"";
  } else {
   delete($clients->{"calibration_picture_mode"});
  }
  &lg_save_clients($clients);
 }
 return &lg_encode_json(&lg_status_response($result->{"status"}||"error",$result->{"message"}||"Unable to change LG calibration mode.",$result));
}

# TEMP DEBUG CALMODE — remove after pinning the greyscale cal-mode trigger
sub lg_calmode_trace (@) {
 my ($msg)=@_;
 if(open(my $f,">>","/tmp/lg_calmode_trace.log")) {
  print $f scalar(localtime).": $msg\n"; close($f);
 }
}

sub webui_lg_picture_settings (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 if($payload->{verification_scan}) {
  my $guard=&lg_automation_guard_json($body);
  return $guard if($guard ne '');
 }
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing first by entering the PIN shown on the TV.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading picture settings." }) if($client_key eq "");
 my $keys=$payload->{"keys"};
 $keys=&lg_picture_default_keys() if(ref($keys) ne "ARRAY" || !@{$keys});
 my $ignore_calibration_picture_mode=$payload->{"ignore_calibration_picture_mode"} ? 1 : 0;
 my $picture_mode=$payload->{"picture_mode"}||"";
 $picture_mode=$clients->{"calibration_picture_mode"}||"" if($picture_mode eq "" && !$ignore_calibration_picture_mode);
 my $category=$payload->{"category"}||"picture";
 $category=&lg_picture_category_or_default($category);
# Read-only poll: if CEC already knows the panel is in standby there is
# nothing to read, and spawning the helper would burn the full 60s
# picture_get wrapper on the daemon's single WebUI request thread. The
# AutoCal panels re-poll this endpoint every ~30s whether or not anyone is
# calibrating, so with the TV off the WebUI spent most of its life frozen
# behind this one call. Fails open in every ambiguous case -- and is never
# applied to the picture_set / calibration paths below. See lg_tv_off_gate.
my $tv_off_gate=&lg_tv_off_gate("read picture settings");
return &lg_encode_json($tv_off_gate) if(ref($tv_off_gate) eq "HASH");
&lg_calmode_trace("picture_get: force_ddc=".($payload->{"force_ddc_white_balance"}?1:0)." pmode=$picture_mode req_pmode=".($payload->{"picture_mode"}||"")); # TEMP DEBUG CALMODE
my $result=&lg_helper_run({
 action => "picture_get",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
 ip => $ip,
 client_key => $client_key,
  keys => $keys,
  picture_mode => $picture_mode,
  signal_mode => $payload->{"signal_mode"}||"",
  category => $category,
	  tv_input => $payload->{tv_input}||&lg_input_from_cec(),
	  include_current_input => $payload->{"include_current_input"} ? &lg_json_true() : &lg_json_false(),
	  force_ddc_white_balance => $payload->{"force_ddc_white_balance"} ? &lg_json_true() : &lg_json_false(),
	  helper_timeout => int($payload->{"helper_timeout"}||0),
	  connect_timeout => 5,
	 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub webui_lg_verify_panel_light (@) {
 my ($body)=@_;
 my $guard=&lg_automation_guard_json($body);
 return $guard if($guard ne '');
 my $request=&lg_decode_json($body);
 return &lg_encode_json({status=>'error',message=>'Explicit confirmation is required for a reversible panel-light test.'}) if(!$request->{confirm_reversible_test});
 # Queue start/resume takes this same lock. Keep it until restoration ends,
 # so a newly claimed queue cannot cause the setter to refuse cleanup.
 my $execution_lock=&lg_automation_execution_file();
 $execution_lock=~s/\.json$/.lock/;
 return &lg_encode_json({status=>'error',message=>'Unable to reserve the idle automation state for verification.'})
  if(!open(my $execution_gate,'>>',$execution_lock));
 return &lg_encode_json({status=>'error',message=>'Automation state is changing. Try verification again when idle.'})
  if(!flock($execution_gate,LOCK_EX|LOCK_NB));
 # Hold the shared TV conversation lock across write, independent read and
 # restoration. Other helper users cannot interleave a TV operation.
 lock($_lg_helper_gate);
 $guard=&lg_automation_guard_json($body);
 return $guard if($guard ne '');
 my $clients=&lg_load_clients();
 return &lg_encode_json({status=>'error',message=>'Exit calibration mode before testing panel light.'}) if($clients->{calibration_mode});
 for my $worker (qw(webui_meter_series_alive webui_meter_lg_autocal_running webui_meter_lg_3d_autocal_running webui_meter_lg_dv_profile_running webui_meter_session_alive)) {
  no strict 'refs';
  return &lg_encode_json({status=>'error',message=>'Finish the active meter or calibration operation before verification.'}) if(defined(&{$worker}) && &{$worker}());
 }
 my $result=verify_lg_panel_light($request,
  sub { &lg_decode_json(&webui_lg_picture_settings(&lg_encode_json($_[0]))) },
  sub { &lg_decode_json(&webui_lg_picture_settings_set(&lg_encode_json($_[0]))) });
 if($result->{write_attempted} && $result->{generation} && $result->{context}) {
  $result->{evidence_saved}=lg_record_setting_observation($result->{generation},$result->{context},$result->{key},'roundtrip',{
   status=>$result->{status} eq 'ok' ? 'verified' : $result->{restored} ? 'failed_restored' : 'restore_failed',
   route=>'application.picture-settings-roundtrip',reason=>$result->{message},
  })->{ok};
 }
 delete $result->{generation};
 return &lg_encode_json($result);
}

sub lg_settings_are_ddc_white_balance (@) {
 my $settings=shift;
 return 0 if(ref($settings) ne "HASH");
 return 0 if(($settings->{"whiteBalanceMethod"}||"") ne "22");
 return 0 if(ref($settings->{"whiteBalanceRed"}) ne "ARRAY");
 return 0 if(ref($settings->{"whiteBalanceGreen"}) ne "ARRAY");
 return 0 if(ref($settings->{"whiteBalanceBlue"}) ne "ARRAY");
 return 1;
}

sub webui_lg_picture_settings_set (@) {
 my $body=shift;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({
	   status => "error",
	   message => "Complete LG PIN pairing first by entering the PIN shown on the TV.",
	   needs_repair => &lg_json_true(),
	   repair_hint => "Use Display and click Submit PIN after typing the code shown on the TV.",
	  });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before changing picture settings." }) if($client_key eq "");
 my $settings=$payload->{"settings"};
 return &lg_encode_json({ status => "error", message => "No LG picture settings were provided." }) if(ref($settings) ne "HASH" || !%{$settings});
 my $readback_keys=$payload->{"readback_keys"};
 if($payload->{"skip_readback"}) {
  $readback_keys=[];
 } elsif(ref($readback_keys) ne "ARRAY" || !@{$readback_keys}) {
  $readback_keys=[keys(%{$settings})];
 }
 my $ignore_calibration_picture_mode=$payload->{"ignore_calibration_picture_mode"} ? 1 : 0;
 my $picture_mode=$payload->{"picture_mode"}||"";
 $picture_mode=$clients->{"calibration_picture_mode"}||"" if($picture_mode eq "" && !$ignore_calibration_picture_mode);
 my $category=$payload->{"category"}||"picture";
 $category=&lg_picture_category_or_default($category);
	 my $ddc_white_balance=&lg_settings_are_ddc_white_balance($settings);
	 my $keep_calibration_mode=exists($payload->{"keep_calibration_mode"})
	  ? ($payload->{"keep_calibration_mode"} ? 1 : 0)
	  : (($clients->{"calibration_mode"}||$ddc_white_balance) ? 1 : 0);
 my $calibration_mode_active=($payload->{"calibration_mode_active"}||($ddc_white_balance&&$keep_calibration_mode&&$clients->{"calibration_mode"})) ? 1 : 0;
 $calibration_mode_active=0 if($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"});
	 my $held_prepare=$ddc_white_balance
	  ? &lg_prepare_held_calibration_mode($clients,$keep_calibration_mode,$calibration_mode_active,$picture_mode)
	  : undef;
	 return &lg_encode_json($held_prepare) if(ref($held_prepare) eq "HASH");
 &lg_calmode_trace("picture_set: ddc_wb=$ddc_white_balance keep=$keep_calibration_mode active=$calibration_mode_active force=".($payload->{"force_ddc_white_balance"}?1:0)." method=".($settings->{"whiteBalanceMethod"}||"")." pmode=$picture_mode req_pmode=".($payload->{"picture_mode"}||"")." skip_readback=".($payload->{"skip_readback"}?1:0)); # TEMP DEBUG CALMODE
 my $result=&lg_helper_run({
  action => "picture_set",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  ip => $ip,
  client_key => $client_key,
  settings => $settings,
  readback_keys => $readback_keys,
	  picture_mode => $picture_mode,
	  signal_mode => $payload->{"signal_mode"}||"",
	  tv_input => $payload->{tv_input}||&lg_input_from_cec(),
		  keep_calibration_mode => $keep_calibration_mode,
		  calibration_mode_active => $calibration_mode_active,
		  reset_ddc_baseline => ($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"}) ? &lg_json_true() : &lg_json_false(),
		  verify_ddc_upload => $payload->{"verify_ddc_upload"} ? &lg_json_true() : &lg_json_false(),
		  force_ddc_white_balance => $payload->{"force_ddc_white_balance"} ? &lg_json_true() : &lg_json_false(),
		  category => $category,
		  helper_timeout => int($payload->{"helper_timeout"}||0),
	  connect_timeout => 5,
	 });
 # A native webOS picture-mode write can reset the sink's HDMI pipeline
 # while vc4 has a page flip outstanding.  Older renderers then remain
 # alive in an unbounded drmHandleEvent() read and the TV keeps showing
 # the previous patch.  A direct picture-mode selection is an idle/display
 # control operation (the calibration writers send larger settings maps),
 # so resynchronise the renderer immediately and come back on black.
 #
 # Only when the TV was actually written to. On a pre-2022 set (webOS <= 6,
 # ddc_only) the helper answers virtual_picture_settings: it records the DDC
 # target mode and never asks the TV to switch, so there is no HDMI link
 # reset to recover from -- restarting the renderer there is a black-out for
 # nothing on every picture-mode selection. Likewise when the helper found
 # the TV already on the requested mode (picture_mode_changed false): no
 # write went out, so there is nothing to resync.
 my $mode_changed=exists($result->{"picture_mode_changed"}) ? ($result->{"picture_mode_changed"} ? 1 : 0) : 1;
 if(($result->{"status"}||"") eq "ok"
    && exists($settings->{"pictureMode"})
    && scalar(keys(%{$settings})) == 1
    && !$result->{"virtual_picture_settings"}
    && $mode_changed) {
  &pattern_generator_stop();
  &pattern_generator_start();
  $result->{"renderer_resynced"}=&pattern_generator_is_running() ? &lg_json_true() : &lg_json_false();
  if(!$result->{"renderer_resynced"}) {
   $result->{"message"}=($result->{"message"}||"LG picture mode changed.")." Pattern renderer did not restart.";
  }
 }
 my $updated_clients=$clients;
 my $updated_clients_dirty=0;
 $updated_clients=&lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 # Remember the mode PGenerator last asked the TV to be in, separately from
 # calibration_picture_mode below. That field only moves on a DDC
 # white-balance write, so it holds the last CALIBRATED mode and is stale the
 # moment the operator switches modes by hand -- which is exactly when it gets
 # consulted. On a generation that cannot report its active mode at all (a
 # 2021 C1 cannot, on any route -- see 2841812f), this is the only record of
 # what the panel was actually asked to show, and Full Auto Cal checks its
 # target against it before spending an hour. It is exactly that -- what we
 # last ASKED for: the palm:// switch that sets it is fire-and-forget on this
 # generation (picture_mode_changed true while picture_mode_verified false),
 # so it is unverified precisely where it is the only evidence, and it is
 # cleared on disconnect (lg_mark_disconnected) so it cannot outlive its
 # session.
 if(($result->{"status"}||"") eq "ok" && ($result->{"picture_mode_changed"} || $result->{"picture_mode_verified"})) {
  my $written=$result->{"active_picture_mode"}
   || ((ref($result->{"applied"}) eq "HASH") ? ($result->{"applied"}{"pictureMode"}||"") : "")
   || $result->{"requested_picture_mode"}
   || "";
  if($written ne "") {
   $updated_clients->{"last_written_picture_mode"}=$written;
   $updated_clients->{"last_written_picture_mode_at"}=time();
   $updated_clients_dirty=1;
  }
 }
	 if(($result->{"status"}||"") eq "ok" && $ddc_white_balance && ($result->{"ddc_1d_lut"} || exists($result->{"calibration_mode"}))) {
	  &lg_calmode_trace("picture_set APPLIED calibration_mode=".($keep_calibration_mode?"true":"false")." ddc_1d_lut=".($result->{"ddc_1d_lut"}?1:0)); # TEMP DEBUG CALMODE
	  $updated_clients->{"calibration_mode"}=$keep_calibration_mode ? &lg_json_true() : &lg_json_false();
	  my $cal_mode=$result->{"calibration_picture_mode"}||$result->{"active_picture_mode"}||$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
	  if($keep_calibration_mode) {
	   $updated_clients->{"calibration_picture_mode"}=$cal_mode if($cal_mode ne "");
	  } else {
	   delete($updated_clients->{"calibration_picture_mode"});
	  }
	  $updated_clients_dirty=1;
	  $result->{"calibration_mode"}=$keep_calibration_mode ? &lg_json_true() : &lg_json_false();
	  $result->{"calibration_picture_mode"}=$cal_mode if($cal_mode ne "");
	 }
 # One write covers both the last-written record and the calibration-mode
 # fields above; a calibrated picture_set sets both and must not save twice.
 &lg_save_clients($updated_clients) if($updated_clients_dirty);
 if(&lg_picture_needs_repair($result)) {
   $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
   $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 } elsif(($result->{"error_code"}||"") eq "lg-calibration-permission") {
   $result->{"repair_hint"}="The TV accepted pairing but denied LG calibration/DDC access. Clear the existing LG Connect Apps entry for PGenerator/LG Remote App on the TV, then pair from Display again.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_picture_reset (@) {
 my $body=shift;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({
	   status => "error",
	   message => "Complete LG PIN pairing first by entering the PIN shown on the TV.",
	   needs_repair => &lg_json_true(),
	  });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting picture settings." }) if($client_key eq "");
 my $picture_mode=$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
 my $stale_cleanup=&lg_clear_stale_calibration_mode_for_reset($clients,$ip,$client_key,$picture_mode,$payload->{"signal_mode"}||"");
 return &lg_encode_json($stale_cleanup) if(ref($stale_cleanup) eq "HASH" && ($stale_cleanup->{"status"}||"") ne "ok");
 my $result=&lg_helper_run({
  action => "picture_reset",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
	  ip => $ip,
	  client_key => $client_key,
	  picture_mode => $picture_mode,
	  signal_mode => $payload->{"signal_mode"}||"",
	  last_written_picture_mode => $clients->{"last_written_picture_mode"}||"",
	  require_white_balance_reset => $payload->{"require_white_balance_reset"} ? &lg_json_true() : &lg_json_false(),
	  reset_ddc_state => $payload->{"require_white_balance_reset"} ? 1 : 0,
	  tv_input => &lg_input_from_cec(),
	  connect_timeout => 5,
	 });
 $result->{"stale_calibration_mode_cleanup"}=$stale_cleanup if(ref($result) eq "HASH" && ref($stale_cleanup) eq "HASH");
 &lg_record_calibration_mode_result($clients,$result,0,$picture_mode);
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_picture_apply_all_inputs (@) {
 my $body=shift;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing first by entering the PIN shown on the TV.", needs_repair => &lg_json_true() });
 }
 # Applying to all inputs is irreversible on the TV. Refuse while an AutoCal
 # worker is alive (it would copy a half-converged mode onto every input and
 # stall the single serialised request lane its own meter/DDC calls use) and
 # while a calibration session is still held/unconfirmed (same reasoning as
 # the reset endpoints' lg_clear_stale_calibration_mode_for_reset).
 if(&lg_autocal_worker_running(1)) {
  return &lg_encode_json({
   status => "error",
   message => "LG Auto Cal is still running. Stop it before applying picture settings to all inputs.",
   error_code => "lg-calibration-session-active",
  });
 }
 if($clients->{"calibration_mode"}) {
  return &lg_encode_json({
   status => "error",
   message => "A LG calibration session is still held on the TV. Run Reset picture mode first, then apply to all inputs.",
   error_code => "lg-calibration-session-held",
  });
 }
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before applying picture settings to all inputs." }) if(&lg_clients_disconnected($clients));
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before applying picture settings to all inputs." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before applying picture settings to all inputs." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "picture_apply_all_inputs",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

# Panel protection (TPC/GSR) on or off. Write-only on the TV: the helper can
# only report that the alert-bridge request was dispatched.
sub webui_lg_panel_protection (@) {
 my $body=shift;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $payload=&lg_decode_json($body);
 $payload={} if(ref($payload) ne "HASH");
 return &lg_encode_json({ status => "error", error_code => "panel-protection-invalid-request", message => "Specify enable as true or false for panel protection." })
  if(!exists($payload->{"enable"}));
 my $enable=$payload->{"enable"} ? 1 : 0;
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing first by entering the PIN shown on the TV.", needs_repair => &lg_json_true() });
 }
 # The helper conversation shares the serialised TV lane with AutoCal workers.
 if(&lg_autocal_worker_running(1)) {
  return &lg_encode_json({
   status => "error",
   message => "LG Auto Cal is still running. Stop it before changing panel protection.",
   error_code => "lg-calibration-session-active",
  });
 }
 my $connect_message="Connect the LG TV before changing panel protection.";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => $connect_message }) if(&lg_clients_disconnected($clients));
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => $connect_message }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => $connect_message }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "panel_protection",
  enable => $enable,
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_cec_fallback (@) {
 my $command=shift;
 $command=lc($command||"");
 return {} if($command !~ /^(?:active|input|volup|voldown|mute)$/);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 return {} if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending");
 my $ip=&lg_target_ip({},$clients);
 return {} if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return {} if($client_key eq "");
 my $target_input="";
 if($command eq "active" || $command eq "input") {
  $target_input=&lg_input_from_cec();
  $target_input="hdmi1" if($target_input eq "");
 }
 my $result=&lg_helper_run({
  action => "remote_control",
  ip => $ip,
  client_key => $client_key,
  command => $command,
  target_input => $target_input,
  connect_timeout => 4,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(ref($result) eq "HASH" && ($result->{"status"}||"") eq "ok");
 return $result;
}

sub lg_3d_lut_payload_path_ok (@) {
 my $path=shift;
 $path="" if(!defined($path));
 return ($path =~ m{^/var/lib/PGenerator/lg/luts/[A-Za-z0-9_.-]+\.bin$}) ? 1 : 0;
}

sub webui_lg_3d_lut_probe (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before probing 3D LUT support.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before probing 3D LUT support." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before probing 3D LUT support." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before probing 3D LUT support." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "3d_lut_probe",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  signal_mode => $payload->{"signal_mode"}||"",
  write_probe => $payload->{"write_probe"} ? &lg_json_true() : &lg_json_false(),
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the 3D LUT probe again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_3d_lut_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $payload_path=$payload->{"payload_path"}||"";
 return &lg_encode_json({ status => "error", message => "LG 3D LUT upload requires an exported payload under /var/lib/PGenerator/lg/luts." }) if(!&lg_3d_lut_payload_path_ok($payload_path) || !-f $payload_path);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading a 3D LUT.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a 3D LUT." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a 3D LUT." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a 3D LUT." }) if($client_key eq "");
 my $held_prepare=&lg_prepare_held_calibration_mode(
  $clients,$payload->{"keep_calibration_mode"},$payload->{"calibration_mode_active"},
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 return &lg_encode_json($held_prepare) if(ref($held_prepare) eq "HASH");
 my $result=&lg_helper_run({
  action => "3d_lut_upload",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  signal_mode => $payload->{"signal_mode"}||"",
  payload_path => $payload_path,
  upload_command => $payload->{"upload_command"}||"",
  get_command => $payload->{"get_command"}||"",
  keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
  calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_record_calibration_mode_result(
  $clients,$result,$payload->{"keep_calibration_mode"} ? 1 : 0,
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the 3D LUT upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_3d_lut_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting the 3D LUT.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting the 3D LUT." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting the 3D LUT." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting the 3D LUT." }) if($client_key eq "");
 my $held_prepare=&lg_prepare_held_calibration_mode(
  $clients,$payload->{"keep_calibration_mode"},$payload->{"calibration_mode_active"},
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 return &lg_encode_json($held_prepare) if(ref($held_prepare) eq "HASH");
 my $result=&lg_helper_run({
  action => "3d_lut_reset",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  signal_mode => $payload->{"signal_mode"}||"",
  upload_command => $payload->{"upload_command"}||"",
  get_command => $payload->{"get_command"}||"",
  keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
  calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_record_calibration_mode_result(
  $clients,$result,$payload->{"keep_calibration_mode"} ? 1 : 0,
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub webui_lg_hdr_tone_map_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $peak_luminance=0+$payload->{"peak_luminance"};
 return &lg_encode_json({ status => "error", message => "HDR tone-map upload requires a measured peak luminance." }) if($peak_luminance <= 0);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading HDR tone-map data.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading HDR tone-map data." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading HDR tone-map data." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading HDR tone-map data." }) if($client_key eq "");
 # If dpg_data is supplied, upload the 1D DPG first inside the same
 # CAL_START/CAL_END session as the tone map. The reference binds the DPG and
 # the tone map inside a single session; PGen previously uploaded them
 # in separate sessions and the tone-map roll-off did not bind against
 # the previously-uploaded 1D DPG (5-20% IRE luma collapsed ~10x in the
 # post-call PQ series read). The autocal commit path passes dpg_data
 # here so both land in one session.
 my $dpg_data=$payload->{"dpg_data"};
 if(defined $dpg_data) {
  return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires dpg_data." }) if(ref($dpg_data) ne "ARRAY");
  return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires a 3072-value (3 channels x 1024 points) uint16 array.", expected_count => 3072, received_count => scalar(@{$dpg_data}) }) if(scalar(@{$dpg_data}) != 3072);
 }
  my $result=&lg_helper_run({
   action => "hdr_tone_map_upload",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
   ip => $ip,
   client_key => $client_key,
   picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
   peak_luminance => $peak_luminance,
   dpg_data => $dpg_data,
   ddc_layout => "hdr20",
   keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
   calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
   helper_timeout => int($payload->{"helper_timeout"}||0),
   connect_timeout => 5,
  });
 &lg_record_calibration_mode_result($clients,$result,0,$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"");
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR tone-map upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_1d_dpg_read (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before reading the HDR20 1D DPG.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "1d_dpg_read",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub webui_lg_1d_dpg_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $dpg_data=$payload->{"dpg_data"};
 return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires dpg_data." }) if(!defined($dpg_data));
 return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires a 3072-value (3 channels x 1024 points) uint16 array.", expected_count => 3072, received_count => (ref($dpg_data) eq "ARRAY") ? scalar(@{$dpg_data}) : -1 }) if(ref($dpg_data) ne "ARRAY" || @{$dpg_data} != 3072);
 my @normalized=map { my $i=int($_+0); $i=0 if($i < 0); $i=65535 if($i > 65535); $i; } @{$dpg_data};
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading the HDR20 1D DPG.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if($client_key eq "");
 my $held_prepare=&lg_prepare_held_calibration_mode(
  $clients,$payload->{"keep_calibration_mode"},$payload->{"calibration_mode_active"},
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 return &lg_encode_json($held_prepare) if(ref($held_prepare) eq "HASH");
 my $result=&lg_helper_run({
  action => "1d_dpg_upload",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  signal_mode => $payload->{"signal_mode"}||"",
  dpg_data => \@normalized,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
  keep_calibration_mode => ($payload->{"keep_calibration_mode"} ? 1 : 0),
  calibration_mode_active => ($payload->{"calibration_mode_active"} ? 1 : 0),
 });
 &lg_record_calibration_mode_result(
  $clients,$result,$payload->{"keep_calibration_mode"} ? 1 : 0,
  $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||""
 );
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 # Durable history snapshot, opt-in via archive_history. NOT unconditional: the
 # greyscale solver uploads a DPG on every inner iteration, so archiving each
 # one would bury the list under hundreds of entries. Callers set the flag only
 # for curves worth restoring -- the final commit and the post-cal smoothing --
 # and pass a variant so the raw solve and the smoothed curve are both kept and
 # are distinguishable in the list.
 if($payload->{"archive_history"} && ($result->{"status"}||"") eq "ok") {
  eval {
   &_lg_cal_hist_archive_1d(\@normalized,{
    picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
    signal_mode => $payload->{"signal_mode"}||"",
    de => $payload->{"archive_de"},
    run_id => $payload->{"archive_run_id"}||"",
    variant => $payload->{"archive_variant"}||"",
    display_model => $payload->{"display_model"}||"",
   });
   1;
  };
 }
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR20 1D DPG upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_dv_profile_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $measurements=$payload->{"measurements"};
 return &lg_encode_json({ status => "error", message => "Dolby Vision profile upload requires measured black/white luminance and R/G/B chromaticity." })
  if(ref($measurements) ne "HASH"
   || !defined($measurements->{"white_luminance"}) || !defined($measurements->{"black_luminance"})
   || !defined($measurements->{"red_x"}) || !defined($measurements->{"red_y"})
   || !defined($measurements->{"green_x"}) || !defined($measurements->{"green_y"})
   || !defined($measurements->{"blue_x"}) || !defined($measurements->{"blue_y"}));
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading a Dolby Vision profile.", needs_repair => &lg_json_true() });
 }
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a Dolby Vision profile." }) if(&lg_clients_disconnected($clients));
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a Dolby Vision profile." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before uploading a Dolby Vision profile." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "dv_profile_upload",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  measurements => $measurements,
  keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
  calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_record_calibration_mode_result($clients,$result,0,$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"");
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(($result->{"status"}||"") eq "ok") {
  eval {
   &_lg_cal_hist_archive_dv($measurements,{
    picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
    display_model => $payload->{"display_model"}||"",
   });
  };
 }
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the Dolby Vision profile upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

# Dolby Vision profile measurement worker (Task 7's meter_lg_dv_profile.pl):
# a short, one-shot spawn/poll pair mirroring webui_meter_lg_autocal_start /
# webui_meter_lg_autocal_status (usr/share/PGenerator/webui.pm), but without
# that pair's greyscale-specific config rewriting -- the worker only reads
# the handful of fields it already knows about (input_max, display_type,
# ccss_override, delay_ms, pattern_signal_range/signal_range,
# transport_signal_range, picture_mode, upload, fixture_mode/*), so the
# client-supplied body is written to the config file as-is.
my $_meter_lg_dv_profile_file="/tmp/meter_lg_dv_profile.json";
my $_meter_lg_dv_profile_config_file="/tmp/meter_lg_dv_profile_config.json";
my $_meter_lg_dv_profile_stop_file="/tmp/meter_lg_dv_profile.stop";
my $_meter_lg_dv_profile_log_file="/tmp/meter_lg_dv_profile.log";
my $_meter_lg_dv_profile_start_lock_file="/tmp/meter_lg_dv_profile.start.lock";

sub webui_meter_lg_dv_profile_running (@) {
 my $alive=`pgrep -f '[m]eter_lg_dv_profile\\.pl' 2>/dev/null`;
 return ($alive=~/\d/) ? 1 : 0;
}

sub webui_meter_lg_dv_profile_same_run_running (@) {
 my ($body)=@_;
 return 0 if(!defined($body) || $body eq "" || !-f $_meter_lg_dv_profile_config_file);
 my $requested="";
 $requested=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"\\]{1,200})"/);
 return 0 if($requested eq "");
 my $config="";
 if(open(my $fh,"<",$_meter_lg_dv_profile_config_file)) { local $/; $config=<$fh>; close($fh); }
 return 0 if($config eq "");
 return ($config=~/"full_autocal_run_id"\s*:\s*"\Q$requested\E"/) ? 1 : 0;
}

# The start handler writes the config and an initial "running" state under
# its lock BEFORE system() backgrounds the setsid worker, but pgrep cannot
# see that worker until the child has exec'd. This is the evidence that
# bridges the gap: a fresh initial state still claiming "running". The mtime
# bound keeps a crashed worker's leftover state from answering forever — the
# status endpoint's liveness check rewrites such a state on its next poll.
sub webui_meter_lg_dv_profile_recently_started (@) {
 return 0 if(!-f $_meter_lg_dv_profile_file);
 my $age=time()-((stat($_meter_lg_dv_profile_file))[9]||0);
 return 0 if($age>20);
 my $json="";
 if(open(my $fh,"<",$_meter_lg_dv_profile_file)) { local $/; $json=<$fh>; close($fh); }
 return ($json=~/"status"\s*:\s*"running"/) ? 1 : 0;
}

sub webui_meter_lg_dv_profile_mark_cancelled (@) {
 return unless(-f $_meter_lg_dv_profile_file);
 my $json="";
 if(open(my $fh,"<",$_meter_lg_dv_profile_file)) { local $/; $json=<$fh>; close($fh); }
 return if($json eq "");
 # Keep the rewrites below off the keys inside activity events.
 my $events;
 ($json,$events)=&webui_worker_status_detach_events($json);
 if($json=~/"status"\s*:\s*"[^"]*"/) {
  $json=~s/"status"\s*:\s*"[^"]*"/"status":"cancelled"/;
 } else {
  $json=~s/\}\s*\z/,"status":"cancelled"}/;
 }
 if($json=~/"message"\s*:\s*"[^"]*"/) {
  $json=~s/"message"\s*:\s*"[^"]*"/"message":"Dolby Vision profile measurement stopped"/;
 } else {
  $json=~s/\}\s*\z/,"message":"Dolby Vision profile measurement stopped"}/;
 }
 if(open(my $fh,">",$_meter_lg_dv_profile_file)) { print $fh &webui_worker_status_attach_events($json,$events); close($fh); chmod(0666,$_meter_lg_dv_profile_file); }
}

sub webui_meter_lg_dv_profile_kill (@) {
 my $mark=shift;
 &webui_meter_lg_dv_profile_request_stop();
 system("sudo pkill -TERM -f '[m]eter_lg_dv_profile\\.pl' 2>/dev/null");
 select(undef,undef,undef,0.4);
 system("sudo pkill -9 -f '[m]eter_lg_dv_profile\\.pl' 2>/dev/null") if(&webui_meter_lg_dv_profile_running());
 &webui_meter_lg_dv_profile_mark_cancelled() if($mark);
}

sub webui_meter_lg_dv_profile_request_stop (@) {
 return 0 if(!open(my $fh,">",$_meter_lg_dv_profile_stop_file));
 my $ok=print $fh time();
 $ok=0 if(!$ok || !close($fh));
 chmod(0666,$_meter_lg_dv_profile_stop_file) if($ok);
 return $ok ? 1 : 0;
}

sub webui_meter_lg_dv_profile_start (@) {
 my ($body)=@_;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 my $replayed=PGAutomation::worker_replay_json($body,$_meter_lg_dv_profile_file);
 return $replayed if($replayed ne "");
 return '{"status":"error","message":"Dolby Vision profile payload required"}' if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 my $start_lock;
 return '{"status":"error","retryable":true,"message":"Unable to serialize Dolby Vision profile startup"}'
  if(!open($start_lock,">>",$_meter_lg_dv_profile_start_lock_file));
 flock($start_lock,LOCK_EX);
 my $_autocal_handoff_guard=&webui_meter_lg_autocal_handoff_guard();
 return $_autocal_handoff_guard if(defined($_autocal_handoff_guard));
 # retryable:false so the Full AutoCal busy loop does not treat a FOREIGN
 # worker's rejection as a transient hand-off wait and then adopt that
 # worker (the adoption probe additionally requires a run-id match).
 return '{"status":"error","retryable":false,"message":"LG 3D LUT AutoCal is already running"}' if(&webui_meter_lg_3d_autocal_running());
 # The same-run check runs FIRST, against both liveness sources: pgrep for a
 # visible worker, and the just-written config + initial state for a worker
 # still inside the spawn gap. A same-run duplicate arriving in that gap
 # would otherwise pass the process check and start a second worker over the
 # first one's config and state files.
 if(&webui_meter_lg_dv_profile_same_run_running($body)
    && (&webui_meter_lg_dv_profile_running() || &webui_meter_lg_dv_profile_recently_started())) {
  return '{"status":"started","message":"Dolby Vision profile measurement already running"}';
 }
 if(&webui_meter_lg_dv_profile_running()) {
  return '{"status":"error","retryable":false,"message":"Dolby Vision profile measurement is already running"}';
 }
 my ($scoped_body,$scope_error)=&webui_lg_freeze_calibration_context($body);
 return &lg_encode_json({status=>'error',message=>$scope_error}) if($scope_error);
 $body=$scoped_body;
 my $_dv_display_model=&webui_lg_display_model_name({});
 if($_dv_display_model ne "" && $body!~/"display_model"\s*:/) {
  $_dv_display_model=~s/\\/\\\\/g; $_dv_display_model=~s/"/\\"/g;
  $body=~s/\}\s*\z/,"display_model":"$_dv_display_model"}/;
 }
 # Clean up any stale session/meter state before the worker starts its own
 # /api/meter/read calls -- same reasoning as webui_meter_lg_3d_autocal_start
 # calling this at the greyscale-to-3D handoff.
 &webui_meter_stop();
 unlink($_meter_lg_dv_profile_stop_file);
 if(-e $_meter_lg_dv_profile_stop_file) {
  system("sudo rm -f ".quotemeta($_meter_lg_dv_profile_stop_file)." 2>/dev/null");
  unlink($_meter_lg_dv_profile_stop_file);
 }
 # Precompute the pattern-insertion flash codes, exactly as the greyscale
 # AutoCal start handler does, so the DV profile conditions the panel with the
 # same insertion levels the greyscale pass used. Without this the worker falls
 # back to a plain percentage of full scale, which is not the code the DV
 # ladder emits for that stimulus.
 my $_dv_ins_body=&lg_decode_json($body);
 if(ref($_dv_ins_body) eq "HASH" && $_dv_ins_body->{"patch_insert"}) {
  my $_dv_range=$_dv_ins_body->{"pattern_signal_range"}||$_dv_ins_body->{"signal_range"}||"";
  my %_dv_opts=( dv_series => 1 );
  my ($p_code,$p_im)=("",255);
  my ($t_code,$t_im)=("",255);
  if($_dv_ins_body->{"patch_insert_patch_enabled"}) {
   ($p_code,$p_im)=&webui_grey_code_for_stimulus($_dv_ins_body->{"patch_insert_patch_level"},"dv","2.2",$_dv_range,\%_dv_opts);
  }
  if($_dv_ins_body->{"patch_insert_time_enabled"}) {
   ($t_code,$t_im)=&webui_grey_code_for_stimulus($_dv_ins_body->{"patch_insert_time_level"},"dv","2.2",$_dv_range,\%_dv_opts);
  }
  # Normalise to valid JSON integers -- an empty code would emit
  # "patch_insert_patch_code":, and the worker would fail to parse its config.
  $p_code=0 if(!defined($p_code) || $p_code !~ /^-?\d+$/);
  $t_code=0 if(!defined($t_code) || $t_code !~ /^-?\d+$/);
  $p_im=255 if(!defined($p_im) || $p_im !~ /^-?\d+$/);
  $t_im=255 if(!defined($t_im) || $t_im !~ /^-?\d+$/);
  $body=~s/\}\s*\z/,"patch_insert_patch_code":$p_code,"patch_insert_patch_input_max":$p_im,"patch_insert_time_code":$t_code,"patch_insert_time_input_max":$t_im}/;
 }
 return PGAutomation::encode_json({status=>"error",message=>"Unable to persist private worker configuration"})
  if(!PGAutomation::write_atomic($_meter_lg_dv_profile_config_file,$body,0600));
 # Stamp the Full AutoCal run id (if any) into the initial status so the
 # browser's adoption probe can tell THIS run's worker from a foreign one
 # from the very first poll. The worker's own rewrites drop the key;
 # webui_meter_lg_dv_profile_status re-injects it from the config file.
 my $_dv_run_id="";
 $_dv_run_id=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"\\]{1,200})"/);
 my $init=($_dv_run_id ne "")
  ? '{"status":"running","full_autocal_run_id":"'.$_dv_run_id.'","message":"Starting Dolby Vision profile measurement","steps":[]}'
  : '{"status":"running","message":"Starting Dolby Vision profile measurement","steps":[]}';
 $init=PGAutomation::seed_worker_state_json($init,$body);
 return PGAutomation::encode_json({status=>"error",message=>"Unable to persist worker launch identity"})
  if(!&webui_worker_state_init_write($_meter_lg_dv_profile_file,$init));
 my $log_file=&webui_prepare_tmp_worker_log($_meter_lg_dv_profile_log_file,"meter_lg_dv_profile");
 my $cmd="setsid /usr/bin/perl /usr/bin/meter_lg_dv_profile.pl '$_meter_lg_dv_profile_config_file' '$_meter_lg_dv_profile_file' '$_meter_lg_dv_profile_stop_file' </dev/null >'$log_file' 2>&1 &";
 system($cmd);
 return '{"status":"started","message":"Dolby Vision profile measurement started"}';
}

sub webui_meter_lg_dv_profile_status (@) {
 my ($query,$file)=@_;
 # Tests pass their own state file; the daemon always uses the fixed path.
 $file=$_meter_lg_dv_profile_file if(!defined($file) || $file eq "");
 return '{"status":"idle","message":"No Dolby Vision profile measurement has run yet","steps":[]}' if(!-f $file);
 # ?view=summary serves the automation poller's projection (see
 # webui_worker_status_read in webui.pm); nothing below writes the file.
 my ($json)=&webui_worker_status_read($file,$query);
 return '{"status":"idle","message":"No Dolby Vision profile measurement has run yet","steps":[]}' if($json eq "");
 # Keep the fix-ups below off the keys inside activity events.
 my $events;
 ($json,$events)=&webui_worker_status_detach_events($json);
 # The worker is a short, one-shot ~5-patch run -- a single liveness check is
 # enough to catch a killed/crashed process. The long-running greyscale/3D
 # workers need a multi-poll debounce to ride out meter-session bounces
 # (see webui_meter_lg_3d_autocal_status); this one does not run long enough
 # to need that extra bookkeeping.
 if($json=~/"status"\s*:\s*"running"/ && !&webui_meter_lg_dv_profile_running()) {
  $json=~s/"status"\s*:\s*"running"/"status":"error"/;
  if($json=~/"message"\s*:\s*"[^"]*"/) {
   $json=~s/"message"\s*:\s*"[^"]*"/"message":"Dolby Vision profile measurement process ended unexpectedly"/;
  } else {
   $json=~s/\}\s*\z/,"message":"Dolby Vision profile measurement process ended unexpectedly"}/;
  }
 }
 # The worker's status rewrites do not carry the Full AutoCal run id, but
 # the config written at start does. Re-inject it so the adoption probe can
 # verify worker identity for the whole run, not just the start window.
 if($json!~/"full_autocal_run_id"/ && $json=~/^\s*\{\s*"/ && -f $_meter_lg_dv_profile_config_file) {
  my $cfg="";
  if(open(my $cf,"<",$_meter_lg_dv_profile_config_file)) { local $/; $cfg=<$cf>; close($cf); }
  if($cfg=~/"full_autocal_run_id"\s*:\s*"([^"\\]{1,200})"/) {
   my $run=$1;
   $json=~s/^\s*\{/{"full_autocal_run_id":"$run",/;
  }
 }
 return &webui_worker_status_attach_events($json,$events);
}

sub webui_meter_lg_dv_profile_stop (@) {
 my ($body)=@_;
 if(defined($body) && $body=~/"automation_graceful"\s*:\s*true/i) {
  my $automation_guard=&lg_automation_guard_json($body);
  return $automation_guard if($automation_guard ne "");
  return &lg_encode_json({status=>"error",message=>"Unable to write Dolby Vision profile stop request"})
   if(!&webui_meter_lg_dv_profile_request_stop());
  return &lg_encode_json({status=>"ok",message=>"Dolby Vision profile stop requested"});
 }
 return &webui_meter_stop_complete($body);
}

sub webui_meter_lg_dv_profile_force_stop (@) {
 my ($body)=@_;
 my $automation_guard=&lg_automation_guard_json($body);
 return $automation_guard if($automation_guard ne "");
 &webui_meter_lg_dv_profile_kill(1);
 return '{"status":"ok","message":"Dolby Vision profile force stop requested"}';
}

sub webui_lg_hdr_calman_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting HDR calibration state.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting HDR calibration state." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting HDR calibration state." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting HDR calibration state." }) if($client_key eq "");
 my $picture_mode=$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
 my $stale_cleanup=&lg_clear_stale_calibration_mode_for_reset($clients,$ip,$client_key,$picture_mode,"hdr10");
 return &lg_encode_json($stale_cleanup) if(ref($stale_cleanup) eq "HASH" && ($stale_cleanup->{"status"}||"") ne "ok");
 my $result=&lg_helper_run({
  action => "hdr_calman_reset",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $picture_mode,
  last_written_picture_mode => $clients->{"last_written_picture_mode"}||"",
  ddc_layout => $payload->{"ddc_layout"}||"hdr20",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 $result->{"stale_calibration_mode_cleanup"}=$stale_cleanup if(ref($result) eq "HASH" && ref($stale_cleanup) eq "HASH");
 &lg_record_calibration_mode_result($clients,$result,0,$picture_mode);
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR calibration reset again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

# Dolby Vision counterpart of webui_lg_hdr_calman_reset -- kept as its own
# route/handler rather than a branch in the HDR one (operator directive
# 2026-07-24: DV gets its own path, the HDR path/text stay untouched).
sub webui_lg_dv_calman_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting Dolby Vision calibration state.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting Dolby Vision calibration state." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting Dolby Vision calibration state." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting Dolby Vision calibration state." }) if($client_key eq "");
 my $picture_mode=$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
 my $stale_cleanup=&lg_clear_stale_calibration_mode_for_reset($clients,$ip,$client_key,$picture_mode,"dv");
 return &lg_encode_json($stale_cleanup) if(ref($stale_cleanup) eq "HASH" && ($stale_cleanup->{"status"}||"") ne "ok");
 my $result=&lg_helper_run({
  action => "dv_calman_reset",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $picture_mode,
  last_written_picture_mode => $clients->{"last_written_picture_mode"}||"",
  ddc_layout => $payload->{"ddc_layout"}||"hdr20",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 $result->{"stale_calibration_mode_cleanup"}=$stale_cleanup if(ref($result) eq "HASH" && ref($stale_cleanup) eq "HASH");
 &lg_record_calibration_mode_result($clients,$result,0,$picture_mode);
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the Dolby Vision calibration reset again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_sdr_calman_reset (@) {
 # SDR counterpart of webui_lg_hdr_calman_reset. The auto-cal wizard
 # calls /api/lg/sdr-calman-reset after the SDR picture-mode reset
 # to clear any prior HDR cycle's BT.2020 3x3 matrix / 3D LUT so the
 # SDR DPG deltas are applied in BT.709 code space. Without this
 # route the dispatcher falls through to the generic "Unknown LG
 # route" error and the wizard surfaces it as "Reset failed - Unknown
 # LG route." The helper (pgenerator-lg lg_sdr_calman_reset_workflow)
 # has been there since the SDR reference reset was added; the webui
 # endpoint to reach it was not.
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting SDR calibration state.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting SDR calibration state." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting SDR calibration state." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", delivery_state => "not-sent", message => "Connect the LG TV before resetting SDR calibration state." }) if($client_key eq "");
 my $picture_mode=$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
 my $stale_cleanup=&lg_clear_stale_calibration_mode_for_reset($clients,$ip,$client_key,$picture_mode,"sdr");
 return &lg_encode_json($stale_cleanup) if(ref($stale_cleanup) eq "HASH" && ($stale_cleanup->{"status"}||"") ne "ok");
 my $result=&lg_helper_run({
  action => "sdr_calman_reset",
  expected_tv_input => $payload->{"expected_tv_input"}||"",
  expected_profile_hash => $payload->{"expected_profile_hash"}||"",
  tv_input => $payload->{"tv_input"}||"",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $picture_mode,
  ddc_layout => $payload->{"ddc_layout"}||"sdr26",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 $result->{"stale_calibration_mode_cleanup"}=$stale_cleanup if(ref($result) eq "HASH" && ref($stale_cleanup) eq "HASH");
 &lg_record_calibration_mode_result($clients,$result,0,$picture_mode);
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the SDR calibration reset again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}


# --- Calibration history: final uploaded 1D DPGs, 3D LUTs, DV configs ---
my $_lg_cal_hist_runs="/var/lib/PGenerator/lg/autocal-runs";
my $_lg_cal_hist_luts="/var/lib/PGenerator/lg/luts";
my $_lg_cal_hist_dir="/var/lib/PGenerator/lg/calibration-history";

# Stable human-readable model used in newly archived AutoCal artifact names.
# Prefer a model explicitly carried by the workflow, then the connected/saved
# WebOS client. Keeping this lookup server-side means 1D and DV uploads are
# named correctly even when an older browser did not include display metadata.
sub webui_lg_display_model_name (@) {
 my ($meta)=@_;
 $meta={} if(ref($meta) ne "HASH");
 my $model=$meta->{"display_model"} || $meta->{"model_name"} || "";
 foreach my $key (qw(lg_generation preflight_lg_generation)) {
  my $generation=$meta->{$key};
  next unless($model eq "" && ref($generation) eq "HASH");
  $model=$generation->{"model_name"} || $generation->{"platform_model"} || $generation->{"product_name"} || "";
 }
 if($model eq "") {
  my $clients=eval { &lg_load_clients() } || {};
  my $client=eval { &lg_primary_client($clients) } || {};
  $model=$client->{"model_name"} || $client->{"name"} || $clients->{"model_name"} || $clients->{"name"} || "";
 }
 $model=~s/^\s+|\s+$//g;
 return $model;
}

sub _lg_cal_hist_model_token {
 my ($meta)=@_;
 my $model=&webui_lg_display_model_name($meta);
 $model=~s/[^A-Za-z0-9._-]+/_/g;
 $model=~s/^[._-]+|[._-]+$//g;
 return $model;
}

sub _lg_cal_hist_json_escape {
 my ($s)=@_;
 $s="" if(!defined $s);
 $s=~s/\\/\\\\/g; $s=~s/"/\\"/g; $s=~s/\n/\\n/g; $s=~s/\r/\\r/g; $s=~s/\t/\\t/g;
 return $s;
}

sub _lg_cal_hist_read_json_file {
 my ($path)=@_;
 return undef unless(defined($path) && -f $path);
 my $raw="";
 if(open(my $fh,"<",$path)) { local $/; $raw=<$fh>; close($fh); }
 return undef if($raw eq "" || $raw!~/^\s*\{/);
 return &lg_decode_json($raw) if(defined(&lg_decode_json));
 return undef;
}

# List final autocal uploads only:
#  - 1D: autocal-runs/*/grey-state with final_1d_lut_uploaded + a 3072-value DPG
#  - 3D: /var/lib/PGenerator/lg/luts/*.bin with companion .json (export_lut triple)
#  - DV: runs whose stages.ndjson have a successful dv_profile_upload

# Resolve a run's final 1D DPG regardless of layout. The greyscale worker stores
# the HDR20 curve under hdr20_1d_dpg_data and the SDR26 curve under
# sdr_1d_dpg_data; the list and reupload paths previously read only the HDR key,
# so a COMPLETED SDR run (final_1d_lut_uploaded=true) was skipped and no SDR 1D
# LUT ever appeared in Calibration History -- leaving SDR calibrations with no
# restore path at all. Returns (dpg, signal_mode, de) with signal_mode inferred
# from whichever key carried the data when the run did not stamp one.
sub _lg_cal_hist_run_1d {
 my ($state)=@_;
 return (undef,"",undef) unless(ref($state) eq "HASH");
 my $hdr=$state->{"hdr20_1d_dpg_data"};
 if(ref($hdr) eq "ARRAY" && scalar(@$hdr)==3072) {
  return ($hdr,"hdr10",
   defined($state->{"hdr20_1d_dpg_best_de"}) ? $state->{"hdr20_1d_dpg_best_de"}
    : $state->{"hdr20_1d_dpg_final_de"});
 }
 my $sdr=$state->{"sdr_1d_dpg_data"};
 if(ref($sdr) eq "ARRAY" && scalar(@$sdr)==3072) {
  return ($sdr,"sdr",
   defined($state->{"sdr_1d_dpg_best_de"}) ? $state->{"sdr_1d_dpg_best_de"}
    : $state->{"sdr_1d_dpg_final_de"});
 }
 return (undef,"",undef);
}

# Did this run's DPG already carry the post-cal shadow smoothing? Recorded so the
# history label can distinguish the smoothed curve from the raw solve.
sub _lg_cal_hist_run_smoothed {
 my ($state)=@_;
 return 0 unless(ref($state) eq "HASH");
 return 1 if($state->{"sdr_1d_dpg_low_end_smoothed"});
 return 1 if($state->{"hdr20_1d_dpg_low_end_smoothed"});
 return 0;
}

sub _lg_cal_hist_ensure_dir {
 system("mkdir -p ".quotemeta($_lg_cal_hist_dir)."/1d ".quotemeta($_lg_cal_hist_dir)."/dv 2>/dev/null");
 system("chmod 0777 ".quotemeta($_lg_cal_hist_dir)." ".quotemeta($_lg_cal_hist_dir)."/1d ".quotemeta($_lg_cal_hist_dir)."/dv 2>/dev/null");
}

sub _lg_cal_hist_write_json {
 my ($path,$data)=@_;
 return 0 unless(defined($path) && ref($data) eq "HASH");
 &_lg_cal_hist_ensure_dir();
 my $json=&lg_encode_json($data);
 return 0 if(!defined($json) || $json eq "");
 if(open(my $fh,">",$path)) { print $fh $json; close($fh); chmod(0666,$path); return 1; }
 return 0;
}

sub _lg_cal_hist_archive_1d {
 my ($dpg_data,$meta)=@_;
 return 0 unless(ref($dpg_data) eq "ARRAY" && scalar(@$dpg_data)==3072);
 $meta={} if(ref($meta) ne "HASH");
 &_lg_cal_hist_ensure_dir();
 my ($sec,$min,$hour,$mday,$mon,$year)=localtime(time());
 my $stamp=sprintf("%04d%02d%02d_%02d%02d%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec);
 my $pm=$meta->{"picture_mode"}||"mode"; $pm=~s/[^A-Za-z0-9._-]+/_/g;
 my $sm=$meta->{"signal_mode"}||"sig"; $sm=~s/[^A-Za-z0-9._-]+/_/g;
 my $display_model=&webui_lg_display_model_name($meta);
 my $model_token=&_lg_cal_hist_model_token($meta);
 # variant distinguishes curves archived for the SAME run -- notably the raw
 # solve versus the post-cal shadow-smoothed curve, so either can be restored.
 my $variant=$meta->{"variant"}||""; $variant=~s/[^A-Za-z0-9._-]+/_/g;
 my $id="${stamp}".($model_token ne "" ? "_${model_token}" : "")."_${sm}_${pm}".($variant ne "" ? "_${variant}" : "");
 return _lg_cal_hist_write_json("$_lg_cal_hist_dir/1d/${id}.json",{
  id => "1dfile:$id",
  type => "1d",
  picture_mode => $meta->{"picture_mode"}||"",
  signal_mode => $meta->{"signal_mode"}||"",
  display_model => $display_model,
  variant => $meta->{"variant"}||"",
  de => $meta->{"de"},
  archived_at => time()+0,
  dpg_data => $dpg_data,
  source_run => $meta->{"run_id"}||"",
 });
}

sub _lg_cal_hist_archive_dv {
 my ($measurements,$meta)=@_;
 return 0 unless(ref($measurements) eq "HASH" && defined($measurements->{"white_luminance"}));
 $meta={} if(ref($meta) ne "HASH");
 &_lg_cal_hist_ensure_dir();
 my ($sec,$min,$hour,$mday,$mon,$year)=localtime(time());
 my $stamp=sprintf("%04d%02d%02d_%02d%02d%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec);
 my $pm=$meta->{"picture_mode"}||"dolbyVision";
 my $pm_safe=$pm; $pm_safe=~s/[^A-Za-z0-9._-]+/_/g;
 my $display_model=&webui_lg_display_model_name($meta);
 my $model_token=&_lg_cal_hist_model_token($meta);
 my $id="${stamp}".($model_token ne "" ? "_${model_token}" : "")."_${pm_safe}";
 my $current="";
 if(open(my $fh,"<","$_lg_cal_hist_runs/current")) { local $/; $current=<$fh>; close($fh); chomp($current); $current=~s/[^A-Za-z0-9._-]//g; }
 if($current ne "" && -d "$_lg_cal_hist_runs/$current") {
  _lg_cal_hist_write_json("$_lg_cal_hist_runs/$current/dv-profile-measurements.json",{
   measurements => $measurements,
   picture_mode => $pm,
   signal_mode => "dv",
   display_model => $display_model,
   archived_at => time()+0,
  });
 }
 return _lg_cal_hist_write_json("$_lg_cal_hist_dir/dv/${id}.json",{
  id => "dvfile:$id",
  type => "dv",
  picture_mode => $pm,
  signal_mode => "dv",
  display_model => $display_model,
  archived_at => time()+0,
  measurements => $measurements,
  source_run => $current||($meta->{"run_id"}||""),
 });
}

# The list is derived only from archive and run files. Decoding every archive
# (each 1D entry carries a 3,072-value LUT) took 15-19 s on the appliance and
# held the single TV lane. A stat-only fingerprint of every file the list
# reads decides whether the last result is still valid.
sub _lg_cal_hist_fingerprint {
 require Digest::MD5;
 eval { require Time::HiRes; 1 };
 my $md5=Digest::MD5->new;
 $md5->add("calibration-history-list:1\n");
 my $add=sub {
  my ($path)=@_;
  my @st=eval { Time::HiRes::stat($path) };
  @st=stat($path) if(!@st);
  $md5->add($path,"\0",(@st ? join(':',$st[1],$st[7],$st[9]) : '-'),"\n");
 };
 foreach my $dir ("$_lg_cal_hist_dir/1d","$_lg_cal_hist_dir/dv",$_lg_cal_hist_luts) {
  if(opendir(my $dh,$dir)) { $add->("$dir/$_") foreach(sort grep { $_ ne '.' && $_ ne '..' } readdir($dh)); closedir($dh); }
  else { $md5->add("$dir:absent\n"); }
 }
 if(opendir(my $dh,$_lg_cal_hist_runs)) {
  foreach my $run (sort grep { $_ ne '.' && $_ ne '..' } readdir($dh)) {
   $add->("$_lg_cal_hist_runs/$run/$_") foreach(qw(grey-state.json manifest.json dv-profile-measurements.json 3d-state.json stages.ndjson));
  }
  closedir($dh);
 } else { $md5->add("$_lg_cal_hist_runs:absent\n"); }
 return $md5->hexdigest;
}

sub webui_lg_calibration_history_list (@) {
 my $cache="$_lg_cal_hist_dir.list-cache";
 my $fingerprint=eval { _lg_cal_hist_fingerprint() } || '';
 if($fingerprint ne '' && open(my $fh,"<",$cache)) {
  local $/; my $raw=<$fh>; close($fh);
  # Only a complete, decodable body counts (a torn write must not be served).
  if(defined($raw) && $raw=~/\A\Q$fingerprint\E\n(\{"status":"ok".*\})\n?\z/s) {
   my $body=$1;
   return $body if(eval { ref(JSON::PP::decode_json($body)) eq 'HASH' });
  }
 }
 my $body=_lg_cal_hist_list_uncached();
 if($fingerprint ne '') {
  my $tmp="$cache.$$.".int(rand(1_000_000_000)).".tmp";
  if(open(my $out,">",$tmp)) {
   my $ok=print {$out} "$fingerprint\n$body\n";
   $ok=close($out) && $ok;
   if(!$ok || !rename($tmp,$cache)) { unlink($tmp); }
  }
 }
 return $body;
}

# Per-file memo for the list: a calibration adds or changes a few files, and
# only those are decoded again. Only what the list reads is kept: scalars,
# nested hashes two levels down (config, measurements), and the lengths of the
# 1D curve arrays (the list checks for 3,072 values). Readings, LUT tables and
# every other array are dropped, so a multi-megabyte AutoCal state costs a few
# kilobytes. Entries for files the latest list did not read are forgotten.
my %_lg_cal_hist_lite_memo;
my %_lg_cal_hist_lite_seen;
my %_lg_cal_hist_length_keys=map {$_=>1} qw(dpg_data hdr20_1d_dpg_data sdr_1d_dpg_data);
sub _lg_cal_hist_lite_value {
 my ($value,$depth)=@_;
 $depth||=0;
 return $value if(ref($value) ne 'HASH');
 my %lite;
 foreach my $key (keys %$value) {
  my $item=$value->{$key};
  if(!ref($item) || ref($item) eq 'JSON::PP::Boolean') { $lite{$key}=$item; }
  elsif(ref($item) eq 'ARRAY') {
   my @shape;
   $#shape=$#$item if($_lg_cal_hist_length_keys{$key});
   $lite{$key}=\@shape;
  }
  elsif(ref($item) eq 'HASH' && $depth<2) { $lite{$key}=_lg_cal_hist_lite_value($item,$depth+1); }
 }
 return \%lite;
}
sub _lg_cal_hist_read_json_lite {
 my ($path)=@_;
 $_lg_cal_hist_lite_seen{$path}=1;
 my @st=eval { require Time::HiRes; Time::HiRes::stat($path) };
 @st=stat($path) if(!@st);
 if(!@st) { delete $_lg_cal_hist_lite_memo{$path}; return undef; }
 my $key=join(':',$st[1],$st[7],$st[9]);
 my $hit=$_lg_cal_hist_lite_memo{$path};
 return $hit->{value} if(ref($hit) eq 'HASH' && $hit->{key} eq $key);
 my $value=_lg_cal_hist_read_json_file($path);
 $value=_lg_cal_hist_lite_value($value) if(defined($value));
 $_lg_cal_hist_lite_memo{$path}={key=>$key,value=>$value};
 return $value;
}
sub _lg_cal_hist_lite_memo_paths { return sort keys %_lg_cal_hist_lite_memo; }

sub _lg_cal_hist_list_uncached (@) {
 %_lg_cal_hist_lite_seen=();
 my @items;
 # Durable archive (preferred — reuploadable snapshots written on successful upload)
 if(opendir(my $dh,"$_lg_cal_hist_dir/1d")) {
  foreach my $f (sort { $b cmp $a } readdir($dh)) {
   next unless($f =~ /^([A-Za-z0-9._-]+)\.json$/);
   my $meta=_lg_cal_hist_read_json_lite("$_lg_cal_hist_dir/1d/$f");
   next unless(ref($meta) eq "HASH" && ref($meta->{"dpg_data"}) eq "ARRAY" && @{$meta->{"dpg_data"}}==3072);
   my $id=$meta->{"id"} || "1dfile:$1";
   my $mtime=(stat("$_lg_cal_hist_dir/1d/$f"))[9] || ($meta->{"archived_at"}||0);
   my $pm=$meta->{"picture_mode"}||"";
   my $sm=$meta->{"signal_mode"}||"";
   my $variant=$meta->{"variant"}||"";
   my $display_model=$meta->{"display_model"}||"";
   my $label="$1 1D ".($sm||"?")." ".($pm||"");
   $label.=" (".$variant.")" if($variant ne "" && $1!~/\Q$variant\E/);
   $label=~s/\s+$//;
   push @items,{
    id => $id,
    type => "1d",
    label => $label,
    picture_mode => $pm,
    signal_mode => $sm,
    variant => $variant,
    display_model => $display_model,
    mtime => $mtime+0,
    de => defined($meta->{"de"}) ? ($meta->{"de"}+0) : undef,
    source => "archive",
    reuploadable => ($pm ne '' && $sm =~ /^(?:sdr|hdr10|dv)$/) ? 1 : 0,
    note => ($pm ne '' && $sm =~ /^(?:sdr|hdr10|dv)$/) ? 'Restores the 1D LUT only; other settings and profiles are unchanged.' : 'Saved signal or picture mode is missing; automatic restore is unavailable.',
   };
  }
  closedir($dh);
 }
 if(opendir(my $dh,"$_lg_cal_hist_dir/dv")) {
  foreach my $f (sort { $b cmp $a } readdir($dh)) {
   next unless($f =~ /^([A-Za-z0-9._-]+)\.json$/);
   my $meta=_lg_cal_hist_read_json_lite("$_lg_cal_hist_dir/dv/$f");
   next unless(ref($meta) eq "HASH" && ref($meta->{"measurements"}) eq "HASH");
   my $id=$meta->{"id"} || "dvfile:$1";
   my $mtime=(stat("$_lg_cal_hist_dir/dv/$f"))[9] || ($meta->{"archived_at"}||0);
   my $pm=$meta->{"picture_mode"}||"dolbyVision";
   my $display_model=$meta->{"display_model"}||"";
   push @items,{
    id => $id,
    type => "dv",
    label => "$1 DV config $pm",
    picture_mode => $pm,
    signal_mode => "dv",
    display_model => $display_model,
    mtime => $mtime+0,
    reuploadable => 1,
    source => "archive",
   };
  }
  closedir($dh);
 }
 # 1D from autocal runs (final only) — skip if already archived with same run
 if(opendir(my $dh,$_lg_cal_hist_runs)) {
  foreach my $run (sort { $b cmp $a } readdir($dh)) {
   next if($run eq "." || $run eq ".." || $run eq "current");
   next if($run !~ /^[A-Za-z0-9._-]+$/);
   my $dir="$_lg_cal_hist_runs/$run";
   next unless(-d $dir);
   my $state=_lg_cal_hist_read_json_lite("$dir/grey-state.json");
   next unless(ref($state) eq "HASH");
   my $uploaded=($state->{"final_1d_lut_uploaded"} || $state->{"hdr20_1d_dpg_uploaded"} || $state->{"sdr_1d_dpg_uploaded"}) ? 1 : 0;
   my ($dpg,$sm_from_data,$de_from_data)=_lg_cal_hist_run_1d($state);
   next unless($uploaded && ref($dpg) eq "ARRAY" && scalar(@$dpg) == 3072);
   my $manifest=_lg_cal_hist_read_json_lite("$dir/manifest.json") || {};
   my $cfg=(ref($manifest->{"config"}) eq "HASH") ? $manifest->{"config"} : {};
   # calibration_picture_mode is what the SDR26 worker stamps; the manifest
   # config is frequently absent on these runs.
   my $pm=$cfg->{"picture_mode"} || $state->{"picture_mode"} || $state->{"calibration_picture_mode"} || "";
   my $sm=$cfg->{"signal_mode"} || $state->{"signal_mode"} || $state->{"requested_signal_mode"} || $sm_from_data || "";
   my $display_model=$cfg->{"display_model"} || "";
   my $mtime=(stat("$dir/grey-state.json"))[9] || 0;
   my $smoothed=_lg_cal_hist_run_smoothed($state);
   my $label=($display_model ne "" ? $display_model." " : "").$run." 1D ".($sm||"?")." ".($pm||"").($smoothed ? " (smoothed)" : "");
   $label=~s/\s+$//;
   push @items,{
    id => "1d:$run",
    type => "1d",
    label => $label,
    run_id => $run,
    picture_mode => $pm,
    signal_mode => $sm,
    display_model => $display_model,
    variant => ($smoothed ? "smoothed" : ""),
    mtime => $mtime+0,
    de => defined($de_from_data) ? ($de_from_data+0) : undef,
    source => "run",
    reuploadable => ($pm ne '' && $sm =~ /^(?:sdr|hdr10|dv)$/) ? 1 : 0,
    note => ($pm ne '' && $sm =~ /^(?:sdr|hdr10|dv)$/) ? 'Restores the 1D LUT only; other settings and profiles are unchanged.' : 'Saved signal or picture mode is missing; automatic restore is unavailable.',
   };
  }
  closedir($dh);
 }
 # 3D LUTs with LG .bin (final upload payload)
 if(opendir(my $dh,$_lg_cal_hist_luts)) {
  foreach my $f (sort { $b cmp $a } readdir($dh)) {
   next unless($f =~ /^([A-Za-z0-9._-]+)\.bin$/);
   my $base=$1;
   next unless(-f "$_lg_cal_hist_luts/$base.bin");
   my $meta=_lg_cal_hist_read_json_lite("$_lg_cal_hist_luts/$base.json") || {};
   my $mtime=(stat("$_lg_cal_hist_luts/$base.bin"))[9] || 0;
   my $pm=$meta->{"picture_mode"} || "";
   my $sm=$meta->{"signal_mode"} || "";
   my $method=$meta->{"method"} || "";
   my $display_model=$meta->{"display_model"} || "";
   my $label=$base;
   $label=$meta->{"title"} if(defined($meta->{"title"}) && $meta->{"title"} ne "");
   push @items,{
    id => "3d:$base",
    type => "3d",
    label => $label,
    base => $base,
    picture_mode => $pm,
    signal_mode => $sm,
    method => $method,
    display_model => $display_model,
    mtime => $mtime+0,
    has_cube => (-f "$_lg_cal_hist_luts/$base.cube") ? 1 : 0,
    download => (-f "$_lg_cal_hist_luts/$base.cube") ? "/api/3d-lut/cube?file=${base}.cube" : "",
    source => "luts",
   };
  }
  closedir($dh);
 }
 # DV from runs — only when measurements are available (reuploadable)
 if(opendir(my $dh,$_lg_cal_hist_runs)) {
  foreach my $run (sort { $b cmp $a } readdir($dh)) {
   next if($run eq "." || $run eq ".." || $run eq "current");
   next if($run !~ /^[A-Za-z0-9._-]+$/);
   my $dir="$_lg_cal_hist_runs/$run";
   my $meas_path="$dir/dv-profile-measurements.json";
   my $meas;
   if(-f $meas_path) {
    my $wrap=_lg_cal_hist_read_json_lite($meas_path) || {};
    $meas=$wrap->{"measurements"} if(ref($wrap->{"measurements"}) eq "HASH");
    $meas=$wrap if(!$meas && defined($wrap->{"white_luminance"}));
   }
   if(ref($meas) ne "HASH") {
    my $state=_lg_cal_hist_read_json_lite("$dir/grey-state.json") || {};
    my $state3=_lg_cal_hist_read_json_lite("$dir/3d-state.json") || {};
    $meas=$state->{"dv_profile_measurements"} || $state3->{"dv_profile_measurements"} || $state3->{"measurements"};
   }
   next unless(ref($meas) eq "HASH" && defined($meas->{"white_luminance"}));
   my $manifest=_lg_cal_hist_read_json_lite("$dir/manifest.json") || {};
   my $cfg=(ref($manifest->{"config"}) eq "HASH") ? $manifest->{"config"} : {};
   my $pm=$cfg->{"picture_mode"} || "";
   my $display_model=$cfg->{"display_model"} || "";
   # Prefer DV picture modes when labeling
   my $stages_path="$dir/stages.ndjson";
   if(-f $stages_path && open(my $fh,"<",$stages_path)) {
    while(my $line=<$fh>) {
     next unless($line =~ /"stage"\s*:\s*"dv_profile_upload"/ && $line =~ /"ok"\s*:\s*true/);
     if($line =~ /"picture_mode"\s*:\s*"([^"]*)"/) {
      # The log line is raw bytes; decode so the body's UTF-8 encoding is not applied twice.
      $pm=$1;
      utf8::decode($pm);
     }
    }
    close($fh);
   }
   $pm=$pm || "dolbyVision";
   my $mtime=(-f $meas_path) ? ((stat($meas_path))[9]||0) : ((stat($stages_path))[9]||0);
   push @items,{
    id => "dv:$run",
    type => "dv",
    label => ($display_model ne "" ? $display_model." " : "")."$run DV config $pm",
    run_id => $run,
    picture_mode => $pm,
    signal_mode => "dv",
    display_model => $display_model,
    mtime => $mtime+0,
    reuploadable => 1,
    source => "run",
   };
  }
  closedir($dh);
 }
 @items=sort { ($b->{"mtime"}||0) <=> ($a->{"mtime"}||0) } @items;
 my @json;
 foreach my $it (@items) {
  my @pairs;
  for my $k (qw(id type label run_id base picture_mode signal_mode display_model method download note source)) {
   next unless(defined($it->{$k}) && $it->{$k} ne "");
   push @pairs,"\"$k\":\""._lg_cal_hist_json_escape($it->{$k})."\"";
  }
  for my $k (qw(mtime de has_cube reuploadable)) {
   next unless(defined($it->{$k}));
   my $v=$it->{$k};
   if($k eq "de") { push @pairs,"\"de\":".sprintf("%.4f",$v+0); }
   else { push @pairs,"\"$k\":".(int($v+0)); }
  }
  push @json,"{".join(",",@pairs)."}";
 }
 # Forget files this list no longer reads (pruned runs, removed archives).
 delete @_lg_cal_hist_lite_memo{grep {!$_lg_cal_hist_lite_seen{$_}} keys %_lg_cal_hist_lite_memo};
 # Titles and models come from decoded JSON as characters: send UTF-8 bytes,
 # as every other JSON body is, so the browser and the disk cache can decode it.
 my $body="{\"status\":\"ok\",\"items\":[".join(",",@json)."]}";
 utf8::encode($body);
 return $body;
}

sub webui_lg_calibration_history_download (@) {
 my ($body)=@_;
 my $payload=ref($body) eq "HASH" ? $body : &lg_decode_json($body||"{}");
 my $id="";
 if(ref($payload) eq "HASH") { $id=$payload->{"id"}||""; }
 if($id eq "" && defined($body) && !ref($body) && $body=~/id=([^&]+)/) { $id=$1; $id=~s/%3A/:/gi; $id=~s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; }
 return &lg_encode_json({ status => "error", message => "id required" }) if($id eq "");
 if($id =~ /^1d:([A-Za-z0-9._-]+)$/) {
  my $run=$1;
  my $state=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/grey-state.json");
  my ($run_dpg,$run_sm,$run_de)=_lg_cal_hist_run_1d($state);
  return &lg_encode_json({ status => "error", message => "1D data not found" })
   unless(ref($run_dpg) eq "ARRAY" && @{$run_dpg}==3072);
  my $manifest=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/manifest.json") || {};
  my $cfg=(ref($manifest->{"config"}) eq "HASH") ? $manifest->{"config"} : {};
  return &lg_encode_json({
   status => "ok", type => "1d", run_id => $run, dpg_data => $run_dpg,
   signal_mode => $cfg->{"signal_mode"} || $state->{"signal_mode"} || $state->{"requested_signal_mode"} || $run_sm || "",
   picture_mode => $cfg->{"picture_mode"} || $state->{"picture_mode"} || $state->{"calibration_picture_mode"} || "",
   display_model => $cfg->{"display_model"} || "",
  });
 }
 if($id =~ /^3d:([A-Za-z0-9._-]+)$/) {
  my $base=$1;
  return &lg_encode_json({ status => "ok", type => "3d", redirect => "/api/3d-lut/cube?file=${base}.cube" });
 }
 if($id =~ /^1dfile:([A-Za-z0-9._-]+)$/) {
  my $meta=_lg_cal_hist_read_json_file("$_lg_cal_hist_dir/1d/$1.json");
  return &lg_encode_json({ status => "error", message => "1D archive not found" })
   unless(ref($meta) eq "HASH" && ref($meta->{"dpg_data"}) eq "ARRAY");
  return &lg_encode_json({ status => "ok", type => "1d", dpg_data => $meta->{"dpg_data"}, picture_mode => $meta->{"picture_mode"}||"", signal_mode => $meta->{"signal_mode"}||"", display_model => $meta->{"display_model"}||"" });
 }
 if($id =~ /^dvfile:([A-Za-z0-9._-]+)$/) {
  my $meta=_lg_cal_hist_read_json_file("$_lg_cal_hist_dir/dv/$1.json");
  return &lg_encode_json({ status => "error", message => "DV archive not found" })
   unless(ref($meta) eq "HASH" && ref($meta->{"measurements"}) eq "HASH");
  return &lg_encode_json({ status => "ok", type => "dv", measurements => $meta->{"measurements"}, picture_mode => $meta->{"picture_mode"}||"" });
 }
 return &lg_encode_json({ status => "error", message => "Unknown id" });
}

sub _lg_cal_hist_restore_1d {
 my ($data,$saved_mode,$saved_signal,$payload)=@_;
 my $mode=$payload->{picture_mode}||$saved_mode||'';
 my $signal=$payload->{signal_mode}||$saved_signal||'';
 return &lg_encode_json({status=>'error',message=>'Restore requires the original saved signal and picture mode; cross-mode 1D restoration is not allowed.'})
  if(!$saved_mode || !$saved_signal || $mode ne $saved_mode || $signal ne $saved_signal || $signal !~ /^(?:sdr|hdr10|dv)$/);
 return &lg_encode_json({status=>'error',message=>"Select $signal output on the generator before restoring this 1D LUT."})
  if(defined(&webui_pattern_signal_mode) && &webui_pattern_signal_mode('{}') ne $signal);
 # Same bookends as the 3D and DV archives: the restore owns CAL_START and
 # CAL_END unless the caller says it manages the session, never reports an
 # upload as successful when entry or exit failed, and never strands a
 # session it tried to enter.
 my $context={picture_mode=>$mode,signal_mode=>$signal};
 my $enable=($payload->{enable_calibration} // 1) ? 1 : 0;
 my $disable=($payload->{disable_calibration} // 1) ? 1 : 0;
 return _lg_cal_hist_restore_with_bookends($context,$enable,$disable,
  # Only claim an active session this restore entered; a caller-managed
  # session is left for the helper to enter itself, as 3D and DV do.
  sub { &webui_lg_1d_dpg_upload(&lg_encode_json({%$context,dpg_data=>$data,keep_calibration_mode=>1,($enable?(calibration_mode_active=>1):()),helper_timeout=>90})) });
}

# 3D LUT and DV profile archives use optional, caller-selected session
# bookends. Unlike the old bare eval calls, an unacknowledged entry must never
# reach the upload, and an upload exception must not skip requested cleanup.
sub _lg_cal_hist_restore_with_bookends {
 my ($context,$enable,$disable,$upload)=@_;
 my ($result,$upload_attempted);
 my $stage='calibration-entry';
 my $ok=eval {
  if($enable) {
   my $on=&lg_decode_json(&webui_lg_calibration_mode(&lg_encode_json({%$context,enabled=>JSON::PP::true})));
   die(($on->{message}||'TV did not acknowledge calibration entry')."\n")
    if(($on->{status}||'') ne 'ok' || !$on->{calibration_mode});
  }
  $stage='archive-upload';$upload_attempted=1;
  $result=&lg_decode_json($upload->());
  die "Archive upload returned no valid result\n" if(!exists($result->{status}));
  1;
 };
 if(!$ok) {
  $result={status=>'error',error_code=>$stage eq 'calibration-entry'?'calibration-entry-unconfirmed':'archive-upload-failed',
   failure_stage=>$stage,message=>'Archive restore failed: '.($@||'Unknown restore failure')};
 }
 # Honour explicitly held sessions after success, but do not strand a session
 # this call tried to enter when entry/upload failed or its outcome is unknown.
 if($disable || ($enable && (!$ok || ($result->{status}||'') ne 'ok'))) {
  my $off=eval { &lg_decode_json(&webui_lg_calibration_mode(&lg_encode_json({%$context,enabled=>JSON::PP::false}))) };
  my $exit_error=$@;
  if(ref($off) ne 'HASH' || ($off->{status}||'') ne 'ok' || !exists($off->{calibration_mode}) || $off->{calibration_mode}) {
   my $entered=$ok || $stage ne 'calibration-entry';
   my $detail=$exit_error||(ref($off) eq 'HASH'?$off->{message}:undef)||'No exit acknowledgement';
   # An unacknowledged entry has no session to exit: keep the entry failure as
   # the error and report the viewing state as unconfirmed, rather than sending
   # the user to Exit Calibration for a session that never started.
   $result={%{$result||{}},status=>'error',upload_status=>$upload_attempted?($result->{status}||'unknown'):'not-attempted',
    cleanup_required=>JSON::PP::true,cleanup_detail=>$detail,
    ($entered
     ? (error_code=>'calibration-exit-unconfirmed',exit_status=>'unconfirmed',message=>($result->{message}||'Archive upload finished').'; calibration exit is unconfirmed. Use Exit Calibration before testing the TV.')
     : (error_code=>'calibration-entry-unconfirmed',exit_status=>'unconfirmed',message=>($result->{message}||'Archive restore failed').'; the TV also did not confirm normal viewing. Check the picture mode before testing the TV.'))};
  }
 }
 return &lg_encode_json($result);
}

sub webui_lg_calibration_history_reupload (@) {
 my ($body)=@_;
 my $payload=&lg_decode_json($body);
 my $id=$payload->{"id"} || "";
 return &lg_encode_json({ status => "error", message => "id required" }) if($id eq "");
 my $picture_mode=$payload->{"picture_mode"} || "";
 my $signal_mode=$payload->{"signal_mode"} || "";
 my $enable_cal=($payload->{"enable_calibration"} // 1) ? 1 : 0;
 my $disable_cal=($payload->{"disable_calibration"} // 1) ? 1 : 0;

 # A Dolby Vision reupload enters calibration mode (CAL_START), which the TV
 # rejects with an opaque "500 Driver error" unless the display is in Relative
 # DV map mode (dv_map_mode 2); Absolute (1) or unset is what fails. The DV
 # AutoCal path enforces the same rule (webui_lg_autocal_dv_map_mode_error, PR #3)
 # and the Web UI switches to Relative before calling this (lgCalHistoryReupload
 # -> meterDvAutoCalSetMapMode). This is the safety net: it turns a stale/Absolute
 # map mode into an actionable error for a direct caller or a failed switch,
 # before the archive read or any TV call. The rule is inlined (not the webui.pm
 # predicate) so the reupload dispatcher stays loadable without webui.pm, as the
 # rest of lg.pm is. %pgenerator_conf is the main program's daemon-wide global;
 # reference it by package so this stays clean under strict when lg.pm loads alone.
 if($enable_cal && $id =~ /^dv(?:file)?:/) {
  my $map_mode=defined($main::pgenerator_conf{"dv_map_mode"}) ? $main::pgenerator_conf{"dv_map_mode"} : "";
  if($map_mode ne "2") {
   my $seen=($map_mode eq "") ? "unset" : (($map_mode eq "1") ? "Absolute (1)" : "'".$map_mode."'");
   return &lg_encode_json({ status => "error", error_code => "dv-map-mode-not-relative",
    message => "Dolby Vision reupload requires DV map mode Relative (dv_map_mode 2); it is currently ".$seen.". Set the DV map mode to Relative before reuploading, as the Web UI does automatically." });
  }
 }

 if($id =~ /^1d:([A-Za-z0-9._-]+)$/) {
  my $run=$1;
  my $state=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/grey-state.json");
  my ($run_dpg,$run_sm,$run_de)=_lg_cal_hist_run_1d($state);
  return &lg_encode_json({ status => "error", message => "1D DPG data not found for run $run" })
   unless(ref($run_dpg) eq "ARRAY" && @{$run_dpg}==3072);
  my $manifest=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/manifest.json") || {};
  my $cfg=(ref($manifest->{"config"}) eq "HASH") ? $manifest->{"config"} : {};
  my $saved_mode=$cfg->{"picture_mode"} || $state->{"picture_mode"} || $state->{"calibration_picture_mode"} || "";
  # Fall back to the layout the DPG itself came from, so an SDR run cannot be
  # re-pushed as HDR (which would write the curve into the wrong picture mode).
  my $saved_signal=$cfg->{"signal_mode"} || $state->{"signal_mode"} || $state->{"requested_signal_mode"} || $run_sm || "";
  my $result_json=_lg_cal_hist_restore_1d($run_dpg,$saved_mode,$saved_signal,$payload);
  eval {
   my $decoded=&lg_decode_json($result_json);
   if(ref($decoded) eq "HASH" && ($decoded->{"status"}||"") eq "ok") {
    &_lg_cal_hist_archive_1d($run_dpg,{
     picture_mode => $saved_mode,
     signal_mode => $saved_signal,
     de => $run_de,
     run_id => $run,
     variant => (_lg_cal_hist_run_smoothed($state) ? "smoothed" : ""),
    });
   }
  };
  return $result_json;
 }

 if($id =~ /^3d:([A-Za-z0-9._-]+)$/) {
  my $base=$1;
  my $bin="$_lg_cal_hist_luts/$base.bin";
  return &lg_encode_json({ status => "error", message => "3D LUT payload missing: $base.bin" }) unless(-f $bin);
  my $meta=_lg_cal_hist_read_json_file("$_lg_cal_hist_luts/$base.json") || {};
  $picture_mode ||= $meta->{"picture_mode"} || "";
  $signal_mode ||= $meta->{"signal_mode"} || "";
  my $up_body=&lg_encode_json({
   payload_path => $bin,
   picture_mode => $picture_mode,
   signal_mode => $signal_mode,
   keep_calibration_mode => 1,
   helper_timeout => 120,
  });
  return _lg_cal_hist_restore_with_bookends(
   {picture_mode=>$picture_mode,signal_mode=>$signal_mode},$enable_cal,$disable_cal,
   sub { &webui_lg_3d_lut_upload($up_body) });
 }

 if($id =~ /^1dfile:([A-Za-z0-9._-]+)$/) {
  my $meta=_lg_cal_hist_read_json_file("$_lg_cal_hist_dir/1d/$1.json");
  return &lg_encode_json({ status => "error", message => "1D archive not found" })
   unless(ref($meta) eq "HASH" && ref($meta->{"dpg_data"}) eq "ARRAY" && @{$meta->{"dpg_data"}}==3072);
  return _lg_cal_hist_restore_1d($meta->{dpg_data},$meta->{picture_mode},$meta->{signal_mode},$payload);
 }

 if($id =~ /^dvfile:([A-Za-z0-9._-]+)$/) {
  my $meta=_lg_cal_hist_read_json_file("$_lg_cal_hist_dir/dv/$1.json");
  return &lg_encode_json({ status => "error", message => "DV archive not found" })
   unless(ref($meta) eq "HASH" && ref($meta->{"measurements"}) eq "HASH");
  $picture_mode ||= $meta->{"picture_mode"} || "dolbyVisionFilmMaker";
  my $up_body=&lg_encode_json({
   measurements => $meta->{"measurements"},
   picture_mode => $picture_mode,
   signal_mode => "dv",
   keep_calibration_mode => 1,
  });
  return _lg_cal_hist_restore_with_bookends(
   {picture_mode=>$picture_mode,signal_mode=>'dv'},$enable_cal,$disable_cal,
   sub { &webui_lg_dv_profile_upload($up_body) });
 }

 if($id =~ /^dv:([A-Za-z0-9._-]+)$/) {
  my $run=$1;
  my $meas;
  my $meas_path="$_lg_cal_hist_runs/$run/dv-profile-measurements.json";
  $meas=_lg_cal_hist_read_json_file($meas_path) if(-f $meas_path);
  if(ref($meas) ne "HASH") {
   my $state=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/grey-state.json") || {};
   my $state3=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/3d-state.json") || {};
   $meas=$state->{"dv_profile_measurements"} || $state3->{"dv_profile_measurements"} || $state3->{"measurements"};
  }
  return &lg_encode_json({ status => "error", message => "DV profile measurements not archived for this run; cannot reupload." })
   unless(ref($meas) eq "HASH" && defined($meas->{"white_luminance"}));
  my $manifest=_lg_cal_hist_read_json_file("$_lg_cal_hist_runs/$run/manifest.json") || {};
  my $cfg=(ref($manifest->{"config"}) eq "HASH") ? $manifest->{"config"} : {};
  $picture_mode ||= $cfg->{"picture_mode"} || "dolbyVisionFilmMaker";
  $signal_mode ||= "dv";
  my $up_body=&lg_encode_json({
   measurements => $meas,
   picture_mode => $picture_mode,
   signal_mode => "dv",
   keep_calibration_mode => 1,
  });
  return _lg_cal_hist_restore_with_bookends(
   {picture_mode=>$picture_mode,signal_mode=>'dv'},$enable_cal,$disable_cal,
   sub { &webui_lg_dv_profile_upload($up_body) });
 }

 return &lg_encode_json({ status => "error", message => "Unknown history id" });
}

sub webui_lg_api (@) {
 my $path=shift;
 my $method=shift;
 my $body=shift;
 my $query=shift;
 if($method eq "POST" && $path ne "/api/lg/picture-settings") {
  my $automation_guard=&lg_automation_guard_json($body);
  return $automation_guard if($automation_guard ne "");
 }
 if(($path eq "/api/lg/status" || $path eq "/api/lg/detect") && $method eq "GET") {
  return &webui_lg_status_json();
 }
 if($path eq "/api/lg/manual-ip" && $method eq "POST") {
  return &webui_lg_manual_ip($body);
 }
	 if($path eq "/api/lg/connect" && $method eq "POST") {
	  return &webui_lg_connect($body);
	 }
	 if($path eq "/api/lg/disconnect" && $method eq "POST") {
	  return &webui_lg_disconnect();
	 }
	 if($path eq "/api/lg/scan" && $method eq "GET") {
  return &webui_lg_scan();
 }
 if($path eq "/api/lg/scan/saved" && $method eq "GET") {
  return &lg_encode_json(&lg_scan_saved_devices());
 }
 if($path eq "/api/lg/scan/startup" && $method eq "GET") {
  return &lg_startup_scan_status();
 }
 if($path eq "/api/lg/calibration-mode" && $method eq "POST") {
  return &webui_lg_calibration_mode($body);
 }
 if($path eq "/api/lg/3d-lut/probe" && $method eq "POST") {
  return &webui_lg_3d_lut_probe($body);
 }
 if($path eq "/api/lg/3d-lut/upload" && $method eq "POST") {
  return &webui_lg_3d_lut_upload($body);
 }
 if($path eq "/api/lg/3d-lut/reset" && $method eq "POST") {
  return &webui_lg_3d_lut_reset($body);
 }
 if($path eq "/api/lg/hdr-tone-map/upload" && $method eq "POST") {
  return &webui_lg_hdr_tone_map_upload($body);
 }
 if($path eq "/api/lg/hdr-calman-reset" && $method eq "POST") {
  return &webui_lg_hdr_calman_reset($body);
 }
 if($path eq "/api/lg/dv-calman-reset" && $method eq "POST") {
  return &webui_lg_dv_calman_reset($body);
 }
 if($path eq "/api/lg/sdr-calman-reset" && $method eq "POST") {
  return &webui_lg_sdr_calman_reset($body);
 }
 if($path eq "/api/lg/1d-dpg/upload" && $method eq "POST") {
  return &webui_lg_1d_dpg_upload($body);
 }
 if($path eq "/api/lg/dv-profile/upload" && $method eq "POST") {
  return &webui_lg_dv_profile_upload($body);
 }
 if($path eq "/api/lg/dv-profile/start" && $method eq "POST") {
  return &webui_meter_lg_dv_profile_start($body);
 }
 if($path eq "/api/lg/dv-profile/status" && $method eq "GET") {
  return &webui_meter_lg_dv_profile_status($query);
 }
 if($path eq "/api/lg/dv-profile/stop" && $method eq "POST") {
  return &webui_meter_lg_dv_profile_stop($body);
 }
 if($path eq "/api/lg/dv-profile/kill" && $method eq "POST") {
  return &webui_meter_lg_dv_profile_force_stop($body);
 }
 if($path eq "/api/lg/1d-dpg/read" && $method eq "POST") {
  return &webui_lg_1d_dpg_read($body);
 }
 if($path eq "/api/lg/calibration-history" && $method eq "GET") {
  return &webui_lg_calibration_history_list();
 }
 if($path eq "/api/lg/calibration-history/download" && $method eq "POST") {
  return &webui_lg_calibration_history_download($body);
 }
 if($path eq "/api/lg/calibration-history/reupload" && $method eq "POST") {
  return &webui_lg_calibration_history_reupload($body);
 }
 if($path eq "/api/lg/pair-pin/start" && $method eq "POST") {
  return &webui_lg_pin_pair_start($body);
 }
 if($path eq "/api/lg/pair-pin/submit" && $method eq "POST") {
  return &webui_lg_pin_pair_submit($body);
 }
 if($path eq "/api/lg/picture-settings" && ($method eq "GET" || $method eq "POST")) {
  # Only requests that arrive over HTTP are answered from the cache: every
  # in-process caller (readiness, the calibration-context freeze, hazard
  # probes) reaches webui_lg_picture_settings directly and always reads live.
  my $cached=&lg_browser_picture_settings_while_automation($body);
  return $cached if($cached ne "");
  my $json=&webui_lg_picture_settings($body);
  &lg_remember_picture_settings($json,$body);
  return $json;
 }
 if($path eq "/api/lg/picture-settings/set" && $method eq "POST") {
  return &webui_lg_picture_settings_set($body);
 }
 if($path eq "/api/lg/verify-panel-light" && $method eq "POST") {
  return &webui_lg_verify_panel_light($body);
 }
 if($path eq "/api/lg/picture-settings/reset" && $method eq "POST") {
  return &webui_lg_picture_reset($body);
 }
 if($path eq "/api/lg/picture-settings/apply-all-inputs" && $method eq "POST") {
  return &webui_lg_picture_apply_all_inputs($body);
 }
 if($path eq "/api/lg/panel-protection" && $method eq "POST") {
  return &webui_lg_panel_protection($body);
 }
 if($path eq "/api/lg/forget" && $method eq "POST") {
  return &webui_lg_forget($body);
 }
 if($path eq "/api/lg/autocal/run/begin" && $method eq "POST") { return &webui_lg_autocal_run_begin($body); }
 if($path eq "/api/lg/autocal/run/end"   && $method eq "POST") { return &webui_lg_autocal_run_end($body); }
 return &lg_encode_json({ status => "error", message => "Unknown LG route" });
}

sub webui_lg_autocal_run_begin (@) {
 my $body = shift;
 my $payload = &lg_decode_json($body);
 $payload = {} if(ref($payload) ne "HASH");
 my $run_id = "";
 if($PGAC_LOADED) {
  eval {
   my $clients = &lg_load_clients();
   my $ip = $payload->{"ip"} || "";
   my $tv = {};
   if(ref($clients) eq "HASH" && ref($clients->{$ip}) eq "HASH") {
    my $c = $clients->{$ip};
    $tv = {
     model_name       => $c->{"model_name"} || "",
     software_version => $c->{"software_version"} || "",
     paired           => ($c->{"client_key"} ? &lg_json_true() : &lg_json_false()),
    };
   }
   my $controller_id=$payload->{"controller_id"}||"";
   $controller_id="" if($controller_id!~/\A[A-Za-z0-9._-]{1,200}\z/);
   my $client_run_token=$payload->{"client_run_token"}||"";
   $client_run_token="" if($client_run_token!~/\A[A-Za-z0-9._-]{1,200}\z/);
   my $manifest = {
    workflow           => $payload->{"workflow"} || "",
    controller_id      => $controller_id,
    client_run_token   => $client_run_token,
    config             => (ref($payload->{"config"}) eq "HASH") ? $payload->{"config"} : {},
    pgenerator_version => $payload->{"pgenerator_version"} || "",
    tv                 => $tv,
   };
   $run_id = PGAutoCalRun::run_begin($manifest);
   1;
  };
 }
 return &lg_encode_json({ status => "ok", run_id => $run_id });
}

sub webui_lg_autocal_run_end (@) {
 my $body = shift;
 my $payload = &lg_decode_json($body);
 $payload = {} if(ref($payload) ne "HASH");
 my $run_is_current=1;
 my $resolved_run_id="";
 if($PGAC_LOADED) {
  # If current() itself dies the eval leaves $run_is_current at 1 — a
  # deliberate fail-open: blocking the cleanup below on a diagnostics
  # failure could leave the TV stuck in calibration mode.
  eval {
   my $current_run_id=PGAutoCalRun::current();
   my $payload_run_id=$payload->{"run_id"}||"";
   my $payload_controller_id=$payload->{"controller_id"}||"";
   $payload_controller_id="" if($payload_controller_id!~/\A[A-Za-z0-9._-]{1,200}\z/);
   my $payload_client_run_token=$payload->{"client_run_token"}||"";
   $payload_client_run_token="" if($payload_client_run_token!~/\A[A-Za-z0-9._-]{1,200}\z/);
   $resolved_run_id=$payload_run_id || $current_run_id;
   my $unattributed=0;
   if($payload_run_id ne "") {
    $run_is_current=0 if($current_run_id ne "" && $payload_run_id ne $current_run_id);
   } elsif($current_run_id ne "") {
    # A run/begin response can time out after the server already created the
    # record. The saved workflow still carries the unique client token
    # generated for that begin attempt, even after another tab adopts its
    # lease; match it against the immutable run manifest. Unlike a tab id,
    # the per-run token also rejects an older callback from the same tab.
    my $manifest=PGAutoCalRun::run_manifest($current_run_id);
    my $manifest_client_run_token=(ref($manifest) eq "HASH") ? ($manifest->{"client_run_token"}||"") : "";
    if($payload_client_run_token eq "" || $manifest_client_run_token eq "" || $payload_client_run_token ne $manifest_client_run_token) {
     # A different/no run token cannot prove it owns the live run and must
     # not write its summary or tear down workflow/session state.
     $run_is_current=0;
     $unattributed=1;
    }
   }
   PGAutoCalRun::run_end($resolved_run_id, {
    status => $payload->{"status"} || "complete",
    note   => $payload->{"note"}   || "",
   }) if(!$unattributed);
   1;
  };
 }
 # A delayed callback may finalise its own diagnostics, but it must not clear
 # the active run's workflow metadata or close that run's calibration session.
 if(!$run_is_current) {
  return &lg_encode_json({
   status => "ok",
   stale_run_ignored => &lg_json_true(),
   run_id => $resolved_run_id,
  });
 }
 # The full workflow (or a standalone-greyscale run) has reached a
 # terminal state. Clear the full-workflow + HDR tone-map metadata from
 # the persisted autocal state so a FRESH browser session (no
 # localStorage completion-token) no longer reads full_workflow=true /
 # hdr20_1d_tonemap_pending=true on its first status poll and fires a
 # phantom 3D-LUT autocal restart or a phantom "Upload HDR tone map"
 # popup. This is the non-racy place to clear: the status endpoint is
 # read mid-workflow by the active session to advance greyscale -> 3D-LUT,
 # so it cannot distinguish a stage boundary from a finished run. The JS
 # calls /api/lg/autocal/run/end exactly once with status:complete
 # (meterFullAutoCalComplete) or status:aborted (meterFullAutoCalAbort),
 # and the standalone-greyscale completion (meterAutoCalCloseCompleteAction).
 if(defined &webui_meter_lg_autocal_clear_full_workflow_state) {
  eval { &webui_meter_lg_autocal_clear_full_workflow_state(); };
 }
 my $clients=&lg_load_clients();
 my $cleanup=&lg_close_calibration_mode_at_run_end($clients,$payload);
 return &lg_encode_json($cleanup);
}

# A normal worker commit closes CAL_START itself. This is the terminal
# failsafe for an aborted/crashed stage: if persistence still says the TV is
# in calibration mode, attempt one explicit CAL_END and only clear the flag
# after the TV acknowledges it.
sub lg_close_calibration_mode_at_run_end (@) {
 my ($clients,$payload)=@_;
 $clients={} if(ref($clients) ne "HASH");
 $payload={} if(ref($payload) ne "HASH");
 return { status => "ok", calibration_cleanup_needed => &lg_json_false() }
  if(!$clients->{"calibration_mode"} && !$payload->{force_stop});
 if(&lg_autocal_worker_running(1)) {
  return {
   status => "error",
   error_code => "lg-calibration-session-active",
   calibration_mode => &lg_json_true(),
   message => "LG Auto Cal is still running, so its calibration session was not closed underneath it.",
  };
 }
 my $ip=&lg_target_ip($payload,$clients);
 my $client=&lg_primary_client($clients);
 my $client_key=(ref($client) eq "HASH") ? ($client->{"client_key"}||$client->{"client-key"}||"") : "";
 if($ip eq "" || $client_key eq "") {
  return {
   status => "error",
   error_code => "lg-calibration-session-stuck",
   calibration_mode => &lg_json_true(),
   message => "The run ended while LG calibration mode was still recorded, but no paired TV was available for CAL_END. Reconnect the TV and use Reset Picture Mode.",
  };
 }
 my $cleanup=&lg_helper_run({
  action => "calibration_mode",
  ip => $ip,
  client_key => $client_key,
  enable => 0,
  picture_mode => $payload->{current_picture_mode} ? "" : $clients->{"calibration_picture_mode"}||"",
  signal_mode => $payload->{current_picture_mode} ? "" : $payload->{"signal_mode"}||"",
  helper_timeout => 75,
  connect_timeout => 5,
 });
 if(ref($cleanup) ne "HASH" || ($cleanup->{"status"}||"") ne "ok") {
  my $detail=(ref($cleanup) eq "HASH" ? ($cleanup->{"message"}||"") : "")
   || "the TV did not acknowledge CAL_END";
  return {
   status => "error",
   error_code => "lg-calibration-session-stuck",
   calibration_mode => &lg_json_true(),
   cleanup_response => $cleanup,
   message => "The run ended, but LG calibration mode could not be closed: $detail. Restart the TV before another calibration.",
  };
 }
 &lg_store_calibration_mode_state($clients,0,"");
 $cleanup->{"calibration_mode"}=&lg_json_false();
 $cleanup->{"stale_calibration_mode_cleared"}=&lg_json_true();
 $cleanup->{"message"}="The run ended and its remaining LG calibration session was closed.";
 return $cleanup;
}

###############################################
#             LG Web UI Helpers               #
###############################################
sub _lg_webui_fragment (@) {
 my ($name)=@_;
 # Fallback for harness contexts that load lg.pm without webui.pm; the daemon
 # always routes through webui_asset. Warn loudly — a silent "" here surfaces
 # only as a distant substring-assertion failure.
 if(!defined($name) || ($name ne "webui-lg-card.html" && $name ne "webui-lg.js")) {
  warn "lg fragment request rejected: ".(defined($name) ? $name : "(undefined)")."\n";
  return "";
 }
 my $path=__FILE__;
 $path=~s{[^/]+\z}{$name};
 my $content="";
 if(open(my $fh,"<:raw",$path)) {
  local $/;
  $content=<$fh>//"";
  close($fh);
 }
 warn "lg fragment missing or empty: $name ($path)\n" if($content eq "");
 return $content;
}

sub webui_lg_card_html (@) {
 return defined(&webui_asset) ? &webui_asset("webui-lg-card.html") : &_lg_webui_fragment("webui-lg-card.html");
}

sub webui_lg_js (@) {
 return defined(&webui_asset) ? &webui_asset("webui-lg.js") : &_lg_webui_fragment("webui-lg.js");
}

sub webui_lg_load_info_js (@) {
 # Do not refresh calibration history here — loadInfo runs on a 30s poll and
 # was blanking the history list ("Loading history...") every cycle.
 return 'lgBindDisplayModeControl();lgDisplayControlRender();loadLgStatus(true);';
}

sub webui_lg_init_js (@) {
 # Saved TVs render immediately; the full first-start scan runs in a sibling
 # daemon thread and is consumed asynchronously without blocking meter status.
 # History is not loaded on init — only when the operator opens History (tablet)
 # or enters the LG Display workspace (desktop).
 return 'lgBindDisplayModeControl();lgDisplayControlRender();setTimeout(()=>loadLgStatus(),750);setTimeout(()=>lgLoadSavedTvs(),1200);setTimeout(()=>lgStartupAutoDetect(),1400);';
}

return 1;
