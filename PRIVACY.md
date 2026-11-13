# Privacy

Call Rec Transcript is a set of scripts that runs on your Mac. Its author runs no server
and receives nothing: no account, no analytics, no telemetry.

## What stays on your Mac

- The audio. Recording (your microphone and the other people's audio) and transcription
  (whisper.cpp) happen locally. The audio files are never sent anywhere.
- The transcripts, notes and PDFs, in the folders you choose. Whether those folders are
  synced (iCloud Drive, Obsidian Sync...) is your choice.

## What leaves your Mac

- **The text of the transcript, to Claude, to write the note.** It goes either through the
  `claude` CLI logged in to your own Claude account, or to the Anthropic API with your own
  `ANTHROPIC_API_KEY` (sent only to `api.anthropic.com`). Anthropic's own terms and privacy
  policy apply to it. Through the CLI it runs with no tools and is not saved as a session
  (an older CLI without those options runs it as a plain one-off request).
  Turn notes off with `CRT_NOTE=off` and nothing at all leaves your Mac.
- **One download at setup**: the speech-recognition model, from Hugging Face. Nothing about
  you or your calls is sent with it.

## Recording other people

A call recording is personal data about everyone on the call (in the EU it falls under the
GDPR), and the rules on recording calls differ by country. Tell the other people that you
are recording and ask if it is OK; if someone says no, stop and take notes by hand. You are
responsible for the recordings you make. This is not legal advice.

## Contact

Questions or problems: open an issue at
https://github.com/maraplale/call-rec-transcript/issues
