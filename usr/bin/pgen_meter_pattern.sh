#!/bin/bash
# Shared local-renderer acknowledgement contract for session and series reads.
# Success means the requested patch was accepted, not proof of TV light output.
meter_post_local_patch() {
 local api_base="$1" payload="$2" response transport_status
 METER_PATTERN_ERROR=''
 response=$(curl -f -sS --max-time 8 "$api_base/pattern" -X POST \
  -H 'Content-Type: application/json' -d "$payload" 2>&1)
 transport_status=$?
 if (( transport_status != 0 )); then
  METER_PATTERN_ERROR="Pattern request failed (transport $transport_status): ${response:0:300}"
  return 1
 fi
 METER_PATTERN_ERROR=$(printf '%s' "$response" | perl -MJSON::PP -e '
  local $/; my $r=eval {decode_json(<STDIN>)};
  if(ref($r) ne "HASH") {print "Pattern renderer returned invalid JSON"; exit 1}
  if(($r->{status}||"") ne "ok" || ($r->{pattern}||"") ne "patch" || $r->{unchanged} || $r->{superseded}) {
   print "Pattern renderer did not accept the measurement patch: ".($r->{message}||$r->{error_code}||$r->{pattern}||$r->{status}||"unknown response"); exit 1;
  }
 ')
 return $?
}

meter_pattern_error_json() {
 printf '%s' "$METER_PATTERN_ERROR" | perl -MJSON::PP -e '
  local $/; my $message=<STDIN>;
  print encode_json({status=>"error",error_code=>"pattern-request-failed",message=>$message,request_id=>$ARGV[0]||""});
 ' "${1:-}"
}
