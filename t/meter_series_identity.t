use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;
use JSON::PP ();
open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};close $fh;
my @functions;
for my $name (qw(series_state_claim_lost load_series_identity_meta write_state_json)) {
 my ($f)=$source=~/^($name\(\) \{.*?^\})/ms;
 die "Missing production function $name" if !$f;
 push @functions,$f;
}
# Execute the actual shell state writer, isolated from USB and device commands.
# Both startup/minimal and explicit-points writes must retain attempt metadata.
for my $with_points (0,1) {
 my $dir=tempdir(CLEANUP=>1);
 local $ENV{IDENTITY_TEST_DIR}=$dir;
 open my $seed,'>',"$dir/state.json" or die $!;
 print {$seed} JSON::PP::encode_json({series_id=>'owned-series',type=>'colors',points=>913,signal_mode=>'hdr10',
  target_gamma=>'st2084',automation_worker_id=>'batch-1-colours',full_autocal_run_id=>'batch-1'});close $seed;
 my $functions=join("\n",@functions);$functions=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 my $payload={status=>'complete',series_id=>'owned-series',readings=>[{Y=>1.234}],calibration_target_context=>{white_nits=>123}};
 @$payload{qw(type points)}=('colors',913) if $with_points;
 my $script=<<'BASH';
set -e
STATE_FILE="$IDENTITY_TEST_DIR/state.json"
SERIES_ID=owned-series
SERIES_META_JSON=''
SERIES_META_LOADED=''
SERIES_WORKER_META_JSON=''
# Do not touch host ownership/permissions during this isolated regression.
chown() { :; }
BASH
 $script.=$functions."\nwrite_state_json <<'PAYLOAD'\n".JSON::PP::encode_json($payload)."\nPAYLOAD\ncat \"\$STATE_FILE\"\n";
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my $text=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,"points=$with_points writer succeeds") or diag $errors;
 my $state=eval {JSON::PP::decode_json($text)}||{};
 is($state->{automation_worker_id},'batch-1-colours',"points=$with_points retains worker attempt");
 is($state->{full_autocal_run_id},'batch-1',"points=$with_points retains run identity");
 ok($state->{worker_pid}>1,"points=$with_points records worker PID");
 SKIP: {
  skip 'process birth ticks need Linux /proc',1 if !-r "/proc/$$/stat";
  like($state->{worker_start_ticks}//'',qr/^\d+$/,"points=$with_points records process birth");
 }
 is($state->{points},913,'series identity is retained');
 is_deeply($state->{readings},$payload->{readings},'physical readings unchanged');
 is_deeply($state->{calibration_target_context},$payload->{calibration_target_context},'provided chart context unchanged');
}
# The crash trap must keep the worker attempt identity so the runner reports
# the crash itself rather than a worker-identity mismatch (P18), keep the
# readings taken so far, publish atomically, and leave the file alone once
# another helper owns it, with or without python.
my ($trap)=$source=~/^(write_state_on_exit\(\) \{.*?^\})/ms;die 'Missing production function write_state_on_exit' if !$trap;
sub crash_trap {
 my (%o)=@_;
 my $dir=tempdir(CLEANUP=>1);
 open my $seed,'>:raw',"$dir/state.json" or die $!;
 print {$seed} JSON::PP->new->utf8->encode({status=>'running',series_id=>'owned-series',type=>'colors',points=>913,current_step=>3,
  current_name=>$o{name}//'Red 50%',readings=>[{name=>'Red 25%',Y=>1.5},{name=>'Red 50%',Y=>3.25}],automation_worker_id=>'batch-1-colours',full_autocal_run_id=>'batch-1'});close $seed;
 my $functions=join("\n",@functions,$trap);$functions=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 my $meta=$o{worker_meta}//'';$meta=~s/'/'"'"'/g;
 my $script="set -e\nSTATE_FILE=\"$dir/state.json\"\nREADY_FILE=\"$dir/ready\"\nSTOP_FILE=\"$dir/stop\"\nSERIES_ID=".($o{series_id}//'owned-series')."\nTOTAL=7\n"
  ."SERIES_META_JSON=''\nSERIES_META_LOADED=''\nSERIES_WORKER_META_JSON='$meta'\nchown() { :; }\n"
  .($o{no_python}?"python() { return 127; }\n":'').$functions."\n".($o{write_fails}?"printf() { return 1; }\n":'')
  ."inode_before=\$(perl -e 'print((stat shift)[1])' \"\$STATE_FILE\")\n"
  .($o{ascii_locale}?"export LC_ALL=C LANG=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0\n":'')
  ."write_state_on_exit\ncat \"\$STATE_FILE\"\necho\n"
  ."inode_after=\$(perl -e 'print((stat shift)[1])' \"\$STATE_FILE\")\n"
  ."[ \"\$inode_before\" = \"\$inode_after\" ] && echo same-inode || echo new-inode\n"
  ."ls \"$dir\" | grep -c exit.tmp || true\n";
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my @out=<$out>;my $errors=do {local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,"$o{label}: crash trap runs") or diag $errors;
 my $leftover=pop @out;chomp $leftover;
 my $inode=pop @out;chomp $inode;
 is($leftover,'0',"$o{label}: no temporary crash record is left behind");
 my $state=eval {JSON::PP->new->utf8->decode(join('',@out))}||{};
 # A crash record is published by rename (new inode); an untouched file keeps its inode.
 is($inode,(($state->{status}//'') eq 'error' ? 'new-inode' : 'same-inode'),"$o{label}: the state file is replaced by rename, never rewritten in place");
 return $state;
}
{
 my $state=crash_trap(label=>'python available');
 is($state->{status},'error','crash trap records the helper exit');
 is($state->{error},'series_helper_exited_unexpectedly','crash trap names the cause');
 is($state->{automation_worker_id},'batch-1-colours','crash trap keeps the worker attempt identity');
 is($state->{full_autocal_run_id},'batch-1','crash trap keeps the run identity');
 is(scalar(@{$state->{readings}||[]}),2,'readings taken so far survive the crash record');
 like($state->{current_name},qr/exited unexpectedly/,'the current patch is marked');
}
{
 my $state=crash_trap(label=>'no python',no_python=>1,worker_meta=>'"automation_worker_id":"batch-1-colours","full_autocal_run_id":"batch-1"');
 is($state->{status},'error','without python the flat record still reports the exit');
 is($state->{automation_worker_id},'batch-1-colours','without python the identity loaded earlier is kept');
 is_deeply($state->{readings},[],'without python the flat record carries no readings');
}
{
 my $long='x'.("\x{00e9}" x 120).' Grey'; # odd byte offset: the 200-byte cut lands mid-character
 my $state=crash_trap(label=>'long multibyte name',name=>$long);
 is($state->{status},'error','a name cut mid-character still produces JSON that Perl decodes');
 unlike($state->{current_name}//'',qr/\x{fffd}|[\x{d800}-\x{dfff}]/,'no replacement or surrogate characters in the name');
}
{
 my $long='x'.("\x{00e9}" x 120).' Grey';
 my $state=crash_trap(label=>'long multibyte name without python',name=>$long,no_python=>1,worker_meta=>'"automation_worker_id":"batch-1-colours"');
 is($state->{status},'error','without python a name cut mid-character still produces JSON that Perl decodes');
 like($state->{current_name}//'',qr/\(exited unexpectedly\)$/,'a long name keeps the exit marker');
 is($state->{automation_worker_id},'batch-1-colours','and the identity is kept');
}
{
 my $state=crash_trap(label=>'crash record write fails',write_fails=>1);
 is($state->{status},'running','a crash record that fails to write is discarded, not renamed over the state');
 is(scalar(@{$state->{readings}||[]}),2,'the existing state and its readings are intact');
}
{
 # Python 3.5 under an ASCII locale cannot read non-ASCII text; the trap reads bytes.
 my $long='x'.("\x{00e9}" x 120).' Grey';
 my $state=crash_trap(label=>'ASCII locale',name=>$long,ascii_locale=>1);
 is($state->{status},'error','under an ASCII locale the crash record is still written');
 is(scalar(@{$state->{readings}||[]}),2,'under an ASCII locale the readings are kept');
 is($state->{automation_worker_id},'batch-1-colours','under an ASCII locale the identity is kept');
}
for my $case ([0,'lost claim'],[1,'lost claim without python']) {
 my $state=crash_trap(label=>$case->[1],series_id=>'stale-series',no_python=>$case->[0]);
 is($state->{status},'running',"$case->[1]: the new owner's record is not overwritten");
 is($state->{automation_worker_id},'batch-1-colours',"$case->[1]: the new owner's identity is untouched");
}
done_testing();
