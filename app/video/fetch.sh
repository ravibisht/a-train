#!/bin/bash
# fetch.sh — download the dashboard background clip if it is missing. Called by build.sh; safe to re-run.
# The clip is "A-Train Status Greenscreen" by The Mining Meteor (YouTube 3nxXwfkTkuU); the creator asks for
# credit, which the dashboard footer shows. It is not stored in this repository: each build downloads it.
# Needs yt-dlp (brew install yt-dlp). Without it the app simply runs without a background video.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/atrain.mp4"
[[ -s "$OUT" ]] && exit 0
if [[ "${ATRAIN_NO_VIDEO:-0}" == "1" ]]; then echo "- background video skipped (ATRAIN_NO_VIDEO=1)"; exit 0; fi
YTDLP="$(command -v yt-dlp || true)"
if [[ -z "$YTDLP" ]]; then
  echo "- background video not downloaded: yt-dlp missing (brew install yt-dlp), app runs without it"
  exit 0
fi
echo "- downloading the background clip (credit: The Mining Meteor, YouTube 3nxXwfkTkuU)"
"$YTDLP" --quiet --no-warnings -f "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]/b" \
  --merge-output-format mp4 -o "$OUT" "https://www.youtube.com/watch?v=3nxXwfkTkuU" \
  || { rm -f "$OUT"; echo "- download failed; building without the background video"; exit 0; }
echo "- background clip saved to $OUT ($(du -h "$OUT" | cut -f1))"
