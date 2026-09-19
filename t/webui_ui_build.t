use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
# A page compares the digest it first saw with later pings, so it must be
# fixed at boot, deterministic, and cover every spliced fragment.
like(main::webui_ui_build(),qr/^[0-9a-f]{16}$/,'the digest is fixed when the module loads, before any worker serves a page');
ok(main::webui_check_assets(),'boot asset check passes with the repo fragments');
my $build=main::webui_ui_build();
like($build,qr/^[0-9a-f]{16}$/,'boot records a 16-hex interface digest');
is(main::webui_ui_build_digest(),$build,'digest is deterministic for unchanged fragments');
my $original=\&main::webui_asset;
{
 no warnings qw(redefine once);
 local *main::webui_asset=sub { my ($name)=@_; my $c=$original->($name); return $name eq 'webui-automation.js' ? $c."\n// changed\n" : $c; };
 isnt(main::webui_ui_build_digest(),$build,'a changed automation script changes the digest');
}
is(main::webui_ui_build(),$build,'the boot value is not affected by later reads');
done_testing();
