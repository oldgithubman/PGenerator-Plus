use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
# lg.pm carries its own copy of the validator for the daemon side.
require "$Bin/../usr/share/PGenerator/webui.pm";
do "$Bin/../usr/share/PGenerator/lg.pm" if !defined &main::lg_picture_category_or_default;
ok(defined &main::lg_picture_category_or_default, 'daemon-side category validator is defined') or diag("error: $@");
foreach my $topic ('ZZZ', undef) {
 local $_ = $topic;
 my $label = defined($topic) ? "topic '$topic'" : 'undefined topic';
 is(main::lg_picture_category_or_default('picture$hdmi1.filmMaker.2d.x'), 'picture$hdmi1.filmMaker.2d.x', "scoped category accepted with $label");
 is(main::lg_picture_category_or_default('cal_dpg'), 'cal_dpg', "underscore category accepted with $label");
 is(main::lg_picture_category_or_default('pic ture'), 'picture', "category with a space falls back with $label");
}
done_testing();
