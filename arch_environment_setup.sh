#!/bin/bash

#trap ctrl_c SIGINT
#function ctrl_c {
#   return break
#}


clear
printf "\nWelcome to Arch environment setup.
If you used the Arch installer, this script is for you. It setup a basic environment in your machine.
ctrl+d may be used to skip a input.\n\n"
sleep 1


printf "Change root password, because I know you still have the default one!\n"
passwd root


printf "\nChange hostname too!\n"
read -r -p "hostname: " hostname
if [[ -n "$hostname" ]]; then
   echo "$hostname" > /etc/hostname
fi


printf "\n\nCreate a new default and unprivileged user.\n"
read -r -p "User name: " userName
if useradd -d "/home/${userName}" -s /bin/bash -m "$userName" ; then
   passwd "$userName"
fi


printf "\nEnabling wired network connection.\n"
printf "Choose below the default wired interface:\n"
ip a | egrep "^[[:digit:]]{1,2}:" | cut -d ":" -f2
read -r -p "Interface name: "
if dhcpcd -N "$REPLY" > /dev/null ; then
   if ping -c3 -w10 -q 8.8.8.8 > /dev/null 2>&1 ; then
      systemctl enable dhcpcd@"$REPLY" > /dev/null
      printf "Connected\n\n"
   else
      printf "NOT connected\n\n"
   fi
else
   printf "Couldn't start dhcpcd to ${REPLY}\n\n"
fi


printf "Configuring repositories with multilib and archlinuxfr(yaourt)\n\n"
cat >> /etc/pacman.conf <<_EOF_

[multilib]
Include = /etc/pacman.d/mirrorlist

[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/\$arch

_EOF_


printf "Updating system.\n"
pacman -Syu


printf "\nInstalling basic softwares.\n\n"
declare -a vga
if lspci | grep -i "vga" | egrep -i "(nvidia|geforce)" > /dev/null ; then
   printf "Nvidia card found, choose the driver:
   1 - xf86-video-nouveau     (open source)
   2 - nvidia
   3 - nvidia-304xx
   4 - none\n"
   read -r -p "Driver [1/2/3/4]: "
   if [[ "$REPLY" -eq "1" ]]; then
      vga+=("xf86-video-nouveau")
   elif [[ "$REPLY" -eq "2" ]]; then
      vga+=("nvidia")
   elif [[ "$REPLY" -eq "3" ]]; then
      vga+=("nvidia-304xx")
   fi
fi

if lspci | grep -i "vga" | egrep -i "( amd | ati | radeon )" > /dev/null ; then
   printf "ATI/AMD card found, choose the driver:
   1 - xf86-video-ati   (open source)
   2 - catalyst-dkms    (proprietary - yaourt only, install manually later)
   3 - none\n"
   read -r -p "Driver [1/2/3]: "
   if [[ "$REPLY" -eq "1" ]]; then
      vga+=("xf86-video-ati")
   fi
fi

if lspci | grep -i "vga" | grep -i "intel" > /dev/null ; then
   printf "Intel card found\n"
   vga+=("xf86-video-intel")
fi

if [[ "${#vga[@]}" -eq "0" ]]; then
   printf "Graphic card not found, installing default (vesa).\n"
   vga+=("xf86-video-vesa")
fi

echo ""
read -r -p "Do you intend to use wi-fi in this machine [yes/no]? "
if [[ "$REPLY" =~ (yes|y) ]]; then
   wifi="iw wpa_supplicant dialog"
fi

printf "\nChoose the Desktop Environment:
   1 - gnome 3
   2 - xfce 4
   3 - none\n"
read -r -p "DE [1/2/3]: "
if [[ "$REPLY" -eq "1" ]]; then
   de="xorg-server xorg-xinit gnome gnome-screensaver"
   de2=1
elif [[ "$REPLY" -eq "2" ]]; then
   de="xorg-server xorg-xinit xfce4"
   de2=2
fi
echo ""

#bash-completion xorg-server-utils xf86-input-synaptics
pacman -S openssh vim yaourt ${vga[@]} $wifi $de || {
   printf "Installation failure, aborting...\n" ; exit 1; }


if [[ -n "$userName" ]]; then
   printf "\nCreating .xinitrc in /home/${userName}\n"
   if [[ "$de2" -eq "1" ]]; then
      systemctl stop gdm.service > /dev/null
      systemctl disable gdm.service > /dev/null
      head -n -5 /etc/X11/xinit/xinitrc | tee /home/$userName/.xinitrc > /dev/null
      echo 'gnome-screensaver &' >> /home/$userName/.xinitrc
      echo 'exec gnome-session' >> /home/$userName/.xinitrc
   elif [[ "$de2" -eq "2" ]]; then
      head -n -5 /etc/X11/xinit/xinitrc | tee /home/$userName/.xinitrc > /dev/null
      echo 'exec startxfce4' >> /home/$userName/.xinitrc
   fi
else
   printf "\nSkipping .xinitrc creation, no username provided.\n"
fi


printf "\nAll Done, reboot your system and enjoy!\n"
printf "If you installed a desktop environment, you can start it after login typing:
   $ startx\n\n"
exit 0
