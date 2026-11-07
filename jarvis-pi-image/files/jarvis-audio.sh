#!/bin/bash
# Before Jarvis starts: finds the USB speakerphone (Jabra etc.) and makes it the default microphone and speaker.
MIC_CARD=$(arecord -l 2>/dev/null | awk '/^card [0-9]+:/ && tolower($0) ~ /usb|jabra|respeaker|emeet|anker|seeed|audio/ {gsub(":","",$2); print $2; exit}')
[ -z "$MIC_CARD" ] && MIC_CARD=$(arecord -l 2>/dev/null | awk '/^card [0-9]+:/ {gsub(":","",$2); print $2; exit}')
if [ -z "$MIC_CARD" ]; then
  echo "No microphone yet: plug in the USB speakerphone. Trying again shortly."
  exit 1
fi
# Play through the same USB device when it has a speaker, else the Pi's headphone socket.
if aplay -l 2>/dev/null | grep -q "^card $MIC_CARD:"; then SPK_CARD=$MIC_CARD; else SPK_CARD=0; fi
cat > /etc/asound.conf <<ASOUND
pcm.!default {
  type asym
  playback.pcm "plug:hw:$SPK_CARD"
  capture.pcm "plug:hw:$MIC_CARD"
}
ctl.!default {
  type hw
  card $SPK_CARD
}
ASOUND
# Sensible starting levels, only the first time (so alsamixer changes stick).
if [ ! -f /var/lib/jarvis-voice/levels-set ]; then
  for control in Mic Capture; do amixer -q -c "$MIC_CARD" sset "$control" 85% cap 2>/dev/null || true; done
  for control in Speaker PCM Master Headphone; do amixer -q -c "$SPK_CARD" sset "$control" 85% unmute 2>/dev/null || true; done
  mkdir -p /var/lib/jarvis-voice && touch /var/lib/jarvis-voice/levels-set
  alsactl store 2>/dev/null || true
fi
echo "Microphone: card $MIC_CARD, speaker: card $SPK_CARD"
