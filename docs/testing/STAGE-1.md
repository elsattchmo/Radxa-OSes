# Stage 1: hardware baseline (~5 minutes)

Checks every piece of the Q6A that SteamOS will need, on the mainline Linux kernel, and records the numbers the plan depends on:

- RAM left after firmware
- refresh rates your TV offers (1080p120? 4K?)
- whether VRR is possible through the board's HDMI chip
- the GPU's speed grade, for overclocking
- temperatures under load

Nothing is changed on the board.

## Before you start

- TV on, set to the Q6A's HDMI input
- **Headphones plugged into the 3.5 mm jack**, and the TV volume turned up
- Stage 0 finished

## Run it

```
cd ~/Radxa-OSes
git pull
sudo ./q6a-test stage1
```

What happens:

1. About a minute of quick checks scroll past: firmware, kernel, memory, NVMe, display, GPU.
2. **The TV shows a 3D GPU test for about 20 seconds.** Then it asks:
   *"Did the TV show spinning/shaded 3D scenes without flicker or corruption?"* Type `y` or `n` and press Enter.
3. A 60-second CPU load runs and records temperatures. The board gets warm; that's expected.
4. **Sound:** press Enter, and a short tone plays on each sound output in turn (headphones, then HDMI/TV). After each one it asks whether you heard it.
5. Wi-Fi and Bluetooth scans run (keep a Bluetooth device nearby if you can), then it checks Valve's server is reachable.
6. It prints the summary table.

**Send me the table** printed after the dashed line ([how](README.md#how-to-send-results-back)).

## If something goes wrong

| Symptom | What to do |
|---|---|
| "Please run with sudo" | Put `sudo` in front of the command |
| Lots of `SKIP … missing` | Run `sudo ./q6a-test deps` and try again |
| The TV stays black after the GPU test | Wait 30 seconds; the test ends by itself. If not, press Ctrl+C (over SSH) or reboot |
| No tone from the headphones | Answer `n`; that's useful information. Check the volume and plug, but don't spend long on it |
| You want to run it with no questions | `sudo ./q6a-test stage1 --auto` |

## What I look for

The gate is in [../TEST-PLAN.md](../TEST-PLAN.md#stage-1-gate). The important ones: running from NVMe, Vulkan finds the Adreno 643, the GPU test showed on the TV, sound devices exist, Wi-Fi and Bluetooth present, Valve's server reachable.

Next: [STAGE-2.md](STAGE-2.md)
