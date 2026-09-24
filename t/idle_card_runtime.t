use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/pattern.pm";

# Exercise the real timer, legacy writer and WebUI pattern path. Equipment
# boundaries are local fixtures; no renderer, meter or TV is contacted.
local $main::var_dir=tempdir(CLEANUP=>1);
make_path("$main::var_dir/running");
local $main::command_file="$main::var_dir/running/operations.txt";
local $main::pattern_start='PatternStart';
local $main::w_s=1920; local $main::h_s=1080;
local $main::max_x=1920; local $main::max_y=1080;
local $main::bits_default=8; local $main::frame_default=1;
local $main::bg_default='0,0,0'; local $main::position_default='0,0';
local $main::pname_file='';
local %main::pgenerator_conf=(screensaver_enabled=>'1',screensaver_delay_s=>10,
 color_format=>0,max_bpc=>8,signal_mode=>'sdr',rgb_quant_range=>1);
my ($now,$owner,$video,$stabilise,$renders,$range_changes)=(100,'',0,0,0,0);
my ($render_hook,$stop_hook);
local *main::log=sub {};
local *main::webui_idle_card_now=sub {$now};
local *main::webui_display_owner=sub {$owner};
local *main::webui_idle_card_video_playing=sub {$video};
local *main::webui_idle_card_stabilization_wanted=sub {$stabilise};
local *main::webui_meter_stabilization_active=sub {$stop_hook->() if $stop_hook; return (0,25,100)};
local *main::pattern_generator_is_running=sub {1};
local *main::webui_preferred_rgb_quant_range=sub {2};
local *main::apply_source_rgb_quant_range=sub {$range_changes++};
local *main::video_program_stop=sub {};
local *main::create_return_file=sub {};
local *main::webui_reload_pgenerator_conf=sub {};
local *main::webui_pattern_signal_mode=sub {'sdr'};
local *main::pg_dv_transport_mode=sub {'standard'};
local *main::webui_pattern_max_luma=sub {100};
local *main::webui_meter_simulation_enabled=sub {0};
local *main::pattern_log_patch_request=sub {};
local *main::load_new_pattern_file=sub {};
local *main::stats=sub {};
my $real_model=\&main::webui_idle_card_model;
local *main::webui_idle_card_model=sub {
 return PGIdleCard::card_model(PGIdleCard::requested_signal({signal_mode=>'sdr'},'1920x1080 @ 60'),{},{});
};
local *main::webui_idle_card_render=sub {
 my (undef,undef,undef,$file)=@_;
 $renders++;
 $render_hook->() if $render_hook;
 # The production path reads PNG dimensions after rendering. A fixed IHDR
 # isolates scheduling from the locally installed ImageMagick version.
 open(my $fh,'>:raw',$file) or die $!;
 print $fh "\x89PNG\r\n\x1a\n",pack('N',13),'IHDR',pack('N N',800,500);
 close $fh;
 return '';
};
sub write_pattern {
 open(my $fh,'>',"$main::command_file.client") or die $!;
 print $fh $_[0]; close $fh;
 rename("$main::command_file.client",$main::command_file) or die $!;
}
sub read_pattern {
 open(my $fh,'<',$main::command_file) or die $!;
 local $/; return <$fh>;
}
sub request { return PGAutomation::decode_json(main::webui_pattern(PGAutomation::encode_json(shift))); }
sub reset_idle {
 %main::_idle_card=(); $now+=100;
 ($owner,$video,$stabilise,$render_hook,$stop_hook)=('',0,0,undef,undef);
 $main::pgenerator_conf{screensaver_enabled}='1';
 write_pattern("PATTERN_NAME=stop\nRGB=0,0,0\n");
 main::webui_idle_card_tick();
}
my $auto={name=>'screensaver',only_if_idle=>JSON::PP::true,only_if_unowned=>JSON::PP::true};
my $auto_stop={name=>'stop',only_if_idle=>JSON::PP::true,only_if_unowned=>JSON::PP::true};

# CommandRGB and Resolve's writer need not supply PATTERN_NAME, including
# when their requested measurement patch is black.
for my $rgb ('128,128,128','0,0,0') {
 reset_idle();
 main::create_pattern_file('RECTANGLE','1920,1080',100,$rgb,'0,0,0','0,0','','',1,'calman','FULL',255);
 my $patch=read_pattern();
 unlike($patch,qr/^PATTERN_NAME=/m,"legacy $rgb fixture has no name");
 main::webui_idle_card_tick(); $now+=11; main::webui_idle_card_tick();
 is(read_pattern(),$patch,"timer preserves unnamed $rgb client patch");
 ok(request({name=>'stop',only_if_idle=>JSON::PP::true})->{unchanged},'idle-only Hide preserves the client patch too');
}
is($renders,0,'client patches never trigger a card render');
reset_idle();
$now+=9; main::webui_idle_card_tick();
like(read_pattern(),qr/^PATTERN_NAME=stop/m,'card waits for the full delay');
$now+=2; main::webui_idle_card_tick();
like(read_pattern(),qr/^PATTERN_NAME=screensaver/m,'unowned idle frame shows the card');
ok(ref($main::_idle_card{shown}{card}) eq 'HASH','successful display publishes card metadata');
is($range_changes,0,'card does not take range ownership or restart the current signal');
is(request($auto_stop)->{pattern},'stop','automatic Hide clears the card');
is($range_changes,0,'automatic Hide also preserves signal ownership');
request($auto);
is(request({name=>'stop',only_if_idle=>JSON::PP::true})->{pattern},'stop','browser Hide accepts the existing idle-only request');
is($range_changes,0,'browser Hide preserves signal ownership without an extra flag');
$now+=2; main::webui_idle_card_tick();
is(PGAutomation::decode_json($main::_idle_card_status)->{state},'waiting','Hide re-arms the delay');

# A change made while rendering must win, even when it writes another stop
# frame or acquires the meter without having sent its first patch yet.
for my $next ("PATTERN_NAME=patch\nRGB=128,128,128\n", "DRAW=RECTANGLE\nRGB=0,0,0\n", "PATTERN_NAME=stop\nRGB=0,0,0\n") {
 reset_idle(); $render_hook=sub {write_pattern($next)};
 ok(request($auto)->{unchanged},'command arriving during render cancels the pending card');
 is(read_pattern(),$next,'new command remains installed');
 ok(!exists($main::_idle_card{shown}),'cancelled card is not published as displayed');
}
reset_idle(); $render_hook=sub {$owner='measurement series'};
is(request($auto)->{error_code},'pattern-owned','owner acquired during rendering blocks the card');
like(read_pattern(),qr/^PATTERN_NAME=stop/m,'late ownership leaves the output unchanged');
my $before=$renders;
is(request({name=>'screensaver'})->{error_code},'pattern-owned','Show now also respects ownership');
is($renders,$before,'existing ownership blocks rendering immediately');
is(request({name=>'stop',only_if_idle=>JSON::PP::true})->{error_code},'pattern-owned','existing idle-only callers also respect ownership');
for my $reason ('video','stabilisation') {
 reset_idle(); $render_hook=sub {$reason eq 'video' ? $video=1 : $stabilise=1};
 ok(request($auto)->{unchanged},"$reason starting during render cancels the card");
}
reset_idle();
request($auto);
my $old=read_pattern(); my $shown=$main::_idle_card{shown};
my ($image)=$old=~/^IMAGE=(.+)$/m;
$render_hook=sub {$owner='measurement series'};
is(request($auto)->{error_code},'pattern-owned','owned redraw is cancelled');
is(read_pattern(),$old,'cancelled redraw preserves the displayed command');
ok(-s $image,'cancelled redraw preserves its image');
is($main::_idle_card{shown},$shown,'cancelled redraw preserves its published position');

reset_idle(); request($auto);
$stop_hook=sub {$owner='measurement series'};
is(request($auto_stop)->{error_code},'pattern-owned','ownership acquired during stop preparation blocks automatic Hide');
like(read_pattern(),qr/^PATTERN_NAME=screensaver/m,'blocked Hide leaves the output unchanged');
reset_idle(); request($auto);
$main::pgenerator_conf{screensaver_enabled}='0'; $now+=2;
main::webui_idle_card_tick();
like(read_pattern(),qr/^PATTERN_NAME=stop/m,'disabling the idle card clears it');

# A black renderer startup frame is eligible, but a named black measurement
# is still a patch; colour alone must never determine display ownership.
for my $case (['PatternStart','0,0,0','stop'],['PatternStart','128,128,128','PatternStart'],['patch','0,0,0','patch']) {
 write_pattern("PATTERN_NAME=$case->[0]\nRGB=$case->[1]\n");
 is(main::webui_pattern_file_idle_name(),$case->[2],"classifies $case->[0] at $case->[1]");
}

# Command installation and renderer failures must not advertise a card that
# never reached the display or remove the last image the renderer can reload.
reset_idle(); request($auto);
my $installed=read_pattern();
my $installed_state=$main::_idle_card{shown};
my ($installed_image)=$installed=~/^IMAGE=(.+)$/m;
my @images_before=sort glob("$main::var_dir/running/idle_card_*.png");
{
 local $main::command_file="$main::var_dir/running/not-a-file";
 mkdir($main::command_file) or die $!;
 is(request({name=>'screensaver'})->{status},'error','failed command rename returns an error');
 is($main::_idle_card{shown},$installed_state,'failed installation preserves published card');
 ok(-s $installed_image,'failed installation preserves previous image');
 is_deeply([sort glob("$main::var_dir/running/idle_card_*.png")],\@images_before,'failed installation removes the unused PNG');
}
{
 local *main::pattern_generator_is_running=sub {0};
 local *main::pattern_generator_start=sub {die 'automatic idle must not start the renderer'};
 is(request($auto)->{status},'error','automatic card yields to a stopped renderer');
 is_deeply([sort glob("$main::var_dir/running/idle_card_*.png")],\@images_before,'unavailable renderer does not leak the prepared PNG');
}
is(read_pattern(),$installed,'failed operations leave the installed command unchanged');

reset_idle(); request($auto);
$main::_idle_card{shown}{signature}='stale-content';
$render_hook=sub {$owner='measurement series'};
$now+=61; main::webui_idle_card_tick();
is(PGAutomation::decode_json($main::_idle_card_status)->{state},'held','cancelled refresh reports ownership hold');
$owner=''; $render_hook=undef; $now+=5;
main::webui_idle_card_tick();
is(PGAutomation::decode_json($main::_idle_card_status)->{state},'showing','cancelled refresh retries promptly after ownership clears');

# Unchanged content must eventually travel to fresh positions. Expiry uses
# the monotonic clock, independent of the browser's wall-clock shown_at.
reset_idle(); request($auto);
my $sequence_state=$main::_idle_card{shown};
my $sequence_command=read_pattern();
$sequence_state->{card}{shown_at}=1;
$now=$sequence_state->{renew_at}-1;
main::webui_idle_card_tick();
is(read_pattern(),$sequence_command,'unchanged card keeps its sequence until expiry');
$now+=61; $render_hook=sub {$owner='measurement series'};
main::webui_idle_card_tick();
is(read_pattern(),$sequence_command,'ownership acquired during renewal preserves the sequence');
is($main::_idle_card{shown},$sequence_state,'cancelled renewal preserves its expired deadline and displayed positions');
is(PGAutomation::decode_json($main::_idle_card_status)->{state},'held','cancelled position renewal reports ownership hold');
$owner=''; $render_hook=undef; $now+=5;
main::webui_idle_card_tick();
isnt(read_pattern(),$sequence_command,'position renewal retries promptly after ownership clears');
is($main::_idle_card{shown}{signature},$sequence_state->{signature},'unchanged model receives the new sequence');
isnt(PGAutomation::encode_json($main::_idle_card{shown}{card}{positions}),
 PGAutomation::encode_json($sequence_state->{card}{positions}),'new sequence has fresh positions');
is($main::_idle_card{shown}{renew_at},$now+2400,'successful renewal schedules another complete forty-minute sequence');

# Saved transport values must pass through the same policy as the renderer.
# Exercise both policies so retiring LLDV cannot leave a stale label or codes.
{
 local $main::pgenerator_conf{signal_mode}='dv';
 local $main::pgenerator_conf{dv_transport}='lldv';
 local *main::read_from_file=sub {'1920x1080 @ 60'};
 local *main::webui_idle_card_readback=sub {return ()};
 local *main::webui_idle_card_kit=sub {{}};
 local $PGIdleCard::DV_LEVELS{lldv}={value=>60,label=>50,black=>16};
 for my $policy ('standard','lldv') {
  local *main::pg_dv_transport_mode=sub {$policy};
  my $model=$real_model->();
  my ($transport)=grep {$_->{label} eq 'DV transport'} @{$model->{rows}};
  is($transport->{requested},$policy eq 'lldv' ? 'Low latency' : 'Standard',"requested transport follows $policy policy");
  is($model->{headline},$policy eq 'lldv' ? 'Dolby Vision LL' : 'Dolby Vision',"headline follows $policy policy");
  my $render=\&main::webui_idle_card_render;
  my $levels;
  local *main::webui_idle_card_render=sub {$levels=$_[1]; return $render->(@_)};
  my @candidate=main::webui_idle_card_pattern(1920,1080,'dv','16,16,16');
  is($candidate[1],'',"card renders under $policy policy");
  is_deeply($levels,$PGIdleCard::DV_LEVELS{$policy},"text codes follow $policy policy");
 }
 is($main::pgenerator_conf{dv_transport},'lldv','observing transport does not rewrite the saved setting');
}

# Preview writers overlap across workers. Finish one while the other has a
# partial image, and run renderer cleanup while both temporary files exist.
{
 my $ready=Thread::Queue->new();
 my @release=map {Thread::Queue->new()} 1..2;
 my @workers;
 for my $index (0..1) {
  push @workers,threads->create(sub {
   local *main::webui_idle_card_render=sub {
    my $file=$_[3];
    open(my $fh,'>',$file) or die $!; print $fh "partial-$index"; close $fh;
    $ready->enqueue($file);
    $release[$index]->dequeue();
    open($fh,'>',$file) or die $!; print $fh "complete-$index"; close $fh;
    return '';
   };
   return [main::webui_idle_card_preview_png()];
  });
 }
 my @files=map {$ready->dequeue()} 1..2;
 isnt($files[0],$files[1],'concurrent previews have distinct output files');
 main::webui_idle_card_cleanup();
 ok(-f $files[0] && -f $files[1],'renderer cleanup preserves both active previews');
 $release[0]->enqueue('finish');
 is_deeply($workers[0]->join(),['complete-0',''],'first response reads its own complete preview');
 $release[1]->enqueue('finish');
 is_deeply($workers[1]->join(),['complete-1',''],'second response reads its own complete preview');
 ok(!-e $files[0] && !-e $files[1],'completed previews remove both temporary files');
}
for my $failure ('return-error','exception','unreadable') {
 my $file;
 local *main::webui_idle_card_render=sub {
  $file=$_[3];
  die "injected preview exception\n" if $failure eq 'exception';
  return 'injected preview error' if $failure eq 'return-error';
  unlink($file); return '';
 };
 my ($png,$error)=eval {main::webui_idle_card_preview_png()};
 ok(!defined($png) && ($error||$@),"preview $failure is reported");
 ok(!-e $file,"preview $failure reclaims its temporary file");
}
{
 local *File::Temp::new=sub {die "injected temporary file creation failure\n"};
 my ($png,$error)=eval {main::webui_idle_card_preview_png()};
 is($@,'','preview file creation failure does not escape the request handler');
 ok(!defined($png),'failed preview creation returns no image');
 like($error,qr/preview image could not be created/,'preview creation failure identifies the operation');
}

# Failed conversions and exceptions must reclaim both the candidate and
# older interrupted attempts without retiring the installed image/preview.
reset_idle(); request($auto);
my $active_command=read_pattern();
my $active_state=$main::_idle_card{shown};
my ($active_image)=$active_command=~/^IMAGE=(.+)$/m;
my $preview="$main::var_dir/running/idle_card_preview.png";
open(my $preview_fh,'>',$preview) or die $!;
print $preview_fh 'preview'; close $preview_fh;
my @retained=sort ($active_image,$preview);
my $render=\&main::webui_idle_card_render;
for my $failure ('convert-error','invalid-png','render-exception','sequence-exception','post-render-exception') {
 my $orphan="$main::var_dir/running/idle_card_orphan.png";
 open(my $fh,'>',$orphan) or die $!; print $fh 'orphan'; close $fh;
 my $sequence=\&PGIdleCard::sequence_pattern;
 local *main::webui_idle_card_render=sub {
  my $result=$render->(@_);
  die "injected render failure\n" if $failure eq 'render-exception';
  if($failure eq 'invalid-png') {
   open(my $bad,'>',$_[3]) or die $!; print $bad 'partial PNG'; close $bad;
  }
  return $failure eq 'convert-error' ? 'injected conversion failure' : $result;
 };
 local *PGIdleCard::sequence_pattern=sub {
  die "injected sequence failure\n" if $failure eq 'sequence-exception';
  return $sequence->(@_);
 };
 local *main::video_program_stop=sub {die "injected post-render failure\n" if $failure eq 'post-render-exception'};
 my $reply=eval { request({name=>'screensaver'}) };
 my $error=$@;
 ok($failure=~/exception/ ? $error=~/injected/ : ($reply->{status}||'') eq 'error',"$failure is reported");
 is_deeply([sort glob("$main::var_dir/running/idle_card_*.png")],\@retained,"$failure leaves only the active image and preview");
 is(read_pattern(),$active_command,"$failure preserves the installed command");
 is($main::_idle_card{shown},$active_state,"$failure preserves published metadata");
}
{
 local *File::Temp::new=sub {die "injected temporary file creation failure\n"};
 my $reply=eval {request({name=>'screensaver'})};
 is($@,'','temporary file creation failure does not escape the request handler');
 is($reply->{status},'error','temporary file creation failure returns a JSON error');
 like($reply->{message},qr/image could not be created/,'creation error identifies the failed operation');
 is(read_pattern(),$active_command,'creation failure preserves the installed command');
 is_deeply([sort glob("$main::var_dir/running/idle_card_*.png")],\@retained,'creation failure preserves the active image and preview');
}
{
 local *main::create_return_file=sub {die "injected notification failure\n"};
 eval { request({name=>'screensaver'}) };
 like($@,qr/injected notification failure/,'exercise exception after command installation');
 my ($image)=read_pattern()=~/^IMAGE=(.+)$/m;
 ok(-s $image,'an exception after installation keeps the committed image');
 ok(!-e $active_image,'successful replacement retires the previous image');
}

# Reader and renderer workers are created before either publishes an update.
# The reader must see live nested metadata through the shared JSON snapshot,
# even though its private timer hash contains an unrelated inherited copy.
reset_idle();
is(main::webui_route_device_lane('POST','/api/pattern'),'renderer','Show now and Hide use the timer lane');
ok(!main::webui_route_is_concurrent_safe('POST','/api/pattern'),'pattern posts cannot bypass renderer serialisation');
my $read_queue=Thread::Queue->new();
my $write_queue=Thread::Queue->new();
my $read_replies=Thread::Queue->new();
my $write_replies=Thread::Queue->new();
my $reader=threads->create(sub {
 $main::_idle_card{shown}={card=>{headline=>'reader-local stale copy'}};
 while($read_queue->dequeue() eq 'read') {
  $read_replies->enqueue(main::webui_idle_card_status_json());
 }
});
my $writer=threads->create(sub {
 while((my $action=$write_queue->dequeue()) ne 'quit') {
  if($action eq 'automatic') { $now+=11; main::webui_idle_card_tick(); }
  elsif($action eq 'patch') { write_pattern("DRAW=RECTANGLE\nRGB=0,0,0\n"); }
  else { request({name=>$action,only_if_idle=>JSON::PP::true}); }
  $now+=2; main::webui_idle_card_tick();
  $write_replies->enqueue('done');
 }
});
for my $case (['automatic','showing'],['stop','waiting'],['screensaver','showing'],['patch','busy']) {
 $write_queue->enqueue($case->[0]); $write_replies->dequeue();
 $read_queue->enqueue('read');
 my $status=PGAutomation::decode_json($read_replies->dequeue());
 is($status->{state},$case->[1],"reader sees $case->[0] state from renderer thread");
 if($case->[1] eq 'showing') {
  is(scalar @{$status->{card}{positions}},120,'reader receives the complete hop positions');
  isnt($status->{card}{headline},'reader-local stale copy','reader ignores its private timer hash');
 } else { ok(!exists($status->{card}),'reader sees obsolete card metadata removed'); }
}
$write_queue->enqueue('quit'); $read_queue->enqueue('quit');
$writer->join(); $reader->join();
done_testing();
