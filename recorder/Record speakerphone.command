#!/bin/bash
# Double-click: records a call made with the phone on speakerphone next to the Mac.
# Same recorder, microphone only (see README, "Speakerphone calls").
REC_SPEAKERPHONE=1 exec "$(cd "$(dirname "$0")" && pwd)/Record call.command"
