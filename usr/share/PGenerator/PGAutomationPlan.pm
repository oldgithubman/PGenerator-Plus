package PGAutomationPlan;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use PGAutomation ();

# Exclude evidence and derived device observations, not request fields. New
# execution options therefore invalidate the plan by default rather than
# accidentally falling outside a hand-maintained allowlist.
# JSON round trips through the daemon, the browser and older JSON::PP builds
# do not preserve whether a value was a number or a numeric string. Execution
# intent must not change with that, so numeric scalars hash by their value.
sub _normalize_scalars {
    my ($value) = @_;
    if (ref($value) eq 'HASH') { $value->{$_} = _normalize_scalars($value->{$_}) for keys %$value; return $value; }
    if (ref($value) eq 'ARRAY') { $value->[$_] = _normalize_scalars($value->[$_]) for 0..$#$value; return $value; }
    return $value if ref($value) || !defined($value);
    return $value =~ /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/ ? ''.(0+$value) : $value;
}

sub intent_hash {
    my ($source) = @_;
    my $item = _normalize_scalars(PGAutomation::clone($source) || {});
    # The hash answers one question: is this the job the operator queued? So it
    # drops per-run bookkeeping and everything read from the TV. "id" is minted
    # fresh for every run, and lg_generation, apply_all_supported and
    # panel_protection_supported are added by a readiness pass that talked to
    # the TV, so a static start never has them. Leaving any of them in made two
    # runs of the same queue hash differently by construction, which is why the
    # readiness result a start is meant to reuse never matched (P13). A TV that
    # changed is caught by identity_matches (input, capability profile, device
    # identity), not by this hash.
    delete @$item{qw(item_number id status checkpoints checkpoint checkpoint_status active_stage stage_started_at
        failure warnings readiness settings_recovery profile_baseline_needs_restore recheck fault_injected
        hazard_restore hazards hazard_capabilities drift_recovery_attempts drift_recovery_pending
        setting_contracts generation_profile capability_profile calibration_settings_recipe device_identity
        best_available_settings best_available_write_ack supported_picture_keys tv_input preflight_contract
        worker_status started_at completed_at series calibration_results panel-light apply-all quality_result
        lg_generation apply_all_supported panel_protection_supported)};
    return sha256_hex(PGAutomation::encode_json($item));
}

sub contract {
    my ($item) = @_;
    return {intent_hash=>intent_hash($item),tv_input=>$item->{tv_input}||'',
        profile_hash=>$item->{capability_profile}{hash}||'',device_identity=>PGAutomation::clone($item->{device_identity}||{})};
}

sub identity_matches {
    my ($item, $contract) = @_;
    return 0 if ref($contract) ne 'HASH';
    return 0 if ($contract->{tv_input}||'') ne ($item->{tv_input}||'')
        || ($contract->{profile_hash}||'') ne ($item->{capability_profile}{hash}||'');
    return PGAutomation::encode_json($contract->{device_identity}||{}) eq PGAutomation::encode_json($item->{device_identity}||{});
}

sub matches {
    my ($item, $contract) = @_;
    return 0 if ref($contract) ne 'HASH' || ($contract->{intent_hash}||'') ne intent_hash($item);
    return identity_matches($item, $contract);
}

# Job start re-runs readiness after selecting the job's signal and picture
# mode. A contract frozen by a full preflight saw that same mode, so the
# merged result must still match exactly. A limited preflight (a TV whose
# picture mode cannot be read) never selected the mode, so its readiness
# output legitimately differs once the mode is active (P24). For those the
# queue intent is compared as it stood before the job's own readiness merge;
# the TV input, compatibility profile and device identity must still match.
sub job_start_matches {
    my ($planned_intent_hash, $merged_item, $contract) = @_;
    return 0 if ref($contract) ne 'HASH';
    return matches($merged_item, $contract) if !$contract->{limited};
    return 0 if ($contract->{intent_hash}||'') ne ($planned_intent_hash||'');
    return identity_matches($merged_item, $contract);
}
1;
