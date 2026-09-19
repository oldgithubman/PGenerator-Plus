use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
# Every /api/config POST derives 7-14 keys and used to run one privileged
# process per key even when the value on disk was already right (~12 s per
# output switch on the appliance, paid again at every job start). Now only a
# changed value reaches sudo; the runner still confirms by GET.
my @sudo;
local *main::sudo=sub {push @sudo,[@_];1};
local *main::webui_reload_pgenerator_conf=sub {1};
local *main::sync_pattern_bits_default=sub {1};
local *main::webui_renderer_restart_begin=sub {'restart-1'};
local *main::resolve_redraw_last=sub {1};
# Dolby Vision transport helpers live in variables.pm, which the daemon loads
# before webui.pm; this test only needs their shape.
local *main::pg_dv_transport_mode=sub {$_[0]||'tunnel'};
local *main::pg_dv_transport_color_format=sub {'2'};
local *main::pg_dv_transport_interface=sub {'0'};
local *main::pg_dv_transport_ll_flag=sub {'0'};
local *main::pg_dv_transport_max_bpc=sub {'8'};
local *main::pg_dv_transport_std_flag=sub {'1'};
%main::pgenerator_conf=();
my ($first,$restart)=main::webui_apply_config('{"signal_mode":"hdr10","eotf":"2","primaries":"2","colorimetry":"9"}');
ok(scalar(@sudo)>0,'a fresh configuration writes its keys');
ok($restart,'and restarts the renderer for a signal change');
my $written=scalar(@sudo);
@sudo=();
my ($second,$again)=main::webui_apply_config('{"signal_mode":"hdr10","eotf":"2","primaries":"2","colorimetry":"9"}');
is(scalar(@sudo),0,'the same configuration again writes nothing');
ok(!$again,'and does not restart the renderer');
like($second,qr/"status":"ok"/,'the no-op still answers ok');
@sudo=();
main::webui_apply_config('{"signal_mode":"hdr10","eotf":"2","primaries":"2","colorimetry":"9","max_luma":"4000"}');
is(scalar(@sudo),1,'one changed key writes exactly that key');
is($sudo[0][1],'max_luma','the changed key');
@sudo=();
main::webui_apply_config('{"signal_mode":"hdr10","eotf":"2","primaries":"2","colorimetry":"9","max_luma":"4000","dv_map_mode":"2"}');
is_deeply([sort map {$_->[1]} @sudo],['dv_map_mode','dv_metadata'],'the DV map/metadata pair is written together even when only one half changed');
done_testing();
