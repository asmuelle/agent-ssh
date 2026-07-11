import Foundation

public enum StackComponentKind: String, Codable, CaseIterable, Sendable {
    case dockerCompose
    case springBoot
    case nextjs
    case reverseProxy
    case firewall
    case postgres

    public var displayName: String {
        switch self {
        case .dockerCompose: return "Docker Compose"
        case .springBoot: return "Spring Boot"
        case .nextjs: return "Next.js"
        case .reverseProxy: return "Reverse Proxy"
        case .firewall: return "Firewall"
        case .postgres: return "PostgreSQL"
        }
    }
}

public enum StackDiagnosticState: String, Codable, Sendable {
    case healthy
    case warning
    case critical
    case unknown
}

public struct StackDiagnosticComponent: Codable, Identifiable, Equatable, Sendable {
    public var kind: StackComponentKind
    public var state: StackDiagnosticState
    public var detail: String

    public var id: String { kind.rawValue }
}

public struct StackDiagnosticSnapshot: Equatable, Sendable {
    public var components: [StackDiagnosticComponent]
    public var rawOutput: String
}

public enum StackDiagnosticParser {
    private static let marker = "__AGENT_SSH_STACK__"

    public static func parse(_ output: String) -> StackDiagnosticSnapshot {
        let components = output.split(whereSeparator: \.isNewline).compactMap { rawLine -> StackDiagnosticComponent? in
            let fields = rawLine.split(
                separator: "\t",
                maxSplits: 3,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 4,
                  fields[0] == marker,
                  let kind = StackComponentKind(rawValue: fields[1]),
                  let state = StackDiagnosticState(rawValue: fields[2])
            else { return nil }
            return StackDiagnosticComponent(kind: kind, state: state, detail: fields[3])
        }
        return StackDiagnosticSnapshot(components: components, rawOutput: output)
    }
}

/// Fixed read-only discovery probe for the supported production stack. It emits
/// structured marker rows while leaving ordinary command output available as
/// local evidence. It never installs, restarts, reloads, or writes configuration.
public enum StackDiagnosticProbe {
    public static let script = #"""
    emit_stack() {
      kind="$1"
      state="$2"
      detail=$(printf '%s' "$3" | tr '\t\r\n' '   ')
      printf '__AGENT_SSH_STACK__\t%s\t%s\t%s\n' "$kind" "$state" "$detail"
    }

    # Docker Engine and Docker Compose projects.
    if command -v docker >/dev/null 2>&1; then
      if docker info >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
          compose_rows=$(docker compose ls --format json 2>/dev/null || true)
          compose_count=$(printf '%s\n' "$compose_rows" | grep -c '"Name"' 2>/dev/null || true)
          emit_stack dockerCompose healthy "Docker available; ${compose_count:-0} compose projects discovered"
        else
          emit_stack dockerCompose warning "Docker is available, but docker compose is unavailable"
        fi
      else
        emit_stack dockerCompose warning "Docker is installed but the current user cannot query the daemon"
      fi
    fi

    # Spring Boot/JVM workloads. jcmd is used only for a read-only VM inventory.
    spring_rows=$(ps -eo pid=,args= 2>/dev/null | grep -E '[j]ava .*([.]jar|spring|org[.]springframework)' | head -20 || true)
    if [ -n "$spring_rows" ]; then
      spring_count=$(printf '%s\n' "$spring_rows" | grep -c . || true)
      if command -v jcmd >/dev/null 2>&1; then
        jvm_count=$(jcmd -l 2>/dev/null | grep -c . || true)
        emit_stack springBoot healthy "${spring_count:-0} Spring/JAR processes; ${jvm_count:-0} JVMs visible to jcmd"
      else
        emit_stack springBoot warning "${spring_count:-0} Spring/JAR processes; jcmd unavailable for JVM inspection"
      fi
    fi

    # Next.js and common Node process-manager workloads.
    next_rows=$(ps -eo pid=,args= 2>/dev/null | grep -E '[n]ext-server|[n]ext start|[n]ode .*next' | head -20 || true)
    if [ -n "$next_rows" ]; then
      next_count=$(printf '%s\n' "$next_rows" | grep -c . || true)
      pm2_detail=""
      if command -v pm2 >/dev/null 2>&1; then
        pm2_count=$(pm2 jlist 2>/dev/null | grep -o '"pm_id"' | wc -l | tr -d ' ' || true)
        pm2_detail="; ${pm2_count:-0} PM2 processes"
      fi
      emit_stack nextjs healthy "${next_count:-0} Next.js processes${pm2_detail}"
    fi

    # nginx, Caddy, and Traefik reverse proxies with read-only validation.
    proxy_found=0
    if command -v nginx >/dev/null 2>&1; then
      proxy_found=1
      if nginx -t >/dev/null 2>&1; then
        emit_stack reverseProxy healthy "nginx config valid"
      else
        emit_stack reverseProxy warning "nginx detected; config validation failed or needs privileges"
      fi
    fi
    if command -v caddy >/dev/null 2>&1; then
      proxy_found=1
      if [ -r /etc/caddy/Caddyfile ] && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        emit_stack reverseProxy healthy "Caddyfile valid"
      else
        emit_stack reverseProxy warning "Caddy detected; Caddyfile not readable or validation failed"
      fi
    fi
    if command -v traefik >/dev/null 2>&1; then
      proxy_found=1
      traefik_version=$(traefik version 2>/dev/null | head -1 || true)
      emit_stack reverseProxy unknown "Traefik detected ${traefik_version}"
    fi
    [ "$proxy_found" -eq 0 ] || true

    # UFW, firewalld, and nftables. Query only; never modify rules.
    if command -v ufw >/dev/null 2>&1; then
      ufw_status=$(sudo -n ufw status 2>/dev/null | head -1 || ufw status 2>/dev/null | head -1 || true)
      case "$ufw_status" in
        *inactive*) emit_stack firewall warning "ufw inactive" ;;
        *active*) emit_stack firewall healthy "ufw active" ;;
        *) emit_stack firewall unknown "ufw detected; status unavailable" ;;
      esac
    elif command -v firewall-cmd >/dev/null 2>&1; then
      firewalld_state=$(firewall-cmd --state 2>/dev/null || true)
      if [ "$firewalld_state" = "running" ]; then
        emit_stack firewall healthy "firewalld running"
      else
        emit_stack firewall warning "firewalld detected; state ${firewalld_state:-unknown}"
      fi
    elif command -v nft >/dev/null 2>&1; then
      if sudo -n nft list ruleset >/dev/null 2>&1 || nft list ruleset >/dev/null 2>&1; then
        emit_stack firewall healthy "nftables ruleset readable"
      else
        emit_stack firewall unknown "nftables detected; ruleset not readable"
      fi
    else
      emit_stack firewall warning "No ufw, firewalld, or nftables command detected"
    fi

    # PostgreSQL readiness and local client visibility.
    if command -v pg_isready >/dev/null 2>&1; then
      pg_status=$(pg_isready 2>&1 || true)
      case "$pg_status" in
        *"accepting connections"*) emit_stack postgres healthy "$pg_status" ;;
        *"no response"*|*"rejecting connections"*) emit_stack postgres critical "$pg_status" ;;
        *) emit_stack postgres unknown "$pg_status" ;;
      esac
    elif command -v psql >/dev/null 2>&1; then
      emit_stack postgres unknown "psql installed; pg_isready unavailable"
    fi
    """#
}
