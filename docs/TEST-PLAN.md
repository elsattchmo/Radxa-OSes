# Test plan

Every stage ends with a **gate**: a short list of checks that must pass before the next stage starts. Each stage that runs on the board has a script that does the work and writes one report file. You send the report back, and the results decide what gets built next.

**Start here:** [testing/README.md](testing/README.md) has the step-by-step instructions.

## How the stages fit the build plan

```
Stage 0  board prep ─► Stage 1  hardware ─► Stage 2  Valve + gamescope   (you, now)
                                                   │ gate passed
                                                   ▼
      I build M1 (first image) ─► Stage 3 ─► M2/M4 (Game Mode, parity) ─► Stage 4
                                                   ▼
      I build M3 (update pipeline) ─► Stage 5 ─► M5 (performance) ─► Stage 6 ─► M6 public beta
```

Milestones M1–M6 are defined in [ROADMAP.md](ROADMAP.md#after-that-milestones). Each one ships only after its stage's gate passes on your board.

| Stage | What it proves | Who runs it | How long | Guide |
|---|---|---|---|---|
| **0. Prepare the board** | Firmware is current, Armbian runs from NVMe, the edge kernel is installed | You, following steps | 1–2 h, once | [STAGE-0.md](testing/STAGE-0.md) |
| **1. Hardware baseline** | Every piece of Q6A hardware we need works on mainline Linux. Also measures RAM, display modes, the GPU's speed grade and the VRR question | `sudo ./q6a-test stage1` | ~5 min | [STAGE-1.md](testing/STAGE-1.md) |
| **2. Valve's SteamOS + gamescope** | Valve's Frame image runs on this CPU, Valve's graphics driver drives the A643, and **Valve's gamescope lights up the TV** | `sudo ./q6a-test stage2` | ~30 min (mostly download) | [STAGE-2.md](testing/STAGE-2.md) |
| 3. First image | Our image boots from NVMe into Steam's Game Mode | You flash an image I build | ~20 min | written when the image exists |
| 4. Game Mode complete | Gamescope tests G1–G10, sound, controllers, Desktop Mode | Automated + checklist | ~1 h | later |
| 5. Updates | Valve update → our pipeline → your board updates from Steam, rollback works | You press "Check for updates" | ~30 min | later |
| 6. Performance | Profiles, overclock stability test, memory budget, benchmarks | Automated | ~1 h | later |

## Stage 1 gate

Must **PASS**:

| ID | Check |
|---|---|
| S1.03 | Running from NVMe |
| S1.04 | Booted by UEFI |
| S1.07 | NVMe found |
| S1.10 | 30 GB free |
| S1.11 | TV connected over HDMI |
| S1.16 | Vulkan finds the Adreno GPU |
| S1.20 | You saw the GPU test on the TV |
| S1.25 | Sound devices exist |
| S1.27 | Wi-Fi adapter present |
| S1.28 | Bluetooth controller present |
| S1.29 | Valve's server reachable |

Should **PASS**, but don't block Stage 2: S1.01 (firmware 260916), S1.02 (kernel 7.2+), S1.26 (you heard the tones).

**Recorded** for planning, with no pass/fail:

| ID | Feeds |
|---|---|
| S1.06 | RAM left after firmware, for the memory budget |
| S1.12 | refresh rates the TV offers: 1080p120? 4K30? |
| S1.13–S1.15 | VRR feasibility |
| S1.17–S1.18 | GPU clock steps and speed-bin fuse, for the overclock plan |
| S1.19 | vkmark score, as a baseline |
| S1.22–S1.24 | temperatures and throttling under load |

## Stage 2 gate

Must **PASS**:

| ID | Check |
|---|---|
| S2.02 | Valve's image downloaded and verified: signature, every chunk, final sha256 |
| S2.05 | No Valve program crashes with an illegal instruction on the A78/A55 cores |
| S2.06 | Valve's own Vulkan driver finds the Adreno 643 |
| S2.07 | Valve's gamescope shows a picture on the TV (G0) |

**Recorded** for the gamescope plan:

| ID | Test |
|---|---|
| S2.08 | forced composition looks the same |
| S2.09 | 720p → 1080p hardware scaling: any flicker? (G4) |
| S2.10 | Upscaling (SGSR if Valve's gamescope has it, else FSR) |
| S2.11 | 120 Hz output |
| S2.12 | FEX/Android support files present. FEX itself comes through Steam and is tested in Stage 3 |

Gamescope logs from every run go in the report: plane assignments, modifiers and errors. I analyse those (G2/G3).

**If S2.07 fails**, it isn't the end of the project. We try the handheld project's MSM gamescope build next, and look for kernel display fixes in the logs ([GAMESCOPE.md §7](GAMESCOPE.md#7-acceptance-tests)).

## Later stages

Stages 3–6 get the same treatment: a script, a guide and a gate. Their checks are already defined:

| Stage | Checks defined in |
|---|---|
| 3–4 | gamescope acceptance tests G0–G10 ([GAMESCOPE.md §7](GAMESCOPE.md#7-acceptance-tests)) and the v1 parity list ([ROADMAP.md](ROADMAP.md)) |
| 5 | update pipeline and rollback ([UPDATES.md §5](UPDATES.md#5-hardware-in-the-loop-testing)) |
| 6 | memory gate ([MEMORY.md §9](MEMORY.md#9-keeping-it-light-over-time-ci-gate)), overclock stability test ([PERFORMANCE.md §7](PERFORMANCE.md#7-overclocking-v1)), benchmarks ([PERFORMANCE.md §10](PERFORMANCE.md#10-benchmarks-and-regressions)) |

Once a test rig exists, the same scripts run unattended in CI (`--auto`).
