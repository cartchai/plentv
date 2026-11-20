# The owner's cheap-device checklist (L-59 / T4-10)

For a Fire Stick 4K Max, a cheap TV, or any low-end device. About 10
minutes. No computer needed — just the app and the remote.

## Before you start

Check the version first: open PlenTV → Settings → About. Write the
version number down. It should match the one in the delivery message.
If it doesn't, install the new APK first — an old version makes the
rest of this meaningless.

## The 6 steps

### 1. Cold start — time to home

Force-close PlenTV first (Settings → Apps → PlenTV → Force stop — or
just restart the stick/TV again), then open it and count seconds on
your phone until the home screen shows your channels/movies. Write
the number down.

- **Good:** under 8 seconds.
- **Bad:** over 15 seconds, or it kicks you back to the Fire Stick
  home screen.

### 2. Zap 10 channels

Open Live TV, wait for the channel list, then tap through 10 channels.

- **Good:** every channel shows picture + sound within a few seconds.
- **Bad:** any channel shows a black screen, stutters, or takes more
  than 5 seconds. Write down which ones.

### 3. Open the guide, scroll 3 screens

Open the TV guide, wait for programme names to appear, then scroll
down 3 screens and back up.

- **Good:** it keeps up with your thumb, programmes show next to channels.
- **Bad:** it stutters badly, goes blank, or rows say "no program data".

### 4. Play 5 minutes

Pick any live channel and let it play for 5 minutes.

- **Good:** picture + sound, no freezing.
- **Bad:** stutter, freeze, or audio drift. Write down what happened
  and when (right away, or after a few minutes?).

### 5. Background + foreground

Press Home, wait 30 seconds, reopen the app.

- **Good:** it resumes where you left it.
- **Bad:** it restarts from the splash screen.

### 6. Open a VOD

Open any movie or series detail page.

- **Good:** it loads, poster shows within a few seconds.
- **Bad:** it spins forever, or the poster stays blank.

## Send the numbers

Go to Settings → Logs → run "Run low-end benchmark" if it's there (it
takes a couple of minutes — let it finish), then Settings → Logs →
Export, and send the file it saves. Also send: the seconds from step 1,
and one line each for steps 2–6 ("smooth" / "stuttery" / "kicked me
out"). That's it — the file has the rest: the tier, the per-phase RSS
table, the frame times, the slow-op lines, and the relief-valve record
(L-50–L-55).

## Red flags — stop and say so

- Kicked back to the Fire Stick home screen at any point (that's a crash).
- The app opens and immediately closes three times in a row (that's the
  auto-dump case — the file will already be saved, just say it happened).
- A blank home screen after 30 seconds (that's the empty-home shape
  from the Hisense).
