# Adversarial F3 check (agent BC): execute meter_series.sh's real
# load_series_identity_meta/write_state_json (and write_state_on_exit) in
# isolation and validate the produced JSON strictly (duplicate keys rejected).
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP ();
use Test::More;
my $WT="$Bin/..";
open my $fh,'<',"$WT/usr/bin/meter_series.sh" or die;my $src=do{local $/;<$fh>};close $fh;
my @fn;for my $n (qw(series_state_claim_lost load_series_identity_meta write_state_json write_state_on_exit)) {my ($f)=$src=~/^($n\(\) \{.*?^\})/ms;die "missing $n" if !$f;push @fn,$f;}
sub run_bash {my ($script)=@_;my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;my $o=do{local $/;<$out>};my $e=do{local $/;<$err>};waitpid($pid,0);return ($?>>8,$o,$e);}
sub strict_json {
    my ($text)=@_;
    my ($rc,$o,$e)=run_bash("python3 - <<'PY'\nimport json,sys\ndef hook(pairs):\n    keys=[k for k,_ in pairs]\n    d=[k for k in set(keys) if keys.count(k)>1]\n    if d: raise ValueError('duplicate keys: '+','.join(sorted(d)))\n    return dict(pairs)\ntry:\n    json.loads(open(sys.argv[1] if len(sys.argv)>1 else '/dev/stdin').read(),object_pairs_hook=hook)\n    print('valid')\nexcept Exception as ex:\n    print('invalid: %s'%ex)\nPY\n");
    return $o;
}
sub scenario {
    my (%o)=@_;
    my $dir=tempdir(CLEANUP=>1);
    open my $s,'>',"$dir/state.json" or die;print {$s} $o{seed};close $s;
    my $f=join("\n",@fn);$f=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
    my $script="STATE_FILE='$dir/state.json'\nSERIES_ID=owned\nSERIES_META_JSON=''\nSERIES_META_LOADED=''\nSERIES_WORKER_META_JSON=''\nREADY_FILE='$dir/r'\nSTOP_FILE='$dir/s'\nchown() { :; }\n$f\n";
    $script.="write_state_json <<'PAYLOAD'\n$_\nPAYLOAD\n" for @{$o{payloads}||[]};
    $script.="write_state_on_exit\n" if $o{on_exit};
    my ($rc,$out,$err)=run_bash($script);
    open my $r,'<',"$dir/state.json" or die;my $text=do{local $/;<$r>};close $r;
    my $dup;{my ($rc2,$o2)=run_bash("python3 -c 'import json,sys\ndef h(p):\n  k=[a for a,_ in p]\n  if len(k)!=len(set(k)): raise ValueError(\"dup:\"+str(sorted(set([x for x in k if k.count(x)>1]))))\n  return dict(p)\ntry:\n  json.loads(open(\"$dir/state.json\").read(),object_pairs_hook=h);print(\"valid\")\nexcept Exception as e:\n  print(\"invalid \"+str(e))'\n");$dup=$o2;chomp $dup;}
    return ($rc,$text,$dup,$err);
}
my $seed=JSON::PP::encode_json({status=>'running',series_id=>'owned',type=>'greyscale',points=>21,signal_mode=>'sdr',target_gamma=>'bt1886',
    automation_worker_id=>'run-0-20260917-000000-abcdef',full_autocal_run_id=>'fa-1',worker_seeded_at=>1});
my %cases=(
  'no points'=>['{"status":"running","series_id":"owned","current_step":1,"total_steps":21,"current_name":"x","readings":[],"white_reading":null}'],
  'with points'=>['{"status":"complete","series_id":"owned","type":"greyscale","points":21,"readings":[{"Y":1}],"white_reading":{"Y":100}}'],
  'nested points in readings'=>['{"status":"running","series_id":"owned","readings":[{"name":"x","points":3}],"white_reading":null}'],
  'repeated writes'=>['{"status":"running","series_id":"owned","readings":[]}','{"status":"running","series_id":"owned","type":"greyscale","points":21,"readings":[]}','{"status":"complete","series_id":"owned","readings":[{"Y":2}]}'],
  'indented heredoc payload'=>['  {"status":"running","series_id":"owned","current_step":1,"readings":[]}'],
);
for my $name (sort keys %cases) {
    my ($rc,$text,$dup,$err)=scenario(seed=>$seed,payloads=>$cases{$name});
    is($rc,0,"$name: writer exit 0") or diag $err;
    is($dup,'valid',"$name: strict JSON (no duplicate keys)") or diag $text;
    my $st=eval {JSON::PP::decode_json($text)}||{};
    is($st->{automation_worker_id},'run-0-20260917-000000-abcdef',"$name: keeps automation_worker_id");
    is($st->{full_autocal_run_id},'fa-1',"$name: keeps full_autocal_run_id");
    ok(defined $st->{worker_pid},"$name: worker_pid present");
    ok(exists $st->{worker_start_ticks},"$name: worker_start_ticks key present (value empty without /proc)");
}
# guided (non-automation) seed: no identity must be invented
{
    my $g=JSON::PP::encode_json({status=>'running',series_id=>'owned',type=>'greyscale',points=>21});
    my ($rc,$text,$dup)=scenario(seed=>$g,payloads=>['{"status":"complete","series_id":"owned","readings":[]}']);
    is($dup,'valid','guided seed: valid JSON');
    my $st=JSON::PP::decode_json($text);
    ok(!exists $st->{automation_worker_id} && !exists $st->{worker_pid},'guided seed: no identity/pid invented');
}
# seed without points (defensive): identity is NOT carried -> first worker write drops it
{
    my $np=JSON::PP::encode_json({status=>'running',series_id=>'owned',automation_worker_id=>'id-x'});
    my ($rc,$text,$dup)=scenario(seed=>$np,payloads=>['{"status":"running","series_id":"owned","readings":[]}']);
    my $st=JSON::PP::decode_json($text);
    ok(!exists $st->{automation_worker_id},'OBSERVATION: a seed without "points" loses automation_worker_id on the first worker write');
}
# unexpected-exit trap: rewrites running state without identity
{
    my ($rc,$text,$dup)=scenario(seed=>$seed,payloads=>['{"status":"running","series_id":"owned","current_step":3,"total_steps":21,"current_name":"50%","readings":[]}'],on_exit=>1);
    my $st=JSON::PP::decode_json($text);
    is($st->{status},'error','on-exit trap wrote an error state');
    is($st->{automation_worker_id},'run-0-20260917-000000-abcdef','the crash trap keeps automation_worker_id, so the runner reports the crash itself (P18)');
}
done_testing();
