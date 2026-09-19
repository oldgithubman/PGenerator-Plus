#!/usr/bin/perl
# The capability resolver's per-process memo and on-disk cache: the readback
# regression of 18 Sep 2026 was every TV helper process resolving the
# catalogue (2-2.6 s on the appliance) several times per TV conversation.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Spec ();
use JSON::PP ();
use Time::HiRes ();
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(clear_lg_capability_cache resolve_lg_capabilities lg_setting_contracts);

my $shipped="$Bin/../usr/share/PGenerator/tv";
my $store=tempdir(CLEANUP=>1);
local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$store;

sub copy_tree {
 my ($from,$to)=@_;
 find({no_chdir=>1,wanted=>sub {
  my $relative=File::Spec->abs2rel($_,$from);
  if(-d $_) { make_path(File::Spec->catdir($to,$relative)); return; }
  copy($_,File::Spec->catfile($to,$relative)) or die "copy $_: $!";
 }},$from);
}
sub cache_files { my @f; find({no_chdir=>1,wanted=>sub { push(@f,$_) if(-f $_ && /\.json$/); }},$store); my @sorted=sort @f; return @sorted; }

my $g3={series=>'G3',platform_model=>'HE_DTV_W23O_AFABATAA',software_version=>'23.25.55',platform_year=>2023,device_uuid=>'cache-test-g3'};
my $c2={series=>'C2',platform_model=>'HE_DTV_W22O_AFABATAA',software_version=>'13.30.05',platform_year=>2022,device_uuid=>'cache-test-c2'};

clear_lg_capability_cache();
my $first=resolve_lg_capabilities($g3,root=>$shipped);
is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','first resolve in a process computes the profile');
ok(($first->{capability_profile_hash}||'') ne '','computed profile carries its hash');
my @files=cache_files();
is(scalar(@files),1,'the computed profile is written to the store once') or diag(join("\n",@files));
like($files[0],qr{/resolved/[0-9a-f]{64}\.json$},'cache file is keyed under resolved/');

my $second=resolve_lg_capabilities($g3,root=>$shipped);
is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'memo','a second resolve in the same process is served from the memo');
is($second,$first,'the memo hands back the same structure');
is(scalar(cache_files()),1,'a memo hit writes nothing');

clear_lg_capability_cache();
my $third=resolve_lg_capabilities($g3,root=>$shipped);
is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'cache','after the memo is cleared the profile comes from the store');
isnt($third,$first,'the cached profile is a fresh structure');
is($third->{capability_profile_hash},$first->{capability_profile_hash},'cached profile keeps the hash');
is_deeply($third,$first,'cached profile is identical to the computed one');
ok(JSON::PP::is_bool($third->{library_valid}) && $third->{library_valid},'booleans survive the round trip');
my $contracts_cached=lg_setting_contracts($g3,root=>$shipped,keys=>[qw(brightness contrast pictureMode)],signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1');
clear_lg_capability_cache();
unlink($_) for cache_files();
my $contracts_computed=lg_setting_contracts($g3,root=>$shipped,keys=>[qw(brightness contrast pictureMode)],signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1');
is_deeply($contracts_cached,$contracts_computed,'setting contracts built from the cached profile match the computed ones');

# A fresh process (the helper is one per TV conversation) reads the store.
{
 my ($sfh,$script_path)=File::Temp::tempfile(SUFFIX=>'.pl',UNLINK=>1);
 print {$sfh} q{use strict; use PGLGCapabilities qw(resolve_lg_capabilities); my $p=resolve_lg_capabilities({series=>'G3',platform_model=>'HE_DTV_W23O_AFABATAA',software_version=>'23.25.55',platform_year=>2023,device_uuid=>'cache-test-g3'},root=>$ARGV[0]); print $PGLGCapabilities::LAST_RESOLVE_SOURCE,' ',$p->{capability_profile_hash};};
 close($sfh);
 my $out=`$^X -I "$Bin/../usr/share/PGenerator" "$script_path" "$shipped"`;
 is($out,'cache '.$first->{capability_profile_hash},'a fresh process resolves the same identity from the store');
}

# Another identity gets its own file; the first is untouched.
resolve_lg_capabilities($c2,root=>$shipped);
is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a different identity is computed');
is(scalar(cache_files()),2,'each identity has its own cache file');

# Any catalogue change invalidates the store entry without bookkeeping.
{
 my $root=tempdir(CLEANUP=>1);
 copy_tree($shipped,$root);
 clear_lg_capability_cache();
 my $before=resolve_lg_capabilities($g3,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a copied library resolves afresh (different root)');
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'cache','and is cached for its root');
 my $index="$root/lg/index.json";
 open(my $fh,'>>',$index) or die $!; print {$fh} "\n"; close($fh);
 clear_lg_capability_cache();
 my $after=resolve_lg_capabilities($g3,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a byte appended to any catalogue file forces a new resolve');
 is($after->{capability_profile_hash},$before->{capability_profile_hash},'the appended newline changes no data, so the hash is unchanged');
}

# A corrupt or foreign file at the cache path is ignored and replaced.
{
 clear_lg_capability_cache();
 unlink($_) for cache_files();
 resolve_lg_capabilities($g3,root=>$shipped);
 resolve_lg_capabilities($c2,root=>$shipped);
 clear_lg_capability_cache();
 my @all=cache_files();
 is(scalar(@all),2,'two entries to corrupt');
 foreach my $path (@all) {
  open(my $fh,'>',$path) or die $!; print {$fh} '{"schema_version":1,"signature":"stale","profile":{}}'; close($fh);
 }
 resolve_lg_capabilities($g3,root=>$shipped);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a cache entry with the wrong signature is recomputed');
 resolve_lg_capabilities($c2,root=>$shipped);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','for every identity');
 is(scalar(cache_files()),scalar(@all),'the stale entries are overwritten, not duplicated');
 foreach my $path (cache_files()) {
  my $text=do { open(my $in,'<',$path) or die $!; local $/; <$in> };
  my $doc=JSON::PP->new->decode($text);
  ok(ref($doc->{profile}) eq 'HASH' && ($doc->{profile}{capability_profile_hash}||'') ne '','a rewritten entry holds a full profile');
 }
}

# An unwritable store never breaks resolution.
SKIP: {
 skip 'root can write anywhere',3 if($> == 0);
 my $readonly=tempdir(CLEANUP=>1);
 chmod(0500,$readonly);
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$readonly;
 clear_lg_capability_cache();
 my $profile=eval { resolve_lg_capabilities($g3,root=>$shipped) };
 is($@,'','resolving with an unwritable store does not die');
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','the profile is computed');
 is($profile->{capability_profile_hash},$first->{capability_profile_hash},'and is the same profile');
 chmod(0700,$readonly);
}

# Old entries age out when a new one is written.
{
 local $PGLGCapabilities::RESOLVED_CACHE_KEEP_SECONDS=1;
 my ($old)=cache_files();
 my $past=time()-10;
 utime($past,$past,$old);
 clear_lg_capability_cache();
 my $root=tempdir(CLEANUP=>1);
 copy_tree($shipped,$root);
 resolve_lg_capabilities($g3,root=>$root);
 ok(!-f $old,'an entry older than the keep window is removed when a new entry is written');
}

# The signature covers this module too, so a deploy that changes the merge
# or match rules never serves a profile the previous release computed.
like(PGLGCapabilities::_library_signature($shipped),qr/(?:^|\n)PGLGCapabilities\.pm:\d+:\d+/,'the resolver module is part of the signature');

# The memo is per store as well as per root and identity.
{
 my $other=tempdir(CLEANUP=>1);
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$shipped);
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$other;
 resolve_lg_capabilities($g3,root=>$shipped);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a different store is not served from the first store\'s memo');
 my @in_other; find({no_chdir=>1,wanted=>sub { push(@in_other,$_) if(-f $_ && /\.json$/); }},$other);
 is(scalar(@in_other),1,'and the profile is written to the second store');
}

# Touching the resolver module invalidates the store entry.
SKIP: {
 my $module="$Bin/../usr/share/PGenerator/PGLGCapabilities.pm";
 my @st=Time::HiRes::stat($module);
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$shipped);
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$shipped);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'cache','served from the store before the module changes');
 skip 'the deployed module is not writable by this user',1 if(!utime($st[8],$st[9]+2,$module));
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$shipped);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a changed module invalidates the store entry');
 utime($st[8],$st[9],$module);
}

# A process holding a library loaded before a catalogue change never writes
# a profile computed from it under the new signature.
{
 my $root=tempdir(CLEANUP=>1);
 copy_tree($shipped,$root);
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','library loaded');
 my $index="$root/lg/index.json";
 my $text=do { open(my $in,'<',$index) or die $!; local $/; <$in> };
 my $doc=JSON::PP->new->decode($text);
 my $old_version=$doc->{library_version};
 $doc->{library_version}='2099.01.01.1';
 open(my $fh,'>',$index) or die $!; print {$fh} JSON::PP->new->canonical->pretty->encode($doc); close($fh);
 my $before=resolve_lg_capabilities($c2,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'computed','a new identity after the change is computed');
 is($before->{library_version},'2099.01.01.1','from the library as it is now, not the one this process loaded earlier');
 isnt($before->{library_version},$old_version,'so the stale library was dropped');
 clear_lg_capability_cache();
 my $fresh=resolve_lg_capabilities($c2,root=>$root);
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'cache','and the entry written for it is served to a fresh process');
 is($fresh->{library_version},'2099.01.01.1','carrying the new version');
}

# The helper's and the daemon's spellings of the same root share one entry.
{
 clear_lg_capability_cache();
 unlink($_) for cache_files();
 resolve_lg_capabilities($g3,root=>$shipped);
 clear_lg_capability_cache();
 resolve_lg_capabilities($g3,root=>"$Bin/../usr/share/PGenerator/../PGenerator/tv");
 is($PGLGCapabilities::LAST_RESOLVE_SOURCE,'cache','a differently spelt path to the same library hits the same entry');
 is(scalar(cache_files()),1,'and writes no second entry');
}

done_testing();
