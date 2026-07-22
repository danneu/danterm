#!/usr/bin/env bash
# Creates an isolated, durable run directory before launching the opt-in real-PTY workflows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_ROOT="${DANTERM_WORKFLOW_RUN_ROOT:-$REPO_ROOT/.build/terminal-workflow-runs}"
WORKFLOW_PATH="${DANTERM_WORKFLOW_PATH:-$PATH}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$RUN_ROOT/$run_id"
mkdir -p "$run_dir"

manifest="$run_dir/environment.txt"
result="$run_dir/result.txt"
{
    printf 'run_id=%s\n' "$run_id"
    printf 'os=%s\n' "$(sw_vers -productVersion 2>/dev/null || uname -sr)"
    printf 'arch=%s\n' "$(uname -m)"
} > "$manifest"

missing=()
for tool in fish fzf swift; do
    path="$(PATH="$WORKFLOW_PATH" command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
        missing+=("$tool")
        continue
    fi
    printf '%s_path=%s\n' "$tool" "$path" >> "$manifest"
    printf '%s_version=%s\n' "$tool" "$(PATH="$WORKFLOW_PATH" "$path" --version 2>&1 | head -1)" >> "$manifest"
done
for tool in /bin/zsh /bin/bash /usr/bin/ssh /usr/bin/ssh-keygen /usr/sbin/sshd /usr/bin/more /usr/bin/less; do
    name="${tool##*/}"
    if [[ ! -x "$tool" ]]; then
        missing+=("$tool")
        continue
    fi
    printf '%s_path=%s\n' "$name" "$tool" >> "$manifest"
    case "$name" in
        ssh|ssh-keygen|sshd)
            version="$(/usr/bin/ssh -V 2>&1)"
            ;;
        *)
            version="$("$tool" --version 2>&1 | head -1 || true)"
            ;;
    esac
    printf '%s_version=%s\n' "$name" "$version" >> "$manifest"
done

if (( ${#missing[@]} > 0 )); then
    printf 'status=preflight-failed\nmissing=%s\n' "${missing[*]}" > "$result"
    echo "terminal workflows: missing prerequisites: ${missing[*]}" >&2
    echo "artifacts: $run_dir" >&2
    exit 2
fi

home_dir="$run_dir/home"
ssh_dir="$run_dir/ssh"
mkdir -p "$home_dir" "$ssh_dir"
chmod 700 "$ssh_dir"

integration_dir="$REPO_ROOT/integrations/shell-integration"
cat > "$home_dir/.zshrc" <<EOF
source "$integration_dir/danterm.zsh"
stty -echo
PROMPT='DANTERM-WORKFLOW> '
HISTFILE="$home_dir/zsh-history"
EOF
cat > "$home_dir/.bashrc" <<EOF
source "$integration_dir/danterm.bash"
stty -echo
PS1='DANTERM-WORKFLOW> '
HISTFILE="$home_dir/bash-history"
EOF
cat > "$home_dir/.bash_profile" <<EOF
source "$home_dir/.bashrc"
EOF
mkdir -p "$home_dir/.config/fish"
cat > "$home_dir/.config/fish/config.fish" <<EOF
source "$integration_dir/danterm.fish"
stty -echo
function fish_prompt; printf 'DANTERM-WORKFLOW> '; end
set -g fish_history danterm_workflow
EOF

for index in $(seq 1 120); do
    printf 'line-%03d terminal workflow corpus\n' "$index"
    if [[ "$index" == 63 ]]; then printf 'UNICODE-λ marker\n'; fi
done > "$run_dir/corpus.txt"
mkdir -p "$home_dir/café"
: > "$home_dir/café/δ.txt"

ssh_port=$((40000 + ($$ % 20000)))
cat > "$ssh_dir/config" <<EOF
Host workflow-host
    HostName 127.0.0.1
    Port $ssh_port
    User $(id -un)
    IdentityFile $ssh_dir/client_key
    UserKnownHostsFile $ssh_dir/known_hosts
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    IdentitiesOnly yes
    IdentityAgent none
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    SendEnv LC_DANTERM_TOKEN
EOF

runner="${DANTERM_WORKFLOW_RUNNER:-}"
if [[ -z "$runner" ]]; then
    /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/host_key"
    /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/client_key"
    cp "$ssh_dir/client_key.pub" "$ssh_dir/authorized_keys"
    host_public_key="$(cut -d ' ' -f 1,2 "$ssh_dir/host_key.pub")"
    printf '[127.0.0.1]:%s %s\n' "$ssh_port" "$host_public_key" > "$ssh_dir/known_hosts"
    cat > "$ssh_dir/sshd_config" <<EOF
Port $ssh_port
ListenAddress 127.0.0.1
HostKey $ssh_dir/host_key
AuthorizedKeysFile $ssh_dir/authorized_keys
PidFile $ssh_dir/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM no
AllowAgentForwarding no
AllowTcpForwarding no
PermitUserEnvironment no
AcceptEnv LC_DANTERM_TOKEN
Subsystem sftp internal-sftp
EOF
    /usr/sbin/sshd -D -e -f "$ssh_dir/sshd_config" > "$ssh_dir/sshd.log" 2>&1 &
    sshd_pid=$!
    trap 'kill "$sshd_pid" 2>/dev/null || true; wait "$sshd_pid" 2>/dev/null || true' EXIT
    PATH="$WORKFLOW_PATH" swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --product TerminalWorkflowRunner
    PATH="$WORKFLOW_PATH" swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --product PTYSessionBootstrap
    runner="$REPO_ROOT/lib/TerminalPTY/.build/debug/TerminalWorkflowRunner"
    bootstrap="$REPO_ROOT/lib/TerminalPTY/.build/debug/PTYSessionBootstrap"
else
    bootstrap="unused-by-injected-runner"
fi

set +e
HOME="$home_dir" PATH="$WORKFLOW_PATH:/usr/bin:/bin:/usr/sbin" \
    DANTERM_FISH="$(PATH="$WORKFLOW_PATH" command -v fish)" \
    DANTERM_FZF="$(PATH="$WORKFLOW_PATH" command -v fzf)" \
    DANTERM_REPO_ROOT="$REPO_ROOT" \
    DANTERM_MACHINE_HOSTNAME="$(hostname)" \
    DANTERM_WORKFLOW_SSH_CONFIG="$ssh_dir/config" \
    "$runner" "$run_dir" "$bootstrap" > "$run_dir/runner.stdout" 2> "$run_dir/runner.stderr"
runner_status=$?
set -e
if (( runner_status != 0 )); then
    printf 'status=failed\nrunner_status=%s\n' "$runner_status" > "$result"
    echo "terminal workflows: failed; artifacts: $run_dir" >&2
    exit 1
fi

printf 'status=passed\n' > "$result"
echo "terminal workflows: all workflows passed"
echo "artifacts: $run_dir"
