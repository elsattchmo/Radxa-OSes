# Stage 0: prepare the board (once)

Goal: current firmware, Armbian running from the NVMe drive, the 7.2 "edge" kernel, and the test tools installed.

## What you need

- [ ] Radxa Dragon Q6A, with heatsink (fan recommended)
- [ ] **M.2 2230 NVMe SSD**, 128 GB or larger. Everything on it will be erased.
- [ ] **12 V USB-C PD power supply**, the kind Radxa recommends for the Q6A
- [ ] TV or monitor, HDMI cable, USB keyboard
- [ ] **USB stick, 8 GB or larger.** Everything on it will be erased.
- [ ] Network: an Ethernet cable is easiest (Wi-Fi works too)
- [ ] A PC (Windows, macOS or Linux) to write the USB stick
- [ ] Only if you need the PC firmware method (step 3B): a **USB A-to-A cable, or a USB A-to-C cable that carries data**

## Step 1: Fit the NVMe

With the power unplugged, fit the SSD in the M.2 slot and screw it down.

## Step 2: Make an Armbian USB stick

1. On your PC, download **Armbian Debian 13 (Trixie) Minimal** for the Dragon Q6A:
   https://dl.armbian.com/radxa-dragon-q6a/Trixie_current_minimal
   (an `.img.xz` file, about 1 GB).
2. Write it to the USB stick with **balenaEtcher** (https://etcher.balena.io) or **Armbian Imager**. You don't need to unzip it first.
3. Plug the USB stick, keyboard, HDMI and Ethernet into the Q6A. Plug in the power last.

The Q6A tries **USB first**, then SD, then NVMe, so it boots from the stick.

4. Armbian's first-boot wizard appears on the TV:
   - set a root password
   - create your user. **Remember the user name and password.**
   - accept the defaults for everything else

You should see a command prompt like `you@radxa-dragon-q6a:~$`.

## Step 3: Check and update the firmware

Run:

```
cat /sys/class/dmi/id/bios_version
```

- **The output contains `260916`:** you're up to date. Go to step 4.
- **Anything else:** update with 3A, or 3B if 3A says it can't.

### 3A. Update from the board itself (easiest)

```
sudo apt update
sudo apt install -y git
git clone -b ccr-7072d8e3-wdiujf https://github.com/elsattchmo/Radxa-OSes.git
sudo Radxa-OSes/tools/update-firmware-ondevice.sh
```

The script:

- checks it's really a Q6A
- checks the firmware flash is reachable
- checks the firmware files are exactly Radxa's `wp_260916` release
- asks you to type `YES`
- uses Armbian's updater, which **backs up** the old firmware and **verifies** every part after writing

When it says **Finished**:

```
sudo poweroff
```

Unplug the power for 10 seconds, plug it back in, and check the version again with the `cat` command above.

If it says **STOPPED**, nothing was written: use 3B.

### 3B. Update from your PC (always works, even on a board that won't boot)

1. Download the firmware: https://dl.radxa.com/dragon/q6a/images/dragon-q6a_flat_build_wp_260916.zip and unzip it.
2. Download `edl-ng` v1.6.0 for your PC: https://github.com/strongtz/edl-ng/releases/tag/v1.6.0
   - Windows also needs the Qualcomm driver: https://dl.radxa.com/dragon/q6a/images/QUD_CustomInst_1.00.91.7.zip. Unzip it and run `Install.bat` as administrator.
3. Put the Q6A in **EDL mode**:
   1. unplug its power
   2. **hold the EDL button**, plug the power in, then release the button
   3. connect the Q6A's **USB 3 Type-A port** to your PC with the A-to-A (or A-to-C data) cable
4. Check the PC sees it:
   - Linux: `lsusb` shows `05c6:9008`
   - Windows: Device Manager shows a Qualcomm 9008 device
5. Open a terminal in the unzipped `flat_build/spinor/dragon-q6a/` folder and run:
   - Linux/macOS: `sudo edl-ng --memory spinor --loader prog_firehose_ddr.elf rawprogram rawprogram0.xml patch0.xml`
   - Windows: `edl-ng.exe --memory spinor --loader prog_firehose_ddr.elf rawprogram rawprogram0.xml patch0.xml`
6. When it finishes, unplug the USB cable and the power, wait 10 seconds, and power on.

If anything fails part-way, don't panic. EDL mode is built into the chip, so you can always repeat 3B.

## Step 4: Install Armbian onto the NVMe

You're still running from the USB stick. **This erases the NVMe.**

```
lsblk
```

Check that you see `nvme0n1` with your SSD's size. Then:

```
curl -L -o armbian.img.xz https://dl.armbian.com/radxa-dragon-q6a/Trixie_current_minimal
xz -dc armbian.img.xz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo poweroff
```

## Step 5: Boot from the NVMe

1. **Remove the USB stick**, then power on. With no USB stick, the board boots the NVMe.
2. The first-boot wizard runs again: set the root password and create your user again.
3. Check you're on the NVMe:
   ```
   findmnt -no SOURCE /
   ```
   It should print something starting with `/dev/nvme0n1`.

Armbian grows its partition to fill the SSD automatically on first boot.

## Step 6: Install the 7.2 "edge" kernel

```
sudo apt update
sudo apt install -y linux-image-edge-qcs6490 linux-dtb-edge-qcs6490
sudo reboot
```

After the reboot:

```
uname -r
```

It should start with `7.2`.

If the board doesn't come back after this reboot, plug the **USB stick** back in and power on. It still has the working 6.18 kernel and boots first. Tell me what you saw, and we'll fix the NVMe install from there, or run Stage 1 on 6.18 first.

## Step 7: Get the test tools

```
sudo apt install -y git
git clone -b ccr-7072d8e3-wdiujf https://github.com/elsattchmo/Radxa-OSes.git
cd Radxa-OSes
sudo ./q6a-test deps
```

If you already cloned it in step 3A, it was on the USB stick, which you've now replaced, so clone again. Later, to get my newest scripts:

```
cd ~/Radxa-OSes && git pull
```

## Step 8 (recommended): Connect from your PC over SSH

On the board:

```
ip -br a
```

Note the address on `end0` or `eth0` (for example `192.168.1.50`). Then on your PC (Windows 10/11 has `ssh` built in):

```
ssh you@192.168.1.50
```

Now you can run the tests from your PC while the TV shows the graphics.

## Stage 0 is done when

- [ ] `cat /sys/class/dmi/id/bios_version` contains `260916`
- [ ] `findmnt -no SOURCE /` shows `/dev/nvme0n1…`
- [ ] `uname -r` starts with `7.2`
- [ ] `~/Radxa-OSes` exists and `sudo ./q6a-test deps` finished

Next: [STAGE-1.md](STAGE-1.md)
