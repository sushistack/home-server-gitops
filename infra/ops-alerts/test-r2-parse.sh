#!/bin/sh
# Self-check for the R2 freshness/rotation jq filter in configmap.yaml (Story 5.8 AC2).
# The date-parse + group-by is the only fragile bit (the rest is live-observable via kubectl logs).
# This feeds a fixture through the SAME filter and asserts the STALE/OLD verdicts.
#
# ponytail: the filter is duplicated here (~8 lines) rather than mounted from one file — drift risk is
#   low and a shared-mount would mean a second ConfigMap key just for a test. Keep in sync with
#   configmap.yaml if you touch the filter. Run: sh infra/ops-alerts/test-r2-parse.sh
set -eu

# Fixed "now" so the test is deterministic: 2026-06-20T00:00:00Z = 1781913600
NOW=1781913600
STALE=$(( 13 * 3600 ))     # 13h
STALED=$(( 27 * 3600 ))    # 27h — daily-cadence exception (R2_DAILY_SVCS)
DAILY="anytype anytype-heart"
RET=$(( 35 * 86400 ))      # 35d

# Fixture: ntfy = fresh+rotated-ok; navidrome = STALE (newest 20h old); miniflux = OLD (oldest 40d);
# anytype = daily-cadence, 20h old => under the 27h exception, must NOT alert (the c1c11c1 false-positive).
# (ntfy newest 1h ago; navidrome newest 20h ago; miniflux newest 2h ago but oldest 40d ago; anytype 20h ago)
FIXTURE='[
  {"Path":"ntfy/ntfy-a.tar.gz","ModTime":"2026-06-19T23:00:00.500Z"},
  {"Path":"ntfy/ntfy-b.tar.gz","ModTime":"2026-06-10T00:00:00Z"},
  {"Path":"navidrome/navidrome-a.tar.gz","ModTime":"2026-06-19T04:00:00Z"},
  {"Path":"miniflux/miniflux-a.tar.gz","ModTime":"2026-06-19T22:00:00Z"},
  {"Path":"miniflux/miniflux-old.tar.gz","ModTime":"2026-05-11T00:00:00Z"},
  {"Path":"anytype/anytype-a.tar.gz","ModTime":"2026-06-19T04:00:00Z"},
  {"Path":"toplevelfile.txt","ModTime":"2026-06-19T23:59:00Z"}
]'

OUT=$(printf '%s' "$FIXTURE" | jq -r --argjson now "$NOW" --argjson stale "$STALE" --argjson staled "$STALED" --arg daily "$DAILY" --argjson ret "$RET" '
    def epoch: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
    ($daily | split(" ")) as $dl
    | [ .[] | select(.Path | contains("/")) | {svc: (.Path|split("/")[0]), t: (.ModTime|epoch)} ]
    | group_by(.svc)[]
    | { svc: .[0].svc, newest: (map(.t)|max), oldest: (map(.t)|min) }
    | (.svc) as $s | (if ($dl | index($s)) then $staled else $stale end) as $th
    | ( if ($now - .newest) > $th then "STALE\t\(.svc)\t\((($now-.newest)/3600)|floor)" else empty end ),
      ( if ($now - .oldest) > $ret  then "OLD\t\(.svc)\t\((($now-.oldest)/86400)|floor)"  else empty end )')

echo "--- filter output ---"; echo "$OUT"; echo "---------------------"

fail=0
echo "$OUT" | grep -q "^STALE	navidrome	20$" || { echo "FAIL: navidrome should be STALE (20h)"; fail=1; }
echo "$OUT" | grep -q "^OLD	miniflux	40$"     || { echo "FAIL: miniflux should be OLD (40d)"; fail=1; }
echo "$OUT" | grep -q "ntfy"                     && { echo "FAIL: ntfy is healthy, must not alert"; fail=1; } || true
echo "$OUT" | grep -q "anytype"                  && { echo "FAIL: anytype is daily-cadence (20h<27h), must not alert"; fail=1; } || true
echo "$OUT" | grep -q "toplevelfile"             && { echo "FAIL: top-level non-prefixed file must be ignored"; fail=1; } || true

[ "$fail" -eq 0 ] && echo "PASS: R2 parse self-check" || { echo "test-r2-parse FAILED"; exit 1; }
