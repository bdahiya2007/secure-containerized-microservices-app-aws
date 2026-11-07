#!/usr/bin/env bash
# Request probe for the disaster recovery drills (docs/DR_Runbook.md). It sends GET <url>/health every 2 seconds and writes one
# CSV line per request, so the gap during a switchover or failover is measured from data, not guessed.
#
# Usage:   scripts/dr-probe.sh <url> [seconds] [output.csv]       e.g. scripts/dr-probe.sh https://products.example.com 900 probe.csv
#          scripts/dr-probe.sh --summary <output.csv>             print the totals and the longest run of failed requests
# Columns: UTC time, HTTP status (000 = no answer), response time in seconds, the IP address that answered.
#          The IP tells the Regions apart: compare it with each load balancer's addresses (dig +short <alb dns name>).
# It only sends GET requests to the URL you give it and changes nothing.
set -u

summary() {
  awk -F, '
    NR > 1 { total++
             if ($2 == "200") { ok++; if (run > longest) longest = run; run = 0 }
             else             { bad++; if (run == 0) first = $1; run++; last = $1 } }
    END    { if (run > longest) longest = run
             printf "requests: %d   200: %d   not 200: %d\n", total, ok, bad
             printf "longest run of failed requests: %d (about %d seconds at 2 s apart)\n", longest, longest * 2 }
  ' "$1"
}

if [ "${1:-}" = "--summary" ]; then
  [ -f "${2:-}" ] || { echo "usage: $0 --summary <output.csv>"; exit 1; }
  summary "$2"; exit 0
fi

URL=${1:-}; SECONDS_TOTAL=${2:-600}; OUT=${3:-dr-probe.csv}
[ -n "$URL" ] || { echo "usage: $0 <url> [seconds] [output.csv]"; exit 1; }
case "$URL" in http://*|https://*) ;; *) echo "the URL must start with http:// or https://"; exit 1 ;; esac

echo "time_utc,status,seconds,remote_ip" > "$OUT"
end=$((SECONDS + SECONDS_TOTAL))
echo "probing $URL/health for ${SECONDS_TOTAL}s into $OUT (Ctrl-C to stop; --summary prints the totals)"
while [ "$SECONDS" -lt "$end" ]; do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  result=$(curl -s -m 5 -o /dev/null -w '%{http_code},%{time_total},%{remote_ip}' "$URL/health" 2>/dev/null || true)
  [ -n "$result" ] || result="000,5,"
  echo "$now,$result" >> "$OUT"
  sleep 2
done
summary "$OUT"
