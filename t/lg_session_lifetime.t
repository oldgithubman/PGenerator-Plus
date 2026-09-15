use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use Time::HiRes qw(time);
use Test::More;

ok(defined(do "$Bin/../usr/sbin/pgenerator-lg"), 'helper loads') or die $@;

{
 my ($command,$request);
 local *IPC::Open2::open2=sub {
  ($_[0])=tempfile(); ($_[1])=tempfile();
  $command=$_[4]; return 12345;
 };
 local *main::socket_write_all=sub { $request=$_[1]; return 1; };
 local *main::socket_read_headers=sub {
  my ($key)=$request=~/Sec-WebSocket-Key: (\S+)/;
  my $accept=main::sha1_base64($key.'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').'=';
  return "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: $accept\r\n\r\n";
 };
 local *main::reap_child_bounded=sub {};
 for my $budget (5,90) {
  my $session=main::websocket_connect_candidate('192.0.2.1','wss',3001,$budget);
  ok($session,'TLS WebSocket handshake succeeds');
  unlike($command,qr/\s-T\s/, 'local compatibility work cannot expire the TLS transport');
  like($command,qr/connect-timeout=\Q@{[main::connect_timeout_for($budget)]}\E\b/,
   'TCP connection establishment retains its independently capped deadline');
  main::websocket_close($session);
 }
}

{
 pipe(my $reader,my $writer) or die $!;
 my $start=time();
 is(main::socket_read_exact({reader=>$reader,select=>IO::Select->new($reader)},1,0.05),undef,
  'an idle live transport still has a bounded per-request read');
 cmp_ok(time()-$start,'<',1,'read deadline does not depend on a socat inactivity timer');
 close $writer; close $reader;
 my $pid=fork(); die 'fork failed' if !defined($pid);
 if(!$pid) { select undef,undef,undef,20; POSIX::_exit(0); }
 $start=time();
 main::reap_child_bounded($pid,0.1);
 cmp_ok(time()-$start,'<',4,'an idle transport child is stopped within the cleanup budget');
 is(waitpid($pid,POSIX::WNOHANG()),-1,'transport cleanup reaps the child');
}

{
 my $resolve=\&main::resolve_lg_capabilities;
 my $calls=0;
 local *main::resolve_lg_capabilities=sub { ++$calls; return $resolve->(@_); };
 local *PGLGCapabilities::resolve_lg_capabilities=sub { ++$calls; return $resolve->(@_); };
 my $g={platform_year=>2023,platform_model=>'HE_DTV_W23O_AFABATAA',series=>'G3'};
 my $profile=main::lg_generation_profile($g);
 is($calls,1,'generation profile resolves the matrix only once, including the mode catalogue');
 is_deeply($profile->{picture_mode_catalogue},main::lg_picture_mode_catalogue($g),
  'reusing the resolved catalogue preserves all capability policy');
}

{
 local *main::lg_authenticated_session=sub {{status=>'ok',session=>{}}};
 local *main::lg_generation_info=sub {{}};
 local *main::lg_generation_profile=sub {{reset_method=>'native'}};
 local *main::lg_calibration_profile_guard=sub {undef};
 local *main::lg_picture_mode_probe=sub {(tv_picture_mode=>'filmMaker')};
 local *main::lg_picture_reset_keys_from_tv=sub {[qw(brightness contrast backlight whiteBalanceRed)]};
 local *main::lg_picture_reset_contract_keys=sub {([qw(brightness contrast backlight whiteBalanceRed)],{contracts=>{}})};
 local *main::lg_recipe=sub {{settings=>[{wire_key=>'brightness',value=>50},{wire_key=>'contrast',value=>85}]}};
 local *main::lg_picture_readback_settings=sub {{}};
 local *main::websocket_close=sub {};
 local *main::diag_log_append=sub {};
 my $reply;
 local *main::lg_request=sub {$reply};
 local *main::lg_luna_request=sub {$reply};
 local *main::lg_calibration_request=sub {$reply};
 my $reset=main::lg_picture_reset_workflow('192.0.2.1','test-key',5,'hdmi4','filmMaker','sdr',1,0);
 is($reset->{status},'error','missing reset replies cannot become success');
 like($reset->{message},qr/no response|did not acknowledge/i,'missing replies are reported honestly');
 unlike($reset->{message},qr/rejected/i,'missing replies are not an explicit TV rejection');
 for my $name (qw(reset_attempts white_balance_reset_attempts panel_light_reset_attempts delete_reset_attempts factory_default_attempts builtin_apply_attempts)) {
  my $entries=$reset->{$name}||[];
  ok(@$entries,"$name exercised");
  ok(!grep(!$_->{failed},@$entries),"$name records missing responses as failures");
 }
 $reply={type=>'error',error=>'401 Not allowed to call method'};
 $reset=main::lg_picture_reset_workflow('192.0.2.1','test-key',5,'hdmi4','filmMaker','sdr',1,0);
 like($reset->{message},qr/401 Not allowed to call method/,'explicit rejection details are preserved');
 $reply={type=>'response',payload=>{returnValue=>main::json_true()}};
 $reset=main::lg_picture_reset_workflow('192.0.2.1','test-key',5,'hdmi4','filmMaker','sdr',1,0);
 is($reset->{status},'ok','acknowledged native resets still succeed');
 ok($reset->{basic_picture_reset_ok},'acknowledged brightness and contrast retain their reset result');
}

done_testing();
