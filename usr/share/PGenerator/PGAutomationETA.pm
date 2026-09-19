package PGAutomationETA;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use PGAutomation ();

# Estimates never control execution. Only timings from completed, uninterrupted
# stages are reused; unlike patch counts, a saved duration includes uploads and
# TV checks. Separate profiles prevent mixing SDR, HDR, meter or LUT options.
sub profile {
 my ($item,$device)=@_;
 my %profile=map {$_=>$item->{$_}} qw(signal_format picture_mode settings panel_light display_type ccss_override observer refresh_rate delay_ms patch_size low_light patch_insert patch_insert_time_enabled patch_insert_time_frequency_ms patch_insert_time_duration_ms patch_insert_time_level patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration_ms patch_insert_patch_level max_bpc signal_range color_format pre_series post_series);
 $profile{device_identity}=$item->{device_identity}||$device;
 my $cal=$item->{calibration}||{};
 $profile{calibration}={map {$_=>$cal->{$_}} qw(target_gamma target_gamut target_white target_delta_e delta_e_formula method profile_source lattice_size solve_cube_size dark_detail shadow_fix lattice_residuals max_iterations headroom_max_iterations max_polish_iterations precision_polish_iterations)};
 return sha256_hex(JSON::PP->new->canonical->encode(\%profile));
}

sub samples {
 my ($run)=@_;
 my @samples;
 for my $item (@{$run->{items}||[]}) {
  my $key=profile($item);
  for my $c (@{$item->{checkpoints}||[]}) {
   next unless ($c->{status}||'') eq 'done' && defined($c->{duration_seconds})
    && $c->{duration_seconds}>0 && $c->{duration_seconds}<86400 && !$c->{timing_interrupted};
   push @samples,{profile=>$key,timing_profile=>timing_profile($item,$c->{name}),stage=>$c->{name},seconds=>0+$c->{duration_seconds}};
  }
 }
 return \@samples;
}

sub history {
 my ($current_id)=@_;
 my $dir=PGAutomation::base_dir().'/runs';
 opendir(my $dh,$dir) or return [];
 my @ids=sort {$b cmp $a} grep {$_ ne $current_id && PGAutomation::safe_component($_) && -d "$dir/$_"} readdir($dh);
 closedir($dh);
 splice(@ids,20) if @ids>20;
 my @samples;
 for my $id (@ids) {
  my $run=PGAutomation::read_json_file("$dir/$id/run.json");
  next unless ref($run) eq 'HASH';
  push @samples,@{samples($run)};
 }
 return \@samples;
}

sub plan {
 my ($item)=@_;
 my $s=$item->{stages}||{};
 my @stages=('item-started','tv-setup-verified');
 push @stages,'pre-readings-done' if $s->{pre_readings};
 if (!defined($s->{calibration}) || $s->{calibration}) {
  push @stages,qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed);
  push @stages,'apply-all-done' if !defined($s->{apply_all}) || $s->{apply_all};
 }
 push @stages,'post-readings-done' if $s->{post_readings};
 return \@stages;
}

sub median {
 my @values=sort {$a<=>$b} @_;
 return undef if !@values;
 my $middle=int(@values/2);
 return @values%2 ? $values[$middle] : ($values[$middle-1]+$values[$middle])/2;
}

# Workflow completion is measured work, not an estimate of elapsed time.
# Each planned stage has equal weight; patch/control counts refine only the
# active stage. Unknown-duration operations never advance merely with time.
sub progress {
 my ($run)=@_;
 my $pre=$run->{preflight_result}||{};
 my $pt=$pre->{progress_total}||1;
 my $pd=$pre->{ready} ? $pt : ($pre->{progress_done}||0);
 my ($done,$total)=($pd/$pt,1);
 my $stage=$run->{active_stage}||'';
 my ($stage_done,$stage_total,$unit)=$stage eq 'queue-preflight' ? ($pd,$pt,'checks') : (0,0,'steps');
 my $index=$run->{active_item};
 if (!$run->{preflight_only}) {
  my $items=$run->{items}||[];
  for my $i (0..$#$items) {
   my $item=$items->[$i];my $plan=plan($item);$total+=@$plan;
   my %finished=map {$_->{name}=>1} grep {($_->{status}||'') =~ /^(?:done|skipped)$/} @{$item->{checkpoints}||[]};
   for my $name (@$plan) {
    my $active=defined($index) && $i==$index && $stage eq $name && ($run->{status}||'')!~/^complete/;
    if (!$active && (($item->{status}||'') =~ /^complete/ || $finished{$name})) {$done++;next;}
    next if !$active;
    my $op=$run->{operation_progress}||{};my $w=$run->{worker_status}||{};
    ($stage_done,$stage_total,$unit)=(0,0,'steps');
    if (($op->{stage}||'') eq $stage && $op->{total}) {
     ($stage_done,$stage_total,$unit)=($op->{completed}||0,$op->{total},$op->{unit}||'steps');
    } elsif ($w->{total_steps}) {
     ($stage_done,$stage_total,$unit)=(($w->{current_step}||1)-1,$w->{total_steps},'patches');
     $stage_done=$stage_total if ($w->{status}||'') =~ /^(?:complete|completed|done)$/;
    }
    if ($stage_total>0) {
     $stage_done=0 if $stage_done<0;$stage_done=$stage_total if $stage_done>$stage_total;
     # Finishing a measurement pass still leaves verification/upload work.
     $done+=.95*$stage_done/$stage_total;
    }
   }
  }
 }
 $done=$total if ($run->{status}||'') =~ /^complete/;
 return {completed=>$done,total=>$total,stage_completed=>$stage_done,stage_total=>$stage_total,unit=>$unit};
}

# Timing compatibility is deliberately broader than calibration identity.
# Picture-mode labels, pinned controls and gamma targets must not prevent us
# learning approximate durations from the same signal path and workload.
# Never borrow another signal family's solver/profile or another device/meter.
sub timing_value {
 my ($value)=@_;
 return {map {$_=>timing_value($value->{$_})} keys %$value} if ref($value) eq 'HASH';
 return [map {timing_value($_)} @$value] if ref($value) eq 'ARRAY';
 return defined($value)?"$value":'';
}

sub timing_profile {
 my ($item,$stage,$device)=@_;
 my %p=map {$_=>timing_value($item->{$_})} qw(signal_format display_type ccss_override observer refresh_rate delay_ms patch_size low_light patch_insert patch_insert_time_enabled patch_insert_time_frequency_ms patch_insert_time_duration_ms patch_insert_time_level patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration_ms patch_insert_patch_level max_bpc signal_range color_format);
 $p{device_identity}=$item->{device_identity}||$device;
 $p{stage}=$stage;
 my $cal=$item->{calibration}||{};
 my @keys=$stage eq 'greyscale-done'
  ? qw(target_delta_e delta_e_formula dark_detail max_iterations headroom_max_iterations max_polish_iterations precision_polish_iterations)
  : $stage eq 'volume-done'
  ? qw(target_delta_e delta_e_formula method profile_source lattice_size solve_cube_size shadow_fix lattice_residuals)
  : ();
 # Copy before stringifying: interpolating the manifest's own scalar caches
 # a string form on it, and the appliance's JSON::PP 2.27 then writes the
 # value back as "17" instead of 17, which changed the job's plan hash.
 $p{calibration}={map {my $v=$cal->{$_};$_=>defined($v)?"$v":''} @keys};
 $p{series}=$item->{$stage eq 'pre-readings-done'?'pre_series':'post_series'}||[] if $stage=~/^(?:pre|post)-readings-done$/;
 return sha256_hex(JSON::PP->new->canonical->encode(\%p));
}

sub update {
 my ($run,$now,$history)=@_;
 my $preflight=($run->{active_stage}||'') eq 'queue-preflight';
 my $index=$preflight ? 0 : $run->{active_item};
 my $stage=$run->{active_stage}||'';
 my $worker=$run->{worker_status}||{};
 my $clock=$run->{worker_timing}||{};
 my $items=$run->{items}||[];
 # Recalculate immediately after queue edits, stage/pass changes or a resume.
 my $identity=JSON::PP->new->canonical->encode([$index,$stage,$run->{stage_started_at},$run->{resumed_at},$worker->{status},$worker->{current_step},$worker->{total_steps},$clock,($run->{preflight_result}||{})->{progress_done},
  [map {[profile($_),$_->{stages},$_->{status},$_->{checkpoint}]} @$items]]);
 my $old=$run->{time_estimate}||{};
 if (($run->{status}||'') ne 'running' || !defined($index) || $index!~/^\d+$/ || $index>=@$items) {
  delete $run->{time_estimate};return;
 }
 return if ($old->{identity}||'') eq $identity && $now-($old->{calculated_at}||0)<15;
 my $result={identity=>$identity,calculated_at=>$now,active_item=>0+$index,stage=>$stage,scope=>'unknown'};
 my (%durations,%compatible);
 for my $sample (@{$history||[]},@{samples($run)}) {
  push @{$durations{$sample->{profile}}{$sample->{stage}}},$sample->{seconds};
  push @{$compatible{$sample->{timing_profile}}},$sample->{seconds} if $sample->{timing_profile};
 }
 my $item=$items->[$index];
 my $approximate=0;
 my $live_stage_total;
 my $duration_for=sub {
  my ($job,$next)=@_;
  my $exact=median(@{$durations{profile($job,$item->{device_identity})}{$next}||[]});
  return $exact if defined($exact);
  my $similar=median(@{$compatible{timing_profile($job,$next,$item->{device_identity})}||[]});
  $similar=$live_stage_total if !defined($similar) && defined($live_stage_total) && $next eq $stage
   && timing_profile($job,$next,$item->{device_identity}) eq timing_profile($item,$stage);
  $approximate=1 if defined($similar);
  return $similar;
 };
 my $current;
 my $pass;
 if ($preflight) {
  my $p=$run->{preflight_result}||{};
  my $elapsed=$now-($p->{started_at}||$now);
  my $done=$p->{progress_done}||0;my $total=$p->{progress_total}||0;
  $current=$elapsed/$done*($total-$done) if $elapsed>=30 && $done>=2 && $total>$done;
 }
 # Iterative calibration is non-linear: this is deliberately a rough estimate
 # based on completed points, never a promise that each iteration costs alike.
 my $total=$worker->{total_steps}||0;
 my $done=($worker->{current_step}||0)-1;
 my $completed=$done-($clock->{start_step}||0);
 my $elapsed=$now-($clock->{started_at}||$now);
 if (($clock->{kind}||'') =~ /^(?:grey|series|3d|dv)$/ && ($clock->{stage}||'') eq $stage
     && ($clock->{started_at}||0)>=($run->{stage_started_at}||0) && ($clock->{started_at}||0)>=($run->{resumed_at}||0)
     && ($worker->{status}||'') eq 'running' && $elapsed>=120 && $completed>=3 && $done<$total) {
  my $pace=$elapsed/$completed;
  my @recent=grep {defined($_) && !ref($_) && /^\d+(?:\.\d+)?$/ && $_>0} @{$clock->{recent_point_seconds}||[]};
  # Near-black points include more samples/iterations. Do not project the
  # bright-point average across them once a slower recent pace is observed.
  my $recent=@recent>=3 ? median(@recent) : undef;
  $pace=$recent if defined($recent) && $recent>$pace;
  $pass=$pace*($total-$done);
  if ($stage eq 'greyscale-done') {$current=$pass;}
  elsif ($stage =~ /^(?:pre|post)-readings-done$/) {
   my $series=$item->{($stage eq 'pre-readings-done'?'pre':'post').'_series'}||[];
   # Saturation adds a white reference to the 24 colour patches.
   my %count=('greyscale-21'=>21,'colors-30'=>30,'saturations-24'=>25);
   my ($found,$extra,$unknown)=(0,0,0);
   for my $key (@$series) {
    if ($found) {defined($count{$key}) ? ($extra+=$count{$key}) : ($unknown=1);}
    $found=1 if $key eq ($clock->{series_key}||'');
   }
   $current=$pass+$extra*$pace if $found && !$unknown;
  }
 }
 my $same=$duration_for->($item,$stage);
 if (!defined($current) && defined($same)) {
  my $remaining=$same-($now-($run->{stage_started_at}||$now));
  $current=$remaining if $remaining>60;
 }
 $live_stage_total=$current+($now-($run->{stage_started_at}||$now)) if defined($pass) && defined($current);
 my ($batch,$unknown,$job_remaining,$job_unknown,$remaining_stages,$known_stages)=(0,0,0,0,0,0);
 if ($preflight) {
  $remaining_stages++;
  if (defined($current)) {$batch+=$current;$known_stages++;} else {$unknown++;}
 }
 my @jobs;
 for my $i ($run->{preflight_only} ? () : ($index..$#$items)) {
  my $job=$items->[$i];next if ($job->{status}||'') =~ /^complete/;
  my %done=map {($_->{name}=>1)} grep {($_->{status}||'') =~ /^(?:done|skipped)$/} @{$job->{checkpoints}||[]};
  my ($job_seconds,$missing,$known)=(0,0,0);
  for my $next (@{plan($job)}) {
   # An active stage may be repeating a checkpoint during recovery.
   next if $done{$next} && !($i==$index && $next eq $stage);
   my $duration=$i==$index && $next eq $stage ? $current : $duration_for->($job,$next);
   $remaining_stages++;
   if (defined($duration)) {$batch+=$duration;$job_seconds+=$duration;$known++;$known_stages++;} else {$unknown++;$missing++;}
  }
  ($job_remaining,$job_unknown)=($job_seconds,$missing) if $i==$index;
  push @jobs,{item=>0+$i,remaining_seconds=>int($job_seconds),unknown_stages=>$missing,known_stages=>$known};
 }
 # A profile pass has a measurable duration even before solve/upload history
 # exists. Include that known work without claiming the entire stage is timed.
 if (defined($pass) && !defined($current) && $pass>0) {$batch+=$pass;$job_remaining+=$pass;}
 $result->{jobs}=\@jobs;
 $result->{job_remaining_seconds}=int($job_remaining) if $job_remaining>0;
 $result->{job_unknown_stages}=$job_unknown;
 $result->{batch_known_seconds}=int($batch) if $batch>0;
 $result->{batch_unknown_stages}=$unknown;
 $result->{known_stages}=$known_stages;
 $result->{remaining_stages}=$remaining_stages;
 $result->{approximate_history}=$approximate?JSON::PP::true:JSON::PP::false;
 $result->{pass_remaining_seconds}=int($pass) if defined($pass) && $pass>0;
 $result->{stage_remaining_seconds}=int($current) if defined($current) && $current>0;
 if (!$unknown && $batch>0 && defined($current)) {$result->{scope}='batch';$result->{remaining_seconds}=int($batch);}
 elsif (defined($current) && $current>0) {$result->{scope}='stage';$result->{remaining_seconds}=int($current);}
 elsif (defined($pass) && $pass>0) {$result->{scope}='pass';$result->{remaining_seconds}=int($pass);}
 $run->{time_estimate}=$result;
}
1;
