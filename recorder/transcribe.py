#!/usr/bin/env python3
"""Transcribes the two tracks of a recording and merges them into one labelled transcript.

Usage: transcribe.py <session-folder> [language]
                     [--speakerphone] [--keep-echo] [--keep-hallucinations]
       (Italian aliases: --viva-voce, --tieni-eco, --tieni-inventate)
Writes: <session-folder>/transcript.md  (and prints its path)

Two tracks: mic.wav is YOU (the person recording), system.wav is OTHERS (everything the
Mac plays: the other participants). Telling who speaks comes for free, no diarization.

With --speakerphone there is a single track, mic.wav, holding both voices (a phone on
speakerphone next to the Mac): no YOU/OTHERS labels; a new paragraph at every pause
(the note works out who said what from context).

Why the WAV is not simply fed to whisper: each track is silent half of the time (while
the other side talks). Whisper swallows long silences into a single segment and returns
useless timestamps, so the turn order between the tracks would break. Silences are cut
out first here, and the timestamps mapped back onto the original.
"""
import array
import json
import os
import re
import subprocess
import sys
import wave
from difflib import SequenceMatcher

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crt_config  # noqa: E402

CFG = crt_config.load()
UI = CFG["CRT_UI_LANG"]
MODEL_DIR = CFG["CRT_MODEL_DIR"]
# (file name, minimum plausible size): smaller means a truncated download
MODELS = [("ggml-large-v3-turbo.bin", 1_500_000_000),
          ("ggml-medium.bin",         1_400_000_000),
          ("ggml-small.bin",            450_000_000)]

WINDOW_MS     = 20     # granularity of the energy analysis
MARGIN_S      = 0.30   # how much to keep before and after each phrase
JOIN_S        = 0.60   # gaps shorter than this are not cut
MIN_REGION_S  = 0.40   # shorter than this is a noise, not a phrase
SILENT_DB     = -55    # a track whose peak is below this is silent
REL_THRESHOLD = 0.04   # speech = above 4% of the track's peak

# On speakerphone the voice from the phone is much quieter than yours: at 4% of the
# peak it got lost. So the quiet parts are raised first, and only true silence is cut.
SPEAKERPHONE_FILTER = "highpass=f=100,dynaudnorm=f=150:g=15:m=20:p=0.9:t=0.002"
REL_THRESHOLD_SPEAKERPHONE = 0.01
PAUSE_SPEAKERPHONE_S = 0.4   # a pause this long between phrases is a likely change of voice

LABELS = {"en": ("YOU", "OTHERS"), "it": ("TU", "ALTRI")}

MODEL = None
SPEAKERPHONE = False


def t(en, it):
    return it if UI == "it" else en


def say(msg):
    print("  " + msg, file=sys.stderr)


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def pick_model():
    for name, minimum in MODELS:
        path = os.path.join(MODEL_DIR, name)
        if not os.path.exists(path):
            continue
        size = os.path.getsize(path)
        if size < minimum:
            say(t(f"⚠️  {name} is incomplete ({size/1e9:.2f} GB): skipping it",
                  f"⚠️  {name} è incompleto ({size/1e9:.2f} GB): lo salto"))
            continue
        return path
    return None


def peak_db(wav):
    r = sh(["ffmpeg", "-hide_banner", "-i", wav, "-af", "volumedetect", "-f", "null", "-"])
    m = re.search(r"max_volume:\s*(-?[\d.]+) dB", r.stderr)
    return float(m.group(1)) if m else -99.0


def to_16k_mono(source, destination):
    filt = ["-af", SPEAKERPHONE_FILTER] if SPEAKERPHONE else []
    r = sh(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", source] + filt + ["-ar", "16000", "-ac", "1", destination])
    return r.returncode == 0


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1
        sr = w.getframerate()
        data = array.array("h")
        data.frombytes(w.readframes(w.getnframes()))
    return sr, data


def speech_regions(sr, samples):
    """Returns [(start_s, end_s)] of the parts where someone speaks."""
    step = int(sr * WINDOW_MS / 1000)
    if step == 0 or len(samples) < step:
        return []

    energies = []
    for i in range(0, len(samples) - step, step):
        total = 0
        for v in samples[i:i + step]:
            total += v * v
        energies.append((total / step) ** 0.5)

    if not energies:
        return []

    # adaptive threshold: the background noise is the 20th percentile, voice is well above
    ordered = sorted(energies)
    floor = ordered[int(len(ordered) * 0.20)]
    top = ordered[-1]
    rel = REL_THRESHOLD_SPEAKERPHONE if SPEAKERPHONE else REL_THRESHOLD
    threshold = max(floor * 4.0, top * rel, 60.0)

    regions, inside, start = [], False, 0
    for idx, e in enumerate(energies):
        tt = idx * step / sr
        if e > threshold and not inside:
            inside, start = True, tt
        elif e <= threshold and inside:
            inside = False
            regions.append((start, tt))
    if inside:
        regions.append((start, len(energies) * step / sr))

    # margins, joining short gaps, dropping fragments
    total_s = len(samples) / sr
    widened = [(max(0, a - MARGIN_S), min(total_s, b + MARGIN_S)) for a, b in regions]
    joined = []
    for a, b in widened:
        if joined and a - joined[-1][1] < JOIN_S:
            joined[-1] = (joined[-1][0], b)
        else:
            joined.append((a, b))
    return [(a, b) for a, b in joined if b - a >= MIN_REGION_S]


def write_regions(sr, samples, regions, base):
    """One file per spoken stretch. Whisper takes them all in one call, and each file
    has a known start: so the timestamps stay exact."""
    files_and_starts = []
    for n, (a, b) in enumerate(regions):
        path = f"{base}-{n:03d}.wav"
        with wave.open(path, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
            w.writeframes(samples[int(a * sr):int(b * sr)].tobytes())
        files_and_starts.append((path, a))
    return files_and_starts


def threads():
    if CFG["CRT_WHISPER_THREADS"].isdigit():
        return CFG["CRT_WHISPER_THREADS"]
    return str(min(8, os.cpu_count() or 4))


def detect_language(sr, samples, regions, base):
    """With language 'auto', short stretches ('yes', 'ok') are easily mistaken for another
    language. So the language is detected once, on the longest stretches (up to ~30 s),
    and then used for every stretch."""
    longest = sorted(regions, key=lambda r: r[1] - r[0], reverse=True)
    chosen, total = [], 0.0
    for a, b in longest:
        chosen.append((a, b))
        total += b - a
        if total >= 30:
            break
    chosen.sort()
    path = base + "-langprobe.wav"
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        for a, b in chosen:
            w.writeframes(samples[int(a * sr):int(b * sr)].tobytes())
    r = sh(["whisper-cli", "-m", MODEL, "-l", "auto", "-dl", "-t", threads(), path])  # no -np: the result is a log line
    try:
        os.remove(path)
    except OSError:
        pass
    m = re.search(r"auto-detected language:\s*([a-z]{2,3})", r.stderr + r.stdout)
    return m.group(1) if m else None


def whisper(files_and_starts, language):
    """One call for all stretches: the model loads once."""
    if not files_and_starts:
        return []
    r = sh(["whisper-cli", "-m", MODEL, "-l", language, "-oj", "-np", "-t", threads()]
           + [path for path, _ in files_and_starts])
    out = []
    for n, (path, start) in enumerate(files_and_starts):
        js = path + ".json"
        if not os.path.exists(js):
            say(t(f"whisper produced no output for {os.path.basename(path)}",
                  f"whisper non ha prodotto output per {os.path.basename(path)}"))
            say((r.stderr or r.stdout)[-300:])
            continue
        with open(js, encoding="utf-8", errors="replace") as f:
            data = json.load(f)
        for seg in data.get("transcription", []):
            text = seg.get("text", "").strip()
            if text and not text.startswith("["):
                out.append((start + seg["offsets"]["from"] / 1000.0,
                            start + seg["offsets"]["to"] / 1000.0, text, n))
    return out


ECHO_WINDOW_S = 8.0     # how far to look for the original phrase
ECHO_SIMILARITY = 0.55  # above this similarity it is the same phrase
ECHO_MIN_CHARS = 22     # shorter than this, echo and a real "yes, right" can't be told apart


def normalize(text):
    text = text.lower()
    text = re.sub(r"[^\w ]", " ", text)
    return re.sub(r"\s+", " ", text.replace("_", " ")).strip()


def remove_echo(segments, you, others):
    """With speakers on, the microphone hears the others again and the same phrase ends up
    on both tracks. YOU lines that are the leftover of a nearby OTHERS phrase are dropped."""
    theirs = [(tt, normalize(x)) for tt, e, x in segments if e == others]
    if not theirs:
        return segments, 0
    kept, dropped = [], 0
    for tt, label, text in segments:
        if label == you and len(text) >= ECHO_MIN_CHARS:
            n = normalize(text)
            if any(abs(t2 - tt) <= ECHO_WINDOW_S
                   and SequenceMatcher(None, n, n2).ratio() >= ECHO_SIMILARITY
                   for t2, n2 in theirs):
                dropped += 1
                continue
        kept.append((tt, label, text))
    return kept, dropped


# Phrases whisper makes up on sounds without words (the check "tink", a notification,
# silence): it learned them from video subtitles. In real calls there were dozens, almost
# all on the OTHERS track.
# Subtitle credits and channel outros are removed wherever they appear...
INVENTED_ANYWHERE = re.compile(
    r"(autore dei )?sottotitoli( e revisione)? (a cura di|creati da(lla comunità)?) [\w.]+"
    r"|\bqtss\b|amara\.org|iscriviti al canale"
    r"|(subtitles|captions)( are)? (by|from) (the )?[\w.]+( community)?|castingwords"
    r"|thanks? (you )?(so much )?for watching( this video)?"
    r"|please subscribe|like and subscribe|subscribe to (my|our|the) channel"
    r"|[♪♫]+", re.I)
# ...courtesy formulas only when they are the whole segment: if someone really said just
# that, losing it takes nothing away from the note.
INVENTED_ALONE = {
    # Italian
    "grazie", "grazie a tutti", "grazie mille", "grazie a voi", "grazie per l attenzione",
    "grazie per la visione", "buona visione", "alla prossima", "ciao a tutti",
    # English
    "thank you", "thank you very much", "thank you so much", "thanks", "thanks everyone",
    "thank you for watching", "thanks for watching", "thank you for listening",
    "thanks for listening", "see you next time", "see you in the next video",
    "bye", "bye bye", "you",
}


def remove_invented(segments):
    """Drops the phrases whisper invents on noises. Returns (segments, how many dropped)."""
    kept, dropped = [], 0
    strip = " .,;:!?-–—"
    for tt, label, text in segments:
        cleaned = INVENTED_ANYWHERE.sub("", text).strip(strip)
        if not normalize(cleaned) or normalize(cleaned) in INVENTED_ALONE:
            dropped += 1
            continue
        kept.append((tt, label, cleaned if cleaned != text.strip(strip) else text))
    return kept, dropped


def mmss(s):
    return f"{int(s)//60:02d}:{int(s)%60:02d}"


def has(*flags):
    return any(f in sys.argv for f in flags)


def main():
    global MODEL, SPEAKERPHONE
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not positional:
        sys.exit("usage: transcribe.py <session-folder> [language] [--speakerphone] "
                 "[--keep-echo] [--keep-hallucinations]")
    d = positional[0]
    language = (positional[1] if len(positional) > 1 else CFG["CRT_LANG"]) or "auto"
    SPEAKERPHONE = has("--speakerphone", "--viva-voce")
    keep_echo = has("--keep-echo", "--tieni-eco")
    keep_invented = has("--keep-hallucinations", "--tieni-inventate")

    MODEL = pick_model()
    if not MODEL:
        sys.exit(t(f"no usable whisper model in {MODEL_DIR} (run get-model.sh)",
                   f"nessun modello whisper utilizzabile in {MODEL_DIR} (lancia get-model.sh)"))
    say(t("model: ", "modello: ") + os.path.basename(MODEL))

    # labels follow the language of the call when known, else the language of the messages
    label_lang = language if language in LABELS else ("it" if UI == "it" else "en")
    you, others = LABELS[label_lang]

    segments, found = [], False
    tracks = [("VOICES", "mic.wav")] if SPEAKERPHONE else [(others, "system.wav"), (you, "mic.wav")]
    prepared = []
    for label, name in tracks:
        wav = os.path.join(d, name)
        if not os.path.exists(wav) or os.path.getsize(wav) < 1000:
            say(t(f"{label}: no track", f"{label}: traccia assente"))
            continue
        peak = peak_db(wav)
        if peak < SILENT_DB:
            say(t(f"{label}: silent track (peak {peak:.0f} dB), skipping",
                  f"{label}: traccia muta (picco {peak:.0f} dB), salto"))
            continue
        base = os.path.join(d, "voices" if SPEAKERPHONE else ("you" if label == you else "others"))
        full = base + "-16k.wav"
        if not to_16k_mono(wav, full):
            say(t(f"{label}: conversion failed", f"{label}: conversione fallita"))
            continue
        sr, samples = read_wav(full)
        regions = speech_regions(sr, samples)
        if not regions:
            say(t(f"{label}: no speech detected", f"{label}: nessun parlato rilevato"))
            continue
        prepared.append((label, base, sr, samples, regions))

    if language == "auto" and prepared:
        # detect on the track with the most speech
        label, base, sr, samples, regions = max(
            prepared, key=lambda p: sum(b - a for a, b in p[4]))
        detected = detect_language(sr, samples, regions, base)
        if detected:
            language = detected
            say(t(f"language detected: {language}", f"lingua riconosciuta: {language}"))
            if language in LABELS and not SPEAKERPHONE and LABELS[language] != (you, others):
                new_you, new_others = LABELS[language]
                prepared = [(new_you if p[0] == you else new_others,) + p[1:] for p in prepared]
                you, others = new_you, new_others
        else:
            say(t("language not detected: each stretch is detected on its own",
                  "lingua non riconosciuta: ogni tratto la riconosce da sé"))

    for label, base, sr, samples, regions in prepared:
        spoken = sum(b - a for a, b in regions)
        total = len(samples) / sr
        say(t(f"{label}: {total:.0f}s in total, {spoken:.0f}s of speech in "
              f"{len(regions)} stretches — transcribing…",
              f"{label}: {total:.0f}s totali, {spoken:.0f}s di parlato in "
              f"{len(regions)} tratti — trascrivo…"))
        found = True
        pieces = write_regions(sr, samples, regions, base)
        paragraph, prev_end, prev_piece = 0, None, None
        for tt, end, text, n in whisper(pieces, language):
            if SPEAKERPHONE:
                # the "label" becomes the paragraph: a new one at every pause
                if prev_end is not None and (n != prev_piece or tt - prev_end >= PAUSE_SPEAKERPHONE_S):
                    paragraph += 1
                prev_end, prev_piece = end, n
                segments.append((tt, f"{label}{paragraph}", text))
            else:
                segments.append((tt, label, text))

    if not found:
        sys.exit(t("no track with speech: nothing to transcribe",
                   "nessuna traccia con parlato: non c'è niente da trascrivere"))

    segments.sort(key=lambda x: x[0])

    if not keep_invented:
        segments, dropped = remove_invented(segments)
        if dropped:
            say(t(f"phrases invented by whisper on noises: {dropped} removed "
                  f"(«Thank you.», subtitle credits…)",
                  f"frasi inventate da whisper sui rumori: {dropped} tolte "
                  f"(«Grazie.», crediti dei sottotitoli…)"))

    if not SPEAKERPHONE and not keep_echo:
        segments, dropped = remove_echo(segments, you, others)
        if dropped:
            say(t(f"speaker echo: {dropped} {you} lines dropped "
                  f"(the others' phrases heard again by the microphone)",
                  f"eco delle casse: {dropped} righe {you} scartate "
                  f"(erano frasi degli altri risentite dal microfono)"))

    lines, last = [], None
    for tt, label, text in segments:
        if label == last:
            lines[-1] += " " + text
        else:
            prefix = "" if SPEAKERPHONE else f"{label}: "
            lines.append(f"[{mmss(tt)}] {prefix}{text}")
            last = label

    if language != "auto":
        with open(os.path.join(d, "language"), "w") as f:
            f.write(language + "\n")
    out = os.path.join(d, "transcript.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n\n".join(lines) + "\n")
    print(out)


if __name__ == "__main__":
    main()
