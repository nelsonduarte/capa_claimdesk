#!/bin/sh
# Regenerate the governance / SBOM pack for capa_claimdesk.
#
# Every artifact under governance/ is emitted by the Capa compiler from
# main.capa, so the pack is byte-for-byte reproducible: an auditor can
# rerun this script and diff its output against what ships in the repo
# and get ZERO differences, not just "stable modulo timestamps".
#
# Determinism comes from SOURCE_DATE_EPOCH (the reproducible-builds.org
# convention). The compiler's --cyclonedx / --spdx / --vex / --provenance
# emitters stamp their build time from this instant instead of the wall
# clock, so the timestamp fields (timestamp / created / annotationDate /
# startedOn / finishedOn) are pinned along with everything else.
#
# The epoch is a FIXED value versioned in governance/SOURCE_DATE_EPOCH,
# NOT derived from the commit/HEAD time. That matters: the pack is
# generated and committed in one go, so deriving the epoch from HEAD
# would be circular. An auditor who checks out the pack's commit would
# see a different HEAD time than the one used to build it, and the diff
# would fail. A constant in the repo makes the build independent of when
# or where it runs.
#
# capa_claimdesk imports its own modules by package path
# (capa_claimdesk.money, capa_claimdesk.engine, ...), so the compiler
# must resolve the package from the PARENT of this repository. That is
# the same CAPA_PATH the main program and the negative-case runner use
# (see the project README). This script computes it from its own
# location so it works regardless of the caller's working directory.
#
# To bump the epoch for a new release, derive it from a chosen UTC date
# rather than hand-typing a number (which risks a wrong value):
#
#     date -u -d 2027-01-01 +%s > governance/SOURCE_DATE_EPOCH   # GNU date
#     # BSD/macOS: date -u -j -f %Y-%m-%d 2027-01-01 +%s
#
# then rerun this script and commit the regenerated pack in the same
# commit.
set -e

# Resolve paths relative to this script, not the caller's cwd.
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
parent="$(cd "$root/.." && pwd)"

# The package root that holds capa_claimdesk/ must be on CAPA_PATH so the
# self-imports resolve. Preserve any CAPA_PATH the caller already set.
if [ -n "${CAPA_PATH:-}" ]; then
    CAPA_PATH="$parent:$CAPA_PATH"
else
    CAPA_PATH="$parent"
fi
export CAPA_PATH

# Strip any stray carriage return so the value is a clean decimal. The
# compiler's SOURCE_DATE_EPOCH parser actually TOLERATES a trailing CR,
# so this is defence in depth to keep the epoch file clean, not because
# the parser rejects it. With the eol=lf pin in .gitattributes a CRLF
# checkout cannot reach this file anyway.
SOURCE_DATE_EPOCH="$(tr -d '\r' < "$here/SOURCE_DATE_EPOCH")"
export SOURCE_DATE_EPOCH

main="$root/main.capa"

capa --manifest   "$main" > "$here/manifest.json"
capa --cyclonedx  "$main" > "$here/sbom.cyclonedx.json"
capa --spdx       "$main" > "$here/sbom.spdx.json"
capa --vex        "$main" > "$here/vex.cyclonedx.json"
capa --provenance "$main" > "$here/provenance.slsa.json"

echo "governance pack regenerated under governance/ (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
