#!/usr/bin/env zsh

# ./install.zsh --timezone Europe/Moscow --hostname oborona --locales en_US.UTF-8,ru_RU.UTF-8 --partition /dev/sda=efi:200M,boot:fat:200M,pv1:lvm --vg pv1 --lv 'swap:enc:-L 1G,root:enc:-l 100%FREE'

zmodload zsh/zutil

declare mnt_root
declare -A partitions
declare -aU devs vgs
declare lvm_enabled=
declare encryption_enabled=
declare timezone
declare -aU locales
declare hostname
declare initramfs=mkinitcpio
declare bootldr=uki
declare efi_entry="Arch Linux"
declare luks_passphrase
declare kernel_pkg=linux
declare kernel_cmdline=

function assoc_set() {
  local arr=$1
  shift
  _=${(PAA)=arr::="${(@kv)${(P)arr}}" "$@"}
}

function array_append() {
  local arr=$1
  shift
  _=${(PA)=arr::="${(@)${(P)arr}}" "$@"}
}

function assign() {
  local var=$1 opt=$2
  _=${(P)var::=$opt}
}

function declare_dev() {
  local dev=$1
  if (( ${(P)+dev} )) {
    if [[ ${${(P)dev}[pt_num]} ]] {
      local disk=${${(P)dev}[disk]}
      die "$dev is already defined as a partition of $disk"
    }

    if [[ ${${(P)dev}[lvargstr]} ]] {
      local vg=${${(P)dev}[vg]}
      die "$dev is already defined as a logical volume of $vg"
    }

    if [[ ${${(P)dev}[vgcreate]} == yes ]] {
      local vg=${${(P)dev}[vg]}
      die "$dev is already defined as a volume group '$vg'"
    }

    die "'$dev' is reserved and cannot be used as a device identifier"
  }
  declare -gA $dev
  devs+=($dev)
}

function partition_disks() {
  local disk dev pt_devs
  for disk pt_devs (${(kv)partitions}) {
    local args=(--clear)
    pt_devs=(${=pt_devs})
    for dev ($pt_devs) {
      local pt_guid=$(uuidgen)
      local device_ref="PARTUUID=${pt_guid}"
      assoc_set $dev pt_guid $pt_guid device_ref $device_ref

      if [[ ${${(P)dev}[luks]} == yes ]] {
        local typecode='8309'
      } elif [[ $dev == efi ]] {
        local typecode='EF00'
      } elif [[ $dev == boot && $boot[xbootldr] == yes ]] {
        local typecode='EA00'
      } else {
        local fs=${${(P)dev}[fs]}
        case $fs {
          (fat)
            local typecode='0B00'
            ;;
          (swap)
            local typecode='8200'
            ;;
          (ext2|ext3|ext4)
            local typecode='8300'
            ;;
          (lvm)
            local typecode='8E00'
            ;;
          (*)
            die "Unsupported file system '${fs}'"
            ;;
        }
      }
      local pt_num=${${(P)dev}[pt_num]}
      local pt_size=${${(P)dev}[pt_size]}
      if [[ -n $pt_size ]] {
        args+=(--new "${pt_num}::+${pt_size}")
      } else {
        args+=(--new $pt_num)
      }
      args+=(--typecode "${pt_num}:${typecode}" --partition-guid "${pt_num}:${pt_guid}")
    }
    args+=(--print)
    say "Making GPT on $disk"
    cmd sgdisk $args $disk

    # Look up devices by partition UUIDs.
    for dev ($pt_devs) {
      local device_ref=${${(P)dev}[device_ref]}
      local device=$(blkid -o device -t $device_ref)
      if [[ -z $device ]] {
        die "Failed to look up device ${device_ref}"
      }
      assoc_set $dev device $device
    }
  }
}

function create_lvm_volumes() {
  local vg dev
  for vg ($vgs) {
    local plvols="vg_${vg}_lvols"
    for dev (${(P)plvols}) {
      local lvolname=${${(P)dev}[lvolname]}
      local lvargstr=${${(P)dev}[lvargstr]}
      local lvargs=(${(Q)${(z)lvargstr}})
      local idx=${lvargs[(I)-n|--name]}
      if (( $idx )) {
        local lvolname=${lvargs[$idx+1]}
        if [[ -z $lvolname ]] {
          die "${dev} logical volume name is not set via ${lvargs[$idx]}"
        }
      } else {
        local lvolname="${dev}vol"
        lvargs+=(-n $lvolname)
      }

      say "Creating LVM logical volume '${lvolname}' in volume group '${vg}'"
      cmd lvcreate $vg $lvargs
      local device="/dev/${vg}/${lvolname}"
      assoc_set $dev device $device
    }
  }
}

function ask_luks_passphrase() {
  [[ $encryption_enabled != yes ]] && return

  luks_passphrase=x
  local luks_passphrase_confirmation=
  while [[ $luks_passphrase != $luks_passphrase_confirmation ]] {
    echo -n "Set LUKS passphrase: "
    read -s luks_passphrase
    echo -n "\nVerify LUKS passphrase: "
    read -s luks_passphrase_confirmation
    echo
    if [[ $luks_passphrase != $luks_passphrase_confirmation ]] {
      say "Passphrases don't match!"
    }
  }
}

function format_devices() {
  local dev
  for dev ($devs) {
    if [[ ${${(P)dev}[vgcreate]} == yes ]] {
      local vg=${${(P)dev}[vg]}
      local ppvols="${vg}_pvols"
      local pvdevices=()
      for dev (${(P)ppvols}) {
        local device=${${(P)dev}[device]}
        pvdevices+=($device)
      }
      say "Creating LVM volume group '${vg}'"
      cmd vgcreate $vg $pvdevices
      continue
    }

    local device=${${(P)dev}[device]}
    local lvargstr=${${(P)dev}[lvargstr]}
    if [[ -n $lvargstr ]] {
      local vg=${${(P)dev}[vg]}
      local lvargs=(${(Q)${(z)lvargstr}})
      local idx=${lvargs[(I)-n|--name]}
      if (( $idx )) {
        local lvolname=${lvargs[$idx+1]}
        if [[ -z $lvolname ]] {
          die "${dev} logical volume name is not set via ${lvargs[$idx]}"
        }
      } else {
        local lvolname="${dev}vol"
        lvargs+=(-n $lvolname)
      }

      say "Creating LVM logical volume '${lvolname}' in volume group '${vg}'"
      cmd lvcreate $vg $lvargs

      local device="/dev/${vg}/${lvolname}"
      assoc_set $dev lvolname $lvolname device $device
    }

    if [[ ${${(P)dev}[luks]} == yes ]] {
      local luks_device=$device
      local luks_fs_guid=$(uuidgen)
      local luks_device_ref=${${(P)dev}[device_ref]:-UUID=${luks_fs_guid}}
      say "Formatting $luks_device to LUKS"
      echo -n $luks_passphrase | cmd cryptsetup luksFormat --uuid $luks_fs_guid $luks_device -

      local mapname="crypt-${luks_fs_guid}"
      device="/dev/mapper/${mapname}"

      say "Mapping LUKS device $luks_device to $device"
      echo -n $luks_passphrase | cmd cryptsetup luksOpen -d - $luks_device $mapname

      assoc_set $dev device $device device_ref '' luks_device $luks_device luks_fs_guid $luks_fs_guid luks_device_ref $luks_device_ref
    }

    local fs=${${(P)dev}[fs]}
    case $fs {
      (fat)
        local fs_guid=$(uuidgen | tr a-z A-Z)
        fs_guid=${fs_guid:9:9}
        say "Formatting ${device} to FAT"
        cmd mkfs.fat -F 32 -i ${fs_guid//-} $device
        ;;
      (swap)
        local fs_guid=$(uuidgen)
        say "Formatting ${device} to swap"
        cmd mkswap --uuid $fs_guid $device
        ;;
      (ext2)
        local fs_guid=$(uuidgen)
        say "Formatting ${device} to ext2"
        cmd mkfs.ext2 -U $fs_guid $device
        ;;
      (ext3)
        local fs_guid=$(uuidgen)
        say "Formatting ${device} to ext3"
        cmd mkfs.ext3 -U $fs_guid $device
        ;;
      (ext4)
        local fs_guid=$(uuidgen)
        say "Formatting ${device} to ext4"
        cmd mkfs.ext4 -U $fs_guid $device
        ;;
      (lvm)
        say "Creating LVM physical volume ${device}"
        cmd pvcreate -ff $device
        ;;
      (*)
        die "Unsupported file system $fs in $dev ($device)"
        ;;
    }
    local device_ref=${${(P)dev}[device_ref]:-UUID=${fs_guid}}
    assoc_set $dev fs_guid $fs_guid device_ref $device_ref
  }
}

function mount_devices() {
  if [[ ${+swap} ]] {
    say "Enabling swap at ${swap[device]}"
    swapon ${swap[device]}
  }

  local -A mounts
  local dev
  for dev ($devs) {
    local mnt=${${(P)dev}[mnt]}
    if [[ -z $mnt ]] {
      continue
    }
    local device=${${(P)dev}[device]}
    local dir="${mnt_root}${mnt%%/}"
    mounts[$dir]=$device
  }
  for dir (${(ko)mounts}) {
    device=$mounts[$dir]
    say "Mounting ${device} at ${dir}"
    cmd mount --mkdir $device $dir
  }
}

function make_kernel_cmdline() {
  kernel_cmdline="root=${root[device_ref]}"
  if (( ${+swap} )) {
    kernel_cmdline+=" resume=${swap[device_ref]}"
  }
  kernel_cmdline+=" rw"
}

function bootstrap() {
  say "Bootstrapping the system at ${mnt_root}"
  cmd pacstrap -K $mnt_root base

  disable_initramfs_hooks

  local -a packages=($kernel_pkg linux-firmware $initramfs)
  if [[ $lvm_enabled == yes ]] {
    packages+=lvm2
  }
  cmd_chroot pacman -S --noconfirm $packages

  say "Setting root password at ${mnt_root}/etc/passwd"
  cmd_chroot passwd root

  if [[ $encryption_enabled == yes ]] {
    say "Generating ${mnt_root}/etc/crypttab.initramfs"
    generate_crypttab >> ${mnt_root}/etc/crypttab.initramfs
    local exitcode=$?
    (( $exitcode )) && die "Failed to write the file: exit code $exitcode"
  }

  say "Generating ${mnt_root}/etc/fstab"
  if [[ $encryption_enabled == yes || $lvm_enabled == yes ]] {
    cmd genfstab -U ${mnt_root} >> ${mnt_root}/etc/fstab
  } else {
    cmd genfstab -t PARTUUID ${mnt_root} >> ${mnt_root}/etc/fstab
  }

  say "Linking ${mnt_root}/etc/localtime"
  cmd_chroot ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
  cmd_chroot hwclock --systohc

  say "Uncommenting locales in ${mnt_root}/etc/locale.gen"
  cmd sed -i "s/^#\\(${(j.\|.)locales//./\\.}\\)/\\1/" ${mnt_root}/etc/locale.gen
  cmd_chroot locale-gen

  say "Creating ${mnt_root}/etc/locale.conf"
  echo "LANG=en_US.UTF-8" > ${mnt_root}/etc/locale.conf
  (( $? )) && die "Failed to write ${mnt_root}/etc/locale.conf: exit code $?"

  say "Creating ${mnt_root}/etc/vconsole.conf"
  echo "KEYMAP=us" >> ${mnt_root}/etc/vconsole.conf
  (( $? )) && die "Failed to write ${mnt_root}/etc/vconsole.conf"

  say "Creating ${mnt_root}/etc/hostname"
  echo $hostname > ${mnt_root}/etc/hostname
  (( $? )) && die "Failed to write ${mnt_root}/etc/hostname: exit code $?"

  setup_initramfs
}

function disable_initramfs_hooks() {
  cmd_chroot mkdir -p /etc/pacman.d/hooks
  case $initramfs {
    (mkinitcpio)
      cmd_chroot ln -s /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
      ;;
    (*)
      die "Unsupported initramfs '${initramfs}'"
      ;;
  }
}

function setup_initramfs() {
  if (( ${+efi} )) {
    local efi_path="${efi[mnt]}/EFI/${efi_entry}"
    mkdir -p "${mnt_root}${efi_path}"
  } else {
    local efi_path=${boot[mnt]}
  }

  case $initramfs {
    (mkinitcpio)
      local preset=${mnt_root}/etc/mkinitcpio.d/${kernel_pkg}.preset
      say "Generating ${preset}"
      cmd cp ${mnt_root}/usr/share/mkinitcpio/hook.preset $preset
      cmd sed -i "s|%PKGBASE%|${kernel_pkg}|g" $preset
      cmd sed -i 's|^#default_options=\(.\+\)$|default_options=\1|' $preset
      if [[ $bootldr == (uki|systemd-boot) ]] {
        cmd sed -i "s|^#\\(.\\+\\)_uki=\"\\(/[^/]\\+\\)\+/\\([^/]\+\\)\"|\\1_uki=\"${efi_path}/\\3\"|g" $preset
      }

      say "Setting up hooks in ${mnt_root}/etc/mkinitcpio.conf"
      local -a hooks=(base systemd autodetect modconf kms keyboard sd-vconsole block)
      if [[ $lvm_enabled == yes ]] {
        hooks=($hooks lvm2)
      }
      if [[ $encryption_enabled == yes ]] {
        hooks=($hooks sd-encrypt)
      }
      hooks=($hooks filesystems fsck)
      cmd sed -i "s/^HOOKS=(.\\+)$/HOOKS=($hooks)/" ${mnt_root}/etc/mkinitcpio.conf
      cmd rm -f ${mnt_root}/etc/pacman.d/hooks/90-mkinitcpio-install.hook
      local trigger_files=(${mnt_root}/usr/lib/initcpio/* ${mnt_root}/usr/lib/modules/*/vmlinuz)
      echo ${(F)trigger_files#$mnt_root} | cmd_chroot /usr/share/libalpm/scripts/mkinitcpio install
      ;;
    (*)
      die "Unsupported initramfs '${initramfs}'"
      ;;
  }
}

function setup_bootldr() {
  case $bootldr {
    (efistub)
      efibootmgr --create\
                 --disk ${efi[disk]:-$boot[disk]} --part ${efi[pt_num]:-$boot[pt_num]}\
                 --label $efi_entry\
                 --loader /vmlinuz-${kernel_pkg}\
                 --unicode "root=${root[device_ref]} resume=${swap[device_ref]} rw initrd=\\initramfs-linux.img"
      ;;
    (uki)
      efibootmgr --create\
                 --disk ${efi[disk]:-$boot[disk]} --part ${efi[pt_num]:-$boot[pt_num]}\
                 --label $efi_entry\
                 --loader /EFI/Linux/arch-${kernel_pkg}.efi\
                 --unicode "root=${root[device_ref]} resume=${swap[device_ref]} rw initrd=\\initramfs-linux.img"
      ;;
    (systemd-boot)
      ;;
    (*)
      die "Unsupported boot loader '$bootldr'"
      ;;
  }
}

function generate_crypttab() {
  local -a table
  local dev
  for dev ($devs) {
    if [[ ${${(P)dev}[luks]} != yes ]] {
      continue
    }
    local luks_device=${${(P)dev}[luks_device]}
    local luks_device_ref=${${(P)dev}[luks_device_ref]}
    say "Adding ${luks_device} to crypttab"
    table=($table $dev $luks_device_ref -)
  }
  print -a -C 3 $table
}

function parseopt_partition() {
  setopt local_options
  setopt extendedglob

  if [[ $1 =~ ^([^=]+)=(.+)$ ]] {
    local disk=$match[1]
    local optstr=$match[2]
  } else {
    die "Argument error in --partition: You must specify a disk to partition"
  }
  local opts=(${(s:,:)optstr})
  if (( ! $#opts )) {
     die "Argument error in --partition ${disk}=: You must specify partitions"
  }
  local -a pt_devs
  local pt_num
  for pt_num ({1..$#opts}) {
    local ptspec=${opts[$pt_num]}
    local parts=(${(s.:.)ptspec})
    local dev=$parts[1]
    shift parts

    local mnt=
    local fs=
    local luks=
    local pt_size=
    local xbootldr=
    local esp=

    # Set option defaults
    case $dev {
      (efi)
        fs=fat
        mnt=/efi
        ;;
      (boot)
        mnt=/boot
        ;;
      (root)
        mnt=/
        ;|
      (home)
        mnt=/home
        ;|
      (var)
        mnt=/var
        ;|
      (root|home|var)
        fs=ext4
        ;;
      (swap)
        fs=swap
        ;;
    }

    # Parse options
    while (( $#parts )) {
      local opt=$parts[1]
      shift parts
      case $opt {
        (ext2|ext3|ext4|fat)
          fs=$opt
          ;;
        (lvm|pvol|pv)
          fs=lvm
          ;;
        (luks|enc)
          luks=yes
          ;;
        (xbootldr)
          xbootldr=yes
          fs=${fs:-fat}
          ;;
        (efi|esp)
          esp=yes
          fs=${fs:-fat}
          ;;
        ([0-9]##[KMGTP])
          pt_size=$opt
          ;;
        (/*)
          [[ -n $mnt && $mnt != $opt ]] && die "Argument error in --partition ${disk}=: mount path of '${dev}' partition cannot be changed"
          mnt=$opt
          ;;
        (*)
          die "Argument error in --partition ${disk}=: '${dev}' spec contains unsupported option '${opt}'"
          ;;
      }
    }

    [[ -z $fs && -n $mnt ]] && die "Argument error in --partition ${disk}=: '${dev}' filesystem is not defined"

    if [[ $dev == efi ]] {
      [[ $fs == fat ]] || die "Argument error in --partition ${disk}=: /efi partition filesystem must be fat"
      [[ $luks == yes ]] && die "Argument error in --partition ${disk}=: /efi partition cannot be encrypted"
    }

    if [[ $xbootldr == yes ]] {
      [[ $dev == boot ]] || die "Argument error in --partition ${disk}=: xbootldr option cannot be used with '${dev}'"
      [[ $fs == fat ]] || die "Argument error in --partition ${disk}=: xbootldr /boot partition filesystem must be fat"
      [[ $luks == yes ]] && die "Argument error in --partition ${disk}=: xbootldr /boot partition cannot be encrypted"
      [[ $esp == yes ]] && die "Argument error in --partition ${disk}=: xbootldr /boot partition cannot be efi"
    }

    if [[ $esp == yes ]] {
      [[ $dev == boot ]] || die "Argument error in --partition ${disk}=: esp option cannot be used with '${dev}'"
    }

    if [[ $dev == swap ]] {
      [[ $fs == swap ]] || die "Argument error in --partition ${disk}=: swap partition cannot have file system"
    }

    if [[ -z $pt_size && $pt_num -lt $#opts ]] {
      die "Argument error in --partition ${disk}=: partition size of '${dev}' is not set"
    }

    declare_dev $dev
    assoc_set $dev disk $disk pt_num $pt_num pt_size "$pt_size" fs $fs xbootldr "$xbootldr" esp "$esp" luks "$luks" mnt "$mnt"
    pt_devs+=($dev)
  }
  partitions[$disk]=$pt_devs
}

function parseopt_vg() {
  if [[ $1 =~ ^([^=]+)=(.+)$ ]] {
    local vgdev=$match[1]
    local optstr=$match[2]
  } else {
    local vgdev=lvm
    local optstr=$1
  }
  local vg=$vgdev
  declare_dev $vgdev
  assoc_set $vgdev vgcreate yes vg $vg
  declare -ga "${vgdev}_pvols"
  local opts=(${(s:,:)optstr})
  if (( ! $#opts )) {
    die "Argument error in --vg ${vgdev}=: you must specify physical volumes"
  }
  local dev
  for dev ($opts) {
    local fs=${${(P)dev}[fs]}
    [[ -n $fs && $fs != lvm ]] && die "Argument error in --vg ${vgdev}=: '$dev' is not a physical volume, it's gonna be formatted into ${fs}"

    array_append "${vg}_pvols" $dev
  }
}

function parseopt_lv() {
  if [[ $1 =~ ^([^=]+)=(.+)$ ]] {
    local vg=$match[1]
    local optstr=$match[2]
  } else {
    local vg=lvm
    local optstr=$1
  }
  local opts=(${(s:,:)optstr})
  if (( ! $#opts )) {
    die "Argument error in --lv ${vg}=: you must specify logical volumes"
  }
  for lvspec ($opts) {
    local parts=(${(s.:.)lvspec})
    local dev=$parts[1]
    shift parts

    local mnt=
    local fs=
    local luks=
    local lvargstr=

    # Set option defaults
    case $dev {
      (efi)
        die "Argument error in --lv ${vg}=: '${dev}' cannot be a logical volume"
        ;;
      (boot)
        mnt=/boot
        ;|
      (root)
        mnt=/
        ;|
      (home)
        mnt=/home
        ;|
      (var)
        mnt=/var
        ;|
      (root|home|var|boot)
        fs=ext4
        ;;
      (swap)
        fs=swap
        ;;
    }

    # Parse options
    while (( $#parts )) {
      local opt=$parts[1]
      shift parts
      case $opt {
        (ext2|ext3|ext4|fat)
          fs=$opt
          ;;
        (luks|enc)
          luks=yes
          ;;
        (/*)
          [[ -n $mnt && $mnt != $opt ]] && die "Argument error in --lv ${vg}=: mount path of '${dev}' volume cannot be changed"
          mnt=$opt
          ;;
        (-*)
          [[ -n $lvargstr ]] && die "Argument error in --lv ${vg}=: lvcreate arguments for '${dev}' cannot be set twice"
          lvargstr=$opt
          ;;
        (*)
          die "Argument error in --lv ${vg}=: '${dev}' spec contains unsupported option '${opt}'"
          ;;
      }
    }

    [[ -z $fs && -n $mnt ]] && die "Argument error in --lv ${vg}=: '${dev}' filesystem is not defined"

    if [[ $dev == swap ]] {
      [[ $fs == swap ]] || die "Argument error in --lv ${vg}=: swap volume cannot have file system"
    }

    declare_dev $dev
    assoc_set $dev lvargstr "$lvargstr" vg $vg fs $fs luks "$luks" mnt "$mnt"
  }
}

function parseopt_array() {
  local optname=$1 var=$2 optarrstr=$3
  [[ -z $optarrstr ]] && die "Argument error in $optname: must not be empty"
  local opt
  for opt (${(@s:,:)optarrstr}) {
    array_append $var $opt
  }
}

function parseopt_scalar() {
  local optname=$1 var=$2
  shift 2
  if (( ! $#@ )) {
    [[ -z ${(P)var} ]] && die "You must specify $optname"
    return
  }
  local optnamne=$1
  shift
  local opt=$1
  [[ -z $opt ]] && die "Argument error in $optname: must not be empty"
  assign $var $opt
}

function parseopt_scalar_enum() {
  local optname=$1 var=$2 enum=(${=3})
  shift 3
  if (( ! $#@ )) {
    [[ -z ${(P)var} ]] && die "You must specify $optname"
    return
  }
  local optnamne=$1
  shift
  local opt=$1
  [[ -z $opt ]] && die "Argument error in $optname: must not be empty"
  (( ${enum[(I)$opt]} )) || die "Argument error in $optname: unsupported option '$opt'"
  assign $var $opt
}

function parseopts() {
  local opts_partition\
        opts_vg\
        opts_lv\
        opt_root\
        opt_efi\
        opt_efi_entry\
        opt_boot\
        opt_swap\
        opt_home\
        opt_mnt_root\
        opt_initramfs\
        opt_bootldr\
        opt_hostname\
        opt_timezone\
        opts_locales

  zparseopts -D -E -K -\
             {r,-root}:=opt_root\
             -partition+:=opts_partition\
             {-vg,-vgcreate}+:=opts_vg\
             {-lv,-lvcreate}+:=opts_lv\
             -efi:=opt_efi\
             -efi-entry:=opt_efi_entry\
             -boot:=opt_boot\
             -swap:=opt_swap\
             {h,-home}:=opt_home\
             -mnt-root:=opt_mnt_root\
             {-initramfs}:=opt_initramfs\
             {-boot-loader,-bootldr}:=opt_bootldr\
             -hostname:=opt_hostname\
             -timezone:=opt_timezone\
             -locales+:=opts_locales\
    || exit 1
  if [[ $# != 0 ]] {
    die "unknown argument: $1"
  }

  local opt
  for _ opt ($opts_partition) {
    parseopt_partition $opt
  }
  for _ opt ($opts_vg) {
    parseopt_vg $opt
  }
  for _ opt ($opts_lv) {
    parseopt_lv $opt
  }
  for optname opt ($opts_locales) {
    parseopt_array $optname locales "$opt"
  }
  (( $#locales )) || locales=(en_US.UTF-8)
  mnt_root=${${opt_mnt_root[2]:-/mnt/root}%%/}

  parseopt_scalar_enum --boot-loader bootldr "efistub uki systemd-boot" ${(@)opt_bootldr}
  parseopt_scalar_enum --initramfs initramfs "mkinitcpio dracut booster" ${(@)opt_initramfs}
  parseopt_scalar --efi-entry efi_entry ${(@)opt_efi_entry}
  parseopt_scalar --timezone timezone ${(@)opt_timezone}
  parseopt_scalar --hostname hostname ${(@)opt_hostname}

  local dev
  for dev ($devs) {
    if [[ ${${(P)dev}[luks]} == yes ]] {
      encryption_enabled=yes
    }
    if [[ ${${(P)dev}[vgcreate]} == yes || ${${(P)dev}[lvargstr]} == yes ]] {
      lvm_enabled=yes
    }
  }

  [[ -v root ]] || die "You must specify root device either as a partition, logical volume or --root option"
  [[ -v efi || -n ${boot[esp]} ]] || die "You must specify either efi or boot partition with :esp option"
  [[ ${boot[xbootldr]} == yes && $bootldr != systemd-boot ]] && warn "xbootldr partition is useful only with systemd-boot boot loader"
  [[ -v efi && -v boot && $bootldr == efistub ]]
}

function main() {
  partition_disks
  ask_luks_passphrase
  format_devices
  mount_devices
  make_kernel_cmdline
  bootstrap
  # setup_bootldr
}

function cleanup() {
  efibootmgr -B -L $efi_entry --unicode
  umount -R /mnt/root
  swapoff --all

  for device (/dev/mapper/crypt*(N)) {
    cryptsetup close $device
  }

  lvremove -f /dev/lvm/*(N)
  vgremove -f /dev/lvm
  pvremove -ff /dev/sda*
}

function say() {
  echo " [*] $1" >&2
}

function cmd_chroot() {
  local -a args=(arch-chroot $mnt_root "${@[@]}")
  echo ">>" "$args" >&2
  command ${args[@]}
  local exitcode=$?
  (( $exitcode )) && die "$1 exited with code $exitcode"
}

function cmd() {
  echo ">>" "$@" >&2
  command "$@"
  local exitcode=$?
  (( $exitcode )) && die "$1 exited with code $exitcode"
}

function die() {
  echo $1 >&2
  exit 1
}

cleanup
parseopts "$@"
main
exit 0
