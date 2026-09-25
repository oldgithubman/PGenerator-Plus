#!/usr/bin/perl
# Exploratory QA (dogfood pass, Sep 2026) found the Web UI's visible field
# captions were plain sibling text: no <label for=...> and no aria-label, so
# screen readers announced ~80 controls as unlabeled combos, the AP passphrase
# rendered as visible text while the Wi-Fi PSK was masked, unknown page routes
# answered with a bare "404 Not Found" body, and out-of-range HDR metadata
# numbers only surfaced through the native validationMessage. These assertions
# pin the fixes in the shipped fragments: every visible input/select in the
# page fragments must have a programmatic label, apPass must stay masked, the
# page 404 must be an HTML page with a link home, and the calibration chip must
# read unambiguously. Model: t/dv_transport_lldv_retired.t (static fragments).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $dir = "$Bin/../usr/share/PGenerator";

sub slurp {
 my ($name)=@_;
 open(my $fh, '<:raw', "$dir/$name") or die "open $name: $!";
 local $/; my $c=<$fh>; close($fh);
 return $c;
}

my %frag = map { $_ => slurp($_) }
 qw(webui.html webui-body.html webui-automation.html webui-lg-card.html icc_profile.html);
my $all = join("\n", values %frag);

# --- label associations -------------------------------------------------
# A control counts as labeled when any of: aria-label on the tag, a
# <label for="id"> anywhere in the assembled page, or it is wrapped by an
# open <label> whose close tag comes after the control.
my @unlabeled;
for my $file (sort keys %frag) {
 my $c = $frag{$file};
 while ($c =~ /(<(?:select|input)\b[^>]*\bid="([^"]+)"[^>]*>)/g) {
  my ($tagfull, $id) = ($1, $2);
  my $start = $-[0]; # capture before further matches clobber @-
  my ($tag) = $tagfull =~ /^(<[^\s>]+)/;
  my $hidden = $tagfull =~ /type="hidden"/;
  next if $hidden;
  next if $tagfull =~ /aria-label=/;
  # aria-hidden management selects (automation panel policy) are intentionally
  # invisible to AT and excluded from the tab order.
  next if $tagfull =~ /aria-hidden="true"/ && $tagfull =~ /tabindex="-1"/;
  next if $all =~ /<label[^>]*\bfor="\Q$id\E"/;
  # wrapped label: last <label before the control with no </label> between
  my $pre = substr($c, 0, $start);
  my $li = rindex($pre, '<label');
  next if $li >= 0 && index(substr($pre, $li), '</label>') < 0;
  push @unlabeled, "$file: $tag#$id";
 }
}
is_deeply(\@unlabeled, [], 'every visible input/select has a programmatic label')
 or diag explain \@unlabeled;

# Every label 'for' must resolve to an id that exists in the assembled page.
my @dangling;
for my $file (sort keys %frag) {
 while ($frag{$file} =~ /<label[^>]*\bfor="([^"]+)"/g) {
  push @dangling, "$file: for=\"$1\"" unless $all =~ /\bid="\Q$1\E"/;
 }
}
is_deeply(\@dangling, [], 'no label targets a missing id');

# --- AP passphrase masking ----------------------------------------------
like($frag{'webui-body.html'}, qr/<input[^>]*\btype="password"[^>]*\bid="apPass"/,
 'the AP passphrase field is masked like the Wi-Fi PSK');

# --- styled page 404 ------------------------------------------------------
my $pm;
{
 open(my $fh, '<:raw', "$dir/webui.pm") or die "open webui.pm: $!";
 local $/; $pm = <$fh>; close($fh);
}
like($pm, qr/sub webui_not_found_html/, 'webui.pm builds a styled 404 page');
like($pm, qr/webui_not_found_html\(\$path\)/, 'the page 404 catch-all serves the styled page');
# Unknown API routes must keep the compact body clients parse.
like($pm, qr{\$path=~/\^\\/api\\/}, 'the page 404 branch keeps /api/* on the compact response');
like($pm, qr/PG_404_PAGE/, 'the 404 page carries its marker');

# --- calibration chip wording --------------------------------------------
unlike($frag{'webui-body.html'}, qr/>No SW</, 'the header chip no longer reads cryptic "No SW"');
my $appjs = slurp('webui-app.js');
like($appjs, qr/Cal: none/, 'the disconnected calibration chip reads "Cal: none"');
like($appjs, qr/title='Calibration software: not connected\./,
 'the chip tooltip explains what the indicator means');

# --- out-of-range metadata feedback --------------------------------------
like(slurp('webui-theme.css'), qr/input\[type=number\]:out-of-range/,
 'out-of-range number fields get a visible border');
like(slurp('webui-app.js'), qr/aria-invalid/,
 'validity is mirrored onto aria-invalid for assistive tech');

done_testing();
