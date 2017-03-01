#!/bin/bash
set -e

declare -r logfile="installer.log"
RED='\033[0;31m' ; NC='\033[0m'  #No Color

chooseDisk=""
totalSize=-1
diskUse=-1
partitionTable=-1
custom=-1
uefi=0

declare -a partition ; declare -a mountpoint ;
declare -a filesystem         # /dev/sda1 - /boot - ext4
declare -a partedCMD          # command (mkpart, mklabel, set, ...)
declare -a pArg1 ; declare -a pArg2      
declare -a pArg3 ; declare -a pArg4

trap ctrl_c SIGINT


#################################################################


function ctrl_c {
   printf "\n\nUser hit ctrl+c, aborting all!\n\n"
   umount -R /mnt > /dev/null 2>&1
   swapoff "${chooseDisk}*" > /dev/null 2>&1
   exit 130
}


function userConfirmation {
   read -r -p "Are you sure you want to continue [yes/no]? "
   if [[ "$REPLY" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
      return 0
   else
      return 1
   fi
}


function internetCheck {
   printf "Checking internet connection - "
   if curl -Ss https://www.archlinux.org > /dev/null ; then
      printf "OK\n\n"
      return 0
   else
      exit 1
   fi
}


function chooseDisk {
   local aux ; local array ; local element

   printf 'This script works only with installations in a single media.\n'
   printf 'This mean that you cannot install "/boot" in /dev/sda1 and "/home" in /dev/sdb2.\n'
   printf "Choose the disk path between the list below:\n"
   aux=$(lsblk | egrep "^[[:alpha:]]" | cut -d " " -f1 | tail -n +2 | tr "\n" ";")
   IFS=";" read -r -a array <<< "${aux%?}"
   for element in "${array[@]}"; do
      printf "    /dev/${element}\n"
   done

   while true; do
      read -r -p "Disk path: "
      if fdisk -l "$REPLY" > /dev/null ; then
         chooseDisk="$REPLY"
         totalSize=$(fdisk -l "$chooseDisk" | head -n1 | cut -d "," -f2 | cut -d " " -f2)
         totalSize=$(($totalSize/1024/1024))
         return 0
      fi
   done

   return 1
}


function diskUse {
   printf "\nChoose how to use the disk:
   1 - Auto-layout : Format everything and use the whole disk, with a default(hard coded) layout.
   2 - Custom layout : Inform partitions already made OR format everything and create new partitions manually.\n"
   while true; do
      read -r -p "[1/2]: "
      if [[ "$REPLY" =~ ^(1|2)$ ]]; then
         diskUse="$REPLY"
         return 0
      fi
   done

   return 1
}


function formatDisk {
   printf "\nAnswering \"no\" to the next question won't mean that nothing will be lose, even because I'll rewrite the partition table and reformat everyrhing.\n"
   printf "Do you want to ${RED}OVERWRITE THE WHOLE DISK${NC} with shred? This action cannot be undone "
   read -r -p "[yes/no]: "
   if [[ ! "$REPLY" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
      printf "Skipping formatting\n\n"
      return 0
   fi

   printf "\nThis step may take some minutes or hours, be patient.\n"
   if shred -f -n1 -z -v "$chooseDisk" ; then
      printf "All done\n\n"
   else
      print "Shred error, continuing anyway\n\n"
   fi

   return 0
}


function partitionTable {
   if ls /sys/firmware/efi/efivars > /dev/null 2>&1 ; then
      uefi=1
      printf "UEFI motherboard FOUND. I strongly recommend GPT.\n\n"
   else
      printf "UEFI motherboard NOT FOUND.\n\n"
   fi

   printf "Choose the kind of system partition table.
   1 - MBR    (BIOS ONLY)
   2 - GPT    (BIOS or UEFI)\n"
   while true; do
      read -r -p "[1/2]: "
      if [[ "$REPLY" =~ ^(1|2)$ ]]; then
         partitionTable="$REPLY"
         return 0
      fi
   done

   printf "\nSomething went wrong in \"partitionTable\" function\n"
   return 1
}


function autoMBR {
   local root=$(($totalSize-1025))
   local j=0 ; local i=0

   printf "\nThis script works with ext4 and the following partition layout:
   ${chooseDisk}1 - /boot - 256MiB
   ${chooseDisk}2 - /     - $(($root-257))MiB
   ${chooseDisk}3 - swap  - 1024MiB\n"
   if ! userConfirmation; then
      printf "Returning to disk selection.\n\n"
      return 1
   fi

   partedCMD["$j"]="mklabel" ; pArg1["$j"]="msdos"   ; ((j++))
   partedCMD["$j"]="mkpart"; pArg1["$j"]="primary"; pArg2["$j"]="ext4" ; pArg3["$j"]="1MiB" ; pArg4["$j"]="257MiB" ; ((j++))
   partedCMD["$j"]="mkpart"; pArg1["$j"]="primary"; pArg2["$j"]="ext4" ; pArg3["$j"]="257MiB" ; pArg4["$j"]="${root}MiB" ; ((j++))
   partedCMD["$j"]="mkpart"; pArg1["$j"]="primary"; pArg2["$j"]="linux-swap"; pArg3["$j"]="${root}MiB" ; pArg4["$j"]="100%" ; ((j++))
   partedCMD["$j"]="set"   ; pArg1["$j"]="1"      ; pArg2["$j"]="boot" ; pArg3["$j"]="on"   ; ((j++))
   
   partition["$i"]="${chooseDisk}1" ; mountpoint["$i"]="/boot" ; filesystem["$i"]="ext4" ; ((i++))
   partition["$i"]="${chooseDisk}2" ; mountpoint["$i"]="/"     ; filesystem["$i"]="ext4" ; ((i++))
   partition["$i"]="${chooseDisk}3" ; mountpoint["$i"]="swap"  ; filesystem["$i"]="linux-swap" ; ((i++))

   return 0
}


function autoGPT {
   local root=$(($totalSize-1025))
   local j=0 ; local i=0

   if [[ "$uefi" -eq "1" ]]; then
      printf "\nThis script works with fat32, ext4 and the following partition layout:
      ${chooseDisk}1 - bios_grub   - 10MiB
      ${chooseDisk}2 - ESP | /boot - 520MiB
      ${chooseDisk}3 - /           - $(($root-531))MiB
      ${chooseDisk}4 - swap        - 1024MiB\n"
      if ! userConfirmation; then
         printf "Returning to disk selection.\n\n"
         return 1
      fi
      #uefi
      partedCMD["$j"]="mklabel"; pArg1["$j"]="gpt"   ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="1MiB" ; pArg3["$j"]="11MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="ESP"    ; pArg2["$j"]="fat32"; pArg3["$j"]="11MiB" ; pArg4["$j"]="531MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="ext4" ; pArg3["$j"]="531MiB"; pArg4["$j"]="${root}MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="linux-swap"; pArg3["$j"]="${root}MiB" ;pArg4["$j"]="100%"; ((j++))
      partedCMD["$j"]="set"    ; pArg1["$j"]="1"      ; pArg2["$j"]="bios_grub" ; pArg3["$j"]="on" ; ((j++))
      partedCMD["$j"]="set"    ; pArg1["$j"]="2"      ; pArg2["$j"]="boot"      ; pArg3["$j"]="on" ; ((j++))
      
      partition["$i"]="${chooseDisk}2" ; mountpoint["$i"]="/boot" ; filesystem["$i"]="fat32"      ; ((i++))
      partition["$i"]="${chooseDisk}3" ; mountpoint["$i"]="/"     ; filesystem["$i"]="ext4"       ; ((i++))
      partition["$i"]="${chooseDisk}4" ; mountpoint["$i"]="swap"  ; filesystem["$i"]="linux-swap" ; ((i++))
      
      return 0

   else
      printf "\nThis script works with ext4 and the following partition layout:
      ${chooseDisk}1 - bios_grub  - 10MiB
      ${chooseDisk}2 - /boot      - 256MiB
      ${chooseDisk}3 - /          - $(($root-267))MiB
      ${chooseDisk}4 - swap       - 1024MiB\n"
      if ! userConfirmation; then
         printf "Returning to disk selection.\n\n"
         return 1
      fi
      #bios
      partedCMD["$j"]="mklabel"; pArg1["$j"]="gpt"   ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="1MiB" ; pArg3["$j"]="11MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="ext4" ; pArg3["$j"]="11MiB" ; pArg4["$j"]="267MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="ext4" ; pArg3["$j"]="267MiB"; pArg4["$j"]="${root}MiB" ; ((j++))
      partedCMD["$j"]="mkpart" ; pArg1["$j"]="primary"; pArg2["$j"]="linux-swap"; pArg3["$j"]="${root}MiB" ;pArg4["$j"]="100%"; ((j++))
      partedCMD["$j"]="set"    ; pArg1["$j"]="1"      ; pArg2["$j"]="bios_grub" ; pArg3["$j"]="on" ; ((j++))
      partedCMD["$j"]="set"    ; pArg1["$j"]="2"      ; pArg2["$j"]="boot"      ; pArg3["$j"]="on" ; ((j++))
      
      partition["$i"]="${chooseDisk}2" ; mountpoint["$i"]="/boot" ; filesystem["$i"]="ext4"       ; ((i++))
      partition["$i"]="${chooseDisk}3" ; mountpoint["$i"]="/"     ; filesystem["$i"]="ext4"       ; ((i++))
      partition["$i"]="${chooseDisk}4" ; mountpoint["$i"]="swap"  ; filesystem["$i"]="linux-swap" ; ((i++))
      
      return 0
   fi


   printf "Error in \"autoGPT\" function, aborting...\n\n"
   return 1
}


function customLayout {
   printf "\nCustom layout have 2 modes:
   1 - Previously created partitions, just inform them and their mount points. Ideal for dual boot!
   2 - Create everything NEW, from nothing!\n"
   while true; do
      read -r -p "[1/2]: "
      if [[ "$REPLY" =~ ^(1|2)$ ]]; then
         custom="$REPLY"
         return 0
      fi
   done

   return 1
}


function oldPartition {
   declare -a pt ; declare -a mp ; declare -a fs
   local aux1="" ; local aux2="" ; local i=0

   printf "\nI will ask for the mount point ( /, /boot, /home, swap, ...) and their respective partition path."
   printf "\nTo finish, press [ENTER] in a empty \"mount point\" field.\n"
   printf "These are the available partitions paths in ${chooseDisk}:\n"
   blkid | egrep "^(${chooseDisk})" | cut -d ":" -f1 | tr "\n" "\t"
   printf "\n\n"

   while true; do
      while true; do
         read -r -p "Mount point: " aux1
         aux1=$(echo -n "$aux1" | tr '[:upper:]' '[:lower:]')
         if [[ -n "$aux1" ]]; then
            if [[ "$aux1" = "/swap" ]]; then
               printf 'To specify the swap partition, input only "swap"\n'
            else
               break
            fi
         else
            break 2
         fi
      done
      while true; do
         read -r -p "Partition path: " aux2
         if [[ "$aux2" =~ ^(${chooseDisk}[[:digit:]]+)$ ]] && (fdisk -l "$aux2" > /dev/null); then
            break
         fi
      done
      pt["$i"]="$aux2" ; mp["$i"]="$aux1" ; fs[$i]="" ; ((i++))
   done

   printf "\nLayout:\n"
   for (( aux1=0 ; aux1<$i ; aux1++ )); do
      echo "      ${pt[$aux1]} - ${mp[$aux1]}"
   done
   echo ""

   if ! userConfirmation; then
      unset pt ; unset mp ; unset fs
      printf "Returning to disk selection.\n\n"
      return 1
   else
      for (( aux1=0 ; aux1<$i ; aux1++ )); do
         partition["$aux1"]=${pt["$aux1"]}
         mountpoint["$aux1"]=${mp["$aux1"]}
         filesystem[$aux1]=${fs["$aux1"]}
      done
      echo ""
      return 0
   fi

   return 1
}


function setPartitions {
   declare -a pt ; declare -a mp ; declare -a fs
   local j=0 ; local i=0
   declare -a cmd ; declare -a arg1
   declare -a arg2 ; declare -a arg3
   declare -a arg4
   local begin=1 ; local end=-1
   local ts=$(($totalSize-4))    #ex: 8192-8
   local setBoot=0 ; local k=1
   local aux1="" ; local aux2=""

   printf "\nYou have chosen to create your partitions manually, so let's do it.\n"
   printf "This mode is very simple, but not very flexible.\n"
   printf "Just follow the instructions:
   1 - Inform the mount point for the given partition;
   2 - Inform the file system for the given mount point;
   3 - Infomr the size for the given mount point. NUMBERS ONLY!!;
   4 - To finish, press [ENTER] in a empty \"mount point\" field.\n"
   printf "Tips:
   1 - mount points is the same as / , /boot , swap, etc...
   2 - file system is the same as ext4, xfs, btrfs, fat32, etc..
   2 - I consider the size in MiB --> 1024MiB = 1GB. Be careful!
   3 - If you intend to separate /boot, make it as your first partition in disk.
   4 - GPT tables MUST have the first partition as \"bios_grub\", but I'll take care of it for you.
   5 - UEFI motherboards MUST have an \"EFI System Partition\"(ESP). I already take care of it, but if you separate your \"/boot\", I'll put in it.\n\n"


   if [[ "$partitionTable" -eq "1" ]]; then        # MBR
      cmd["$j"]="mklabel" ; arg1["$j"]="msdos" ; ((j++))
   elif [[ "$partitionTable" -eq "2" ]]; then      # GPT
      cmd["$j"]="mklabel" ; arg1["$j"]="gpt"     ; ((j++))
      cmd["$j"]="mkpart"  ; arg1["$j"]="primary" ; arg2["$j"]="${begin}MiB" ; arg3["$j"]="$(($begin+10))MiB" ; ((j++))
      cmd["$j"]="set"     ; arg1["$j"]="$k"      ; arg2["$j"]="bios_grub"   ; arg3["$j"]="on" ; ((j++))
      ((k++))
      begin=$(($begin+10))
      ts=$(($ts-10))
   else
      printf "Unknow error in partitionTable function: \"$partitionTable\"\n\n"
      return 1
   fi

   if [[ "$uefi" -eq "1" ]]; then   #uefi on
      cmd["$j"]="mkpart" ; arg1["$j"]="ESP" ; arg2["$j"]="fat32" ; arg3["$j"]="${begin}MiB" ; arg4["$j"]="$(($begin+520))MiB"; ((j++))
      cmd["$j"]="set"    ; arg1["$j"]="$k"  ; arg2["$j"]="boot"  ; arg3["$j"]="on" ; ((j++))
      pt["$i"]="${chooseDisk}${k}" ; mp["$i"]="/boot" ; fs["$i"]="fat32" ; ((i++))
      ((k++))
      begin=$(($begin+520))
      ts=$(($ts-520))
   fi

   while true; do
      if [[ "$ts" -eq "0" ]]; then
         printf "No space left, finishing.\n"
         break
      fi
      while true; do
         read -r -p "Mount point for ${chooseDisk}${k}: " aux1
         aux1=$(echo "$aux1" | tr '[:upper:]' '[:lower:]')
         if [[ -z "$aux1" ]]; then
            break 2
         elif [[ "$aux1" = "/boot" ]] && [[ "$uefi" -eq "1" ]]; then
            printf "Inserting /boot in ESP partition, next...\n"
            continue 2
         elif [[ "$aux1" = "/boot" ]]; then
            setBoot=1
            break
         elif [[ "$aux1" = "/swap" ]]; then
            printf "To create a swap partition, input just \"swap\"\n"
         elif [[ "$aux1" = "swap" ]] || [[ "$aux1" =~ ^(/[[:alnum:]]*)$ ]]; then
            break
         else
            printf "Inform something like: / , /boot , swap , etc...\n"
         fi
      done
      if [[ "$aux1" = "swap" ]]; then
         aux2="linux-swap"
      else
         while true; do
            read -r -p "File system for ${aux1}: " aux2
            if [[ -n $aux2 ]]; then
               break
            fi
         done
      fi
      printf "Remaining size: ${ts} MiB\n"
      while true; do
         read -r -p "Size of ${aux1} [MiB]: " end
         if [[ -n "$end" ]] && [[ "$end" -le "$ts" ]]; then
            break
         fi
      done

      cmd["$j"]="mkpart"; arg1["$j"]="primary"; arg2["$j"]="$aux2"; arg3["$j"]="${begin}MiB"; arg4["$j"]="$(($begin+$end))MiB"; ((j++))
      if [[ "$setBoot" -eq "1" ]]; then
         cmd["$j"]="set" ; arg1["$j"]="$k" ; arg2["$j"]="boot" ; arg3["$j"]="on" ; ((j++))
         setBoot=0
      fi
      pt["$i"]="${chooseDisk}${k}" ; mp["$i"]="$aux1" ; fs["$i"]="$aux2" ; ((i++))
      ((k++))
      begin=$(($begin+$end))
      ts=$(($ts-$end))
      echo ""
   done

   printf "\nLayout:\n"
   for (( aux1=0; aux1<$i; aux1++ )); do
      printf "    ${pt[$aux1]} - ${mp[$aux1]} - ${fs[$aux1]}\n"
   done
   echo ""

   if ! userConfirmation; then
      unset cmd ; unset arg1
      unset arg2 ; unset arg3 ; unset arg4
      unset pt ; unset mp ; unset fs
      printf "Returning to disk selection.\n\n"
      return 1
   else
      for (( aux1=0 ; aux1<$i ; aux1++ )); do
         partition["$aux1"]=${pt["$aux1"]}
         mountpoint["$aux1"]=${mp["$aux1"]}
         filesystem["$aux1"]=${fs["$aux1"]}
      done
      for (( aux1=0 ; aux1<$j ; aux1++ )); do
         partedCMD["$aux1"]=${cmd["$aux1"]}
         pArg1["$aux1"]=${arg1["$aux1"]}
         pArg2["$aux1"]=${arg2["$aux1"]}
         pArg3["$aux1"]=${arg3["$aux1"]}
         pArg4["$aux1"]=${arg4["$aux1"]}
      done
      echo ""
      return 0
   fi

   return 1
}


function createPartition {
   local len=${#partedCMD[@]} ; local aux1=0

   fdisk -l "$chooseDisk" > /dev/null &&
   parted -s "$chooseDisk" unit MiB &&
   for (( aux1=0 ; aux1<$len ; aux1++ )); do
      parted -s ${chooseDisk} ${partedCMD["$aux1"]} ${pArg1["$aux1"]} ${pArg2["$aux1"]} ${pArg3["$aux1"]} ${pArg4["$aux1"]} || { 
         printf "Partitioning #${aux1} FAILURE! Returning to disk selection\n\n" ; return 1; }
   done

   printf "\n"
   parted "$chooseDisk" unit "MiB" print
   read -r -p "Press [ENTER] to continue"
   printf "Partitioning completed\n\n"

   return 0
   #parted -s "$chooseDisk" mkpart extended "${root}MiB" 100%
   #parted -s "$chooseDisk" mkpart logical  "${root}MiB" 100%
}


function writePartition {
   local len=${#partition[@]} ; local aux1=0 ; local aux2=32;

   fdisk -l "$chooseDisk" > /dev/null &&
   for (( aux1=0 ; aux1<$len ; aux1++ )); do
      if [[ ${filesystem["$aux1"]} =~ ^(fat[[:num:]]*)$ ]]; then
         aux2=$(echo ${filesystem["$aux1"]} | egrep -o "[[:digit:]]{2}$")
         mkfs -t fat -c -F $aux2 ${partition["$aux1"]} > /dev/null || {
            printf "Formatting(#${aux1}) ${filesystem["$aux1"]} FAILURE! Returning to disk selection\n\n" ; return 1; }
      elif [[ ${filesystem["$aux1"]} = "linux-swap" ]]; then
         mkswap -c ${partition["$aux1"]} > /dev/null || {
            printf "mkswap FAILURE! Returning to disk selection\n\n" ; return 1; }
      else
         mkfs -t ${filesystem["$aux1"]} -c ${partition["$aux1"]} > /dev/null || {
            printf "Formatting(#${aux1}) ${filesystem["$aux1"]} FAILURE! Returning to disk selection\n\n" ; return 1; }
      fi
   done

   printf "Formatting completed\n"
   
   return 0
   #mkfs.fat -c -F32 -n "ESP_BOOT" "${chooseDisk}2" > /dev/null &&
   #mkfs.ext4 -c -F -L "root" -q "${chooseDisk}3" > /dev/null &&
}


function mountPartition {
   #partition ; mountpoint ; filesystem
   local aux1 ; local len=${#partition[@]}


   for (( aux1=0 ; aux1<$len ; aux1++ )); do
      if [[ ${mountpoint["$aux1"]} = "/" ]]; then
         mount ${partition["$aux1"]} /mnt > /dev/null &&
         unset partition["$aux1"] &&
         unset mountpoint["$aux1"] &&
         unset filesystem["$aux1"] || {
            printf "Root(/) mounting FAILURE! Returning to disk selection.\n\n" ; return 1; }
      fi
   done

   for (( aux1=0 ; aux1<$len ; aux1++ )); do
      if [[ -z ${mountpoint["$aux1"]} ]]; then
         continue
      elif [[ ${mountpoint["$aux1"]} = "swap" ]]; then
         swapon ${partition["$aux1"]} || {
            printf "Swapon in ${partition[$aux1]} FAILURE! Returning to disk selection.\n\n" ; return 1; }
      else
         mkdir -p /mnt${mountpoint["$aux1"]} > /dev/null &&
         mount ${partition["$aux1"]} /mnt${mountpoint["$aux1"]} > /dev/null || {
            printf "Mount ${mountpoint[$aux1]} in ${partition[$aux1]} FAILURE! Returning to disk selection.\n\n" ; return 1; }
      fi
   done
   
   printf "Mounting completed\n\n"
   
   return 0 
}
   

function installation {
   printf "Wait a sec, you'll edit your mirrorlist file now!\n\n"
   while true; do
      sleep 3
      if ! vim /etc/pacman.d/mirrorlist ; then
         printf "\nMirrorlist edition FAILURE, try again.\n"
      else
         break
      fi
   done

   printf "\n"
   internetCheck

   printf "Installing base system (base and base-devel)\n\n"
   if ! pacstrap -i /mnt base base-devel ; then
      printf "\nBase system installation FAILURE, aborting.\n"
      return 1
   fi

   while true; do
      printf "\nGenerating fstab file\n"
      if ! genfstab -U /mnt > /mnt/etc/fstab ; then
         printf "fstab generation FAILURE, trying again in 5 secs\n"
         sleep 5
      else
         break
      fi
   done

   return 0
}


function configure {
   local pac="" ; local uCode="" ; local efimgr="" ; local grb=""

   if lscpu | grep -i intel > /dev/null ; then
      uCode="intel-ucode"
   fi

   if [[ "$uefi" -eq "1" ]] ; then
      efimgr="efibootmgr"
      grb="grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub"
   else
      grb="grub-install --recheck --target=i386-pc $chooseDisk"
   fi

   pac="pacman -S --noconfirm grub os-prober $efimgr $uCode"

   printf "\n"
   internetCheck

   printf "Configuring base system\n"
   arch-chroot /mnt /bin/bash <<_EOF_
echo "pt_BR.UTF-8 UTF-8" > /etc/locale.gen &&
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen &&
locale-gen > /dev/null &&
echo "LANG=pt_BR.UTF-8" > /etc/locale.conf &&
echo "KEYMAP=br-abnt2" > /etc/vconsole.conf &&
export TZ="America/Sao_Paulo" &&
ln -s /usr/share/zoneinfo/America/Sao_Paulo > /etc/localtime &&
hwclock --systohc --utc > /dev/null &&
printf "\nDownloading and installing grub\n\n" &&
$pac &&
printf "\nConfiguring grub\n\n" &&
$grb &&
grub-mkconfig -o /boot/grub/grub.cfg &&
echo "root:123123" | chpasswd &&
echo CHANGEME > /etc/hostname &&
exit 0 || exit 1
_EOF_
   return "$?"
}


#################################################################


clear
printf "Welcome to Arch Installer v1.0
This bash script will **TRY** to install Arch Linux on your computer/VM.
It works with some hard coded post system configurations like:
   Language: pt_BR.UTF-8 UTF-8
   Keymap: br-abnt2
   Timezone: America/Sao_Paulo
   Hwclock: UTC
   Default user/password: root/123123
If these aren't your options, you can change them in the \"configure\" function inside source code (don't worry, it's easy ;)

Despite some efforts, this scritp was not designed to be user proof, so don't try to mess with it, because it will mess with your computer in return.

Although this script support and work with UEFI, I didn't have the opportunity (yet) to test in this environment.

Hit \"ctrl+c\" anytime to abort everything!

Disclaimer: ${RED}This script comes with absolutely NO warranty and I bear NO responsibility for any damage or data loss in your computer or in any data storage connected to it. Use at your own risk! You have been warned!${NC}\n\n"

if ! userConfirmation; then
   printf "Action denied by user, aborting...\n\n"
   exit 1
fi
clear

echo ""
internetCheck


while true; do
   chooseDisk
   diskUse
   if [[ "$diskUse" -eq "1" ]]; then      #auto-layout
      formatDisk
      if ! partitionTable ; then
         continue
      fi
      if [[ "$partitionTable" -eq "1" ]]; then     #MBR
         if ! autoMBR ; then
            continue
         fi          
         if ! createPartition ; then
            continue
         fi
         if ! writePartition ; then
            continue
         fi
         if ! mountPartition ; then
            continue
         fi
         break
      elif [[ "$partitionTable" -eq "2" ]]; then   #GPT
         if ! autoGPT ; then
            continue
         fi 
         if ! createPartition ; then
            continue
         fi
         if ! writePartition ; then
            continue
         fi
         if ! mountPartition ; then
            continue
         fi
         break
      else
         printf "Unknow error in partitionTable function: \"${partitionTable}\"\n\n"
         exit 1
      fi

   elif [[ "$diskUse" -eq "2" ]]; then    #custom layout
      customLayout
      if [[ "$custom" -eq "1" ]]; then    #pre-made partitions
         if ! oldPartition ; then
            continue
         fi
         if ! mountPartition ; then
            continue
         fi
      elif [[ "$custom" -eq "2" ]]; then    #all new
         formatDisk
         if ! partitionTable ; then
            continue
         fi
         if ! setPartitions ; then
            continue
         fi 
         if ! createPartition ; then
            continue
         fi
         if ! writePartition ; then
            continue
         fi
         if ! mountPartition ; then
            continue
         fi
      else
         printf "Unknow error in customLayout function: \"${custom}\"\n\n"
         exit 1
      fi
      break

   else
      printf "Unknow error in diskUse function: \"${diskUse}\"\n\n"
      exit 1
   fi
done


if ! installation ; then
   printf "Installation FAILURE! Aborting...\n\n"
   exit 1
fi


if configure ; then
   umount -R /mnt > /dev/null 2>&1
   printf "\nCongratulations! Reboot your system, remove the installation media and enjoy your new system (or almost it).\n\n"
   exit 0
else
   umount -R /mnt > /dev/null 2>&1
   swapoff "${chooseDisk}*" > /dev/null 2>&1
   printf "\nConfiguring FAILURE! Aborting...\n\n"
   exit 1
fi
