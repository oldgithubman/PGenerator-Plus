# The automation runner polls a worker's status every two seconds and reads
# only a few top-level keys, while the full greyscale state passes 100 KB.
# ?view=summary serves that projection from the worker's .summary sidecar, or
# from the full state when the sidecar is missing or stale, applies the same
# status fix-ups as the plain view, and never writes a summary back.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

my $dir=tempdir(CLEANUP=>1);
my $encoder=JSON::PP->new->canonical(1);
sub write_text { my ($path,$text)=@_; open my $fh,'>',$path or die "$path: $!"; print {$fh} $text; close $fh; }
sub read_text { my ($path)=@_; open my $fh,'<',$path or return ''; local $/; my $t=<$fh>; close $fh; return $t; }
sub decode { my ($text)=@_; my $v=eval { JSON::PP->new->utf8(1)->decode($text) }; return ref($v) eq 'HASH' ? $v : {}; }
my @summary_keys=@PGAutomation::WORKER_STATUS_SUMMARY_KEYS;
ok(scalar(@summary_keys)>20,'the shared summary key list is exported by PGAutomation');
sub summary_of { my ($state)=@_; my %s; $s{$_}=$state->{$_} for grep { exists $state->{$_} } @summary_keys; return \%s; }
sub expected_keys { my ($state)=@_; return [sort grep { exists $state->{$_} } @summary_keys]; }

# Event 3 carries a bracket, escaped quotes and a backslash, and event 4 a
# nested array and object, so the text splice around the fix-ups is proved
# on the awkward cases.
my @events=map {{seq=>$_,time=>100+$_,message=>$_==3 ? '7% | codes [1,2] "quoted" \\ back' : "event $_",
 $_==4 ? (detail=>{codes=>[1,[2,3]],note=>'a]b',message=>'nested message'}) : ()}} 1..5;
sub full_state {
 my (%over)=@_;
 return {
  status=>'running',current_name=>'Auto Cal 7%',current_step=>34,total_steps=>37,current_delta_e=>0.42,
  message=>'Reading 7% sample 1/1',phase=>'greyscale',automation_worker_id=>'run-1-abc',worker_pid=>4242,
  worker_start_ticks=>'12345',activity_sequence=>5,activity_events=>[@events],started_at=>1000,
  autocal=>JSON::PP::true,calibration_mode=>JSON::PP::true,full_workflow=>JSON::PP::true,
  full_autocal_run_id=>'run-1',full_autocal_phase=>'greyscale',
  hdr20_1d_dpg_anchor_history=>[map {{step=>$_,codes=>[($_)x64]}} 1..400],
  readings=>[map {{x=>$_,y=>$_,z=>$_}} 1..200],
  steps=>[map {{name=>"step $_"}} 1..37],
  %over,
 };
}

is(main::webui_worker_status_summary_after(undef),undef,'no query is the plain view');
is(main::webui_worker_status_summary_after('summary=1'),undef,'the series summary flag does not select the worker projection');
is(main::webui_worker_status_summary_after('view=summary'),0,'view=summary without a cursor keeps every event');
is(main::webui_worker_status_summary_after('view=summary&after=12'),12,'the cursor is read from the query');
is(main::webui_worker_status_summary_after('after=7&view=summary'),7,'parameter order does not matter');
is(main::webui_worker_status_summary_after('view=summary&after=x'),0,'a malformed cursor keeps every event');

# The text splice that keeps the fix-ups off event keys.
{
 my $text=$encoder->encode({activity_events=>[@events],message=>'top',status=>'running'});
 my ($detached,$fragment)=main::webui_worker_status_detach_events($text);
 like($detached,qr/^\{"activity_events":\[\],"message":"top"/,'events are emptied in place');
 is_deeply(decode('{'.$fragment.'}')->{activity_events},\@events,'the fragment holds the whole array');
 is(main::webui_worker_status_attach_events($detached,$fragment),$text,'attaching restores the text byte for byte');
 my ($same,$none)=main::webui_worker_status_detach_events('{"message":"top"}');
 is($same,'{"message":"top"}','a text without events is untouched');
 is(main::webui_worker_status_attach_events($same,$none),'{"message":"top"}','and attaches nothing');
 my $nested='{"activity_events":[{"detail":{"codes":[1,[2,3]],"list":[],"note":"a]b\\"]"},"message":"inner","seq":1}],"message":"top","phase":"x"}';
 my ($d,$f)=main::webui_worker_status_detach_events($nested);
 is($d,'{"activity_events":[],"message":"top","phase":"x"}','a nested array and object inside an event are taken out whole');
 is(main::webui_worker_status_attach_events($d,$f),$nested,'and restored byte for byte');
 my $open='{"activity_events":[{"message":"never closed"';
 my ($o,$of)=main::webui_worker_status_detach_events($open);
 is($o,$open,'an unterminated array leaves the text alone');
 is($of,'','and yields no fragment');
 my $torn='{"activity_events":[{"message":"no end';
 my ($t,$tf)=main::webui_worker_status_detach_events($torn);
 is($t,$torn,'an unterminated string leaves the text alone');
}

my $running=1;
local *main::webui_meter_lg_autocal_running=sub {$running};
local *main::webui_meter_lg_3d_autocal_running=sub {$running};
local *main::webui_meter_lg_dv_profile_running=sub {$running};

# ---- greyscale worker
my $grey="$dir/meter_lg_autocal.json";
unlink("$grey.stop");
my $state=full_state();
write_text($grey,$encoder->encode($state));
my $full_text=read_text($grey);
ok(length($full_text)>60000,'fixture state is large, like a late greyscale stage');
write_text("$grey.summary",$encoder->encode(summary_of($state)));

is(main::webui_meter_lg_autocal_status('view=summary',"$dir/absent.json"),'{"status":"idle"}','no state file is idle in either view');
is(main::webui_meter_lg_autocal_status(undef,$grey),$full_text,'plain view serves the full state byte for byte');
is(main::webui_meter_lg_autocal_status('',$grey),$full_text,'an empty query is the plain view');
is(main::webui_meter_lg_autocal_status('summary=1',$grey),$full_text,'only view=summary selects the projection');

my $text=main::webui_meter_lg_autocal_status('view=summary&after=0',$grey);
ok(length($text)<4000,'summary view is small') or diag(length($text));
my $summary=decode($text);
is_deeply([sort keys %$summary],expected_keys($state),'the summary is exactly the shared key list present in the state');
is($summary->{status},'running','summary carries the status');
is($summary->{current_step},34,'summary carries the patch counter');
is($summary->{automation_worker_id},'run-1-abc','summary carries the attempt identity');
is($summary->{worker_pid},4242,'summary carries the worker pid');
is($summary->{worker_start_ticks},'12345','summary carries the worker start ticks');
ok(!exists $summary->{hdr20_1d_dpg_anchor_history},'anchor history is not in the summary');
ok(!exists $summary->{readings},'readings are not in the summary');
is(scalar @{$summary->{activity_events}},5,'after=0 keeps every event');
is($summary->{activity_events}[2]{message},'7% | codes [1,2] "quoted" \\ back','awkward event text survives the round trip');
ok($summary->{autocal} && $summary->{calibration_mode},'busy flags pass through while the worker runs');

$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=3',$grey));
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[4,5],'after=N drops events already seen');
$summary=decode(main::webui_meter_lg_autocal_status('after=2&view=summary',$grey));
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[3,4,5],'the cursor is honoured whatever the parameter order');
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=9',$grey));
is_deeply($summary->{activity_events},[],'nothing new is an empty list, not a missing key');
is(read_text($grey),$full_text,'serving the summary does not touch the state file');

# A sidecar older than the state file is ignored: the same keys come from a
# decode of the full state, still filtered by the cursor.
write_text("$grey.summary",$encoder->encode({%{summary_of($state)},message=>'stale sidecar'}));
utime(time()-30,time()-30,"$grey.summary") or die "utime: $!";
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=3',$grey));
is($summary->{message},'Reading 7% sample 1/1','a sidecar older than the state file is ignored');
ok(!exists $summary->{hdr20_1d_dpg_anchor_history},'the fallback projects the same keys');
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[4,5],'the fallback applies the cursor too');
is(read_text($grey),$full_text,'the fallback does not touch the state file');
unlink("$grey.summary");
$summary=decode(main::webui_meter_lg_autocal_status('view=summary',$grey));
is($summary->{current_name},'Auto Cal 7%','a missing sidecar falls back to the full state');
is_deeply([sort keys %$summary],expected_keys($state),'the fallback projects exactly the shared key list');

# Undecodable state with no sidecar is served whole rather than hidden.
write_text($grey,'{"status":"running","current_name":"torn"');
is(main::webui_meter_lg_autocal_status('view=summary',$grey),'{"status":"running","current_name":"torn"','text that does not decode is served as it is');
write_text($grey,$encoder->encode($state));
$full_text=read_text($grey);

# The dead-worker flip is applied to the summary text but never saved from
# the summary view; the plain read that follows saves it.
write_text("$grey.summary",$encoder->encode(summary_of($state)));
$running=0;
write_text("$grey.misses",int(time()*1000)-20000);
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
is($summary->{status},'error','summary view still flips a dead running worker to error');
is($summary->{current_name},'Auto Cal process died','the flip rewrites the current name as the plain view does');
is($summary->{message},'Reading 7% sample 1/1','a real worker message survives the flip');
is(read_text($grey),$full_text,'summary mode never writes the flipped text back');
ok(-f "$grey.misses",'summary mode keeps the first-miss marker for the full read');
my $plain=main::webui_meter_lg_autocal_status(undef,$grey);
is(decode($plain)->{status},'error','the full read that follows applies the same flip');
is(decode($plain)->{current_name},'Auto Cal process died','with the same wording');
is(read_text($grey),$plain,'the plain view saves the flipped state');
ok(!-f "$grey.misses",'the plain view clears the first-miss marker');
my $later=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
is($later->{status},'error','a later summary poll reads the saved outcome through the stale-sidecar fallback');

# The fix-ups must rewrite the top-level message, not the first event's:
# canonical order puts activity_events first, and a summary polled with a
# cursor usually has no events left. Compare the views for both flips.
{
 my $placeholder=full_state(message=>'Starting',activity_sequence=>2,
  activity_events=>[{seq=>1,time=>101,message=>'Starting the meter'},{seq=>2,time=>102,message=>'event 2'}]);
 for my $case (['dead process',0,'LG Auto Cal stopped unexpectedly','Auto Cal process died'],
               ['stop file',1,'Auto Cal stopped','Auto Cal cancelled']) {
  my ($name,$stop,$message,$current_name)=@$case;
  write_text($grey,$encoder->encode($placeholder));
  write_text("$grey.summary",$encoder->encode(summary_of($placeholder)));
  write_text("$grey.misses",int(time()*1000)-20000);
  if($stop) { write_text("$grey.stop",'stop'); } else { unlink("$grey.stop"); }
  my $s=decode(main::webui_meter_lg_autocal_status('view=summary&after=2',$grey));
  is($s->{message},$message,"$name: the summary rewrites the top-level message");
  is($s->{current_name},$current_name,"$name: the summary rewrites the current name");
  is_deeply($s->{activity_events},[],"$name: the summary has no events left after the cursor");
  my $p=decode(main::webui_meter_lg_autocal_status(undef,$grey));
  is($p->{message},$s->{message},"$name: the plain view rewrites the same message");
  is($p->{current_name},$s->{current_name},"$name: and the same current name");
  is($p->{activity_events}[0]{message},'Starting the meter',"$name: the first event's message is untouched");
  is(scalar @{$p->{activity_events}},2,"$name: the plain view keeps every event");
  like(read_text($grey),qr/"message":"\Q$message\E"/,"$name: the saved state carries the rewritten top-level message");
  unlink("$grey.stop");
 }
}

# Within the grace window both views report running and persist the first miss.
write_text($grey,$encoder->encode($state));
write_text("$grey.summary",$encoder->encode(summary_of($state)));
unlink("$grey.misses");
$summary=decode(main::webui_meter_lg_autocal_status('view=summary',$grey));
is($summary->{status},'running','a first pgrep miss does not flip the summary');
ok(-f "$grey.misses",'the first miss is recorded from the summary view');
unlink("$grey.misses");

# Stale busy flags on a finished worker are cleared in the summary text only.
my $done=full_state(status=>'complete',phase=>'restoring');
write_text($grey,$encoder->encode($done));
write_text("$grey.summary",$encoder->encode(summary_of($done)));
my $done_text=read_text($grey);
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
ok(!$summary->{autocal} && !$summary->{calibration_mode},'stale busy flags are cleared in the summary view');
is($summary->{phase},'cancelled','the restoring phase rewrite applies too');
is(read_text($grey),$done_text,'clearing flags in summary mode does not rewrite the state file');
main::webui_meter_lg_autocal_status(undef,$grey);
isnt(read_text($grey),$done_text,'the plain view still saves the cleared flags');
like(read_text($grey),qr/"autocal":false/,'with autocal false');
is(scalar @{decode(read_text($grey))->{activity_events}},5,'the saved state keeps its events');

# ---- 3D LUT worker
$running=1;
my $three="$dir/meter_lg_3d_autocal.json";
my $three_state={status=>'running',current_name=>'3D LUT 12/33',current_step=>12,total_steps=>33,message=>'Starting',
 automation_worker_id=>'run-1-3d',worker_pid=>4343,upload_verified=>JSON::PP::false,activity_sequence=>1,
 activity_events=>[{seq=>1,time=>1,message=>'Starting 3D'}],
 hdr20_postcal_shadow_dpg_data=>[map {$_/3072} 0..3071],data=>('x' x 5000)};
write_text($three,$encoder->encode($three_state));
my $three_text=read_text($three);
write_text("$three.summary",$encoder->encode(summary_of($three_state)));
like(main::webui_meter_lg_3d_autocal_status(undef,$three),qr/omitted from status/,'plain 3D view still elides the large payloads');
$text=main::webui_meter_lg_3d_autocal_status('view=summary',$three);
ok(length($text)<1000,'3D summary view is small');
$summary=decode($text);
is($summary->{current_step},12,'3D summary view serves the sidecar');
ok(!exists $summary->{hdr20_postcal_shadow_dpg_data},'3D summary omits the shadow data');
$running=0;
write_text("$three.misses",int(time()*1000)-20000);
$summary=decode(main::webui_meter_lg_3d_autocal_status('view=summary&after=1',$three));
is($summary->{status},'error','3D summary view flips a dead worker to error');
is($summary->{current_name},'3D LUT AutoCal process died','with the plain view wording');
is($summary->{message},'LG 3D LUT AutoCal stopped unexpectedly','3D summary rewrites the top-level message');
is(read_text($three),$three_text,'3D summary mode never writes back');
ok(-f "$three.misses",'3D summary mode keeps the first-miss marker');
$plain=decode(main::webui_meter_lg_3d_autocal_status(undef,$three));
is($plain->{status},'error','3D plain view applies the same flip');
is($plain->{message},$summary->{message},'3D plain view rewrites the same message');
is($plain->{activity_events}[0]{message},'Starting 3D','3D plain view leaves the event message alone');
isnt(read_text($three),$three_text,'3D plain view saves it');
ok(!-f "$three.misses",'3D plain view clears the first-miss marker');

# ---- Dolby Vision profile worker
$running=1;
my $dv="$dir/meter_lg_dv_profile.json";
my $dv_state={status=>'running',current_name=>'White',current_step=>2,total_steps=>5,message=>'Reading white',
 automation_worker_id=>'run-1-dv',worker_pid=>4444,full_autocal_run_id=>'run-1',activity_sequence=>1,
 activity_events=>[{seq=>1,time=>1,message=>'Starting DV'}],
 steps=>[map {{name=>"s$_",xyz=>[1,2,3]}} 1..5],readings=>[1..500]};
write_text($dv,$encoder->encode($dv_state));
my $dv_text=read_text($dv);
write_text("$dv.summary",$encoder->encode(summary_of($dv_state)));
is(main::webui_meter_lg_dv_profile_status(undef,$dv),$dv_text,'plain DV view serves the full state');
$summary=decode(main::webui_meter_lg_dv_profile_status('view=summary&after=0',$dv));
is($summary->{current_name},'White','DV summary view serves the sidecar');
is($summary->{full_autocal_run_id},'run-1','DV summary keeps the run id the adoption probe checks');
ok(!exists $summary->{steps},'DV summary omits the step detail');
$running=0;
$summary=decode(main::webui_meter_lg_dv_profile_status('view=summary&after=1',$dv));
is($summary->{status},'error','DV summary view flips a dead worker');
like($summary->{message},qr/ended unexpectedly/,'with the plain view message');
is(read_text($dv),$dv_text,'DV state file untouched');
$plain=decode(main::webui_meter_lg_dv_profile_status(undef,$dv));
is($plain->{message},$summary->{message},'DV plain view rewrites the same message');
is($plain->{activity_events}[0]{message},'Starting DV','DV plain view leaves the event message alone');
like(main::webui_meter_lg_dv_profile_status('view=summary',"$dir/absent-dv.json"),qr/"status":"idle"/,'no DV state file is idle in the summary view');

# A fresh attempt starts from an init state. After a backward clock step the
# previous attempt's terminal sidecar would outrank it by mtime, so the init
# write removes the sidecar first.
{
 $running=1;
 my $file="$dir/meter_lg_autocal_init.json";
 my $old=full_state(status=>'complete',automation_worker_id=>'old-attempt');
 write_text($file,$encoder->encode($old));
 write_text("$file.summary",$encoder->encode(summary_of($old)));
 utime(time()+3600,time()+3600,"$file.summary") or die "utime: $!";
 is(decode(main::webui_meter_lg_autocal_status('view=summary',$file))->{automation_worker_id},'old-attempt','before the launch the old sidecar is what the summary view serves');
 my $init='{"status":"running","autocal":true,"current_step":0,"total_steps":0,"current_name":"Starting LG Auto Cal...","message":"Starting","readings":[]}';
 ok(main::webui_worker_state_init_write($file,$init),'the init write succeeds');
 ok(!-e "$file.summary",'the previous attempt\'s sidecar is removed');
 is(read_text($file),$init,'the init state is written');
 my $s=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$file));
 is($s->{status},'running','the summary view now serves the init state, not the old terminal sidecar');
 ok(!$s->{automation_worker_id},'with no stale attempt identity');
 for my $source (['webui',"$Bin/../usr/share/PGenerator/webui.pm",2],['lg',"$Bin/../usr/share/PGenerator/lg.pm",1]) {
  my ($name,$path,$count)=@$source;
  my $text=read_text($path);
  is(scalar(()=$text=~/&webui_worker_state_init_write\(/g),$count,"$name: every worker launch writes its init state through the helper");
  unlike($text,qr/write_atomic\(\$_meter_lg_(?:autocal|3d_autocal|dv_profile)_file,\$init/,"$name: no launch writes the init state directly");
 }
 like(read_text("$Bin/../usr/share/PGenerator/webui.pm"),qr/unlink\("\$_meter_lg_3d_autocal_file\.summary"\);\n if\(!rename\(\$state_tmp,\$_meter_lg_3d_autocal_file\)\)/,'the 3D retry launch drops the sidecar before installing its state');
}
done_testing();
