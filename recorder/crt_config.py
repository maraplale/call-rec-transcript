#!/usr/bin/env python3
"""Configuration for call-rec-transcript: one place for keys, defaults and the config file.

Values come from, in order of priority:
  1. environment variables (CRT_*),
  2. the config file (~/.config/call-rec-transcript/config, or $CRT_CONFIG),
  3. the defaults below.

The config file is plain KEY=value lines; # starts a comment; ~ is expanded.

  crt_config.py --shell   print KEY=value lines; the bash scripts export them one by one
  crt_config.py --init    write a commented config file if there is none yet
  crt_config.py --show    print the effective configuration
"""
import os
import sys

STATE_DIR_DEFAULT = "~/.config/call-rec-transcript"

# key: (default, description)
DEFAULTS = {
    "CRT_NOTES_DIR": ("~/Documents/Call Notes",
                      "Where the call notes (.md) are written. Can be an Obsidian vault folder."),
    "CRT_RECORDINGS_DIR": ("~/Documents/Call Notes/recordings",
                           "One folder per call: audio, transcript, recorder log."),
    "CRT_TRANSCRIPTS_DIR": ("",
                            "Where a copy of each transcript goes. Empty = <notes>/transcripts. off = no copy."),
    "CRT_PDF_DIR": ("",
                    "Where the PDF of the note goes. Empty = the notes folder. off = no PDF. "
                    "Example for iCloud Drive: ~/Library/Mobile Documents/com~apple~CloudDocs/Call Notes"),
    "CRT_LANG": ("auto", "Language spoken in calls: auto, it, en, or any whisper language code."),
    "CRT_UI_LANG": ("auto", "Language of the recorder's messages: auto, en, it."),
    "CRT_USER_NAME": ("", "Your name, used in the note (optional). Empty = 'the person recording'."),
    "CRT_NOTE": ("on", "Write a note with Claude after each call: on/off."),
    "CRT_NOTE_ENGINE": ("auto", "auto (API if ANTHROPIC_API_KEY is set, else the claude CLI), api, cli."),
    "CRT_NOTE_MODEL": ("claude-sonnet-5-5", "Model used on the API path."),
    "CRT_KEEP_WAV": ("off", "Keep the original WAV files (about 2 GB per hour) instead of compressing to m4a."),
    "CRT_FRONTMATTER": ("on", "Put a YAML header (title, date, tags) at the top of the note."),
    "CRT_INSTALL_DIR": ("~/Applications/Call Recorder",
                        "Where build.sh puts Call Recorder.app and the double-click launchers."),
    "CRT_MODEL_DIR": ("~/.cache/whisper-cpp", "Where the whisper models are."),
    "CRT_WHISPER_THREADS": ("", "Threads for whisper-cli. Empty = automatic."),
    "CRT_CHROME": ("", "Path to Chrome/Chromium/Edge/Brave for the PDF. Empty = look in /Applications."),
}

BOOLEAN_KEYS = {"CRT_NOTE", "CRT_KEEP_WAV", "CRT_FRONTMATTER"}
TRUE_WORDS = {"1", "on", "yes", "true", "y", "si", "sì"}


def state_dir():
    return os.path.expanduser(os.environ.get("CRT_STATE_DIR") or STATE_DIR_DEFAULT)


def config_path():
    return os.path.expanduser(os.environ.get("CRT_CONFIG") or os.path.join(state_dir(), "config"))


def read_file(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                if key.startswith("export "):
                    key = key[len("export "):].strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if key in DEFAULTS:
                    values[key] = value
    except FileNotFoundError:
        pass
    return values


def _expand(value):
    return os.path.expanduser(value) if value.startswith("~") else value


def _detect_ui_lang(spoken):
    if spoken.startswith("it"):
        return "it"
    if spoken not in ("", "auto"):
        return "en"
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var, "")
        if v and not v.startswith(("C", "POSIX")):
            return "it" if v.startswith("it") else "en"
    try:
        import subprocess
        r = subprocess.run(["defaults", "read", "-g", "AppleLocale"],
                           capture_output=True, text=True, timeout=5)
        if r.stdout.strip().startswith("it"):
            return "it"
    except Exception:
        pass
    return "en"


def load():
    values = {k: d for k, (d, _) in DEFAULTS.items()}
    values.update(read_file(config_path()))
    for key in DEFAULTS:
        if os.environ.get(key) not in (None, ""):
            values[key] = os.environ[key]

    for key in list(values):
        values[key] = _expand(values[key].strip())
    for key in BOOLEAN_KEYS:
        values[key] = "1" if values[key].lower() in TRUE_WORDS else "0"

    notes = values["CRT_NOTES_DIR"]
    if not values["CRT_TRANSCRIPTS_DIR"]:
        values["CRT_TRANSCRIPTS_DIR"] = os.path.join(notes, "transcripts")
    if not values["CRT_PDF_DIR"]:
        values["CRT_PDF_DIR"] = notes
    values["CRT_LANG"] = values["CRT_LANG"].lower() or "auto"
    ui = values["CRT_UI_LANG"].lower()
    values["CRT_UI_LANG"] = ui if ui in ("en", "it") else _detect_ui_lang(values["CRT_LANG"])
    values["CRT_STATE_DIR"] = state_dir()
    values["CRT_CONFIG"] = config_path()
    values["CRT_LAST"] = os.path.join(state_dir(), "last-recording")
    return values


def init_file():
    path = config_path()
    if os.path.exists(path):
        return path, False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ["# call-rec-transcript configuration",
             "# One KEY=value per line. Remove the # in front of a line to change it.",
             "# Environment variables with the same name override this file.", ""]
    for key, (default, desc) in DEFAULTS.items():
        lines.append("# " + desc)
        lines.append("# %s=%s" % (key, default))
        lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return path, True


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "--show"
    if arg == "--init":
        path, created = init_file()
        print(path if created else path + " (already there, left as is)")
        return
    values = load()
    if arg == "--shell":
        for key, value in values.items():
            print("%s=%s" % (key, value.replace("\n", " ")))
    else:
        width = max(len(k) for k in values)
        for key, value in values.items():
            print("%-*s  %s" % (width, key, value))


if __name__ == "__main__":
    main()
