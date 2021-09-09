#!/usr/bin/env bash
# shellcheck disable=SC2154

# Print color echo
function log() {
  local set_color="$2"
  case $set_color in
    bold) color=$(tput bold) ;;
    red) color=$(tput setaf 1) ;;
    green) color=$(tput setaf 2) ;;
    yellow) color=$(tput setaf 3) ;;
    cyan) color=$(tput setaf 6) ;;
    *) text="$1" ;;
  esac
  [ -z "$text" ] && echo "$color $1 $(tput sgr0)" || echo "$text"
}

# Usage function
function usage() {
  log "Usage commands:" bold
  echo "# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)"
  echo "$0 --desktop kde"
  echo ""
  echo "# Enable debug & log file."
  echo "$0 --debug"
}

# Arguments function
function arguments() {
  while true; do
    case "$1" in
      -a | --arch)
        architecture="$2"
        shift 2
        ;;
      --desktop)
        desktop="$2"
        shift 2
        ;;
      -h | --h | -help | --help)
        usage
        exit 0
        ;;
      -d | --debug)
        exec > >(tee -a "${0%.*}.log") 2>&1
        set -x
        shift 0
        break
        ;;
      -\* | --\*)
        log "Unknown option $1" red
        exit 1
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done
}
arguments "$*"

# Function to include common files
function include() {
  local file="$1"
  if [[ -f "common.d/${file}.sh" ]]; then
    log " ✅ Load common file ${file}" green
    # shellcheck source=/dev/null
    source "common.d/${file}.sh"
    return 0
  else
    log " ⚠️  Fail to load ${file} file" red
    exit 1
  fi
}

# systemd-nspawn enviroment
# Putting quotes around $extra_args causes systemd-nspawn to pass the extra arguments as 1, so leave it unquoted.
function systemd-nspawn_exec() {
  ENV="RUNLEVEL=1,LANG=C,DEBIAN_FRONTEND=noninteractive,DEBCONF_NOWARNINGS=yes"
  systemd-nspawn --bind-ro "$qemu_bin" $extra_args --capability=cap_setfcap -E $ENV -M "$machine" -D "$work_dir" "$@"
}

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
function debootstrap_exec() {
  eatmydata debootstrap --foreign --keyring=/usr/share/keyrings/kali-archive-keyring.gpg --components="${components}" \
    --include=kali-archive-keyring,eatmydata --arch "${architecture}" "${suite}" "${work_dir}" "$@"
}

# Disable the use of http proxy in case it is enabled.
function disable_proxy() {
  if [ -n "$proxy_url" ]; then
    unset http_proxy
    rm -rf "${work_dir}"/etc/apt/apt.conf.d/66proxy
  fi
}

# Mirror & suite replacement
function restore_mirror() {
  if [[ -n "${replace_mirror}" ]]; then
    export mirror=${replace_mirror}
  elif [[ -n "${replace_suite}" ]]; then
    export suite=${replace_suite}
  fi
  echo "deb ${mirror} ${suite} main contrib non-free" > "${work_dir}"/etc/apt/sources.list
  echo "#deb-src ${mirror} ${suite} main contrib non-free" >> "${work_dir}"/etc/apt/sources.list
}

# Limite use cpu function
function limit_cpu() {
  if [[ ${cpu_limit:=} -eq "0" || -z $cpu_limit ]]; then
    local cpu_shares=$((num_cores * 1024))
    local cpu_quota="-1"
  else
    local cpu_shares=$((1024 * num_cores * cpu_limit / 100))  # 1024 max value per core
    local cpu_quota=$((100000 * num_cores * cpu_limit / 100)) # 100000 max value per core
  fi
  # Random group name
  local rand
  rand=$(
    tr -cd 'A-Za-z0-9' </dev/urandom | head -c4
    echo
  )
  cgcreate -g cpu:/cpulimit-"$rand"
  cgset -r cpu.shares="$cpu_shares" cpulimit-"$rand"
  cgset -r cpu.cfs_quota_us="$cpu_quota" cpulimit-"$rand"
  # Retry command
  local n=1
  local max=5
  local delay=2
  while true; do
    # shellcheck disable=SC2015
    cgexec -g cpu:cpulimit-"$rand" "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        log "Command failed. Attempt $n/$max " red
        sleep $delay
      else
        log "The command has failed after $n attempts." yellow
        break
      fi
    }
  done
  cgdelete -g cpu:/cpulimit-"$rand"
}

# Choose a locale
function set_locale() {
  LOCALES="$1"
  sed -i "s/^# *\($LOCALES\)/\1/" "${work_dir}"/etc/locale.gen
  systemd-nspawn_exec locale-gen
  echo "LANG=$LOCALES" >"${work_dir}"/etc/locale.conf
  echo "LC_ALL=$LOCALES" >>"${work_dir}"/etc/locale.conf
  cat <<'EOM' >"${work_dir}"/etc/profile.d/default-lang.sh
if [ -z "$LANG" ]; then
    source /etc/locale.conf
    export LANG
elif [ -z "$LC_ALL" ]; then
    source /etc/locale.conf
    export LC_ALL
fi
EOM
}

# Set hostname
function set_hostname() {
  if [[ "$1" =~ ^[a-zA-Z0-9-]{2,63}+$ ]]; then
    echo "$1" >"${work_dir}"/etc/hostname
  else
    log "$1 is not a correct hostname" red
    log "Using kali to default hostname" bold
    echo "kali" >"${work_dir}"/etc/hostname
  fi
}

# Add network interface
function add_interface() {
  interfaces="$*"
  for netdev in $interfaces; do
    cat <<EOF >"${work_dir}"/etc/network/interfaces.d/"$netdev"
auto $netdev
    allow-hotplug $netdev
    iface $netdev inet dhcp
EOF
    log "Configured /etc/network/interfaces.d/$netdev" bold
  done
}

# Make SWAP
function make_swap() {
  if [ "$swap" = yes ]; then
    echo 'vm.swappiness = 50' >>"${work_dir}"/etc/sysctl.conf
    systemd-nspawn_exec apt-get install -y dphys-swapfile >/dev/null 2>&1
    #sed -i 's/#CONF_SWAPSIZE=/CONF_SWAPSIZE=128/g' ${work_dir}/etc/dphys-swapfile
  fi
}

# Print current config.
function print_config() {
  clear
  echo -e "\n"
  log "Compilation info" bold
  if [[ "$hw_model" == *rpi* ]]; then
    name_model="Raspberry PI 2/3/4/400"
    log "Hardware model: $(tput sgr0) $name_model" cyan
  else
    log "Hardware model: $(tput sgr0) $hw_model" cyan
  fi
  log "Architecture: $(tput sgr0) $architecture" cyan
  log "The basedir thinks it is: $(tput sgr0) ${basedir}" cyan
  echo -e "\n"
  sleep 1.5
}

# Calculate the space to create the image and create.
function make_image() {
  # Calculate the space to create the image.
  root_size=$(du -s -B1 "${work_dir}" --exclude="${work_dir}"/boot | cut -f1)
  root_extra=$((root_size * 5 * 1024 / 5 / 1024 / 1000))
  raw_size=$(($((free_space * 1024)) + root_extra + $((bootsize * 1024)) + 4096))
  img_size=$(echo "${raw_size}"Ki | numfmt --from=iec-i --to=si)
  # Create the disk image
  log "Creating image file ${imagename}.img $img_size" green
  fallocate -l "$img_size" "${current_dir}"/"${imagename}".img
}

# Clean up all the temporary build stuff and remove the directories.
function clean_build() {
  log "Cleaning up the temporary build files..." yellow
  rm -rf "${basedir}"
  log "Done." green
  echo -e "\n"
  log "Your image is: $(tput sgr0) $(ls "${imagename}".*)" bold
}