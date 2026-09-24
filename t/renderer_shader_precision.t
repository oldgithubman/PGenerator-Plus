use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# Mesa's surfaceless renderer exercises the actual GLSL without a Pi or TV.
my $status=system('python3',"$Bin/fixtures/renderer_shader_precision.py");
plan skip_all=>'EGL/GLES software renderer unavailable' if(($status >> 8)==77 && !$ENV{PGEN_REQUIRE_SHADER_TESTS});
is($status,0,'actual Pi 4/Pi 5 shaders preserve codes on native integer and HDR float surfaces');
done_testing();
