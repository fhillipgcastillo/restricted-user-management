# Restricted User Manager

A command-line tool for Ubuntu that creates restricted users, isolates folders, and manages fine-grained access control — all from a single script.

---

## Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Modes](#modes)
  - [Mode 1: Restricted User](#mode-1-restricted-user)
  - [Mode 2: Isolate Folder](#mode-2-isolate-folder)
  - [Mode 3: ACL Access Control](#mode-3-acl-access-control)
- [CLI Reference](#cli-reference)
- [Interactive Mode](#interactive-mode)
- [Examples](#examples)
- [How It Works](#how-it-works)
- [Hardening Options](#hardening-options)
- [Troubleshooting](#troubleshooting)
- [Uninstalling / Reverting Changes](#uninstalling--reverting-changes)
- [Security Notes](#security-notes)
- [License](#license)

---

## Overview

This script solves a common sysadmin need: giving someone access to a Linux machine while limiting what they can do. Instead of manually configuring shells, permissions, and ACLs, you run one script and answer a few questions (or pass CLI flags).

Three modes cover the most common scenarios:

| Mode | Use Case | Mechanism |
|------|----------|-----------|
| **Restricted User** | Kiosk accounts, guest users, limited-access operators | `rbash` + locked `PATH` |
| **Isolate Folder** | Private directories no one else should touch | `chmod` / `chown` |
| **ACL Access** | Grant or deny specific users access to specific paths | POSIX ACLs (`setfacl`) |

---

## Requirements

- **OS:** Ubuntu 20.04+ (or any Debian-based distro)
- **Privileges:** Must run as `root` (`sudo`)
- **Packages:** `acl` (auto-installed if missing when using ACL mode)
- **Shell:** Bash 4.0+

---

## Installation

```bash
# Download or copy the script
cp restricted-user-manager.sh /usr/local/sbin/restricted-user-manager
chmod +x /usr/local/sbin/restricted-user-manager
```

Or keep it anywhere and run it directly:

```bash
chmod +x restricted-user-manager.sh
sudo ./restricted-user-manager.sh
```

---

## Quick Start

**Interactive (guided setup):**

```bash
sudo ./restricted-user-manager.sh
```

You'll see a menu, answer prompts, review your config, and confirm.

**One-liner (CLI mode):**

```bash
sudo ./restricted-user-manager.sh --mode restricted-user -u kiosk -a firefox,nano --harden
```

---

## Modes

### Mode 1: Restricted User

Creates a new Linux user (or reconfigures an existing one) with a **restricted Bash shell** (`rbash`) that only allows running a whitelist of commands you specify.

**What it does:**

1. Creates the user with `/bin/rbash` as their shell.
2. Creates a `~/bin` directory inside their home folder.
3. Symlinks only the commands you allow into `~/bin`.
4. Writes a locked `.bash_profile` that sets `PATH="$HOME/bin"` and nothing else.
5. Sets ownership so the user cannot modify their own profile.

**What the restricted user *cannot* do:**

- Change their `PATH`
- Use `cd` to navigate the filesystem
- Redirect output with `>` or `>>`
- Run commands with `/` in the name (no `/usr/bin/something`)
- Modify their `.bash_profile` or `.bashrc`
- Access other users' home directories (with hardening enabled)

**What the restricted user *can* do:**

- Run the specific commands you whitelisted
- Read files their permissions allow
- Work within their home directory

#### CLI Usage

```bash
sudo ./restricted-user-manager.sh \
  --mode restricted-user \
  -u USERNAME \
  -a APP1,APP2,APP3 \
  [-p PASSWORD] \
  [-h /custom/home/path] \
  [--harden]
```

| Flag | Required | Description |
|------|----------|-------------|
| `-u, --username` | Yes | Username for the new account |
| `-a, --apps` | Yes | Comma-separated list of allowed commands |
| `-p, --password` | No | Password (securely prompted if omitted) |
| `-h, --home` | No | Custom home directory (default: `/home/USERNAME`) |
| `--harden` | No | Apply extra security hardening |

---

### Mode 2: Isolate Folder

Locks down a directory using standard Unix permissions (`chmod` and `chown`). Simple and effective when you just need to make a folder private.

**What it does:**

1. Sets the owner and group on the folder.
2. Applies the permission octal you specify (default `700` = owner only).
3. Optionally applies permissions recursively to all contents.

#### CLI Usage

```bash
sudo ./restricted-user-manager.sh \
  --mode isolate-folder \
  -f /path/to/folder \
  [-o USER:GROUP] \
  [--perms OCTAL]
```

| Flag | Required | Description |
|------|----------|-------------|
| `-f, --folder` | Yes | Path to the folder to isolate |
| `-o, --owner` | No | Owner in `user:group` format |
| `--perms` | No | Permission octal (default: `700`) |

#### Common Permission Values

| Octal | Meaning |
|-------|---------|
| `700` | Owner can read/write/execute; nobody else |
| `750` | Owner full access; group can read/execute; others nothing |
| `770` | Owner and group full access; others nothing |
| `755` | Owner full; group and others can read/execute |

---

### Mode 3: ACL Access Control

Uses POSIX Access Control Lists for fine-grained per-user or per-group rules. This is more flexible than basic `chmod` — you can grant one specific user read-only access to a folder owned by someone else, without changing the folder's ownership or group.

**What it does:**

1. Installs the `acl` package if not present.
2. Applies a `setfacl` rule for the target user or group.
3. Optionally applies the rule recursively.
4. Optionally sets a default ACL so new files inherit the rule.

#### CLI Usage

```bash
sudo ./restricted-user-manager.sh \
  --mode acl \
  -f /path/to/folder \
  --acl-target USERNAME_OR_GROUP \
  [--acl-perms rwx] \
  [--acl-action allow|deny]
```

| Flag | Required | Description |
|------|----------|-------------|
| `-f, --folder` | Yes | Target path (file or directory) |
| `--acl-target` | Yes | User or group name to apply the rule to |
| `--acl-perms` | No | Permission string like `rwx`, `r-x`, `r--` (default: `rwx`) |
| `--acl-action` | No | `allow` (apply given perms) or `deny` (set `---`) (default: `allow`) |

#### Permission String Reference

| String | Read | Write | Execute/Traverse |
|--------|------|-------|-----------------|
| `rwx` | Yes | Yes | Yes |
| `r-x` | Yes | No | Yes |
| `r--` | Yes | No | No |
| `rw-` | Yes | Yes | No |
| `---` | No | No | No |

---

## CLI Reference

Full list of all available flags:

```
Usage: sudo ./restricted-user-manager.sh [OPTIONS]

Mode selection (required in CLI mode):
  --mode MODE          restricted-user | isolate-folder | acl

Restricted user options:
  -u, --username NAME  Username for the new account
  -p, --password PASS  Password (prompted if omitted)
  -h, --home PATH      Custom home directory
  -a, --apps CMD,CMD   Comma-separated allowed commands
  --harden             Enable extra hardening

Folder isolation options:
  -f, --folder PATH    Target folder path
  -o, --owner U:G      Owner in user:group format
  --perms OCTAL        Permission octal (default: 700)

ACL options:
  -f, --folder PATH    Target path
  --acl-target NAME    User or group for the ACL rule
  --acl-perms STR      Permission string (default: rwx)
  --acl-action ACTION  allow or deny (default: allow)

General:
  --help               Show help message
```

---

## Interactive Mode

Run the script with no arguments to enter interactive mode:

```bash
sudo ./restricted-user-manager.sh
```

You'll see:

```
━━━ Restricted User Manager — Interactive Setup ━━━

  1) Restricted User  — Create a user with rbash + limited commands
  2) Isolate Folder    — Lock down a folder with chmod/chown
  3) ACL Access        — Fine-grained POSIX ACL rules

Select mode [1/2/3]:
```

The script then walks you through every option with prompts, shows a review summary, and asks for confirmation before making any changes.

Passwords are entered with hidden input and require confirmation (typed twice).

---

## Examples

### Create a kiosk user that can only run Firefox

```bash
sudo ./restricted-user-manager.sh \
  --mode restricted-user \
  -u kiosk \
  -a firefox \
  --harden
```

### Create a data operator with access to a few CLI tools

```bash
sudo ./restricted-user-manager.sh \
  --mode restricted-user \
  -u operator \
  -a ls,cat,less,grep,nano \
  -h /opt/operator
```

### Make a project folder completely private

```bash
sudo ./restricted-user-manager.sh \
  --mode isolate-folder \
  -f /srv/secret-project \
  -o admin:devteam \
  --perms 770
```

### Give an intern read-only access to a shared folder

```bash
sudo ./restricted-user-manager.sh \
  --mode acl \
  -f /srv/shared-docs \
  --acl-target intern \
  --acl-perms r-x \
  --acl-action allow
```

### Block a specific user from accessing a directory

```bash
sudo ./restricted-user-manager.sh \
  --mode acl \
  -f /srv/confidential \
  --acl-target untrusted_user \
  --acl-action deny
```

### Combine modes — create a user then lock them into one folder

```bash
# Step 1: Create the restricted user
sudo ./restricted-user-manager.sh \
  --mode restricted-user \
  -u contractor \
  -a nano,ls,cat \
  --harden

# Step 2: Give them access to only one project folder via ACL
sudo ./restricted-user-manager.sh \
  --mode acl \
  -f /srv/project-x \
  --acl-target contractor \
  --acl-perms rwx \
  --acl-action allow

# Step 3: Deny access to everything else sensitive
sudo ./restricted-user-manager.sh \
  --mode acl \
  -f /srv/internal \
  --acl-target contractor \
  --acl-action deny
```

---

## How It Works

### Restricted Bash (rbash)

`rbash` is a built-in Bash mode that disables several features:

- Cannot change `PATH`, `SHELL`, `ENV`, or `BASH_ENV`
- Cannot use `cd`
- Cannot specify commands with slashes (`/usr/bin/something`)
- Cannot redirect output with `>`, `>>`, `>&`, `&>`, or `<>`
- Cannot use `exec` to replace the shell
- Cannot add/remove shell builtins with `enable`

By combining `rbash` with a `PATH` that only contains symlinks to approved commands, the user is effectively jailed to those commands.

### POSIX ACLs

Standard Unix permissions only allow one owner, one group, and "everyone else." ACLs extend this so you can write rules like "user X gets read-only access to this folder" without changing the owner or group. The `setfacl` and `getfacl` commands manage these rules.

Default ACLs (the `-d` flag) apply automatically to new files created inside a directory, so you don't have to re-run the script every time someone adds a file.

---

## Hardening Options

When `--harden` is passed (or selected interactively), the script applies:

| Hardening | What it does |
|-----------|--------------|
| **Immutable profile** | Uses `chattr +i` on `.bash_profile` and `.bashrc` so even root-level tricks inside rbash can't modify them |
| **Home directory isolation** | Sets all other `/home/*` directories to `750` so the restricted user can't browse them |
| **Cron denied** | Adds the user to `/etc/cron.deny` to prevent scheduled tasks |
| **at denied** | Adds the user to `/etc/at.deny` to prevent deferred commands |

---

## Troubleshooting

**"Command not found" for an allowed app:**
The app might not be installed on the system. Verify with `which appname` before adding it to the allowed list.

**"Operation not permitted" with chattr:**
The filesystem may not support extended attributes (e.g., tmpfs, some NFS mounts). The script warns about this but continues. Hardening still works through file ownership.

**ACL rules not taking effect:**
The filesystem must support ACLs. Most modern ext4 setups do by default. If not, remount with: `sudo mount -o remount,acl /`

**User can still run unexpected commands:**
Some shell builtins (like `echo`, `printf`, `type`) are available in rbash regardless of PATH. This is by design — they don't provide filesystem access. For stronger isolation, consider `firejail` or container-based solutions.

**"User already exists" warning:**
The script can reconfigure existing users. It will change their shell to rbash and rebuild their `~/bin`. Confirm when prompted.

---

## Uninstalling / Reverting Changes

### Remove a restricted user

```bash
# If profile was made immutable, remove that first
sudo chattr -i /home/USERNAME/.bash_profile /home/USERNAME/.bashrc

# Delete the user and their home directory
sudo userdel -r USERNAME

# Clean up deny lists
sudo sed -i '/^USERNAME$/d' /etc/cron.deny /etc/at.deny 2>/dev/null
```

### Remove ACL rules

```bash
# Remove all ACLs from a path
sudo setfacl -b /path/to/folder

# Remove a specific user's ACL
sudo setfacl -x u:USERNAME /path/to/folder

# Remove recursively
sudo setfacl -R -b /path/to/folder
```

### Restore folder permissions

```bash
# Reset to standard permissions
sudo chmod 755 /path/to/folder
sudo chown original_owner:original_group /path/to/folder
```

---

## Security Notes

- **rbash is not a sandbox.** A knowledgeable user with access to certain commands (like `python`, `perl`, `vi`, or `less`) can escape rbash. Only whitelist commands that cannot spawn a shell. Safe choices include: `ls`, `cat`, `less` (with `LESSSECURE=1`), `grep`, `head`, `tail`, `wc`.
- **Avoid whitelisting:** `bash`, `sh`, `zsh`, `python`, `perl`, `ruby`, `node`, `vi`, `vim`, `emacs`, `awk`, `find` (with `-exec`), `env`, `ssh`, `scp`, `ftp`, `wget`, `curl`. These can all be used to break out of the restricted shell.
- **For high-security environments,** combine this script with `firejail`, AppArmor profiles, or `systemd-nspawn` containers.
- **Passwords passed via `-p` flag** will be visible in process listings and shell history. For automation, prefer piping or prompting.

---

## License

MIT — use, modify, and distribute freely.
