# LUKS-guided-manual-partitioning
Easily install Ubuntu with FDE and semi-manual partitioning see the full write-up [here](https://adventures-in-tech.blogspot.com/2018/10/encrypted-ubuntu-installation-with.html)

In short, LGMP enables you to set up an encrypted Ubuntu installation with semi-manual partitioning. In fact, if you know what you're doing, you could very easily set up additional logical volumes during the installation process.
In addition, LGMP creates some useful scripts on the desktop that can be used to change the encryption passphrase or recover from a forgotten passphrase, recover from corrupted LUKS headers, and reinstall to the same encrypted setup, keeping /home intact.

Simply copy the LGMP.sh script to a system running a Live Ubuntu OS from USB or DVD, and run it. It will walk you through the process step-by-step. Have multiple disks and you want to install to /dev/sdb? No problem. The script can handle that.

This script has been tested on the following Ubuntu OSs:
  * 20.04

List of steps this script automates:
* Switch to root if necessary
* Choose the disk you wish to install to
* Warn th euser of the destructive nature of the disk partitioning
* Disable any active LVM volumes/groups
* Close any open LUKS partitions
* Wipe the disk partition table and create a new one (msdos/gpt)
* Get the desired partition/volume sizes
* Create a LUKS keyfile for autodecryption during boot
* Get the LUKS passphrase
* Create the partitions/volumes
This script will pause during Ubuntu installation. After the rinstallationis finished it will continue to:

* Query for trim usage
* Mount required volumed into /target
* Create the crypttab file
* Chroot into /target to update /boot
* Save a copy of the LUKS header and keyfile
