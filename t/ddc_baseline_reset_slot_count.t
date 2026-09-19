#!/usr/bin/perl
# The DDC baseline resets must size their zero-array from the panel's fixed DDC
# ladder, never from the Dark-Detail-merged reading ladder.
#
# The TV's whiteBalance / adjustingLuminance DDC array is a fixed-length
# hardware structure: 20 points on hdr20, 26 on sdr26. Dark Detail interpolates
# extra *meter reading* IREs between those slots; it does not add DDC storage,
# and the webOS setSystemSettings schema caps the array at 26 items. Sizing a
# whole-array reset from ddc_slot_count() (the merged reading count: 31 on
# hdr20, 32 on sdr26) makes the TV reject the write as "array has too many
# items" and aborts the job. On a Reference-settings batch that killed every
# HDR10 job the moment Dark Detail was enabled.
#
# ddc_baseline_slot_count() is the fix. These are the properties that keep it
# correct, including that it did not disturb the measurement ladder or the
# masks that legitimately track the merged count.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $worker = "$Bin/../usr/bin/meter_lg_autocal.pl";
ok(-f $worker, 'meter_lg_autocal.pl is present');

# The worker ends in `unless(caller()){...}`, so `do` defines its subs without
# starting a calibration.
my $rc = do $worker;
ok(defined $rc, 'worker loads without dying') or diag("error: $@");
is($@, '', 'worker loads with no error');

ok(defined &main::ddc_baseline_slots_for_layout, 'ddc_baseline_slots_for_layout is defined');
ok(defined &main::ddc_baseline_slot_count,       'ddc_baseline_slot_count is defined');

# --- the base ladder is the fixed DDC length, whatever Dark Detail is doing ---
for my $dark (0, 1) {
  no warnings 'once';
  $main::LG_AUTOCAL_DARK_DETAIL = $dark;
  is(ddc_baseline_slot_count('hdr20'), 20, "hdr20 baseline is 20 slots (dark_detail=$dark)");
  is(ddc_baseline_slot_count('sdr26'), 26, "sdr26 baseline is 26 slots (dark_detail=$dark)");
}

# --- the measurement ladder is untouched: Dark Detail still merges fillers ---
{
  no warnings 'once';
  # ddc_slots_for_layout returns a list (its Dark-Detail branch ends in sort,
  # which is undef in scalar context), so count it in list context the way the
  # worker itself does -- never scalar(ddc_slots_for_layout(...)).
  $main::LG_AUTOCAL_DARK_DETAIL = 0;
  my @h_off = ddc_slots_for_layout('hdr20');
  my @s_off = ddc_slots_for_layout('sdr26');
  is(scalar(@h_off), 20, 'hdr20 reading ladder is 20 without Dark Detail');
  is(scalar(@s_off), 26, 'sdr26 reading ladder is 26 without Dark Detail');
  $main::LG_AUTOCAL_DARK_DETAIL = 1;
  my @h_on = ddc_slots_for_layout('hdr20');
  my @s_on = ddc_slots_for_layout('sdr26');
  is(scalar(@h_on), 31, 'hdr20 reading ladder still merges to 31 with Dark Detail');
  is(scalar(@s_on), 32, 'sdr26 reading ladder still merges to 32 with Dark Detail');
  # and the baseline count is genuinely a length, not a comma-operator last element
  cmp_ok(ddc_baseline_slot_count('hdr20'), '<', scalar(@h_on),
         'baseline count is below the merged count, so it is a real length');
}

# --- every baseline length is inside the real deployed schema cap ---
# Cross-check against the shipped capability library rather than a copied number,
# so a future schema change that lowered the cap would surface here.
SKIP: {
  my $conf = "$Bin/../usr/share/PGenerator/tv/lg/settings/webos-2020-common.json";
  skip 'capability library not present', 6 if(!-f $conf);
  eval { require JSON::PP; 1 } or skip 'JSON::PP unavailable', 6;
  my $json = do { local $/; open(my $f, '<', $conf) or die $!; <$f> };
  my $ddc  = JSON::PP->new->decode($json)->{profiles}[0]{data}{settings}{ddc_controls};
  for my $key (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
    my $cap = $ddc->{$key}{value_schema}{maximum_items};
    ok(defined($cap) && ddc_baseline_slot_count('hdr20') <= $cap && ddc_baseline_slot_count('sdr26') <= $cap,
       "$key baseline arrays fit the deployed schema cap ($cap)");
  }
  is($ddc->{adjustingLuminance}{value_schema}{maximum_items}, 26,
     'adjustingLuminance cap is the 26 the fix is sized against');
  # the merged reading count would still overflow it -- proves the bug is real
  no warnings 'once';
  $main::LG_AUTOCAL_DARK_DETAIL = 1;
  my @merged_hdr20 = ddc_slots_for_layout('hdr20');
  cmp_ok(scalar(@merged_hdr20), '>', $ddc->{adjustingLuminance}{value_schema}{maximum_items},
         'the un-fixed merged hdr20 count would overflow the cap');
}

# --- source-pin the two whole-array resets so a revert cannot pass silently ---
my $src = do { open(my $f, '<', $worker) or die "read $worker: $!"; local $/; <$f> };

for my $sub (qw(reset_hdr20_luminance_baseline_if_needed reset_ddc_baseline_for_autocal)) {
  my ($body) = $src =~ /(sub \Q$sub\E\b.*?\n\})/s;
  ok($body, "found $sub");
  $body //= '';
  like($body, qr/\@zero\s*=\s*map\s*\{\s*0\s*\}\s*\(1\.\.ddc_baseline_slot_count\(\)\)/,
       "$sub sizes its zero-array from ddc_baseline_slot_count()");
  unlike($body, qr/\@zero\s*=\s*map\s*\{\s*0\s*\}\s*\(1\.\.ddc_slot_count\(\)\)/,
         "$sub no longer sizes its zero-array from the merged ddc_slot_count()");
}
# the resets still exist to zero the panel, i.e. the fix narrowed the length, not the write
like($src, qr/sub reset_hdr20_luminance_baseline_if_needed.*?adjustingLuminance\s*=>\s*\\\@zero/s,
     'reset_hdr20 still uploads the zeroed adjustingLuminance array');

# --- guard against an over-broad replacement: measurement masks keep the merged count ---
my $merged_mask_sites = () = $src =~ /map\s*\{\s*0\s*\}\s*\(1\.\.ddc_slot_count\(\)\)/g;
cmp_ok($merged_mask_sites, '>=', 3,
       'measurement-domain zero-masks still use the merged ddc_slot_count()');

# --- the upload boundary and every white-balance array site use the base ladder ---
# set_picture_values sends whatever arrays it is handed straight to the daemon,
# so the cap must hold at that boundary whatever a caller's in-memory length is.
{
  my ($body) = $src =~ /(sub set_picture_values\b.*?\n\})/s;
  ok($body, 'found set_picture_values');
  $body //= '';
  my ($settings_block) = $body =~ /(my \$settings=\{.*?\n\s*\};\n[^\n]*adjustingLuminance[^\n]*\n)/s;
  ok($settings_block, 'found the $settings upload block in set_picture_values');
  $settings_block //= '';
  like($settings_block,
       qr/numeric_array\(\$arrays->\{\$_\},ddc_baseline_slot_count\(\)\)[^\n]*\n\s*qw\(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue\)/,
       'set_picture_values uploads the RGB white-balance arrays sized from ddc_baseline_slot_count()');
  like($settings_block,
       qr/\$settings->\{"adjustingLuminance"\}=numeric_array\(\$arrays->\{"adjustingLuminance"\},ddc_baseline_slot_count\(\)\)/,
       'set_picture_values uploads adjustingLuminance sized from ddc_baseline_slot_count()');
  unlike($settings_block, qr/ddc_slot_count\(\)/, 'the upload block never uses the merged ddc_slot_count()');
  my $merged_wb_sites = () = $src =~ /numeric_array\([^\n]*?(?:whiteBalance(?:Red|Green|Blue)|adjustingLuminance)[^\n]*?,ddc_slot_count\(\)\)/g;
  is($merged_wb_sites, 0,
     'no whiteBalance/adjustingLuminance array is sized from the merged ddc_slot_count()');
}

done_testing();
