# Stage 2: Valve's SteamOS and gamescope on your board (~30 minutes)

The most important test so far. It answers four questions:

1. Can we download and verify Valve's Steam Frame image?
2. Do Valve's programs run on the Q6A's older CPU cores?
3. Does Valve's own graphics driver work on the Q6A's GPU?
4. **Does Valve's gamescope put a picture on your TV?**

Nothing is installed on your system. Valve's image is downloaded to `/var/lib/q6a-test` (about 4 GB download, 4.5 GB on disk) and mounted read-only while the test runs.

## Before you start

- Stage 1 done, with S1.10 (30 GB free) and S1.29 (Valve's server reachable) passing
- TV on, on the Q6A's input
- **Run this over SSH from your PC** (Stage 0, step 8). During the tests the TV shows gamescope, not the terminal.
- Ethernet if possible, since it's a 4.4 GB download

## Run it

```
cd ~/Radxa-OSes
git pull
sudo ./q6a-test stage2
```

What happens:

1. **Download (about 4 GB, 10–30 minutes).** You'll see progress lines like `74.1%  downloaded 1,516 MB (4.8 MB/s)`. If it stops or you press Ctrl+C, run the same command again and it carries on where it left off.
2. **Verification:** Valve's signature, every chunk, and a final whole-image check (about a minute).
3. Quick checks: CPU compatibility, Valve's graphics driver.
4. **Gamescope tests on the TV.** Press Enter, then watch the TV. Each test shows a moving test image for about 20 seconds:

   | Test | What you should see on the TV |
   |---|---|
   | S2.07 | The test animation, full-screen |
   | S2.08 | The same, drawn a different way: should look identical |
   | S2.09 | Lower resolution (720p) scaled up to fill the screen: watch for **flicker** |
   | S2.10 | 720p upscaled with gamescope's upscaler: should look sharp. It uses SGSR if this gamescope has it; Valve's current build (3.16.28) doesn't, so FSR is used |
   | S2.11 | 120 Hz mode (only if your TV offers it): check the TV's info banner if it shows refresh rate |

   After each one, answer the question in the SSH window with `y` or `n`.
5. It checks the support files for FEX (the translator Steam uses for PC games) and Android apps. FEX itself is downloaded by Steam, so it's tested in Stage 3.
6. The summary table is printed.

**Send me the table** ([how](README.md#how-to-send-results-back)). For this stage, **also send the `.tar.gz`**: it has the gamescope logs I need, showing which hardware planes were used and why anything failed.

## If something goes wrong

| Symptom | What to do |
|---|---|
| The download is very slow or stops | Ctrl+C, then run the same command again: it resumes |
| `signer key changed` | Valve changed its signing key. Don't continue; send me the message |
| `sha256 mismatch` | The download was corrupted. Run `sudo ./q6a-test stage2-cleanup --delete`, then run Stage 2 again |
| The TV stays black during a gamescope test | Answer `n`. That's exactly what this test is for; the logs tell me why |
| The TV is still black after the script finishes | Wait a minute, then reboot the board |
| `No test program … in Valve's image` | Tell me; I'll add one |

## Afterwards

The script unmounts Valve's image when it finishes. The download stays in `/var/lib/q6a-test` so later stages can reuse it. To remove it:

```
sudo ./q6a-test stage2-cleanup --delete
```

## What happens next

- **S2.07 passes** (picture on the TV): the riskiest part of the project is confirmed. I build the first bootable image (Stage 3), and you'll boot straight into Steam's Game Mode.
- **S2.07 fails:** the logs show whether it's the kernel's display driver or gamescope. We try the handheld project's patched gamescope next, then fix the kernel if needed.
