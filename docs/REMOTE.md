# Running on another Mac: the laptop shows, the mini computes (2026-10-22)

The MacBook cannot do the photogrammetry; the Mac mini can, and never sleeps. This note records how the app on one Mac
drives the pipeline on another over the tailnet, what was built, and what is left. It follows the design Notarii
settled on for Mac-to-Mac compute (`notarii/docs/plans/mac-mini-offload.md`: SSH plus rsync, no new listener, no new
protocol) with one change that matters more for hours-long runs than for minutes-long transcriptions: **the laptop never
holds the job.** A run is launched detached on the compute Mac and writes everything it knows to files; the laptop
observes those files through a mirror. Closing the laptop, losing the tunnel, quitting the app: the run does not notice.

## The shape

| | |
|---|---|
| **record** | `work/environments` on the compute Mac is the single record. The pipeline there is the only writer of run status, as before. |
| **mirror** | the laptop keeps `~/Library/Application Support/Tricorder/mirrors/<host>/work/environments`: every manifest, log, preview, USDZ preview, site-plan deliverable and extracted frame, pulled with `rsync -au --delete`. Not mirrored: dense clouds, meshes, textures, COLMAP databases, Blender scenes, the videos and photo originals (`Remote.mirrorExcludes`). The backyard comes to 2.7 GB instead of 87. |
| **commands** | every `python -m tricorder.pipeline …` the app would run locally runs over SSH in the host's checkout (`Remote.pipeline`), one multiplexed connection per host (`ControlMaster`, socket in `/tmp`). `launch` detaches there under `caffeinate`, exactly as for a local run. |
| **liveness** | a pid means something only on the machine that owns it. Before each pull the laptop asks the host for `pipeline reconcile`, which marks runs whose process died as interrupted; the laptop's own reconcile is off for a mirror. |
| **writes** | the app writes names, notes, marks and measurements into the mirror and pushes that one file back at once (`Remote.push`). Pulls use `-u`, so a file the app wrote more recently than the host's copy is never overwritten while its push is on the way. |
| **uploads** | a new video is `rsync --partial --progress` into the host's `data/` inbox, then `new-recording` takes it from there; the sheet shows the percentage. Videos already in that inbox are offered without an upload. |
| **cadence** | pull + refresh every 5 s while anything runs, every 30 s otherwise (3 / 20 s locally, where FSEvents also fire). Tool health every tenth poll. |
| **deletes** | `pipeline trash` moves the item into `work/trash/` on the host (the laptop's Trash would only hold the mirror copy). |

Settings ▸ Compute: *This Mac* (the checkout) or *Another Mac over SSH* (host, user, checkout path; Test runs
`pipeline health` there). The health bar shows the host's name and whether it answered.

New pipeline commands, for the app on the other Mac: `reconcile`, `cancel <env> <run>`, `health`, `inbox`,
`trash <env> [recordings|runs|assets <id>]`. The compute Mac needs this version of `tricorder/pipeline.py`; an older
checkout still mirrors (reconcile is best effort) but cannot be cancelled or trashed from the laptop.

## Why not the alternatives

- **Mount the host's checkout over SMB and point the app at it.** The app's reconcile would write "interrupted" into
  the host's live `run.json` whenever a pid is not alive on the laptop, FSEvents do not cross SMB, and every USDZ
  preview would stream over the tunnel on each open. The mirror keeps the app's file-based views untouched and the
  host's record safe from the laptop.
- **Stream progress over a held SSH session** (Notarii's plan A as written). Fine for a 5-minute worker whose caller
  stays awake; wrong for a 3-hour COLMAP stage on a laptop. Tricorder's runs already detach and already write
  `run.json`, stage logs and previews as they go, so there is nothing to stream.
- **An HTTP agent on the mini** (Notarii's B) buys a surface the phone could call, and only the phone needs it. Below.

## What is left

1. **Keeping the mini current is a button.** `pipeline health` reports `PROTOCOL` and the git revision; when the
   host is behind what the app expects, Settings ▸ Compute shows it and *Update from GitHub* runs `git pull --ff-only`
   in its checkout over the same SSH connection. Bump `PROTOCOL` in `pipeline.py` and `Pipeline.protocolVersion`
   together whenever the app starts relying on a new command.
2. **The video on demand.** The recording page's player has nothing to play on a mirror; a "Fetch video" button
   (`rsync` of `recordings/<rec>/video.mov` into the mirror) is a few lines.
3. **Refuse, not just warn.** When the host is behind, commands that need the new protocol could refuse with the
   update hint instead of failing with "unknown command".
4. **Hardening.** A dedicated key in the host's `authorized_keys` restricted to `python -m tricorder.pipeline …`
   and `rsync --server` under the checkout; Tailscale ACL on port 22.
5. **Frames on demand.** Frames are the bulk of the mirror (1.5 GB per 600-frame walk). They matter only for the
   measurement editor; pulling them when that editor opens would make the first mirror of a new scan seconds.

## The phone: "Share ▸ Tricorder" from Photos

Two ways to get a video from the iPhone to the mini, both wanted:

- **From the Mac app:** *New environment* ▸ drop the video. Dragging from Photos.app gives a file promise, which the
  drop zone does not accept yet (`.dropDestination(for: URL.self)`); AirDrop to the Air, then drop, works today, and
  the video uploads to the mini from the sheet. Accepting file promises (`NSFilePromiseReceiver`) is the fix.
- **From the share sheet:** the Notarii phone app is the template, and its two parts carry over almost unchanged:
  the share extension (`Apps/Share`: app group, inbox staging, a background `URLSession` upload that outlives the
  extension) and the pairing flow (host:port typed once, a code, Test, Save). What Tricorder lacks is a listener on
  the mini. Notarii's lives inside its Mac app; Tricorder's should be a small Python service, `python -m
  tricorder.serve`, run by launchd on the mini: bind the Tailscale address only, `POST /v1/recordings` with the video
  bytes, name and the chain to start ("Site plan from video"), `GET /v1/environments` for the phone's list with run
  progress, the same bearer code. The orchestrator already has `create_environment`, `create_recording`,
  `create_run` and `launch`; the service is a hundred lines over them, and it needs no app open on the mini. The phone
  app then shows what the Mac app's home page shows, read from that endpoint, like Notarii's phone shows the Mac's
  library. The laptop keeps using SSH; the phone cannot.
