#!/usr/bin/env bash
# strip_emoji.sh — example TTS text filter: removes actual emoji before synthesis.
#
# Reads text on stdin, writes filtered text to stdout. Wired in via
# TTS_TEXT_FILTER (see fish_tts_send.sh) -- not active unless an instance's
# config explicitly points at this file.
#
# Deliberately narrow: strips real emoji (the standard Unicode emoji blocks --
# pictographs, dingbats, flags, skin-tone/variation modifiers), not kaomoji
# like (´・ω・`) or unusual punctuation like ⟁ ◈ 𓂀. Those are ordinary letters
# and punctuation, not a well-defined Unicode range -- there's no reliable way
# to regex-detect "kaomoji vs. normal text" without real false-positive risk,
# so this doesn't attempt it.

set -uo pipefail

/usr/bin/python3 -c "
import sys, re

text = sys.stdin.read()

emoji_pattern = re.compile(
    '['
    '\U0001F300-\U0001FAFF'  # misc symbols, emoticons, transport, supplemental
    '\U00002600-\U000027BF'  # misc symbols and dingbats
    '\U0001F1E6-\U0001F1FF'  # regional indicator symbols (flag emoji)
    '\U0000FE0F'             # variation selector-16 (emoji presentation)
    '\U0000200D'             # zero-width joiner (compound emoji)
    ']+',
    flags=re.UNICODE,
)

filtered = emoji_pattern.sub('', text)
filtered = re.sub(r'[ \t]{2,}', ' ', filtered)   # collapse gaps left behind
filtered = re.sub(r'[ \t]+\n', '\n', filtered)   # trailing space before newline
sys.stdout.write(filtered)
"
