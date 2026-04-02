#!/usr/bin/env bash
#===============================================================================
#  restricted-user-manager.sh
#  Create restricted users, isolate folders, and manage ACLs on Ubuntu.
#
#  Usage:
#    Interactive mode : sudo ./restricted-user-manager.sh
#    CLI mode         : sudo ./restricted-user-manager.sh [OPTIONS]
#
#  Modes (pick one):
#    --mode restricted-user   Create a user with rbash and limited commands
#    --mode isolate-folder    Lock down a folder with chmod/chown
#    --mode acl               Fine-grained access with POSIX ACLs
#
#  Common switches:
#    -u, --username NAME      Username for the new/target user
#    -p, --password PASS      Password (prompted securely if omitted)
#    -h, --home PATH          Custom home directory path
#    -a, --apps CMD1,CMD2     Comma-separated allowed commands (restricted-user)
#    -f, --folder PATH        Target folder (isolate-folder / acl)
#    -o, --owner USER:GROUP   Owner for isolated folder
#    --perms OCTAL            Permissions for isolated folder (default 700)
#    --acl-target USER        User to apply ACL rule to
#    --acl-perms rwx          ACL permission string (e.g. rwx, r-x, ---)
#    --acl-action allow|deny  Allow or deny access (default: allow)
#    --harden                 Apply extra hardening (immutable profile, etc.)
#    --help                   Show this help message
#
#  Examples:
#    sudo ./restricted-user-manager.sh --mode restricted-user -u kiosk \
#         -a firefox,vlc --harden
#
#    sudo ./restricted-user-manager.sh --mode isolate-folder \
#         -f /srv/private --owner admin:admin --perms 750
#
#    sudo ./restricted-user-manager.sh --mode acl -f /srv/shared \
#         --acl-target guest --acl-perms r-x --acl-action allow
#===============================================================================

set -euo pipefail

# ─── Colors & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}━━━ $* ━━━${RESET}\n"; }
prompt() { echo -en "${BOLD}$*${RESET}"; }

confirm() {
  local msg="${1:-Continue?}"
  prompt "$msg [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

read_secure() {
  local varname="$1" prompt_msg="$2"
  prompt "$prompt_msg"
  read -rs "$varname"
  echo
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
  fi
}

# ─── Dependency checks ───────────────────────────────────────────────────────
ensure_acl_installed() {
  if ! command -v setfacl &>/dev/null; then
    warn "acl package not found. Installing..."
    apt-get update -qq && apt-get install -y -qq acl
    success "acl package installed."
  fi
}

# ─── Find full path for a command ────────────────────────────────────────────
resolve_cmd() {
  local cmd="$1"
  local path
  path=$(command -v "$cmd" 2>/dev/null) || path=$(which "$cmd" 2>/dev/null) || true
  if [[ -z "$path" ]]; then
    warn "Command '$cmd' not found on this system — skipping."
    return 1
  fi
  echo "$path"
}

# ─── Show help ────────────────────────────────────────────────────────────────
show_help() {
  sed -n '2,/^#====/{ /^#====/d; s/^#//; s/^ //; p }' "$0"
  exit 0
}

#===============================================================================
#  MODE 1: RESTRICTED USER
#===============================================================================
do_restricted_user() {
  local username="$1"
  local password="$2"
  local homedir="$3"
  local apps_csv="$4"
  local harden="$5"

  header "Creating Restricted User: $username"

  # ── Create user ──────────────────────────────────────────────────────────
  if id "$username" &>/dev/null; then
    warn "User '$username' already exists."
    if ! confirm "Reconfigure this user?"; then
      info "Aborted."
      return
    fi
    info "Reconfiguring existing user..."
    usermod -s /bin/rbash "$username"
  else
    local home_args=()
    if [[ -n "$homedir" ]]; then
      home_args=(-d "$homedir")
    fi
    useradd -m "${home_args[@]}" -s /bin/rbash "$username"
    success "User '$username' created with rbash shell."
  fi

  # Resolve final home directory
  homedir=$(eval echo "~$username")

  # ── Set password ─────────────────────────────────────────────────────────
  echo "$username:$password" | chpasswd
  success "Password set."

  # ── Create restricted bin directory ───────────────────────────────────────
  local bindir="$homedir/bin"
  mkdir -p "$bindir"

  # Clear old symlinks in bin
  find "$bindir" -maxdepth 1 -type l -delete 2>/dev/null || true

  # ── Symlink allowed apps ─────────────────────────────────────────────────
  local linked=0
  IFS=',' read -ra APP_LIST <<<"$apps_csv"
  for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs) # trim whitespace
    [[ -z "$app" ]] && continue
    local resolved
    if resolved=$(resolve_cmd "$app"); then
      ln -sf "$resolved" "$bindir/$app"
      success "  Linked: $app -> $resolved"
      ((linked++))
    fi
  done

  if [[ $linked -eq 0 ]]; then
    warn "No valid commands were linked. The user won't be able to run anything."
  fi

  # ── Lock down PATH via .bash_profile ─────────────────────────────────────
  local profile="$homedir/.bash_profile"
  cat >"$profile" <<'PROFILEEOF'
# Restricted user profile — do not modify
export PATH="$HOME/bin"
# Disable dangerous builtins where possible
enable -n source
enable -n .
PROFILEEOF

  # Also set .bashrc to source .bash_profile if interactive
  local bashrc="$homedir/.bashrc"
  cat >"$bashrc" <<'RCEOF'
# Restricted .bashrc
if [ -f "$HOME/.bash_profile" ]; then
    . "$HOME/.bash_profile"
fi
RCEOF

  chown root:root "$profile" "$bashrc"
  chmod 644 "$profile" "$bashrc"
  success "PATH locked to $bindir"

  # ── Ownership ────────────────────────────────────────────────────────────
  chown "$username:$username" "$homedir"
  chown root:"$username" "$bindir"
  chmod 755 "$bindir"

  # ── Extra hardening ──────────────────────────────────────────────────────
  if [[ "$harden" == "yes" ]]; then
    header "Applying Hardening"

    # Make profile immutable
    if command -v chattr &>/dev/null; then
      chattr +i "$profile" 2>/dev/null && success "Made .bash_profile immutable (chattr +i)" || warn "chattr failed — filesystem may not support it."
      chattr +i "$bashrc" 2>/dev/null && success "Made .bashrc immutable (chattr +i)" || true
    fi

    # Prevent user from reading other home dirs
    for d in /home/*/; do
      local dir_owner
      dir_owner=$(basename "$d")
      [[ "$dir_owner" == "$username" ]] && continue
      chmod 750 "$d" 2>/dev/null && info "  Set $d to 750" || true
    done
    success "Other home directories restricted."

    # Prevent cron usage
    echo "$username" >>/etc/cron.deny 2>/dev/null && success "Cron access denied." || true

    # Prevent at usage
    echo "$username" >>/etc/at.deny 2>/dev/null && success "at(1) access denied." || true
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  header "Summary — Restricted User"
  echo -e "  ${BOLD}Username:${RESET}    $username"
  echo -e "  ${BOLD}Shell:${RESET}       /bin/rbash"
  echo -e "  ${BOLD}Home:${RESET}        $homedir"
  echo -e "  ${BOLD}Allowed:${RESET}     $apps_csv"
  echo -e "  ${BOLD}Hardened:${RESET}    $harden"
  echo
  success "Done! Test with:  su - $username"
}

#===============================================================================
#  MODE 2: ISOLATE FOLDER
#===============================================================================
do_isolate_folder() {
  local folder="$1"
  local owner="$2"
  local perms="$3"

  header "Isolating Folder: $folder"

  if [[ ! -d "$folder" ]]; then
    if confirm "Folder '$folder' does not exist. Create it?"; then
      mkdir -p "$folder"
      success "Created $folder"
    else
      error "Aborted."
      return 1
    fi
  fi

  # ── Set ownership ────────────────────────────────────────────────────────
  if [[ -n "$owner" ]]; then
    chown "$owner" "$folder"
    success "Ownership set to $owner"
  fi

  # ── Set permissions ──────────────────────────────────────────────────────
  chmod "$perms" "$folder"
  success "Permissions set to $perms"

  # ── Apply recursively? ───────────────────────────────────────────────────
  if [[ -n "$(ls -A "$folder" 2>/dev/null)" ]]; then
    if confirm "Apply permissions recursively to contents?"; then
      chown -R "$owner" "$folder" 2>/dev/null || true
      chmod -R "$perms" "$folder"
      success "Permissions applied recursively."
    fi
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  header "Summary — Folder Isolation"
  echo -e "  ${BOLD}Folder:${RESET}      $folder"
  echo -e "  ${BOLD}Owner:${RESET}       ${owner:-<unchanged>}"
  echo -e "  ${BOLD}Permissions:${RESET} $perms"
  echo
  echo -e "  ${DIM}Verify with: ls -ld $folder${RESET}"
  echo
  success "Done!"
}

#===============================================================================
#  MODE 3: ACL
#===============================================================================
do_acl() {
  local folder="$1"
  local acl_target="$2"
  local acl_perms="$3"
  local acl_action="$4"

  header "Configuring ACL on: $folder"

  ensure_acl_installed

  if [[ ! -e "$folder" ]]; then
    if confirm "'$folder' does not exist. Create it?"; then
      mkdir -p "$folder"
      success "Created $folder"
    else
      error "Aborted."
      return 1
    fi
  fi

  # Check filesystem supports ACLs
  local mountpoint
  mountpoint=$(df --output=target "$folder" 2>/dev/null | tail -1)
  if ! tune2fs -l "$(df --output=source "$folder" 2>/dev/null | tail -1)" 2>/dev/null | grep -q "acl"; then
    warn "Filesystem at $mountpoint may not have ACL support enabled."
    warn "If this fails, remount with:  mount -o remount,acl $mountpoint"
  fi

  # ── Build ACL rule ───────────────────────────────────────────────────────
  local perm_str="$acl_perms"
  if [[ "$acl_action" == "deny" ]]; then
    perm_str="---"
  fi

  # Determine if target is a user or group
  local acl_prefix="u"
  if getent group "$acl_target" &>/dev/null && ! id "$acl_target" &>/dev/null; then
    acl_prefix="g"
    info "Detected '$acl_target' as a group."
  else
    info "Applying ACL for user '$acl_target'."
  fi

  # ── Apply ACL ────────────────────────────────────────────────────────────
  setfacl -m "${acl_prefix}:${acl_target}:${perm_str}" "$folder"
  success "ACL set: ${acl_prefix}:${acl_target}:${perm_str}"

  # ── Recursive? ───────────────────────────────────────────────────────────
  if [[ -d "$folder" ]]; then
    if confirm "Apply ACL recursively to all contents?"; then
      setfacl -R -m "${acl_prefix}:${acl_target}:${perm_str}" "$folder"
      success "ACL applied recursively."
    fi

    if confirm "Set as default ACL for new files in this directory?"; then
      setfacl -d -m "${acl_prefix}:${acl_target}:${perm_str}" "$folder"
      success "Default ACL set for future files."
    fi
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  header "Summary — ACL Configuration"
  echo -e "  ${BOLD}Path:${RESET}        $folder"
  echo -e "  ${BOLD}Target:${RESET}      $acl_target (${acl_prefix}ser/group)"
  echo -e "  ${BOLD}Action:${RESET}      $acl_action"
  echo -e "  ${BOLD}Permissions:${RESET} $perm_str"
  echo
  echo -e "  ${DIM}Current ACLs:${RESET}"
  getfacl "$folder" 2>/dev/null | sed 's/^/    /'
  echo
  success "Done!"
}

#===============================================================================
#  INTERACTIVE MODE
#===============================================================================
interactive_mode() {
  header "Restricted User Manager — Interactive Setup"

  echo -e "  ${BOLD}1)${RESET} Restricted User  ${DIM}— Create a user with rbash + limited commands${RESET}"
  echo -e "  ${BOLD}2)${RESET} Isolate Folder    ${DIM}— Lock down a folder with chmod/chown${RESET}"
  echo -e "  ${BOLD}3)${RESET} ACL Access        ${DIM}— Fine-grained POSIX ACL rules${RESET}"
  echo

  prompt "Select mode [1/2/3]: "
  read -r mode_choice

  case "$mode_choice" in
  1)
    header "Restricted User Setup"

    prompt "Username: "
    read -r i_username
    [[ -z "$i_username" ]] && {
      error "Username is required."
      exit 1
    }

    read_secure i_password "Password: "
    [[ -z "$i_password" ]] && {
      error "Password is required."
      exit 1
    }

    read_secure i_password2 "Confirm password: "
    if [[ "$i_password" != "$i_password2" ]]; then
      error "Passwords do not match."
      exit 1
    fi

    prompt "Custom home directory (leave empty for /home/$i_username): "
    read -r i_homedir

    echo
    info "Enter the commands/apps this user is allowed to run."
    info "Comma-separated, e.g.: firefox,nano,ls,cat"
    prompt "Allowed apps: "
    read -r i_apps
    [[ -z "$i_apps" ]] && {
      error "At least one app is required."
      exit 1
    }

    echo
    if confirm "Apply extra hardening? (immutable profile, block cron, restrict other homes)"; then
      i_harden="yes"
    else
      i_harden="no"
    fi

    echo
    header "Review Configuration"
    echo -e "  Username:   $i_username"
    echo -e "  Home:       ${i_homedir:-/home/$i_username}"
    echo -e "  Apps:       $i_apps"
    echo -e "  Hardened:   $i_harden"
    echo
    confirm "Proceed?" || {
      info "Aborted."
      exit 0
    }

    do_restricted_user "$i_username" "$i_password" "$i_homedir" "$i_apps" "$i_harden"
    ;;

  2)
    header "Folder Isolation Setup"

    prompt "Folder path to isolate: "
    read -r i_folder
    [[ -z "$i_folder" ]] && {
      error "Folder path is required."
      exit 1
    }

    prompt "Owner (user:group, e.g. admin:admin — leave empty to keep current): "
    read -r i_owner

    prompt "Permissions octal (default 700): "
    read -r i_perms
    i_perms="${i_perms:-700}"

    echo
    header "Review Configuration"
    echo -e "  Folder:      $i_folder"
    echo -e "  Owner:       ${i_owner:-<unchanged>}"
    echo -e "  Permissions: $i_perms"
    echo
    confirm "Proceed?" || {
      info "Aborted."
      exit 0
    }

    do_isolate_folder "$i_folder" "$i_owner" "$i_perms"
    ;;

  3)
    header "ACL Access Setup"

    prompt "Target folder/file path: "
    read -r i_folder
    [[ -z "$i_folder" ]] && {
      error "Path is required."
      exit 1
    }

    prompt "User or group to set ACL for: "
    read -r i_acl_target
    [[ -z "$i_acl_target" ]] && {
      error "Target user/group is required."
      exit 1
    }

    echo
    echo -e "  ${BOLD}allow${RESET} — Grant specific permissions (e.g. rwx, r-x, r--)"
    echo -e "  ${BOLD}deny${RESET}  — Block all access (sets ---)"
    prompt "Action [allow/deny]: "
    read -r i_acl_action
    i_acl_action="${i_acl_action:-allow}"

    local i_acl_perms="---"
    if [[ "$i_acl_action" == "allow" ]]; then
      echo
      info "Permission string examples: rwx, r-x, r--, rw-"
      prompt "Permissions: "
      read -r i_acl_perms
      [[ -z "$i_acl_perms" ]] && {
        error "Permissions required for allow action."
        exit 1
      }
    fi

    echo
    header "Review Configuration"
    echo -e "  Path:        $i_folder"
    echo -e "  Target:      $i_acl_target"
    echo -e "  Action:      $i_acl_action"
    echo -e "  Permissions: ${i_acl_perms}"
    echo
    confirm "Proceed?" || {
      info "Aborted."
      exit 0
    }

    do_acl "$i_folder" "$i_acl_target" "$i_acl_perms" "$i_acl_action"
    ;;

  *)
    error "Invalid choice. Use 1, 2, or 3."
    exit 1
    ;;
  esac
}

#===============================================================================
#  CLI ARGUMENT PARSING
#===============================================================================
MODE=""
USERNAME=""
PASSWORD=""
HOMEDIR=""
APPS=""
FOLDER=""
OWNER=""
PERMS="700"
ACL_TARGET=""
ACL_PERMS="rwx"
ACL_ACTION="allow"
HARDEN="no"
CLI_MODE=false

while [[ $# -gt 0 ]]; do
  CLI_MODE=true
  case "$1" in
  --help) show_help ;;
  --mode)
    MODE="$2"
    shift 2
    ;;
  -u | --username)
    USERNAME="$2"
    shift 2
    ;;
  -p | --password)
    PASSWORD="$2"
    shift 2
    ;;
  -h | --home)
    HOMEDIR="$2"
    shift 2
    ;;
  -a | --apps)
    APPS="$2"
    shift 2
    ;;
  -f | --folder)
    FOLDER="$2"
    shift 2
    ;;
  -o | --owner)
    OWNER="$2"
    shift 2
    ;;
  --perms)
    PERMS="$2"
    shift 2
    ;;
  --acl-target)
    ACL_TARGET="$2"
    shift 2
    ;;
  --acl-perms)
    ACL_PERMS="$2"
    shift 2
    ;;
  --acl-action)
    ACL_ACTION="$2"
    shift 2
    ;;
  --harden)
    HARDEN="yes"
    shift
    ;;
  *)
    error "Unknown option: $1"
    echo "Use --help for usage information."
    exit 1
    ;;
  esac
done

#===============================================================================
#  MAIN
#===============================================================================
check_root

if [[ "$CLI_MODE" == false ]]; then
  interactive_mode
else
  # ── Validate and run CLI mode ────────────────────────────────────────────
  case "$MODE" in
  restricted-user)
    [[ -z "$USERNAME" ]] && {
      error "--username is required."
      exit 1
    }
    [[ -z "$APPS" ]] && {
      error "--apps is required."
      exit 1
    }

    if [[ -z "$PASSWORD" ]]; then
      read_secure PASSWORD "Password for $USERNAME: "
      read_secure PASSWORD2 "Confirm password: "
      [[ "$PASSWORD" != "$PASSWORD2" ]] && {
        error "Passwords do not match."
        exit 1
      }
    fi

    do_restricted_user "$USERNAME" "$PASSWORD" "$HOMEDIR" "$APPS" "$HARDEN"
    ;;

  isolate-folder)
    [[ -z "$FOLDER" ]] && {
      error "--folder is required."
      exit 1
    }
    do_isolate_folder "$FOLDER" "$OWNER" "$PERMS"
    ;;

  acl)
    [[ -z "$FOLDER" ]] && {
      error "--folder is required."
      exit 1
    }
    [[ -z "$ACL_TARGET" ]] && {
      error "--acl-target is required."
      exit 1
    }
    do_acl "$FOLDER" "$ACL_TARGET" "$ACL_PERMS" "$ACL_ACTION"
    ;;

  "")
    error "No --mode specified. Use: restricted-user, isolate-folder, or acl"
    echo "Or run without arguments for interactive mode."
    exit 1
    ;;

  *)
    error "Unknown mode: $MODE"
    echo "Valid modes: restricted-user, isolate-folder, acl"
    exit 1
    ;;
  esac
fi
