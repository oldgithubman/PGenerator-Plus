#!/usr/bin/perl
# LLDV (Low Latency Dolby Vision, 12-bit YCbCr 4:2:2) is retired from the
# user-facing surface. LLDV as the WebUI configured it (12 bpc) kills the
# renderer: it fails EGL config selection ("No EGL configs with appropriate
# attributes") and exits, both when applied and when a persisted LLDV config is
# read at startup (measured on an LG C1 against 2.12.2). Standard DV already
# carries 12-bit source codes through the RPU tunnel, so nothing is lost by
# removing the option.
#
# pg_dv_transport_mode() is the choke point for the DV transport config: every
# dv_transport helper derives from it, and command.pm's
# normalize_dv_transport_conf() re-derives the renderer's own config through it,
# so collapsing "lldv" here means the DV transport config can never resolve to
# LLDV, even from a persisted or injected dv_transport value. (It does not cover
# endpoints that carry a raw color_format / dv_interface of their own -- the
# meter-series API and the LG calibration worker configs -- which a follow-up
# addresses.) These assertions pin the choke point and the three user-facing
# surfaces (the option, the whitelist, and the client defaults) so the
# retirement cannot silently regress. Model: t/idle_pattern_seed.t.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 15;

my $dir = "$Bin/../usr/share/PGenerator";

# variables.pm's top-level runtime touches threads::shared (which a unit test has
# no use for and which dies here), but every sub compiles first, so the transport
# helpers are defined and callable. do() traps that die; we assert on the sub, not
# do()'s return. Mirrors why t/idle_pattern_seed.t declines to load variables.pm.
unshift @INC, $dir;
do "$dir/variables.pm";
ok(defined &main::pg_dv_transport_mode, 'pg_dv_transport_mode is defined');

our %pgenerator_conf;

# --- server contract: the choke point collapses every lldv request ---
%pgenerator_conf = ();
is(main::pg_dv_transport_mode('lldv'),     'standard', 'explicit lldv collapses to standard');
is(main::pg_dv_transport_mode('standard'), 'standard', 'standard stays standard');
is(main::pg_dv_transport_mode(),           'standard', 'no candidate defaults to standard');

%pgenerator_conf = (dv_transport => 'lldv');
is(main::pg_dv_transport_mode(),           'standard', 'a persisted lldv conf collapses to standard');

# --- downstream helpers can therefore never signal LLDV ---
%pgenerator_conf = ();
is  (main::pg_dv_transport_color_format('lldv'), '0', 'lldv never yields color_format 2 (4:2:2)');
isnt(main::pg_dv_transport_max_bpc('lldv'),     '12', 'lldv never forces 12 bpc');
is  (main::pg_dv_transport_ll_flag('lldv'),      '0', 'lldv never sets the low-latency flag');
is  (main::pg_dv_transport_std_flag('lldv'),     '1', 'lldv is treated as standard DV');
is  (main::pg_dv_transport_interface('lldv'),    '0', 'lldv never sets the DV interface');

# --- user-facing surfaces no longer offer or advertise LLDV ---
my $slurp = sub { local $/; open(my $fh, '<', $_[0]) or die "$_[0]: $!"; my $c = <$fh>; close $fh; $c };
my $webui = $slurp->("$dir/webui.pm");
my $body  = $slurp->("$dir/webui-body.html");
my $appjs = $slurp->("$dir/webui-app.js");
my $readme = $slurp->("$Bin/../README.md");

unlike($webui,  qr/"standard"\s*,\s*"lldv"/,          'webui.pm transport whitelist drops lldv');
like  ($webui,  qr/\$dv_transport_modes\s*=\s*'"standard"'\s*;/, 'webui.pm whitelist is standard-only');
unlike($body,   qr/value="lldv"/,                     'webui-body.html no longer offers the LLDV option');
unlike($appjs,  qr/lldv/i,                            'webui-app.js no longer constructs or checks lldv');
unlike($readme, qr/LLDV/,                             'README no longer advertises LLDV');
