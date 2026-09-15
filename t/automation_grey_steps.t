use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";

{
 local @ARGV=('grey-steps-test','token-for-steps-test');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die "runner failed to load: $@" if $@;
}

sub step_at {
 my ($steps,$ire)=@_;
 my @found=grep { abs($_->{ire}-$ire)<0.001 } @$steps;
 is(scalar(@found),1,"one ${ire}% step exists");
 return $found[0];
}

open my $js,'<',"$Bin/../usr/share/PGenerator/webui-app.js" or die $!;
my $shared_js=do {local $/; <$js>};
close $js;
sub guided_slots {
 my ($name)=@_;
 my ($body)=$shared_js=~/const \Q$name\E=\[([^\]]+)\]/;
 die "guided slot list $name missing" if !defined($body);
 return [sort {$a<=>$b} map {0+$_} split /,/, $body];
}
sub body_slots {
 my ($steps)=@_;
 return [sort {$a<=>$b} map {$_->{ire}} grep {$_->{ire}>0 && $_->{ire}!=100} @$steps];
}

my $hdr=main::_grey_steps({signal_format=>'hdr10',signal_range=>'1',max_bpc=>10,color_format=>'1'});
is_deeply([sort {$a<=>$b} map {$_->{ire}} grep {$_->{ire}>0} @$hdr],
 guided_slots('METER_LG_GREY_HDR_AUTOCAL_SLOTS'),'runner and guided HDR20 ladders stay aligned');
is(step_at($hdr,2)->{r},80,'HDR10 Limited 2% uses the established HDR20 slot code');
is(step_at($hdr,4)->{r},100,'HDR10 Limited 4% uses the established HDR20 slot code');
is(step_at($hdr,7)->{r},124,'HDR10 Limited 7% uses the established HDR20 slot code');
is(step_at($hdr,30)->{r},328,'HDR10 Limited 30% uses the established HDR20 slot code');
is(step_at($hdr,5)->{input_max},1023,'10-bit HDR10 steps retain the 10-bit code domain');

my $hdr8=main::_grey_steps({signal_format=>'hdr10',signal_range=>'2',max_bpc=>8,color_format=>'0'});
is(step_at($hdr8,5)->{r},13,'8-bit Full HDR10 uses its own canonical slot table');
is(step_at($hdr8,5)->{input_max},255,'8-bit HDR10 never advertises a 10-bit code domain');

my $dv=main::_grey_steps({signal_format=>'dv',signal_range=>'2',max_bpc=>8,color_format=>'0'});
is(step_at($dv,0)->{r},256,'DV full HDMI transport still authors legal black');
is(step_at($dv,100)->{r},3760,'DV nominal white is legal 12-bit white, not transport maximum');
is(step_at($dv,5)->{r},431,'DV 5% is above black (old code 13 scaled to 208, below black 256)');
is(step_at($dv,5)->{input_max},4095,'DV source precision is independent of 8-bit transport');
for my $bits (8,10,12) {
 for my $range ('1','2') {
  my $item={signal_format=>'dv',signal_range=>$range,max_bpc=>$bits,color_format=>'0',calibration=>{dark_detail=>1}};
  my $steps=main::_grey_steps($item);
  my $manual=PGSignalCode::signal_code_policy({signal_mode=>'dv',dv_series=>1,dv_series_code_bits=>12,dv_series_full_range=>0});
  for my $step (@$steps) {
   my $expected=PGSignalCode::signal_percent_to_code($manual,$step->{ire});
   is_deeply([@$step{qw(r g b input_max)}],[($expected->{code})x3,$expected->{input_max}],"DV $bits/$range $step->{ire}% matches manual source encoding");
  }
  is($item->{signal_range},$range,'authoring patches does not rewrite transport settings');
 }
}

my $sdr=main::_grey_steps({signal_format=>'sdr',signal_range=>'1',max_bpc=>10,color_format=>'1'});
is_deeply(body_slots($sdr),guided_slots('METER_LG_GREY_AUTOCAL_26_SLOTS'),
 'runner and guided YCbCr headroom ladders stay aligned');
is(step_at($sdr,109)->{r},1023,'YCbCr Limited retains superwhite headroom');
ok(step_at($sdr,100)->{autocal_reference_only},'YCbCr legal white is a reference, not a second DDC anchor');
is(step_at($sdr,100)->{read_delay_ms},3000,'legal-white reference gets the established settle delay');
is(step_at($sdr,5)->{read_delay_ms},6000,'dim SDR anchors get the established settle delay');
is(step_at($sdr,20)->{read_delay_ms},3200,'mid-low SDR anchors get the established settle delay');

my $full=main::_grey_steps({signal_format=>'sdr',signal_range=>'2',max_bpc=>10,color_format=>'0'});
is_deeply(body_slots($full),guided_slots('METER_LG_GREY_AUTOCAL_26_SLOTS_FULL'),
 'runner and guided Full SDR ladders stay aligned');
is(step_at($full,100)->{r},1023,'Full SDR peak uses the full-code white');
ok(!step_at($full,100)->{autocal_reference_only},'Full SDR peak remains a real DDC anchor');
ok(!grep({$_->{ire}>100} @$full),'Full SDR has no unrenderable superwhite steps');

done_testing();
