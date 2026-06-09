import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension MonitorDrillDownSheet {
    // MARK: - Diagnostic scripts

    static let cpuScript = """
    set +e
    export LC_ALL=C

    printf 'INFO\tLoad\t%s\n' "$(uptime 2>/dev/null || true)"
    if command -v nproc >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(nproc 2>/dev/null || true)"
    elif command -v sysctl >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    if command -v mpstat >/dev/null 2>&1; then
      mpstat 1 1 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    fi

    emit_cpu_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 8 && count < 35 {
          args=$9
          for (i=10; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,0,0,$8,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,etime=,args= --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,etime=,command= -r 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    else
      printf 'WARN\tCould not collect process CPU data.\n'
    fi

    if out=$(ps -eLo pid,tid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | awk '
        BEGIN { OFS="\t"; count=0 }
        NR > 1 && NF >= 5 && count < 35 {
          print "THREAD",$1,$2,$3,$4,$5
          count++
        }
      '
    else
      printf 'WARN\tThread-level CPU data is unavailable on this host.\n'
    fi
    """

    static let memoryScript = """
    set +e
    export LC_ALL=C

    if command -v free >/dev/null 2>&1; then
      free -h 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    elif command -v vm_stat >/dev/null 2>&1; then
      vm_stat 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
      sysctl hw.memsize 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    else
      printf 'WARN\tNo memory summary command found.\n'
    fi

    emit_memory_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 10 && count < 35 {
          args=$11
          for (i=12; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,rss=,vsz=,etime=,args= --sort=-rss 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,rss=,vsz=,etime=,command= -m 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    else
      printf 'WARN\tCould not collect process memory data.\n'
    fi

    if command -v journalctl >/dev/null 2>&1; then
      sudo -n journalctl -k -n 300 --no-pager 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    elif command -v dmesg >/dev/null 2>&1; then
      sudo -n dmesg 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    else
      printf 'WARN\tKernel memory-pressure logs are unavailable.\n'
    fi
    """

    static func diskScript(mount: String) -> String {
        let quotedMount = RemoteCommandRunner.shellQuote(mount)
        return """
        set +e
        export LC_ALL=C
        mount_path=\(quotedMount)

        usage=$(df -hP "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        [ -n "$usage" ] || usage=$(df -h "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        printf 'MOUNT\t%s\t%s\n' "$mount_path" "$usage"

        if ! command -v find >/dev/null 2>&1; then
          printf 'WARN\tfind is not available on this host.\n'
          exit 0
        fi

        out="${TMPDIR:-/tmp}/agent-ssh-files-$$.tsv"
        err="${TMPDIR:-/tmp}/agent-ssh-files-$$.err"
        trap 'rm -f "$out" "$err"' EXIT
        : > "$out"
        : > "$err"

        find_flags=""
        if find "$mount_path" -xdev -type f -mtime -14 -print -quit >/dev/null 2>&1; then
          find_flags="-xdev"
        fi

        if find "$mount_path" $find_flags -maxdepth 0 -printf '' >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -printf 'FILE\t%s\t%T@\t%TY-%Tm-%Td %TH:%TM\t%u\t%h\t%p\n' > "$out" 2>"$err"
        elif stat -f '%z' "$mount_path" >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -exec stat -f 'FILE\t%z\t%m\t%Sm\t%Su\t%N' -t '%Y-%m-%d %H:%M' {} + > "$out" 2>"$err"
        else
          find "$mount_path" $find_flags -type f -mtime -14 -exec ls -ln {} + 2>"$err" \
            | awk 'BEGIN { OFS="\t" } NF >= 9 { path=$9; for (i=10; i<=NF; i++) path=path " " $i; print "FILE",$5,0,$6 " " $7 " " $8,$3,"",path }' > "$out"
        fi

        if [ -s "$out" ]; then
          sort -nr -k2,2 "$out" | head -n 120
        else
          printf 'WARN\tNo files changed in the last 14 days were found on this mount, or the current user cannot read them.\n'
        fi
        if [ -s "$err" ]; then
          printf 'WARN\tSome paths could not be read while scanning this mount.\n'
        fi
        """
    }

    static func systemdScript(unit: String) -> String {
        let quotedUnit = RemoteCommandRunner.shellQuote(unit)
        return """
        set +e
        export LC_ALL=C
        unit=\(quotedUnit)

        command -v systemctl >/dev/null 2>&1 || { printf 'WARN\tsystemctl is not available on this host.\n'; exit 127; }

        show_unit() {
          systemctl show "$unit" --no-pager "$@" 2>&1 || sudo -n systemctl show "$unit" --no-pager "$@" 2>&1 || true
        }

        emit_show() {
          show_unit "$@" | awk -F= 'BEGIN { OFS="\t" } NF { key=$1; sub(/^[^=]*=/, ""); print "KV",key,$0 }'
        }

        emit_family() {
          printf 'SVCFAMILY\t%s\n' "$1"
        }

        emit_svc() {
          printf 'SVC\t%s\t%s\t%s\n' "$1" "$2" "$3"
        }

        emit_lines() {
          section="$1"
          shift
          "$@" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_shell_lines() {
          section="$1"
          script="$2"
          sh -lc "$script" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_file() {
          kind="$1"
          file="$2"
          [ -n "$file" ] || return 0
          printf 'FILE\t%s\t%s\n' "$kind" "$file"
          (sudo -n sed -n '1,240p' "$file" 2>&1 || sed -n '1,240p' "$file" 2>&1 || true) \
            | awk -v kind="$kind" -v file="$file" 'BEGIN { OFS="\t" } { print "FILELINE",kind,file,NR,$0 }'
        }

        emit_show \
          -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
          -p User -p Group -p DynamicUser -p SupplementaryGroups \
          -p MainPID -p ExecMainPID -p ExecMainStatus -p Restart -p RestartUSec \
          -p WorkingDirectory -p FragmentPath -p DropInPaths \
          -p Environment -p EnvironmentFiles \
          -p ExecStart -p ExecReload -p ExecStop -p ExecStartPre -p ExecStartPost

        fragment=$(systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || true)
        emit_file "Unit File" "$fragment"

        dropins=$(systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || true)
        if [ -n "$dropins" ]; then
          for file in $dropins; do
            emit_file "Drop-in" "$file"
          done
        fi

        env_files=$(systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || true)
        if [ -n "$env_files" ]; then
          for file in $env_files; do
            file=${file#-}
            emit_file "Environment File" "$file"
          done
        fi

        if command -v journalctl >/dev/null 2>&1; then
          (journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || sudo -n journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || true) \
            | awk 'BEGIN { OFS="\t" } NF { print "JOURNAL",$0 }'
        else
          printf 'WARN\tjournalctl is not available on this host.\n'
        fi

        service_key=$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')
        case "$service_key" in
          *nginx*|*apache2*|*httpd*)
            emit_family web
            if command -v nginx >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "nginx -t"
              emit_shell_lines "Virtual Hosts" "nginx -T 2>/dev/null | awk '/^[[:space:]]*(server_name|listen)[[:space:]]/ {print}' | head -n 160"
            elif command -v apachectl >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "apachectl configtest"
              emit_shell_lines "Virtual Hosts" "apachectl -S 2>&1 | head -n 180"
            fi
            emit_shell_lines "Listeners" "ss -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || netstat -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || true"
            emit_shell_lines "TLS Certificates" "find /etc/letsencrypt/live /etc/ssl -maxdepth 3 -type f \\( -name fullchain.pem -o -name cert.pem -o -name '*.crt' \\) 2>/dev/null | head -n 60 | while read -r cert; do end=$(openssl x509 -noout -enddate -in \"$cert\" 2>/dev/null | sed 's/^notAfter=//'); [ -n \"$end\" ] && printf '%s -> %s\\n' \"$cert\" \"$end\"; done"
            ;;
          *apparmor*)
            emit_family apparmor
            emit_shell_lines "Profile State" "aa-status 2>/dev/null || apparmor_status 2>/dev/null || true"
            emit_shell_lines "Recent Denials" "(journalctl -k -n 600 --no-pager 2>/dev/null || dmesg 2>/dev/null || true) | grep -Ei 'apparmor=.*DENIED|audit.*DENIED' | tail -n 120"
            ;;
          *fail2ban*)
            emit_family fail2ban
            emit_shell_lines "Jails" "fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true"
            emit_shell_lines "Bans" "status=$(fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true); jails=$(printf '%s\\n' \"$status\" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); for jail in $jails; do jail=$(printf '%s' \"$jail\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -n \"$jail\" ] || continue; echo \"-- $jail --\"; fail2ban-client status \"$jail\" 2>/dev/null || sudo -n fail2ban-client status \"$jail\" 2>/dev/null || true; done"
            emit_shell_lines "Recent Log" "tail -n 160 /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -n 160 --no-pager 2>/dev/null || true"
            ;;
          *apt-daily*|*unattended-upgrades*|*apt*)
            emit_family apt
            emit_shell_lines "Timers" "systemctl list-timers '*apt*' '*unattended*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Recent Package Activity" "tail -n 160 /var/log/apt/history.log /var/log/apt/term.log /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null"
            emit_shell_lines "Locks" "lslocks 2>/dev/null | grep -E 'apt|dpkg|unattended' || true"
            ;;
          *certbot*|*letsencrypt*)
            emit_family certbot
            emit_shell_lines "Certificates" "certbot certificates 2>/dev/null || sudo -n certbot certificates 2>/dev/null || true"
            emit_shell_lines "Renewal Timers" "systemctl list-timers '*certbot*' '*letsencrypt*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Renewal Logs" "tail -n 180 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || journalctl -u certbot -n 180 --no-pager 2>/dev/null || true"
            ;;
          *chrony*|*timesyncd*|*ntp*)
            emit_family chrony
            emit_shell_lines "Tracking" "chronyc tracking 2>/dev/null || timedatectl 2>/dev/null || true"
            emit_shell_lines "Sources" "chronyc sources -v 2>/dev/null || timedatectl timesync-status 2>/dev/null || true"
            emit_shell_lines "Recent Sync Logs" "journalctl -u chrony -u chronyd -u systemd-timesyncd -n 140 --no-pager 2>/dev/null || true"
            ;;
          *clamav*|*clamd*|*freshclam*)
            emit_family clamav
            emit_shell_lines "Version" "clamdscan --version 2>/dev/null || clamscan --version 2>/dev/null || freshclam --version 2>/dev/null || true"
            emit_shell_lines "Definitions" "ls -lh /var/lib/clamav 2>/dev/null || true"
            emit_shell_lines "Recent Logs" "tail -n 180 /var/log/clamav/clamav.log /var/log/clamav/freshclam.log 2>/dev/null || journalctl -u clamav-daemon -u clamav-freshclam -n 180 --no-pager 2>/dev/null || true"
            ;;
          *containerd*|*docker*)
            emit_family container
            emit_shell_lines "Runtime" "ctr version 2>/dev/null || docker version --format '{{.Server.Version}}' 2>/dev/null || true"
            emit_shell_lines "Containers" "ctr namespaces list 2>/dev/null; ctr -n default containers list 2>/dev/null | head -n 120; docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>/dev/null | head -n 120"
            emit_shell_lines "Disk Usage" "docker system df 2>/dev/null || du -sh /var/lib/containerd /var/lib/docker 2>/dev/null || true"
            ;;
          *dovecot*)
            emit_family mail
            emit_shell_lines "Dovecot Config" "doveconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Listeners" "ss -ltnp 2>/dev/null | grep -E ':(143|993|110|995)\\b|dovecot' || true"
            emit_shell_lines "Auth Failures" "(journalctl -u dovecot -n 600 --no-pager 2>/dev/null || tail -n 600 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'auth.*fail|failed password|Disconnected.*auth' | tail -n 120"
            ;;
          *postfix*)
            emit_family mail
            emit_shell_lines "Queue" "postqueue -p 2>/dev/null || mailq 2>/dev/null || true"
            emit_shell_lines "Postfix Config" "postconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Flow" "(journalctl -u postfix -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'status=(sent|deferred|bounced)|reject|warning|fatal|connect from' | tail -n 160"
            ;;
          *rsyslog*|*journald*)
            emit_family syslog
            emit_shell_lines "Config Validation" "rsyslogd -N1 2>&1 || true"
            emit_shell_lines "Rules And Targets" "grep -RhsE '^[^#].*(@@?|/var/log|omfwd|imjournal|imuxsock)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | head -n 160"
            emit_shell_lines "Log Disk Usage" "du -sh /var/log/* 2>/dev/null | sort -hr | head -n 80"
            ;;
          *snapd*|*snap*)
            emit_family snap
            emit_shell_lines "Refreshes" "snap changes 2>/dev/null | head -n 120 || true"
            emit_shell_lines "Installed Snaps" "snap list 2>/dev/null | head -n 160 || true"
            emit_shell_lines "Snap Services" "snap services 2>/dev/null | head -n 160 || true"
            ;;
          *ssh*|*sshd*)
            emit_family ssh
            emit_shell_lines "Listeners And Sessions" "ss -ltnp 2>/dev/null | grep -E ':22\\b|sshd' || true; who 2>/dev/null || true"
            emit_shell_lines "Auth Activity" "(journalctl -u ssh -u sshd -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/auth.log /var/log/secure 2>/dev/null || true) | grep -Ei 'Accepted|Failed|Invalid user|Disconnected|Unable to negotiate' | tail -n 160"
            emit_shell_lines "Effective Config" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|allowusers|denyusers|authenticationmethods|maxauthtries)' || true"
            ;;
          *)
            emit_family generic
            emit_shell_lines "Listeners" "mainpid=$(systemctl show \"$unit\" --value -p MainPID 2>/dev/null || true); case \"$mainpid\" in \"\"|0) ;; *) ss -ltnp 2>/dev/null | grep -F \"pid=$mainpid,\" || true ;; esac"
            emit_shell_lines "Recent Warnings" "journalctl -u \"$unit\" -n 300 --no-pager 2>/dev/null | grep -Ei 'error|warn|fail|fatal|denied|timeout' | tail -n 80 || true"
            ;;
        esac
        """
    }

    static func ufwScript(sshPort: UInt16?) -> String {
        let sshPortValue = sshPort.map { String($0) } ?? "22"
        return """
        set +e
        export LC_ALL=C

        printf 'INFO\tSSHPort\t\(sshPortValue)\n'
        command -v ufw >/dev/null 2>&1 || { printf 'WARN\tufw is not available on this host.\n'; exit 127; }

        run_ufw() {
          sudo -n ufw "$@" 2>&1 || ufw "$@" 2>&1 || true
        }

        run_ufw status verbose | awk 'NF {print "STATUS\t" $0}'
        run_ufw status numbered | awk 'NF {print "RULE\t" $0}'
        run_ufw app list | awk 'NF {print "APP\t" $0}'

        (sudo -n sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || true) | awk 'NF {print "CONFIG\t" $0}'

        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n tail -n 180 /var/log/ufw.log 2>/dev/null
        elif [ -r /var/log/ufw.log ]; then
          tail -n 180 /var/log/ufw.log 2>/dev/null
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 360 --no-pager 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        elif command -v dmesg >/dev/null 2>&1; then
          sudo -n dmesg 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        else
          printf 'WARN\tNo UFW log source found.\n'
        fi | awk 'NF {print "LOG\t" $0}'

        sudo -n iptables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES\t" $0}' || true
        sudo -n ip6tables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES6\t" $0}' || true
        """
    }

    static func processInspectionScript(pid: Int) -> String {
        """
        set +e
        export LC_ALL=C
        pid=\(pid)
        echo "== Process =="
        ps -fp "$pid" 2>/dev/null || ps -p "$pid" -o pid,ppid,user,stat,comm,pcpu,pmem,etime,args 2>/dev/null || true
        echo
        echo "== /proc status =="
        [ -r "/proc/$pid/status" ] && sed -n '1,220p' "/proc/$pid/status" || echo "/proc status unavailable."
        echo
        echo "== Open files =="
        if command -v lsof >/dev/null 2>&1; then
          lsof -p "$pid" 2>/dev/null | head -n 80 || true
        elif [ -d "/proc/$pid/fd" ]; then
          ls -la "/proc/$pid/fd" 2>/dev/null | head -n 80 || true
        else
          echo "Open-file inspection unavailable."
        fi
        echo
        echo "== Network sockets =="
        if command -v ss >/dev/null 2>&1; then
          ss -tunap 2>/dev/null | grep -F "pid=$pid," | head -n 80 || true
        elif command -v netstat >/dev/null 2>&1; then
          netstat -tunap 2>/dev/null | grep -F "/$pid" | head -n 80 || true
        else
          echo "Socket inspection unavailable."
        fi
        """
    }

    static func directoryInspectionScript(path: String) -> String {
        let quotedPath = RemoteCommandRunner.shellQuote(path)
        return """
        set +e
        export LC_ALL=C
        dir=\(quotedPath)
        echo "== Directory Usage =="
        if du -h -d 1 "$dir" >/dev/null 2>&1; then
          du -h -d 1 "$dir" 2>/dev/null | sort -hr | head -n 80
        elif du -h --max-depth=1 "$dir" >/dev/null 2>&1; then
          du -h --max-depth=1 "$dir" 2>/dev/null | sort -hr | head -n 80
        else
          du -h "$dir"/* 2>/dev/null | sort -hr | head -n 80 || true
        fi
        echo
        echo "== Recently Changed In Directory =="
        find "$dir" -maxdepth 1 -type f -mtime -14 -exec ls -lh {} + 2>/dev/null | sort -k6,8 | tail -n 80 || true
        """
    }

    static func ufwSourceInspectionScript(source: String) -> String {
        let quotedSource = RemoteCommandRunner.shellQuote(source)
        return """
        set +e
        export LC_ALL=C
        source_ip=\(quotedSource)
        echo "== Source =="
        printf '%s\n' "$source_ip"
        echo
        echo "== Reverse DNS =="
        (command -v dig >/dev/null 2>&1 && dig +short -x "$source_ip") || (command -v host >/dev/null 2>&1 && host "$source_ip") || echo "Reverse lookup unavailable."
        echo
        echo "== Recent UFW log lines =="
        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif [ -r /var/log/ufw.log ]; then
          grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 1000 --no-pager 2>/dev/null | grep -F "SRC=$source_ip" | tail -n 120 || true
        else
          echo "No log source found."
        fi
        """
    }
}

extension UInt64 {
    func multipliedWithoutOverflow(by rhs: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : value
    }
}
