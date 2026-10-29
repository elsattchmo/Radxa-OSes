# Radxa-OSes

Porting SteamOS (the Steam Frame / "deckard" arm64 build) to the Radxa Dragon Q6A (QCS6490). The target is everything except VR:

- Game Mode and Desktop Mode
- FEX + Proton for x86 games
- Android apps via Lepton
- Booting from M.2 NVMe
- A/B updates that follow Valve's releases
- Sound (HDMI, headset jack, USB, Bluetooth) and Bluetooth controllers
- Upscaling (SGSR/FSR/NIS), frame generation, 120 Hz modes, VRR if the hardware allows
- GPU overclocking, fan/thermal control and per-game performance profiles

Status: research and planning.

- [docs/ROADMAP.md](docs/ROADMAP.md): scope and what to do first
- [docs/GAMESCOPE.md](docs/GAMESCOPE.md): Game Mode on HDMI, the critical path
- [docs/UPDATES.md](docs/UPDATES.md): automated updates for Valve builds, GPU drivers, kernel and firmware
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): upscaling, frame generation, VRR, overclocking, thermals and profiles
- [docs/PLAN.md](docs/PLAN.md): the original feasibility study and architecture

This project is unofficial and not affiliated with Valve or Radxa. Valve's SteamOS image is never redistributed here. The installer downloads it from Valve and verifies Valve's signature on your own machine.
