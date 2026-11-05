# dead-air

A tech news radio station that runs entirely on this Mac. It reads the tech feeds, Apple Intelligence's on-device model writes a short spoken highlight of each story, and Phonon reads it out loud through Ollama. Nothing goes to a cloud model, and nothing costs a token.

```sh
make install          # builds afm, links the scripts into ~/.local/bin
ollama pull phonon
dead-air              # new stories now, then every 5 minutes
```

It needs macOS 26 with Apple Intelligence turned on, Xcode or the Command Line Tools (for `swiftc`), `uv`, and Ollama with a Phonon model.

## The menu bar player

```sh
make install-app      # builds DeadAir.app into ~/Applications, plus everything `make install` does
open ~/Applications/DeadAir.app
```

A radio icon goes in the menu bar. Click it for the player: what's on air and its source, the words being read, a progress bar, play/pause (space) and skip, "Open story ↗", what's up next, recent stories (click one to open it), the anchor's voice, and a switch for the station IDs.

- It runs `dead-air-wire | dead-air-write` for the words, and does the voicing and playback itself: Phonon through Ollama into WAVs, played with `AVAudioPlayer`. That's what makes pause and skip work, which `afplay` can't do well.
- It registers with Now Playing, so the keyboard's media keys, Control Center, and AirPods controls pause and skip it, and the headline shows up there.
- `deadair://play`, `deadair://pause`, `deadair://toggle`, and `deadair://skip` control it from a script or a Shortcut. For "Hey Siri, play Dead Air", make a Shortcut with one Open URLs action set to `deadair://play`.
- Nothing starts until you press play the first time. Quit stops the wire and writer with it.
- A story counts as heard when it starts playing. The app writes its id to `~/.cache/dead-air/aired.txt` then, and runs wire with `--seen` on that file and `--no-remember`, so a story written but never played comes back next time. The CLI keeps its own list in `seen.txt`.
- Logs from the app, wire, and write go to `~/.cache/dead-air/app.log`.
- It's built with `swiftc` into a hand-made bundle and signed ad hoc, the same as `afm`. It's `DeadAir.app` on disk because make can't handle a space in a target name; the menu says "Dead Air". To start it at login, add it in System Settings → General → Login Items.

## The pieces

Each stage reads stdin and writes stdout, so you can run any of them alone or swap one out.

| Command | Reads | Writes |
|---|---|---|
| `afm` | a prompt (arguments or stdin) | the on-device model's reply |
| `dead-air-wire` | RSS and Atom feeds | one story per line, JSON, with the article's own text |
| `dead-air-write` | stories | one spoken segment per line, JSON (`--text` for plain) |
| `dead-air-speak` | lines of text or JSON | audio on the speakers, and each line as it starts playing |
| `dead-air` | wire options | all three, piped together |
| `DeadAir.app` | a click on the menu bar | the same station, with pause, skip, and media keys |

```sh
echo "Explain DNS to a cat." | afm -i "One sentence."
dead-air-wire --fresh --limit 3 | dead-air-write --text
dead-air-wire --feed "Hacker News=https://hnrss.org/frontpage?points=300" | dead-air-write | dead-air-speak
fortune | dead-air-speak --voice "Old Mortlake" --ident-every 0
```

The stages are installed with a `dead-air-` prefix because a bare `write` would shadow `/usr/bin/write`. In the repo they're `bin/wire`, `bin/write`, and `bin/speak`.

## afm

`afm/afm.swift` is about 100 lines over Apple's `FoundationModels` framework. Flags: `-i` instructions (or `-i @file`), `-t` temperature, `-n` max tokens, `-s` to stream, `--check` to see if the model is there. Exit codes are distinct, so scripts can react: 3 when the prompt is past the 4,096-token context, 4 when Apple's guardrails refuse it, 69 when the model is unavailable.

It's built with plain `swiftc` from the Makefile, not SwiftPM. The SwiftPM in the Command Line Tools on this Mac (Swift 6.3.3) doesn't know `.macOS(.v26)` yet, so a package manifest won't load.

## How the writing works

- `wire` reads Hacker News (150+ points), Ars Technica, The Verge, TechCrunch, Lobsters, and Simon Willison by default (`--list`, or `--feed NAME=URL` to replace them). It skips stories over 12 hours old, headlines that share two names with one already seen, and deals and shopping posts (`--skip`). What it's sent is remembered in `~/.cache/dead-air/seen.txt`, so a restart doesn't rerun the same news; `--fresh` ignores that.
- It pulls each article's `<p>` text, capped at 2,500 characters (`--chars`). The on-device model's whole context is 4,096 tokens, and that leaves plenty of room. When a prompt overflows anyway, `write` retries with 1,200 characters.
- One story per `afm` call. The model never names the source; the code adds "From Ars Technica." or "Seen on Hacker News."
- The code also strips markdown, spells out `$` and `%`, drops a sentence the model said twice, and cuts at the last whole sentence under 80 words (`--max-words`).
- The 3B model loves a press release ("groundbreaking", "revolutionizing"). When a hype word shows up, `write` asks once more for it plainly and keeps the second try if it's clean.
- `speak` voices the next segment while the current one plays, two ahead (`--ahead`), and trims the 200 ms of silence Phonon puts at the start of every clip. Every fourth segment (`--ident-every`), a station ID with the time goes out in the voice of The Thing Under the Stairs (`--ident-voice`). The time is filled in when the ID is voiced, not when the story was written, so it's right even when the writer runs ahead.

## What we measured (2026-11-05, M3 Pro, macOS 26.6.2)

- `afm` writes a 60–80 word segment in 1.0–3.3 s, about 2 s typical.
- Phonon voices 20–28 s of speech in 350–700 ms, and a station ID in under 0.5 s.
- `dead-air --fresh` took about 2.5 s from launch to the first sound: 1 s for the feeds, 2 s for the first segment, then 0.2 s of speech synthesis.
- `wire` checks six feeds in parallel and pulls six articles in about 1.6 s.

## What the small model gets wrong

Apple's on-device model is about 3B parameters, and it shows.

- It copies sentences from the article more than it should, even when told not to. Technical articles (Go's assembler) come out close to a paraphrase of the first paragraph.
- It gets technical facts slightly wrong. It once said Go's assembler "turns Go code into machine code," and another time that OpenSSH "version 10.1 has been patched." Fine for a heads-up, not for anything you'd quote.
- It sometimes names the outlet anyway ("The Verge shared the announcement post"), despite the rule.

For better writing, the writer is one stage: swap `dead-air-write` for one that calls a bigger model, such as qwen3.8 on the 4090, and keep the rest. `~/code/phonon-tts` has the earlier newsroom that does that through Ollama.
