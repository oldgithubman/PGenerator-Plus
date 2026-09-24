#!/usr/bin/perl
# The WebUI's mDNS responder answered only A (and ANY) questions. An
# AAAA-only question for pgenerator.local got no reply at all, so macOS
# never cached a negative and waited ~5s on every lookup of the name.
# Measured 2026-09-23: curl via the hostname spent 5.0s in name lookup on
# every endpoint (70ms for /api/lg/status by IP), and a capture on the unit
# showed 21 AAAA questions in 9s with no packet sent back.
#
# RFC 6762 6.1: a responder with no records of the asked type MUST assert
# their nonexistence with an NSEC record in the Answer section, and MAY add
# that NSEC to the Additional section of replies that do carry answers.
# These assertions decode the packets byte by byte.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Socket ();

use lib "$Bin/../usr/share/PGenerator";
our (%pgenerator_conf);
require "$Bin/../usr/share/PGenerator/webui.pm";

no warnings qw(redefine once);

my $HOST='pgenerator';
my $IP='192.168.2.9';

sub qname { join('',map { chr(length($_)).$_ } split(/\./,shift)).chr(0) }
sub query {
 my ($flags,@q)=@_;
 my $pkt=pack("nnnnnn",0,$flags,scalar(@q),0,0,0);
 $pkt.=$_ for @q;
 return $pkt;
}
sub question { my ($name,$type,$class)=@_; qname($name).pack("nn",$type,$class//1) }

# Minimal decoder for the responses under test.
sub decode {
 my $buf=shift;
 my ($id,$flags,$qd,$an,$ns,$ar)=unpack("nnnnnn",substr($buf,0,12));
 my $off=12;
 my @q;
 for (1..$qd) {
  my ($name,$next,$ok)=&main::webui_mdns_read_name($buf,$off);
  die "bad question" if(!$ok);
  my ($type,$class)=unpack("nn",substr($buf,$next,4));
  push @q,{name=>$name,type=>$type,class=>$class};
  $off=$next+4;
 }
 my @rr;
 for my $section (('an') x $an,('ns') x $ns,('ar') x $ar) {
  my ($name,$next,$ok)=&main::webui_mdns_read_name($buf,$off);
  die "bad name" if(!$ok);
  my ($type,$class,$ttl,$len)=unpack("nnNn",substr($buf,$next,10));
  my $rdata=substr($buf,$next+10,$len);
  push @rr,{section=>$section,name=>$name,type=>$type,class=>$class,ttl=>$ttl,rdata=>$rdata,rdoff=>$next+10};
  $off=$next+10+$len;
 }
 return {id=>$id,q=>\@q,flags=>$flags,qd=>$qd,an=>$an,ns=>$ns,ar=>$ar,rr=>\@rr,len=>length($buf),end=>$off};
}
sub nsec_types {
 my ($buf,$rr)=@_;
 my ($next,$after,$ok)=&main::webui_mdns_read_name($buf,$rr->{rdoff});
 my $bitmap=substr($buf,$after,$rr->{rdoff}+length($rr->{rdata})-$after);
 my ($window,$blen)=unpack("CC",substr($bitmap,0,2));
 my @bytes=unpack("C*",substr($bitmap,2,$blen));
 my @types;
 for my $i (0..$#bytes) { for my $bit (0..7) { push @types,$window*256+$i*8+$bit if($bytes[$i] & (0x80>>$bit)) } }
 return ($next,$window,\@types);
}

# --- Question matching --------------------------------------------------
my @w;
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",28)),$HOST);
is_deeply(\@w,[0,1],'an AAAA-only question is recognized');
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",1)),$HOST);
is_deeply(\@w,[1,0],'an A-only question is recognized');
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",255)),$HOST);
is_deeply(\@w,[1,1],'an ANY question wants both');
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",28,0x8001)),$HOST);
is_deeply(\@w,[0,1],'the unicast-response bit in qclass is ignored');
# macOS bundles A and AAAA, the second name compressed to a pointer at offset 12.
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",1),pack("n",0xC00C).pack("nn",28,1)),$HOST);
is_deeply(\@w,[1,1],'bundled A + compressed AAAA wants both');
@w=&main::webui_mdns_query_wants(query(0,question("MT48-c04eca.local",28)),$HOST);
is_deeply(\@w,[0,0],'a question for another name is ignored');
@w=&main::webui_mdns_query_wants(query(0x8400,question("$HOST.local",28)),$HOST);
is_deeply(\@w,[0,0],'a response packet (QR=1) is ignored');
@w=&main::webui_mdns_query_wants("short",$HOST);
is_deeply(\@w,[0,0],'a truncated packet is ignored');
@w=&main::webui_mdns_query_wants(query(0,question("$HOST.local",28,3)),$HOST);
is_deeply(\@w,[0,0],'a non-IN class is ignored');

# --- AAAA-only: NSEC in Answer, A in Additional ---------------------------
my $neg=&main::webui_mdns_build_aaaa_negative_response($HOST,$IP);
my $d=decode($neg);
is($d->{flags},0x8400,'negative response is an authoritative response');
is_deeply([@$d{qw(qd an ns ar)}],[0,1,0,1],'one answer and one additional record');
is($d->{end},$d->{len},'the packet has no trailing bytes');
my ($ans)=grep { $_->{section} eq 'an' } @{$d->{rr}};
is($ans->{type},47,'the answer is an NSEC record');
is($ans->{name},"$HOST.local",'NSEC owner is the host name');
is($ans->{class},0x8001,'NSEC carries the cache-flush bit and class IN');
is($ans->{ttl},120,'NSEC TTL matches the A record TTL');
my ($next,$window,$types)=nsec_types($neg,$ans);
is($next,"$HOST.local",'NSEC next-domain is the host name itself');
is($window,0,'NSEC bitmap uses window block 0');
is_deeply($types,[1],'NSEC asserts that only an A record exists');
my ($add)=grep { $_->{section} eq 'ar' } @{$d->{rr}};
is($add->{type},1,'the additional record is the A record');
is(Socket::inet_ntoa($add->{rdata}),$IP,'the additional A record carries the address');

# --- A reply (and announcements): A in Answer, NSEC in Additional -----------
my $pos=&main::webui_mdns_build_a_response($HOST,$IP);
$d=decode($pos);
is_deeply([@$d{qw(qd an ns ar)}],[0,1,0,1],'A reply carries one answer and one additional record');
is($d->{end},$d->{len},'the A reply has no trailing bytes');
($ans)=grep { $_->{section} eq 'an' } @{$d->{rr}};
is($ans->{type},1,'the answer is still the A record');
is($ans->{ttl},120,'A TTL is unchanged');
is(Socket::inet_ntoa($ans->{rdata}),$IP,'A answer carries the address');
($add)=grep { $_->{section} eq 'ar' } @{$d->{rr}};
is($add->{type},47,'the additional record is the NSEC');
is_deeply((nsec_types($pos,$add))[2],[1],'additional NSEC asserts that only A exists');

is(&main::webui_mdns_build_aaaa_negative_response('',$IP),'','no host name, no packet');
is(&main::webui_mdns_build_aaaa_negative_response($HOST,''),'','no address, no packet');

# --- Legacy unicast (RFC 6762 6.7) --------------------------------------------
# A query from a source port other than 5353 comes from a plain resolver (dig,
# nslookup). It needs a conventional reply: its own ID, its question echoed,
# TTL <= 10s and no cache-flush bit, or the resolver discards the answer.
my $legacy_q=pack("nnnnnn",0x1234,0,1,0,0,0).question("$HOST.local",1);
my $leg=&main::webui_mdns_build_legacy_response($HOST,$IP,$legacy_q,1);
$d=decode($leg);
is($d->{id},0x1234,'legacy reply echoes the query ID');
is($d->{flags},0x8400,'legacy reply is an authoritative response');
is_deeply([@$d{qw(qd an ns ar)}],[1,1,0,1],'legacy reply carries the question, one answer, one additional');
is_deeply($d->{q},[{name=>"$HOST.local",type=>1,class=>1}],'legacy reply echoes the question');
is($d->{end},$d->{len},'the legacy reply has no trailing bytes');
($ans)=grep { $_->{section} eq 'an' } @{$d->{rr}};
is($ans->{type},1,'legacy A question is answered with the A record');
is(Socket::inet_ntoa($ans->{rdata}),$IP,'legacy A answer carries the address');
is($ans->{ttl},10,'legacy answer TTL is capped at 10 seconds');
is($ans->{class},1,'legacy answer has no cache-flush bit');
($add)=grep { $_->{section} eq 'ar' } @{$d->{rr}};
is($add->{type},47,'legacy additional record is the NSEC');
is_deeply([@$add{qw(ttl class)}],[10,1],'legacy NSEC is capped at 10s with no cache-flush bit');

$legacy_q=pack("nnnnnn",0xBEEF,0,1,0,0,0).question("$HOST.local",28);
$d=decode(&main::webui_mdns_build_legacy_response($HOST,$IP,$legacy_q,0));
is($d->{id},0xBEEF,'legacy AAAA reply echoes the query ID');
($ans)=grep { $_->{section} eq 'an' } @{$d->{rr}};
is($ans->{type},47,'legacy AAAA-only question is answered with the NSEC');
is_deeply([@$ans{qw(ttl class)}],[10,1],'legacy NSEC answer is capped at 10s with no cache-flush bit');
is_deeply((nsec_types(&main::webui_mdns_build_legacy_response($HOST,$IP,$legacy_q,0),$ans))[2],[1],'legacy NSEC asserts that only A exists');

# A compressed second question is echoed as a full name, so the reply decodes.
$legacy_q=pack("nnnnnn",7,0,2,0,0,0).question("$HOST.local",1).pack("n",0xC00C).pack("nn",28,1);
$d=decode(&main::webui_mdns_build_legacy_response($HOST,$IP,$legacy_q,1));
is_deeply($d->{q},[{name=>"$HOST.local",type=>1,class=>1},{name=>"$HOST.local",type=>28,class=>1}],'bundled legacy questions are both echoed');
is($d->{end},$d->{len},'the bundled legacy reply has no trailing bytes');

is(&main::webui_mdns_build_legacy_response('',$IP,$legacy_q,1),'','legacy: no host name, no packet');
is(&main::webui_mdns_build_legacy_response($HOST,'',$legacy_q,1),'','legacy: no address, no packet');
is(&main::webui_mdns_build_legacy_response($HOST,$IP,'short',1),'','legacy: a truncated query gets no packet');

# --- Multicast rate limit (RFC 6762 6) ------------------------------------------
# A record may be multicast on an interface at most once per second. Every
# packet carries both A and NSEC, so one timestamp per interface covers both.
my %last;
ok(&main::webui_mdns_multicast_due(\%last,$IP,100.0),'the first multicast on an interface is sent');
ok(!&main::webui_mdns_multicast_due(\%last,$IP,100.5),'a multicast 0.5s later is held');
ok(&main::webui_mdns_multicast_due(\%last,'10.0.0.1',100.5),'another interface keeps its own clock');
ok(&main::webui_mdns_multicast_due(\%last,$IP,101.0),'a multicast a full second after the last one is sent');
ok(!&main::webui_mdns_multicast_due(\%last,$IP,101.6),'the clock restarts from the last multicast sent');
ok(&main::webui_mdns_multicast_due(\%last,$IP,102.0),'a held multicast does not push the clock back');

# --- The responder loop uses both --------------------------------------------
my $src=do { local(@ARGV,$/)="$Bin/../usr/share/PGenerator/webui.pm"; <> };
my ($loop)=$src=~/^sub webui_mdns \(\@\) \{\n(.*?)^\}/ms;
like($loop,qr/webui_mdns_query_wants\(\$buf,\$mdns_hostname\)/,'the responder classifies each packet');
like($loop,qr/webui_mdns_build_aaaa_negative_response\(/,'the responder answers AAAA-only questions');
unlike($loop,qr/\$qtype == 1 \|\| \$qtype == 255/,'the A-only inline match is gone');
like($loop,qr/if\(\$qport != \$MDNS_PORT\) \{[^}]*webui_mdns_build_legacy_response\([^}]*send\(\$sock, \$resp, 0, \$from\);[^}]*next;\n\s*\}/,'a legacy query gets a unicast-only reply');
like($loop,qr/webui_mdns_multicast_due\(\\%mdns_last_multicast,\$best_ip,/,'replies are multicast through the rate limit');
like($loop,qr/webui_mdns_multicast_due\(\\%mdns_last_multicast,\$route->\{ip\},/,'announcements share the rate limit');
like($loop,qr/CLOCK_MONOTONIC/,'the rate limit runs on the monotonic clock');

done_testing();
