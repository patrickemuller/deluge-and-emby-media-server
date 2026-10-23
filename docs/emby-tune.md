# emby-tune

`emby-tune` checks an Emby server and fixes the settings that usually cause stutter, missing subtitles and dubbed audio. The Emby API checks work on any Emby 4.8+ server, from any machine. The Deluge and disk checks only run on the Linux machine that hosts Emby.

## Running it

On the Emby machine:

```bash
curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash
```

It asks for the server's internal IP (`hostname -I` on the server shows it) and an admin API key (Dashboard > Advanced > API Keys > New), or an admin login. Then it prints what it found, lists the changes it wants to make, and only applies them after you say yes. Nothing gets installed; the script runs from a temp folder.

It refuses public IPs, because it talks to Emby over plain HTTP and the API key would cross the internet. Internal addresses (`192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`), VPN addresses (Tailscale's `100.x`), `localhost` and LAN hostnames all work.

Flags go after `bash -s --`. In these examples `192.168.1.50` stands for your server's internal IP:

```bash
# look only, change nothing
curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash -s -- --host 192.168.1.50 --dry-run

# name the server, subtitles in English + Brazilian Portuguese, original-language audio,
# one user who wants pt-BR subtitles only when the audio isn't Portuguese
curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash -s -- \
  --host 192.168.1.50 --server-name 'Home Cinema' \
  --subtitle-langs en,pt-br --original-audio --user-subs 'Ana=pob,por:Smart'

# measure what this machine can transcode
curl -fsSL https://raw.githubusercontent.com/patrickemuller/deluge-and-emby-media-server/main/install.sh | bash -s -- --host 192.168.1.50 benchmark
```

`EMBY_HOST`, `EMBY_PORT` and `EMBY_API_KEY` environment variables work in place of `--host`, `--port` and `--api-key`.

Or clone the repo and run `./emby-tune.rb --help`.

Other commands:

- `emby-tune benchmark` measures how fast this machine reads and transcodes your own files.
- `emby-tune deluge-apply SETTINGS.json` writes Deluge settings (e.g. [`config/deluge/recommended-settings.json`](../config/deluge/recommended-settings.json)) through deluged's RPC.

## What it fixes on its own

These changes are proposed only when the current value is wrong. A second run on a fixed server says "Nothing to change".

| Area | Setting | When | Why |
|---|---|---|---|
| Transcoding | Throttling on | always | ffmpeg pauses once it's far enough ahead, which frees CPU for other streams |
| Transcoding | HEVC encoding off, max width 1920, hardware encoding off, software tone mapping off | no hardware codecs found | the CPU can't do any of these in real time (see [the Pi 5 numbers](raspberry-pi-5.md)) |
| Subtitles | "Forced only" off, "require hash match" off, skip if the file already has subtitles in that language, installed subtitle plugins turned on | library has download languages | with forced-only or hash-match on, almost nothing downloads; skipping saves the provider's daily quota |
| Library | Intro detection during scans off | no hardware codecs found | audio fingerprinting fights with playback; the nightly task still does it |
| Tasks | Intro detection and thumbnail tasks moved to `--quiet-hour` | no hardware codecs found | heavy CPU work runs when nobody is watching |
| Metadata | AniDB delay 2500 ms (Anime plugin) | delay under 2 s | AniDB bans IPs that send more than one request every 2 seconds |
| Deluge | Unfinished downloads go to an SSD folder and move to the old location when done | downloads land on the HDD Emby streams from | random torrent writes on the media disk are a common cause of buffering ([numbers](deluge-with-emby.md)) |
| Deluge | At most `--deluge-max-downloads` (2) active | more than that | fewer torrents writing at the same time |
| Deluge | Idle disk priority and nice 10 (systemd drop-in) | not already set | Emby's reads go ahead of Deluge's (delayed kernel write flushes are not covered) |
| Linux | BFQ scheduler + 4 MB readahead on library HDDs (udev rule) | another scheduler | BFQ is what makes the idle priority actually work |
| Linux | Pending writes capped at 256 MB (sysctl) | the limit is over 512 MB | flushing gigabytes at once stalls reads for seconds |
| Access | Shared `--media-group` (default `media`) with the Emby user, the Deluge user and you | missing | one group gives both services access, instead of 777 folders or Emby in your personal group |
| Access | Library folders (recursively) and Deluge's download/move folders (top level only, since they often sit at a disk root next to unrelated data): group `media`, `g+rwX`, setgid, default ACL, not world-writable | Emby can't read or write something, or the inheritance pieces are missing | subtitles, images and NFO files save; new files stay shared whoever creates them ([details](permissions.md)) |
| Access | `UMask=0002` and `RequiresMountsFor=<media mounts>` drop-ins for Emby and Deluge, then a restart | not set | new files stay group-writable; neither service starts before the USB disks are mounted |

## What it only warns about

It reports these but leaves them for you to decide:

- an Emby update is available
- remote access over plain HTTP
- the OpenSubtitles username is an email (the API wants the username) or logins fail in the log
- torrents downloading straight into a library folder
- library disks mounted without `noatime`
- transcode temp folder on a spinning disk
- Raspberry Pi under-voltage or throttling
- a high iowait right now (some disk is the bottleneck)
- a media disk formatted NTFS/exFAT (it prints the fstab line with the disk's UUID and the right `uid`/`gid`)
- a parent folder Emby can't enter (e.g. a library inside a private home folder)
- Emby running in a container (it explains PUID/PGID instead)

## Opt-in options

| Flag | Effect |
|---|---|
| `--host IP` / `--port 8096` | your Emby server's internal IP and port; asked for if missing |
| `--server-name 'Home Cinema'` | the name the Emby apps show for your server |
| `--subtitle-langs en,pt-br` | languages every video library downloads subtitles for (Emby's two-letter codes) |
| `--opensubtitles-user NAME` | sets the Open Subtitles plugin login; the password is prompted or read from `OPENSUBTITLES_PASSWORD` |
| `--original-audio` | all users prefer `jpn,kor,chi,eng` audio instead of the track the file marks as default ([why this works](emby-settings.md#original-language-audio)) |
| `--audio-pref jpn,eng` | your own audio language list (ISO 639-2 codes) |
| `--subs-pref eng:Always` | subtitle language and mode for every user |
| `--user-subs 'Name=pob,por:Smart'` | per-user subtitle preference; repeatable |
| `--allow-downloads` | lets every user download media for offline playback |
| `--media-group media` | name of the shared group for the media folders |
| `--only emby,deluge,os,perms` | limit the run to some areas |
| `--yes` | apply without asking |

## Safety

- It never changes the contents of media files. Many people seed straight from their library, and changing a file breaks the torrent. The access fix changes only owners and permission bits.
- It talks to Emby through its HTTP API. It uses `sudo` only for the Deluge and Linux changes, and each of those is marked `(sudo)` in the plan.
- If you log in with a username and password, the session is logged out at the end.
- The access fix restarts Emby and Deluge, and the plan says how many streams are playing at that moment.
- System files it writes match the ones in [`config/`](../config): `/etc/udev/rules.d/60-media-hdd-iosched.rules`, `/etc/sysctl.d/60-media-writeback.conf`, `/etc/systemd/system/<deluge unit>.d/10-low-io-priority.conf`, `/etc/systemd/system/<emby and deluge units>.d/20-media-access.conf`. To undo, delete the file and reboot.

## Requirements

Ruby 2.7+ and curl; `install.sh` offers to install Ruby with apt if it's missing. Only the Ruby standard library is used, so no gems. Deluge is driven through its own RPC protocol, implemented in the script, so nothing else needs to be installed for the Deluge checks.

## How the code is organized

| File | What's in it |
|---|---|
| `emby-tune.rb` | the command line: options, which checks run, printing the plan, applying it |
| `lib/emby_tune/emby_settings.rb` | Emby's own settings as a table of rules, plus the few checks that need more than a table |
| `lib/emby_tune/emby_client.rb` | Emby HTTP API, the LAN-only address check, login |
| `lib/emby_tune/deluge.rb` | Deluge daemon client in plain Ruby and the Deluge checks |
| `lib/emby_tune/disks.rb` | I/O scheduler, writeback and mount checks for media disks |
| `lib/emby_tune/permissions.rb` | shared read/write access for Emby and Deluge |
| `lib/emby_tune/benchmark.rb` | the `benchmark` command |
| `lib/emby_tune/support.rb` | output, the plan, shell helpers |

To change or add an Emby setting, add or edit a row in `emby_settings.rb`:

```ruby
Rule.new(area: "transcode", title: "HEVC (H.265) encoding", set: { "EnableHevcEncoding" => false },
         only_if: [:cpu_only], why: "Software x265 is slower than real time on low-power CPUs.")
```

`set` holds the values to apply, `only_if` the conditions under which the row applies, and an optional `ok_if` accepts other values as already fine (for example, any width up to 1920). The plan line, the comparison with the current value, and the save are the same for every row.
