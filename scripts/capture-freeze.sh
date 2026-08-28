#!/usr/bin/env bash
set -euo pipefail
pid=$(pgrep -x Warren || pgrep -x WarrenApp || echo "")
if [[ -z "$pid" ]]; then
  echo "Warren not running; trying to find via ps..."
  pid=$(ps aux | grep -i "[W]arren" | awk '{print $2}' | head -1)
fi
if [[ -z "$pid" ]]; then
  echo "Cannot find Warren PID"
  exit 1
fi
echo "Capturing diagnostics for PID $pid..."
outdir="$HOME/Library/Logs/Warren"
mkdir -p "$outdir"
ts=$(date +%Y%m%d-%H%M%S)
echo "Sample 3x 2s..."
for i in 1 2 3; do sample "$pid" 2 -f "$outdir/sample-$ts-$i.txt" 2>&1 | head -5; done
echo "Spindump 10s..."
sudo spindump "$pid" 10 -file "$outdir/spindump-$ts.txt" 2>&1 | tail -5 || echo "spindump requires sudo, try: sudo spindump $pid 10 -file $outdir/spindump.txt"
echo "Logs..."
cp "$outdir/terminal-diagnostics.log" "$outdir/terminal-diagnostics-$ts.log" 2>/dev/null || true
cp "$HOME/.warren/headless.log" "$outdir/headless-$ts.log" 2>/dev/null || true
ls -lh "$outdir"/{sample,spindump,terminal-diagnostics,headless}-$ts.* 2>/dev/null || true
echo "Done. Attach $outdir/*-$ts.* when reporting."
