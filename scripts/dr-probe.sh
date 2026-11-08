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
  # The span of an outage is measured from the timestamps (first failed request to the first success after it), not from the
  # number of failed requests: a request that times out takes 5 seconds, not the 2 seconds between requests.
  python3 -I - "$1" <<'PY'
import csv, sys, datetime as dt
rows = list(csv.reader(open(sys.argv[1])))[1:]
t = lambda s: dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
ok = sum(1 for r in rows if r[1] == "200")
print(f"requests: {len(rows)}   200: {ok}   not 200: {len(rows) - ok}")
best = (0, None, None, 0)  # span in seconds, first failure, first success after, failed requests in the run
i = 0
while i < len(rows):
    if rows[i][1] != "200":
        j = i
        while j < len(rows) and rows[j][1] != "200":
            j += 1
        end = rows[j][0] if j < len(rows) else rows[-1][0]
        span = (t(end) - t(rows[i][0])).total_seconds()
        if span > best[0]:
            best = (span, rows[i][0], end, j - i)
        i = j
    else:
        i += 1
if best[1]:
    print(f"longest outage: {best[0]:.0f} s, from {best[1]} to {best[2]} ({best[3]} failed requests; by timestamps, not by count)")
else:
    print("no failed requests")
PY
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
