use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
# pgenerator-lg is a modulino; loading it defines its subs without running.
my $rc = do "$Bin/../usr/sbin/pgenerator-lg";
ok(defined $rc, 'pgenerator-lg loads as a module') or diag("error: $@");
ok(defined &main::lg_picture_category_or_default, 'category validator is defined');
# The original pattern interpolated $_ into the character class, so the
# accepted set depended on whatever the topic held at the call site. Run the
# same assertions under several topics to prove the validator no longer does.
foreach my $topic ('ZZZ', '', undef, 'oledLight') {
 local $_ = $topic;
 my $label = defined($topic) ? "topic '$topic'" : 'undefined topic';
 is(main::lg_picture_category_or_default('picture$hdmi1.filmMaker.2d.x'), 'picture$hdmi1.filmMaker.2d.x', "scoped panel-light category is accepted with $label");
 is(main::lg_picture_category_or_default('cal_dpg'), 'cal_dpg', "underscore category is accepted with $label");
 is(main::lg_picture_category_or_default('picture'), 'picture', "plain category passes through with $label");
 is(main::lg_picture_category_or_default('pic;ture'), 'picture', "category with a shell metacharacter falls back with $label");
 is(main::lg_picture_category_or_default(''), 'picture', "empty category falls back with $label");
 is(main::lg_picture_category_or_default(undef), 'picture', "missing category falls back with $label");
 is(main::lg_picture_category_or_default('x' x 201), 'picture', "over-long category falls back with $label");
}
done_testing();
