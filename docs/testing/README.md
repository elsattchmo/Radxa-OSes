# Testing on your Q6A: start here

You run each stage on the board, and it produces one report. Send me the report and I'll tell you what it means and what happens next. You don't need to interpret the results yourself.

| Stage | You do | Time | Guide |
|---|---|---|---|
| **0** | Update the firmware, put Armbian on the NVMe, install the test tools | 1–2 h, once | [STAGE-0.md](STAGE-0.md) |
| **1** | Run one command; answer a few "did you see/hear it?" questions | ~5 min | [STAGE-1.md](STAGE-1.md) |
| **2** | Run one command; watch the TV and answer questions | ~30 min | [STAGE-2.md](STAGE-2.md) |
| 3+ | Flash images I build and follow a checklist | later | written when ready |

## How to send results back

At the end of each stage the script prints a table and two file paths:

```
  Summary: /home/you/q6a-reports/stage1-20261030-101500/SUMMARY.md
  Full report (send this): /home/you/q6a-reports/stage1-20261030-101500.tar.gz
```

Either:

- **copy the printed table** (everything after the dashed line) and paste it into our chat. That's enough for most stages. Or:
- **send the `.tar.gz`** if I ask for the full logs. To copy it to your PC, run this from the PC (with the board's address from Stage 0, step 8):
  ```
  scp you@BOARD-IP:q6a-reports/*.tar.gz .
  ```
  Or copy it to a USB stick on the board: `cp ~/q6a-reports/*.tar.gz /media/...`

## What the results mean

| Result | Meaning |
|---|---|
| **PASS** | Works |
| **FAIL** | Broken, and I need to look at it |
| **WARN** | Works, but something should be changed. The message says what |
| **INFO** | A measurement for planning (memory, refresh rates, temperatures…) |
| **SKIP** | Not run (missing tool, or you ran with `--auto`) |

The full gate list is in [../TEST-PLAN.md](../TEST-PLAN.md).

## Golden rules

- Nothing in Stages 1–2 changes your firmware or partitions. They only read, play tones, show graphics on the TV, and (Stage 2) download Valve's image into `/var/lib/q6a-test`.
- If a script seems stuck for more than 5 minutes, press **Ctrl+C** and send me the last lines on the screen.
- If the TV goes black during a test and doesn't come back within a minute, wait one more minute and then reboot. Nothing gets damaged.
- Running the tests over **SSH from your PC** (Stage 0, step 8) is easiest: the TV stays free for the graphics tests and you can copy-paste the results.
