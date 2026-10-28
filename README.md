# Radxa-OSes

Porting SteamOS (the Steam Frame / "deckard" arm64 build) to the Radxa Dragon Q6A (QCS6490). The target is everything except VR:

- Game Mode and Desktop Mode
- FEX + Proton for x86 games
- Android apps via Lepton
- Booting from M.2 NVMe
- A/B updates that follow Valve's releases
- GPU overclock and tuning profiles

Status: research and planning. See [docs/PLAN.md](docs/PLAN.md) for the feasibility study, architecture and phased plan.

This project is unofficial and not affiliated with Valve or Radxa. Valve's SteamOS image is never redistributed here. The installer downloads it from Valve and verifies Valve's signature on your own machine.
