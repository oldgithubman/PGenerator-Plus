use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
# The browser releases a pending-edit binding once its run leaves
# PG_AUTOMATION_ACTIVE_STATUSES. That list copies webui_automation_active_status;
# if Perl gains a status the browser does not know, a live edit is dropped early.
sub slurp { my ($path)=@_; open(my $fh,'<:raw',$path) or die "$path: $!"; local $/; return <$fh>; }
my $js=slurp("$Bin/../usr/share/PGenerator/webui-automation.js");
my ($list)=$js=~/const PG_AUTOMATION_ACTIVE_STATUSES=\[([^\]]*)\]/;
ok(defined $list,'the browser declares PG_AUTOMATION_ACTIVE_STATUSES');
my @browser=sort(($list//'')=~/'([^']+)'/g);
my $pm=slurp("$Bin/../usr/share/PGenerator/webui.pm");
my ($body)=$pm=~/sub webui_automation_active_status \(\@\) \{(.*?)\n\}/s;
ok(defined $body,'webui.pm defines webui_automation_active_status');
my @server=sort(($body//'')=~/\$status eq "([^"]+)"/g);
ok(@server>=4,'the server list was read from its source');
is_deeply(\@browser,\@server,'browser and server agree on which run statuses are active');
# The source match above is only as good as its regex; ask the function too.
is(main::webui_automation_active_status($_),1,"server treats $_ as active") for @browser;
is(main::webui_automation_active_status($_),0,"server treats $_ as ended")
 for qw(complete complete-with-warnings failed stopped);
done_testing();
