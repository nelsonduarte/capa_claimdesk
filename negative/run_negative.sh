#!/usr/bin/env bash
# Negative-case runner: the executable proof of capa_claimdesk's
# compile-time guarantees.
#
# Each program under negative/ DELIBERATELY violates one guarantee
# (typestate protocol, linearity, information flow, constant time).
# A correct compiler must REJECT every one. This runner runs
# `capa --check` on each and asserts:
#
#   1. a NON-ZERO exit (the program does not compile), and
#   2. that the rejection message contains the expected phrase
#      (so the program fails for the RIGHT reason, not an unrelated
#      typo or a missing import).
#
# If any case COMPILES (exit 0), that is a soundness hole in the
# guarantee and the runner fails loudly with SOUNDNESS HOLE.
#
# The programs import capa_claimdesk.* by package path, so the runner
# points CAPA_PATH at the parent of this repository, exactly like the
# main program (see the project README).
#
# Usage:  bash negative/run_negative.sh
# Exit:   0 iff every case was rejected for the expected reason.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
export CAPA_PATH="$(cd "$root/.." && pwd)"

# case-file  ::  expected substring in the rejection message
cases=(
  "typestate_skip_state.capa::expects Claim[UnderReview], got Claim[Draft]"
  "typestate_use_after.capa::consumed earlier and cannot be used again"
  "linear_double_spend.capa::consumed earlier and cannot be used again"
  "linear_drop.capa::dropped without being consumed"
  "ifc_leak_field.capa::a @secret value reaches Stdio.println"
  "ifc_leak_destructure.capa::a @secret value reaches Stdio.println"
  "ct_secret_branch.capa::constant-time violation"
)

pass=0
fail=0

for entry in "${cases[@]}"; do
  file="${entry%%::*}"
  want="${entry##*::}"
  path="$here/$file"

  out="$(capa --check "$path" 2>&1)"
  code=$?

  if [ "$code" -eq 0 ]; then
    echo "SOUNDNESS HOLE: $file COMPILED but must be rejected (guarantee bypassed)"
    fail=$((fail + 1))
    continue
  fi

  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "ok   $file  (rejected: \"$want\")"
    pass=$((pass + 1))
  else
    echo "WRONG REASON: $file was rejected (exit $code) but not for the expected reason"
    echo "  expected substring: $want"
    echo "  actual message:"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
done

echo "------------------------------------------------------------"
echo "negative cases: $pass rejected as expected, $fail unexpected"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: not every guarantee was enforced as expected."
  exit 1
fi

echo "PASSED: every guarantee is enforced by the compiler."
exit 0
