#!/bin/bash
# desc: setup partition and system info

# text formatting codes
readonly NORMAL_TEXT='\e[0m'
readonly BOLD_TEXT='\e[1m'
readonly YELLOW='\e[93m'
readonly GREEN='\e[92m'
readonly RED='\e[91m'

readonly defBootSize='1G'
readonly defRootSize='10G'
readonly defEFISize='512M'
readonly defLvmSize='-1M'
readonly defHomeSize='100%'


# function to convert things like 2G or 1M into bytes
bytes() {
    num=${1:-0}
    numfmt --from=iec "$num" 2> /dev/null || return 1
}

# get upper and lower bounds given the start and size
bounds() {
    start=$(bytes "$1")
    size=$2
    stop=$(( start + $(bytes "$size") - 1))
    echo "$start" "$stop"
}

doTrim() {
    [ "${trim,,}" == 'y' ] || return 1;
}

isEFI() {
    mount | grep -qi efi && return 0 || return 1
}

hasKeyfile() {
    [ "${keyfileSize,,}" == "none" ] && return 1 || return 0
}

# generate partition paths; expects a single argument, the partition number
getDiskPartitionByNumber() {
    partNum=$1
    if grep -iq "nvme" <<< "$disk"; then
        # partitions for this disk follow an NVMe naming standard
        part="${disk}p${partNum}"
    else
        # partitions for this disk follow a SATA, IDE, SCSI naming standard
        part="${disk}${partNum}"
    fi
    
    # wait until partition is visible to the system; fixes NVMe race condition following partition creation
    while [ ! -e "${part}" ]
    do
        sleep .5
    done
        echo "$part"
}

#---------------------------------------------------begin stage one---------------------------------------------------#

clear

if [ "$(whoami)" != root ]
then
    echo "Restarting with sudo"
    sudo bash "$0"
    exit
fi

# Choose the disk we're installing to
disks=$(lsblk | grep -P "disk *$" | awk '{print "/dev/"$1}')
while :
do
    [ "$(wc -l <<< "$disks")" -eq 1 ] && opt=1 && break
    echo "The following disks have been detected. To which disk would you like to install?"
    i=1
    for opt in $disks
    do
        printf "   [%$((1+$(wc -l <<< "$disks")/10))d] %s\n" $((i++)) "$opt"
    done
    read -rp "Enter the number of your selection: " opt
    [ "$opt" -gt 0 ] && [ "$opt" -lt "$i" ] && clear; break
done
disk=$(sed -n "${opt}p" <<< "$disks")

# warn user of the distructive nature of this script
clear
printf "WARNING: Continuing will destroy any data that may currently be on %s.\n" "$disk"
printf "Please ensure there are no other operating systems or files that you may want \nto keep on this disk!"
read -rp "To continue, type ERASE in caps: " opt
[ "$opt" != "ERASE" ] && echo -e "No changes made!" && read -rp "Press [Enter] to exit." && exit
clear

# disable any active LVM partitions
lvs=$(lvs --noheadings --rows | head -n1)
if [ -n "$lvs" ]; then
    echo -n "Deactivating LVM volumes ... "
    for lv in $lvs
    do
        lvchange -an "$lv" > /dev/null 2>&1
    done
    echo -e "${GREEN}done${NORMAL_TEXT}"
fi

# close any open LUKS disks
path=""
find /dev/mapper -type l | while read -rp path
do
    dev=$(basename "$path")
    cryptsetup status "$dev" > /dev/null 2>&1 || exit
    echo -n "Closing LUKS device: $dev ... "
    cryptsetup close "$dev" && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"
done
    

# wipe the disk partition info and create new gpt partition table
dd if=/dev/zero of="$disk" bs=1M count=10 2> /dev/null
if isEFI; then
    tableType='gpt'
else
    tableType='msdos'
fi
parted "$disk" mktable $tableType > /dev/null 2>&1 # create partition table

# get the desired partition/volume sizes

totalRAM=$(head -n1 < /proc/meminfo | grep -oP "\d+.*" | tr -d ' B' | tr '[:lower:]' '[:upper:]' | numfmt --from iec --to iec --format "%.f" | sed -e 's/.$//')
maxSWAP=$(echo "scale=0; sqrt($totalRAM)" | bc)

# get the required partition sizes or use defaults
read -rp "Size for /boot: " -i ${defBootSize} bootSize
isEFI && read -rp "Size for /boot/efi: " -i ${defEFISize} efiSize	# execute only if EFI is in use
read -rp "Size for LVM: " -i ${defLvmSize} lvmSize
read -rp "Size for swap in LVM: " -i "${maxSWAP}" swapSize
read -rp "Size for / (root) in LVM: " -i ${defRootSize} rootSize
read -rp "Percent of remaining LVM space to use for /home: " -i ${defHomeSize} homeSize

echo

# get the LUKS passphrase
while :
do
    echo "Nothing will be displayed as you type passphrases!"
    read -srp "Encryption passphrase: " luksPass && echo
    [ "$luksPass" == "" ] && echo "Oops, looks like you forgot to provide a passphrase. Try again." && continue
    read -srp "Confirm encryption passphrase: " confirm
    clear
    [ "$luksPass" == "$confirm" ] && break
    echo "passphrases didn't match or passphrase was blank! Try again"
done

# generate the LUKS keyfile
echo  -e 'In addition to the passphrase you provided, a keyfile can be generated that can \nalso be used for decryption. It is STRONGLY RECOMMENDED that you create this \nfile and store it in a secure location to be used in the event that you ever \nforget your passphrase!\n'
read -rp "Key file size in bytes, or 'none' to prevent key file creation [512]: " keyfileSize && keyfileSize=${keyfileSize:-512}
keyfile=/tmp/LUKS.key
hasKeyfile && dd if=/dev/urandom of="${keyfile}" bs="${keyfileSize}" count=1 2> /dev/null
clear

# fill in the partition size variables with values or defaults
parts="efi=$efiSize boot=$bootSize lvm=$lvmSize swap=${swapSize} root=$rootSize home=$homeSize"
for part in $parts
do
    name=$(cut -f1 -d= <<< "$part")
    [ "$name" == "efi" ] && ! isEFI && continue
    [ "${!name}" ] || eval "${part}"
done
grep -q "%" <<< "${home}" || home="${home}%"

# create physical partitions
clear
offset="1M"	#offset for first partition
physicalParts="boot:ext4 efi:fat32 lvm"
index=$(bytes $offset)
for part in ${physicalParts}
do
    name=$(cut -f1 -d: <<< "$part")
    type=$(awk -F ':' '{print $2}' <<< "$part")
    [ "$name" == "efi" ] && ! isEFI && continue
    if [ "${!name}" == "-1MB" ]; then
        echo -n "Creating $name partition that uses remaining disk space... "
    else
        echo -n "Creating ${!name} $name partition ... "
    fi
    if [ "${!name:0:1}" == "-" ]; then
        parted "$disk" -- unit b mkpart primary "$type" "$index" "${!name}" > /dev/null 2>&1 && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"
    else
        parted "$disk" unit b mkpart primary "$type" "$(bounds "$index" "${!name}")" > /dev/null 2>&1 && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"
        # move index one byte past newly created sector
        index+=$(bytes" ${!name}")
    fi
done

bootPart=$(getDiskPartitionByNumber 1)
isEFI && efiPart=$(getDiskPartitionByNumber 2)

# setup LUKS encryption
echo "Setting up encryption:"
isEFI && luksPart=$(getDiskPartitionByNumber 3) || luksPart=$(getDiskPartitionByNumber 2)
cryptMapper="${luksPart/\/dev\/}_crypt"
echo -en "  Encrypting ${luksPart} with your passphrase ... "
echo -n "${luksPass}" | cryptsetup luksFormat -c aes-xts-plain64 -h sha512 -s 512 --iter-time 5000 --use-random -S 1 -d - "${luksPart}"
echo -e "${GREEN}done${NORMAL_TEXT}"
if hasKeyfile; then
    echo -e "  ${BOLD_TEXT}We're going to need some random data for this next step. If it takes long, try  moving the mouse around or typing on the keyboard in a different window.${NORMAL_TEXT}"
    echo -n "  Adding key file as a decryption option for ${luksPart} ... "
    cryptsetup luksAddKey "${luksPart}" "${keyfile}" <<< "${luksPass}"
    echo -e "${GREEN}done${NORMAL_TEXT}"
fi

# unlock LUKS partition
echo -n "  Decrypting newly created LUKS partition ... "
echo -n "$luksPass" | cryptsetup luksOpen "${luksPart}" "${cryptMapper}" && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"

# setup LVM and create logical partitions
echo "Setting up LVM:"
pvcreate /dev/mapper/"${cryptMapper}" > /dev/null 2>&1
vgcreate vg0 /dev/mapper/"${cryptMapper}" > /dev/null 2>&1
echo -n "  Creating  ${swapSize} swap logical volume ... "
lvcreate -n swap -L "${swapSize}" vg0 > /dev/null 2>&1 && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"
echo -n "  Creating ${rootSize}  root logical volume ... "
lvcreate -n root -L "${rootSize} " vg0 > /dev/null 2>&1 && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"
spaceLeft=$(bc <<< "$(vgdisplay --units b | grep Free | awk '{print $7}')"*"$(tr -d '%' <<< "$homeSize")"/100 | numfmt --to=iec)
echo -n "  Creating ${spaceLeft} home logical volume ... "
lvcreate -n home -l +"${homeSize}"free vg0 > /dev/null 2>&1 && echo -e "${GREEN}done${NORMAL_TEXT}" || echo -e "${RED}failed${NORMAL_TEXT}"

# stage one complete; pause and wait for user to perform installation
echo -e "${YELLOW}${BOLD_TEXT}\n\nAt this point, you should KEEP THIS WINDOW OPEN and start the installation \nprocess. When you reach the \"Installation type\" page, select \"Something else\" \nand continue to manual partition setup.\n  ${bootPart} should be used as ext2 for /boot\n $(isEFI && printf "  %s should be used as EFI System Partition\n" "$efiPart" )  /dev/mapper/vg0-home should be used as ext4 for /home\n  /dev/mapper/vg0-root should be used as ext4 for /\n  /dev/mapper/vg0-swap should be used as swap\n  $disk should be selected as the \"Device for boot loader installation\"${NORMAL_TEXT}"
echo
echo -e "${BOLD_TEXT}After installation, once you've chosen the option to continue testing, press     [Enter] in this window.${NORMAL_TEXT}"
read -rs && echo

#---------------------------------------------------begin stage two---------------------------------------------------#

echo

# query for trim usage
echo -e "If you are installing to an SSD, you can enable trim. Beware, some SSD\nmanufacturers advise against the use of trim with their drives! The use of trim\nwith encryption also presents some security concerns in that, while it may not\nexpose encrypted data, it may expose information about encrypted data. If you\nare unsure, don't enable, and be sure to check your manufacturer\nrecommendations. Also, if you plan to use LVM snapshots, do not enable trim."
read -rp "Enable trim [y/N]: " trim


# mount stuff for chroot
echo -n "Mounting the installed system ... "
mount /dev/vg0/root /mnt
mount /dev/vg0/home /mnt/home
mount "${bootPart}" /mnt/boot
isEFI && mount "${efiPart}" /mnt/boot/efi
mount --bind /dev /mnt/dev
mount --bind /run/lvm /mnt/run/lvm
echo -e "${GREEN}done${NORMAL_TEXT}"

# create crypttab entry
echo -n "Creating /etc/crypttab entry ... "
luksUUID="$(blkid | grep "$luksPart" | tr -d '"' | grep -oP "\bUUID=[0-9a-f\-]+")"
echo -e "${cryptMapper}\t${luksUUID}\tnone\tluks" > /mnt/etc/crypttab
chmod 600 /mnt/etc/crypttab
echo -e "${GREEN}done${NORMAL_TEXT}"

# enable trim if requested
# trim implemented using instructions found at http://blog.neutrino.es/2013/howto-properly-activate-trim-for-your-ssd-on-linux-fstrim-lvm-and-dmcrypt/
if doTrim; then
    echo -n "Enabling trim ... "
    # enable trim for LUKS
    sed -i 's/luks$/luks,discard/' /etc/crypttab

    # enable trim in LVM
    lineStr="$(grep -nP "issue_discards ?=" /etc/lvm/lvm.conf )"
    lineNum=$(cut -f1 -d: <<< "$lineStr")
    replaceText="$(cut -f2 -d: <<< "$lineStr" | tr -d '#' | sed 's/issue_discards.*/issue_discards = 1/')"
    sed -i "${lineNum}s/.*/$replaceText/" /etc/lvm/lvm.conf
    
    # enable weekly fstrim
    allParts="/ /boot /home $(isEFI && echo "/boot/efi")"
    cat << EOF > /etc/cron.weekly/dofstrim
#! /bin/sh
for mount in $allParts
do
    fstrim \$mount
done
EOF
    chmod 755 /etc/cron.weekly/dofstrim
    echo -e "${GREEN}done${NORMAL_TEXT}"
fi

# chroot and update the boot files
echo "Updating your boot files:"
echo '#!/bin/bash
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devpts devpts /dev/pts
update-initramfs -k all -c
update-grub > /dev/null 2>&1' > /mnt/boot-update.sh
chmod +x /mnt/boot-update.sh
chroot /mnt "./boot-update.sh"
rm /mnt/boot-update.sh

# save some files to the installed users desktop
user=$(grep "1000:1000" < /mnt/etc/passwd |  cut -f1 -d:)
dest=/mnt/home/$user/Desktop
mkdir -p "$dest"

# save a backup of the LUKS header
cryptsetup luksHeaderBackup "$luksPart" --header-backup-file "$dest/LUKS.header"

# if one was created, save the LUKS keyfile to desktop of system user
if hasKeyfile; then
    echo
    name=$(basename $keyfile)
    mv "$keyfile" "$dest"
    echo -e "${YELLOW}${BOLD_TEXT}Your LUKS key file and a passphrase reset script have been saved in \n${dest/\/mnt/} on the installed system. Guard these files because \neither can be used to decrypt your system! \nFollowing your first boot, move these files to a secure location ASAP! ${NORMAL_TEXT}"
fi

chmod 400 "$dest"/*
chmod u+x "$dest"/*.sh
chown -R 1000:1000 "$dest"

echo
echo "${GREEN}All finished! ${NORMAL_TEXT}"
echo "After rebooting your system, you will be able to decrypt with the passphrase you"
echo "provided or the key file you saved."
read -rsp "Press [Enter] to reboot" && echo
reboot