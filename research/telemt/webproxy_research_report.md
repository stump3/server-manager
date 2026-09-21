# WEBPROXY Research Report: TeleMT / MTPROTO_FIX_By_MEKO / MTProxyL and Server-manager Integration Feasibility

*Research-only deliverable. No Server-manager code was modified. No commits, no pushes, no implementation.*

*Repositories cloned and inspected directly (git clone over `github.com`/`codeload.github.com`) rather than relying on training-data recall:*

| Repo | Commit inspected | First WEB-related commit | Last commit touching WEB code |
|---|---|---|---|
| `telemt/telemt` | `935b5a3` (2026‑09‑13) | `1029703` "WEB", 2026‑08‑23 | 2026‑09‑13 (45 commits to `src/web/`) |
| `Mekotofeuka/MTPROTO_FIX_By_MEKO` | `f809bb9` | n/a (wrapper only) | n/a |
| `Liafanx/MTProxyL` | `8f17410` | `d7985e9`, 2026‑08‑27 | 2026‑09‑20 (26 commits to `lib/web.sh`) |
| `stump3/server-manager` | `7d8aff0` (`main`, only branch on GitHub) | — | last touch to telemt integration: 2026‑08‑12, **predates** TeleMT's WEB feature |

**Critical scope limitation, stated up front:** the Server-manager architecture this task asks me to reason against — Inventory, Capability Registry, Desired State, Planner, Provider/renderer, `PortAllocation`, `docs/edge_contracts.md`, `docs/CORE_RUNTIME_CONTRACTS.md`, `lib/core/`, `lib/panel/`, `lib/telemt/`, F/J topologies, MODE1/MODE2 — **does not exist in the only branch (`main`) reachable from this session's GitHub clone.** That branch still has the pre-split `lib/panel.sh` (2428 lines) and `lib/telemt.sh` (1498 lines) monoliths, no `lib/core/` directory, and no capability/planner vocabulary anywhere in its docs. Per this project's own retained working notes, the described architecture lives on an unpushed local working tree (`variant-f-j` branch, agent workflow that never commits/pushes without explicit sign-off). I therefore could not run the "EXISTING SERVER-MANAGER STUDY" and "COMPATIBILITY MATRIX" sections against real code. Sections 13–18 are marked accordingly and should be re-run by whoever has the actual working tree open — this report gives them the WEBPROXY-side facts to do that quickly.

---

## 1. Executive summary

- **WEBPROXY, in all three repositories, is one thing: TeleMT's native `WEB` transport.** Neither MTPROTO_FIX_By_MEKO nor MTProxyL implement an independent MTProto‑over‑HTTP/WebSocket protocol. Both drive TeleMT's own `[web]` configuration surface and TeleMT's own HTTP/WebSocket engine (`src/web/*` in the TeleMT source tree, ~19–26k lines of Rust, first shipped 2026‑08‑22/23 as engine version 3.5.0/3.5.1, iterated through 3.5.7). *(SOURCE FACT)*
- TeleMT **never terminates TLS** for WEB. An external terminator (NGINX or HAProxy) must own the certificate and forward plain HTTP/1.1 to a private TeleMT listener (`transport = "web"`). This is stated in TeleMT's own docs and enforced in code (`ListenerTransport::Web` is a distinct variant from `ListenerTransport::Mtproxy`; the WEB HTTP server in `src/web/http.rs` speaks only plain `hyper::server::conn::http1`, no TLS). *(SOURCE FACT)*
- The discriminator between "WEB traffic" and "ordinary HTTPS/decoy" is **HTTP Host header + exact path match, done post‑TLS‑termination**, not SNI and not ALPN. SNI only comes into play one layer earlier, at the multiplexer that shares a public port between WEB and something else (see §9). *(SOURCE FACT, `src/web/http.rs:157‑215`)*
- **MTPROTO_FIX_By_MEKO** does not implement WEBPROXY. It is a bash installer/menu that (a) downloads a template `config.toml` fragment that is a verbatim copy of TeleMT's own `[web]` schema, (b) certbot‑provisions a cert, and (c) writes an NGINX vhost that is byte‑for‑byte the same template published in TeleMT's own documentation. It only wires up TeleMT; it does not touch the other proxy engines it otherwise manages (mtg, mtproto.zig, teleproxy, python_mtproto). *(SOURCE FACT)*
- **MTProxyL** is the deepest integration: a mature bash manager (`lib/web.sh`, 2070 lines; `lib/tui_web.sh`, 209 lines) plus a Go control‑plane (`mtproxyl-panel`) and a Telegram bot, all of which render TeleMT's `[web]`/`[[server.listeners]]` TOML and either NGINX‑stream or HAProxy front‑end configs from a small set of bash‑level settings (`WEB_LAYOUT`, `WEB_FRONTEND`, `WEB_CARRIER`, `WEB_DECOY_MODE`, `WEB_DECOY_UPSTREAM`, `WEB_HAPROXY_CERT`, …). It formalizes exactly the **shared‑vs‑split** and **frontend** decisions this research was asked to pin down (§9). *(SOURCE FACT)*
- MTProxyL's own architecture for "one port, two protocols" is **functionally identical to the classic Xray "Nginx‑stream SNI routing" pattern** already documented in this project's `xray-architecture.md` (§3.2, "Вариант B"): an `stream { ssl_preread on; map $ssl_preread_server_name ... }` block demultiplexes by SNI to either a WEB‑TLS backend or the ordinary FakeTLS/MTProto backend, both reached with PROXY protocol. HAProxy can play the same router role (`req.ssl_sni` ACL) as an explicit alternative — again mirroring the Xray document's own §11 open question 2 ("Nginx stream vs HAProxy"). This is a strong signal that Server-manager's existing (or planned) Xray/nginx‑stream renderer abstractions are the *right shape* of abstraction to reuse for TeleMT WEB, not a mismatch requiring new primitives. *(INFERENCE, grounded in source facts above and the attached Xray document)*
- WEBPROXY is best modelled in Server‑manager terms as: **a second, independent transport/listener for the TeleMT capability, requiring its own domain, its own certificate lifecycle, and (in the shared case) an SNI‑routing capability at the nginx layer that already has to exist for anything resembling the Xray "Вариант B" pattern.** It is *not* "just another port" and it is *not* a property that can be bolted onto the existing FakeTLS domain. §13–18 develop this, with explicit gaps flagged where verification against the real `variant-f-j` tree is required. *(DESIGN PROPOSAL, built on SOURCE FACTs above)*

---

## 2. TeleMT architecture

### 2.1 What WEB actually is

TeleMT's own documentation is unusually explicit and was written after the feature was code‑complete, not before:

> "WEB mode carries ordinary MTProxy streams through bounded HTTPS or WebSocket carriers compatible with Telegram Desktop's `WEB` proxy type. Telemt does not terminate TLS…" — `docs/WEB/WEB_PROXY.en.md:5` *(SOURCE FACT, quoted per copyright limits: this is the repository's own README‑style doc, paraphrase used elsewhere in this report)*

So WEB is simultaneously:
- a **carrier** (in the terminology this task uses) — one of `https`, `https-lanes`, `websocket`, `websocket-lanes`, defined as a Rust enum `WebCarrier` (`src/config/types/web_carrier.rs:9‑19`);
- a **frontend requirement** — it needs an external L7 TLS terminator, because TeleMT's WEB HTTP server is plaintext‑only (`src/web/http.rs` uses `hyper::server::conn::http1`, no `rustls`/TLS acceptor anywhere in `src/web/`);
- a distinct **transport** at the listener level — `ListenerTransport::Web` vs `ListenerTransport::Mtproxy` (`src/config/types/server.rs:81‑87`), each bound to its own `[[server.listeners]]` entry;
- **not** a new application‑layer MTProto variant — the inner MTProto handshake, user/secret model (`plain`/`dd` 16‑byte secrets), and the DC transport are the ordinary TeleMT proxy engine; WEB only changes how bytes reach that engine.

### 2.2 Byte‑level connection path (SOURCE FACT, `src/web/http.rs`, `docs/WEB/WEB_PROXY.en.md:11‑23`)

```text
Telegram Desktop
    | HTTPS or WSS :443 (public)
    v
NGINX or HAProxy  — TLS termination, sets Host + one X-Forwarded-For
    | plain HTTP/1.1, private network
    v
TeleMT WEB listener  (transport = "web", e.g. 127.0.0.1:18080)
    |
    +-- Host header matches a configured [[web.vhosts]] AND
    |   path ∈ {/api/v1/session, /api/v1/up, /api/v1/down, /api/v1/ws, "/"}
    |     -> capability/bootstrap check (GET /?bridge=<43-char base64url>)
    |     -> authenticated carrier -> bounded logical MTProxy relay -> Telegram DC
    |
    `-- anything else (unknown Host, unknown path, invalid bridge query)
          -> configured decoy (static directory snapshot or private HTTP upstream)
```

Routing is implemented in `handle_request()` (`src/web/http.rs:157‑220`): it looks up the request's `Host` in `web_runtime.vhosts` (a map keyed by hostname), returns a generic 404 if the host is unknown, then dispatches on exact `path` — `/api/v1/ws` to the WebSocket handler, `{/api/v1/session,/api/v1/up,/api/v1/down}` to the HTTP carrier handler, `/` (GET/HEAD only) to the bridge/capability handler, everything else falls through to the decoy path (`decoy::serve_decoy`). **There is no SNI‑level discrimination inside TeleMT** — by the time TeleMT sees the request, TLS is already gone. Answering the task's explicit question: the discriminator between WEB and "ordinary HTTPS" *at the TeleMT layer* is **Host header + exact path**, never SNI, never ALPN, never first‑bytes sniffing.

Client bootstrap: an unauthenticated `GET /?bridge=<capability>` on the root path returns a small self‑contained bridge (`src/web/bridge.rs` + `src/web/bridge/*.js`, `document.html`) — this is a **generated single‑page JS application (an actual browser‑executable WebView payload)**, not a config file, that Telegram Desktop's embedded WebView loads to speak the HTTPS/WebSocket carrier protocol back to the server. This is TeleMT's disambiguator for the "does the MTProto engine itself understand HTTP/WebSocket, or does a frontend unwrap it" question: **TeleMT's own Rust engine is the HTTP/WebSocket implementation** (via `hyper`); NGINX/HAProxy only does TLS + L7 host routing, never protocol translation. `decoy_fasttrack_mode` (an optimization added later, see `web_decoy_fasttrack.rs`, most recent commit in the sampled history) lets the root‑path capability scan be short‑circuited for `HEAD` or malformed `bridge` queries without weakening the full scan for canonical‑shaped requests.

### 2.3 Configuration schema (SOURCE FACT, `src/config/types/web.rs`, `src/config/types/web_carrier.rs`, `src/config/types/server.rs`)

```toml
[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"                       # ListenerTransport::Web
proxy_protocol = false                  # must be false for WEB (enforced, §19)
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]   # non-empty, /0 rejected (validate_web.rs:144-156)

[web]
enabled = true
carrier = "https-lanes"                 # WebCarrier::{Https,HttpsLanes,Websocket,WebsocketLanes}
carriers = ["websocket-lanes","websocket","https-lanes"]  # optional negotiation order
carrier_learning = true
carrier_negotiation_aggressiveness = "conservative"  # conservative|balanced|aggressive
decoy_fasttrack_mode = "off"            # off|shadow|enforce
http_connection_capacity_action = "drop"  # drop|respond|wait

[[web.vhosts]]
host = "proxy.example.com"
public_addr = "203.0.113.10:443"        # concrete IP, feeds the inner relay tuple

[web.vhosts.decoy]
mode = "http_upstream"                  # or "static_directory"
upstream = "http://127.0.0.1:18081"     # must be loopback/link-local/private (enforced)

[[web.vhosts.profiles]]
user = "web-user"                       # existing [access.users] key
secret_mode = "dd"                      # plain | dd
max_sessions = 8
max_streams = 512
max_streams_per_session = 64
```

Key structural facts:
- A `[[web.vhosts]]` entry **requires** at least one profile or the engine refuses to accept it (documented and mirrored defensively in MTProxyL, §4.3).
- `WebConfig.carrier_candidates()` (`src/config/types/web.rs:447‑458`) always appends the configured fallback `carrier` exactly once, even if it also appears in `carriers`.
- `[web.limits]` is **process‑owned**: any change requires a full TeleMT restart, never a hot reload (`docs/WEB/WEB_PROXY.en.md:260`, confirmed structurally by `[[server.listeners]]` also being restart‑only). Everything else under `[web]` is hot‑reloadable via the control API.

### 2.4 Maturity signal (SOURCE FACT, git history)

The single commit that introduced WEB (`1029703`, 2026‑08‑23) **deleted a 2035‑line `IMPLEMENTATION_PLAN.md` and a `ROADMAP.md`** in the same diff that added `src/config/types/web.rs`, `validate_web.rs`, `runtime_web.rs`, `src/web/{bridge,frame,http,manager,session,stream}.rs`, and touched the core proxy pipeline (`src/proxy/authenticated.rs` new, `src/proxy/client.rs`, `src/proxy/handshake/*`, `src/proxy/middle_relay/*`) — 7460 insertions in one commit. Over the following three weeks (45 commits, through 2026‑09‑13 in the sampled window) the `src/web/` tree grew to **25,945 total lines** (≈19,293 excluding the 24 dedicated test files), and the changelog‑equivalent commit messages show real hardening work: `websocket-lanes` recovery after restart, decoy fast‑track path, native macOS status‑schema preservation. This is **implemented and actively maintained**, not a documentation‑only placeholder — but it is also **three weeks old at the time of this research**, which the docs themselves flag ("End‑to‑end validation with the intended Telegram Desktop build and the real public TLS endpoint remains an operator acceptance step" — `docs/WEB/WEB_PROXY.en.md:9`). *(SOURCE FACT)*

### 2.5 NGINX / HAProxy templates TeleMT itself publishes

TeleMT's docs ship both an NGINX template (`http` context, `proxy_pass` to the loopback WEB listener, `Upgrade`/`Connection` map for WebSocket, HTTP/2 for `https-lanes`) and an HAProxy template (`frontend ... bind :443 ssl ...`, `acl ... hdr(host)`, `backend` to the loopback WEB listener). Both are reproduced in MTProxyL's generated configs almost verbatim (§4), and MTPROTO_FIX_By_MEKO's generated NGINX config is a byte‑for‑byte copy of TeleMT's. This triangulation across three independent codebases is strong confirmation that this NGINX/HAProxy shape is the canonical, intended deployment pattern for WEB, not one implementer's guess.

---

## 3. MTPROTO_FIX_By_MEKO architecture

**Explicit finding: this repository does not implement WEBPROXY.** *(SOURCE FACT — no WEBPROXY-specific code found anywhere in the repo; the only WEB-related artifacts are a config template and installer glue.)*

- Repo shape: a bash installer/menu (`install.sh`, `main.sh`, `3x-ui_menu.sh`) that installs and "fixes" a Telegram‑client TCP‑handshake connectivity issue (unrelated to WEBPROXY — a censorship‑circumvention timing fix) across five different underlying MTProto engines listed under `proxys/`: `mtgv1_1.sh`, `mtgv2_1.sh`, `mtprotozig1.sh`, `python_mtproto1.sh`, `telemt1.sh`, `telemt_in_docker1.sh`, `telemt_panel_amirotin.sh`, `teleproxy1.sh`.
- `data/webconfig.txt` is a **template `config.toml` fragment for TeleMT**, using the identical field names documented in §2.3 (`transport = "web"`, `[web]`, `[[web.vhosts]]`, `[web.vhosts.decoy]`, `[[web.vhosts.profiles]]`) with placeholder values (`zdez.tvoi.domen.com`, `12.34.56.789:443`, a fixed example secret).
- `install.sh:setup_web_config()` (lines 423‑487) downloads that template, does string substitution for host/IP/user/secret, and writes it into TeleMT's `config.toml`.
- `install.sh:setup_nginx()` / the `-nginx` flag (lines 491‑599) runs certbot, then writes an NGINX vhost that is **structurally and almost textually identical** to TeleMT's own documented template (`upstream telemt_web { server 127.0.0.1:18080; }`, the same `map $http_upgrade` block, the same `proxy_set_header` list, the same timeout values).
- It prints the resulting `tg://webproxy?server=...&secret=...` link (lines 1174‑1189), matching TeleMT's own link format exactly.
- **It has no analogous integration for the other four engines it manages** (mtg, mtproto.zig, teleproxy, python_mtproto) — grepping the whole repository for WEB‑specific tokens turns up nothing outside `install.sh` and `data/webconfig.txt`. Those engines do not have a WEB/WEBPROXY concept at all in this codebase.

Answering the task's specific sub‑questions for this repo: it is a pure **orchestration/automation wrapper**, not a transport, carrier, frontend, or protocol implementation of its own. It performs zero protocol work; NGINX (which it also just templates) is the actual TLS terminator and L7 host router, exactly as in TeleMT's own docs. There is no domain‑fronting, no SNI multiplexing logic, and no code path here worth reusing beyond "this confirms the TeleMT template is the correct one to standardize on."

---

## 4. MTProxyL architecture

MTProxyL is a full VPN/MTProto lifecycle manager (bash core + Go panel + Python Telegram bot) that treats TeleMT as its underlying MTProto+WEB engine (`WEB_MIN_ENGINE_VERSION="3.5.1"`, `lib/web.sh:7`). `lib/web.sh` (2070 lines, first added 2026‑08‑27 — four days after TeleMT's own WEB commit — with 26 commits through 2026‑09‑20) is the authoritative source for the concepts this task asked to trace exactly.

### 4.1 Core boolean/enum surface (SOURCE FACT, function bodies quoted/paraphrased from `lib/web.sh`)

| Function / var | Meaning (from source, not name‑guessed) |
|---|---|
| `web_is_enabled()` | `WEB_ENABLED == "true"` |
| `mtproto_is_enabled()` | `PROXY_MODE != "web"` (i.e. classic MTProto is *not* disabled) |
| `web_is_only_mode()` | `PROXY_MODE == "web"` — MTProto transport removed entirely, only WEB serves clients |
| `proxy_transport_mode_title()` | Human label for `PROXY_MODE`: `mtproto` → "Только MTProto" (MTProto only), `web` → "Только WEB" (WEB only), `combined` → "MTProto + WEB" |
| `WEB_LAYOUT` / `web_layout_is_split()` | `shared` (default) = **one public port shared with FakeTLS, nginx splits by SNI**; `split` = WEB gets its own dedicated public port, the MTProto engine keeps `PROXY_PORT` untouched, line 40‑42: *"shared — один публичный порт на двоих, nginx разводит по SNI. split — у WEB свой порт, движок остаётся на PROXY_PORT напрямую."* |
| `WEB_FRONTEND` / `web_frontend_is_haproxy()` etc. | `nginx` (default, managed by MTProxyL) / `haproxy` (an external HAProxy — possibly on a different host entirely — owns :443 and TLS) / `haproxy-nginx` (external HAProxy owns :443 as a pure TCP/SNI router and PROXY‑protocol‑forwards to MTProxyL's own local nginx, which still does TLS + decoy) |
| `web_frontend_is_direct()` | true when nginx binds the *public* port itself with no SNI‑multiplexing layer in front (true in WEB‑only mode, or in `split` layout) |
| `WEB_CARRIER` | passed straight through to TeleMT's `carrier` field; no reinterpretation |
| `WEB_DECOY_MODE` / `WEB_DECOY_UPSTREAM` | maps 1:1 onto TeleMT's `web.vhosts.decoy.mode` (`static_directory`/`http_upstream`) and `.upstream` |
| `WEB_HAPROXY_CERT` | PEM path used only when HAProxy itself terminates TLS (pure `haproxy` frontend mode); defaults to `/etc/haproxy/certs/<web-domain>.pem` |
| `web_public_port()` | `443` if any HAProxy variant is in front; else `WEB_PUBLIC_PORT` (default 443) if "direct"; else `PROXY_PORT` (shared‑via‑nginx‑stream case) |
| `web_domain()` | explicit `WEB_DOMAIN`, else `web.<selfmask-domain>` — **must differ from the FakeTLS masking domain in `shared` layout**, because both are discriminated by SNI at the same nginx `stream` block, and a collision would route FakeTLS clients into the WEB backend (line 66‑69 comment, and enforced in `web_preflight_problems()` / `_validate_web_domain()`) |

### 4.2 Exact meaning of "shared" vs "split" (task explicitly asked for this — answered from source, not names)

**`shared`** = same public IP **and** same public TCP port (443) **and** the same physical certificate‑bearing endpoint, discriminated by **TLS SNI inspected before decryption** — i.e. exactly the "Вариант B / Nginx stream (SNI routing)" pattern in this project's own `xray-architecture.md`. Concretely (`web_nginx_stream_block()`, `lib/web.sh:442‑475`):

```nginx
stream {
    map $ssl_preread_server_name $mtproxyl_upstream {
        proxy.web.example.com   mtproxyl_web;      # WEB TLS terminator (local nginx http server)
        default                  mtproxyl_faketls;  # ordinary FakeTLS/MTProto engine listener
    }
    upstream mtproxyl_web     { server 127.0.0.1:15444; }   # WEB_TLS_PORT
    upstream mtproxyl_faketls { server 127.0.0.1:15443; }   # WEB_MTPROXY_PORT
    server {
        listen 443;
        ssl_preread on;
        proxy_pass $mtproxyl_upstream;
        proxy_protocol on;   # both branches get real client IP via PROXY protocol
    }
}
```

Who accepts the first packet: **nginx's `stream` server on the shared public port.** Who parses TLS: **nobody, fully** — `ssl_preread` only peeks at the ClientHello's SNI extension without terminating TLS. Who forwards: nginx `proxy_pass`, prefixing PROXY protocol v1 so both backends see the real client IP. Non‑matching traffic (any SNI other than the exact configured WEB domain) is treated as **ordinary MTProto/FakeTLS**, i.e. the fallback bucket in this scheme is FakeTLS, not a generic decoy site — WEB's own decoy site is a second, independent fallback *inside* the WEB branch, applied later by TeleMT itself against Host+path (§2.2), not by nginx.

A separate `haproxy-nginx` variant reimplements the identical SNI‑ACL router in HAProxy instead of nginx‑stream (`_web_haproxy_nginx_config()`, `lib/web.sh:678‑752`, using `tcp-request content accept if { req.ssl_hello_type 1 }` + `acl mtproxyl_web_sni req.ssl_sni -i <domain>`), while nginx still does the actual TLS termination one hop downstream. This is a direct, source‑confirmed instance of the exact "HAProxy vs Nginx‑stream" choice already posed as an open question in `xray-architecture.md` §11‑2.

A pure `haproxy` frontend mode goes one step further and has **HAProxy itself terminate TLS directly** (`bind :443 ssl crt ...`), forwarding plain HTTP straight to TeleMT's WEB listener with no nginx in the path at all — this is TeleMT's own documented "HAProxy TLS termination" recipe, reproduced faithfully.

**`split`** = WEB gets an entirely separate public port (`WEB_PUBLIC_PORT`, independently settable, defaulting to 443 *if* WEB is the only thing on that port — MTProxyL requires `PROXY_PORT != web_public_port()` in this layout, checked in `web_preflight_problems()`). No SNI multiplexing is needed; nginx (or HAProxy) can bind the WEB port directly (`web_frontend_is_direct()` is true here) because there is nothing else to disambiguate against. In `split`, the WEB domain is allowed to equal the FakeTLS masking domain, because they are separated by port, not by name.

### 4.3 Carrier semantics — confirmed from source, not inferred from names

`WEB_CARRIER` is a pure pass‑through value to TeleMT's own `carrier` field (§2.3); MTProxyL does not reinterpret `https`/`https-lanes`/`websocket`/`websocket-lanes` — see the settable‑parameter catalog `_WEB_SETTABLE` (`lib/web.sh:1700‑1718`), which lists `WEB_CARRIER|enum:https,https-lanes,websocket,websocket-lanes` verbatim. Two derived facts *are* computed locally, from operational experience, not from the protocol itself:
- `web_carrier_needs_http2()` — true only for `https-lanes`, because that carrier is documented (§2, TeleMT docs) to require public HTTP/2.
- `web_carrier_survives_zapret2()` — true only for `websocket`/`websocket-lanes`. A code comment (`lib/web.sh:264‑276`) explains that Zapret2 (a censorship‑resistance TCP‑window‑clamping technique this project's ecosystem also runs) clamps the congestion window in SYN+ACK, *before* the ClientHello/SNI is visible, so it cannot be selectively excluded by domain; long‑lived WebSocket carriers amortize that one‑time clamp cost over a session, HTTP‑polling carriers pay it repeatedly. This is an operational interaction MTProxyL discovered and encodes as a warning (`web_warn_zapret2()`), not a protocol fact.

### 4.4 Client link / user‑profile model (SOURCE FACT)

TeleMT's control API **does not create a WEB profile when a user is created** (confirmed both in TeleMT's own doc — "User creation does not create a WEB profile" — and in MTProxyL's code comment at `lib/web.sh:1898‑1900`: *"Движок не заводит профиль WEB вместе с пользователем — ни через конфиг, ни через API. Без профиля у нового пользователя не будет WEB‑ссылки…"*). MTProxyL therefore maintains profile↔user pairing **itself**, by direct TOML text editing (`_web_profiles_toml()` at config‑render time for locally‑owned installs; `web_target_add_profile()`/`web_target_remove_profile()`/`web_target_rename_profile()`, `lib/web.sh:1921‑2021`, using `awk` to surgically add/remove/rename `[[web.vhosts.profiles]]` blocks for "reanimator" mode, where MTProxyL manages a config file it does not own end‑to‑end). `web_target_sync_profiles()` (`lib/web.sh:2026‑2053`) reconciles the profile list against `[access.users]` whenever they drift (e.g. a panel created a user through TeleMT's own `/v1/users` API, which — as above — never creates the matching WEB profile).

Link format: `tg://webproxy?server=<host>&secret=[dd]<hex-secret>` — no port (`web_target_link()`, `lib/web.sh:2056‑2070`; matches TeleMT's own documented link format exactly, §2.3). `WEB_SECRET_MODE` (`plain`/`dd`) controls only the client‑facing secret representation, not a distinct credential. Users sharing an underlying secret collide at the WEB layer (only the first is kept as a profile — `_web_profiles_toml()` explicitly warns and skips duplicates, `lib/web.sh:350‑354`); this is a TeleMT capability‑derivation constraint (secret is the entire client capability), not an MTProxyL limitation.

### 4.5 Preflight validation / failure surface (SOURCE FACT, `web_preflight_problems()`, `lib/web.sh:1352‑1439`)

MTProxyL refuses to enable WEB unless, among other checks: a domain is configured; the domain has a public A‑record that (in `shared`/managed‑nginx cases) resolves to *this* server's own detected public IP (`web_server_ip()`, with DoH‑over‑HTTPS resolution specifically to defeat split‑DNS false positives); the WEB domain differs from the FakeTLS domain in `shared` layout; the decoy configuration is internally consistent; the public port is exactly 443 (Telegram Desktop's WEB client hard‑codes 443 and never sends a port in `tg://webproxy` links); the underlying TeleMT binary is ≥ `3.5.1` (**silent‑downgrade failure mode**, §19); the user/profile count doesn't exceed the engine's `max_profiles` limit (MTProxyL raises this itself, rounding up to the next multiple of 32); and the target ports aren't already bound by something else.

### 4.6 Ecosystem completeness

The Go panel (`mtproxyl-panel/internal/mtproxylctl/web.go`) is a **thin wrapper**: it shells out to the identical bash CLI (`c.run(ctx, "web", "json")`, `"web","enable"`, etc.) and parses the JSON `web_status_json()` output rather than reimplementing any WEB logic (confirmed by reading `web.go:1‑60`, which is pure `exec` + `json.Unmarshal`). The Telegram bot (`mtproxyl-tgbot/`) and TUI (`lib/tui_web.sh`, 5 menu functions: layout, frontend, carrier, decoy, top‑level) are UI layers over the same bash functions. There is exactly one implementation of WEB logic in this whole ecosystem — `lib/web.sh` driving TeleMT — replicated as a CLI, a TUI, a JSON API, and a web dashboard.

---

## 5. Three‑way comparison matrix

| Row | TeleMT | MTPROTO_FIX_By_MEKO | MTProxyL |
|---|---|---|---|
| WEB implementation status | **Native, implemented** (Rust, `src/web/`, 25.9k LOC, shipped 3.5.0, hardened through 3.5.7) — SOURCE FACT | **None** — pure config/NGINX templating wrapper around TeleMT's WEB — SOURCE FACT | **None of its own** — orchestrates TeleMT's WEB via generated TOML — SOURCE FACT |
| Protocol/carrier | Defines all 4 carriers (`https`, `https-lanes`, `websocket`, `websocket-lanes`) — SOURCE FACT | Passes through TeleMT's carrier field via template (fixed to whatever the template says; not user‑selectable in the script) — SOURCE FACT | Passes `WEB_CARRIER` straight through, exposes it as a settable/TUI param — SOURCE FACT |
| TLS termination | Never (by design) | External nginx (certbot‑managed) | External nginx (default) **or** external/co‑located HAProxy, per `WEB_FRONTEND` |
| HTTP termination | TeleMT itself (`hyper`, plain HTTP/1.1) | N/A (delegates to TeleMT) | N/A (delegates to TeleMT) |
| WebSocket | TeleMT itself, RFC 6455, two carrier variants | N/A | N/A (passthrough) |
| Frontend | Any (operator‑supplied) | NGINX only, auto‑provisioned | NGINX (managed) / external HAProxy / HAProxy+NGINX hybrid — 3 explicit modes |
| SNI usage | None (TLS already gone by the time TeleMT sees the request) | None (single vhost, no multiplexing) | **Yes, in `shared` layout only** — `ssl_preread`/`req.ssl_sni` demultiplexes WEB vs FakeTLS on one port |
| Domain requirements | One hostname per `[[web.vhosts]]`, arbitrary | One domain, operator‑supplied at install time | One domain; **must differ from the FakeTLS domain in `shared` layout**, may coincide in `split` |
| Port layout | Configurable private listener; public port is whatever the frontend binds | Public 443 via NGINX; private loopback 18080 | `shared`: public 443 shared via SNI; `split`: independent `WEB_PUBLIC_PORT`; several private ports (`WEB_LISTEN_PORT`, `WEB_TLS_PORT`, `WEB_MTPROXY_PORT`) |
| Shared mode | N/A (TeleMT has no opinion; it just binds the listener it's told to) | N/A (always effectively "split" — WEB is the only thing MTPROTO_FIX_By_MEKO's WEB flag touches; ordinary MTProto/other engines are separately managed) | **Explicit `WEB_LAYOUT=shared`** — one port, SNI‑routed |
| Split mode | N/A | N/A (default posture) | **Explicit `WEB_LAYOUT=split`** — dedicated port |
| Client link | `tg://webproxy?server=HOST&secret=[dd]SECRET`, no port | Same format, printed by the installer | Same format, generated by `web_link_for_secret()`/`web_target_link()` |
| User/profile model | `[access.users]` (shared secret store) + separate `[[web.vhosts.profiles]]`; **API does not link them automatically** | N/A (one fixed user set up at install) | Actively reconciles profiles↔users (`web_sync_profiles`, `web_target_sync_profiles`) |
| Certificate management | Out of scope (operator's frontend) | certbot via nginx plugin, standalone fallback | certbot (managed‑nginx path) or operator‑supplied PEM (`WEB_HAPROXY_CERT`, pure‑HAProxy path) |
| Firewall | Out of scope | Not handled | Not directly handled in the inspected `lib/web.sh` slice (relies on `lib/nft.sh`/`lib/ipblock.sh` elsewhere in the repo — not traced in this pass; **UNKNOWN in depth, flagged**) |
| Runtime control | Rich control‑plane API: `/v1/runtime/web/*`, `/web-status` debug HTML, Prometheus metrics — SOURCE FACT | None | `mtproxyl web {status,json,enable,disable,mode,links,sync,set,settable}` CLI, mirrored in Go panel and Telegram bot |
| API | REST, documented in `docs/Architecture/API/API.md` (not deep‑dived in this pass) plus the WEB‑specific runtime/status endpoints in `docs/WEB/WEB_PROXY.en.md` §"API management" | None | CLI + Go HTTP panel (thin wrapper) + Telegram bot (thin wrapper) |
| Migration | Config‑reload semantics documented per‑field (hot vs restart‑only) — SOURCE FACT | None (one‑shot install script) | `_web_restore_runtime()` rollback on failed `web_enable`; `web_target_sync_profiles` reconciliation for externally‑edited configs |
| Backup | Out of scope | None | `backup_target_config("web-profiles", ...)` before profile‑sync edits (one call site observed; full backup subsystem in `lib/backup.sh` not deep‑dived — **UNKNOWN in depth, flagged**) |
| Decoy site | `static_directory` or `http_upstream`, enforced loopback/private‑only for the latter | Whatever the operator's existing site is (not templated by the script itself) | Same two modes, `web_effective_decoy_dir()`/`_web_decoy_toml()`, plus an "empty" default decoy and its own CSP/security‑header layer on top |
| Limitations | `plain`/`dd` secrets only, no `ee` (FakeTLS‑style) secret support in WEB; `[web.limits]` restart‑only; single‑process‑local session/bootstrap registries (no built‑in multi‑node affinity) | Only integrates with TeleMT, not the other 4 engines it manages; no shared/split concept, no SNI multiplexing | Requires TeleMT ≥ 3.5.1 (silent downgrade risk on older engines, §19); HTTP/2 required for `https-lanes`; Zapret2 interacts badly with non‑WebSocket carriers |
| Production readiness | Explicitly flagged by the authors as needing an "operator acceptance step" against the real TLS endpoint and target Telegram Desktop build; 3 weeks of hardening commits at time of research | Small, single‑purpose install script; no update/rollback story beyond re‑running it | Most mature of the three: rollback‑on‑failure, DNS/cert/port preflight checks, active 3‑week commit cadence tracking TeleMT's own releases, full CLI/TUI/panel/bot surface |

---

## 6. Exact WEBPROXY protocol flow

See §2.2 for the annotated diagram. Restated as the specific answers the task asked for:

1. **What bytes does the client send before MTProto payload appears?** A complete TLS ClientHello/handshake to the frontend (SNI = the WEB domain in shared mode, or none-of-your-business in split mode since the port is dedicated), then, once TLS is up, an ordinary HTTPS request: either `GET /?bridge=<capability>` (bootstrap), or `POST/GET` to `/api/v1/session`, `/api/v1/up`, `/api/v1/down`, or a `GET /api/v1/ws` WebSocket Upgrade. MTProto framing only appears **inside** the bodies/frames of these HTTP(S) exchanges, encoded per TeleMT's own binary frame codec (`src/web/frame.rs`). *(SOURCE FACT)*
2. **Where does TLS terminate?** At the external frontend (nginx or HAProxy) — never inside TeleMT. In MTProxyL's `shared` layout, an *intermediate* un‑terminating SNI peek (`ssl_preread`/`req.ssl_sni`) happens first, followed by full termination at a second hop. *(SOURCE FACT)*
3. **Where does HTTP terminate?** Inside TeleMT (`hyper` HTTP/1.1 server in `src/web/http.rs`). The frontend only proxies HTTP/1.1 (even when the public side negotiated HTTP/2 for `https-lanes` — the private hop is always HTTP/1.1 per TeleMT's own NGINX template comment). *(SOURCE FACT)*
4. **Where does WebSocket terminate?** Inside TeleMT (`src/web/http/websocket.rs`, `src/web/session/websocket.rs`) — full RFC 6455 handling, including subprotocol negotiation (`tproxy-v1.<token>` / `tproxy-lane-v1.<token>.<id>` / `tproxy-auto-*`). *(SOURCE FACT)*
5. **Does the MTProto engine itself understand HTTP/WebSocket?** Yes — this is the key architectural fact. WEB is not "MTProto behind a dumb HTTP pipe"; TeleMT's own process is the HTTP/WebSocket implementation. *(SOURCE FACT)*
6. **Does nginx/HAProxy/frontend unwrap it?** Only the TLS layer, and (in `shared` layout only) the SNI‑based routing decision. Never the HTTP/WebSocket/MTProto layers. *(SOURCE FACT)*
7. **Does it require SNI?** Only as an *implementation choice* for sharing one public port with something else (MTProxyL's `shared` layout). It is not required by the WEB protocol itself — a dedicated port (`split`) needs no SNI logic at all, and TeleMT's own minimal example config assumes a dedicated vhost/port with no SNI multiplexing mentioned. *(SOURCE FACT)*
8. **Does it require a dedicated domain?** Yes, always — TeleMT's WEB traffic is routed by HTTP Host header at the TeleMT layer regardless of layout; in `shared` layout that domain additionally must be distinct from the FakeTLS masking domain (§4.2). *(SOURCE FACT)*
9. **Can it share :443 with normal MTProto?** Yes, via SNI‑based port sharing (MTProxyL's `shared` layout) — but note this shares the **port**, not the **listener socket or process**; it is still two independent backend processes/listeners behind an SNI router, not a single MTProto listener that also happens to understand WEB. *(SOURCE FACT)*
10. **Can it share :443 with FakeTLS/REALITY/Xray?** With FakeTLS, yes, demonstrated (§4.2). With Xray REALITY specifically: **not evaluated in this research** — REALITY's ClientHello handling and TeleMT's `ssl_preread`‑based SNI split are two different unrelated ecosystems (Xray‑core vs TeleMT) that were not observed coexisting behind one router in any of the three repos studied. Given both are pure SNI‑based demultiplexing at the nginx‑stream/HAProxy layer, and nginx‑stream's `map $ssl_preread_server_name` can route to an arbitrary number of upstreams keyed by arbitrary SNI values, there is no protocol‑level reason three‑way sharing (FakeTLS + WEB + Xray‑REALITY on one port, keyed by three distinct SNI/domain names) would fail — but this is **INFERENCE**, not confirmed by any of the three studied repos, and REALITY's specific ClientHello‑replay defense (§2 of `xray-architecture.md`) was not cross‑checked against `ssl_preread`'s parsing behavior.
11. **What distinguishes WEB traffic from ordinary HTTPS at the frontend?** In `shared` layout: SNI value at the nginx‑stream/HAProxy router. Once past that router (or always, in `split`/direct layouts): nothing distinguishes it from ordinary HTTPS until it reaches TeleMT's own Host+path routing (§2.2) — this is intentional; the doc explicitly warns against splitting "only recognized carrier paths" at the TLS terminator because it would make authenticated and unauthenticated traffic "observably different" and bypass the decoy policy (`docs/WEB/WEB_PROXY.en.md:25`). *(SOURCE FACT)*
12. **How are non‑WEB connections handled?** At the TeleMT layer: routed to the configured decoy (static site or private HTTP upstream), preserving method/path/headers/body, indistinguishable in timing/behavior from a real site serving a 404 or its actual content. At the nginx‑stream SNI‑router layer (shared mode only): routed to the ordinary FakeTLS/MTProto backend, which has its own independent decoy/masking behavior (out of scope of this WEB‑specific research; covered generally in `xray-architecture.md`'s discussion of FakeTLS‑style masking for the Xray world, and by TeleMT's separate `[censorship]` masking config for its own FakeTLS mode).

---

## 7. Exact frontend flow

Already covered in full generality in §2.2 and §4.2 (three MTProxyL frontend variants: `nginx`, `haproxy`, `haproxy-nginx`). Summary table:

| Frontend mode | Public :443 owner | TLS termination | SNI routing needed? | WEB backend reached via |
|---|---|---|---|---|
| `nginx` + `shared` layout | nginx (`stream` block) | nginx (second, inner `server {listen 127.0.0.1:15444 ssl ...}` block) | Yes (`ssl_preread`) | Loopback HTTP, `proxy_pass http://127.0.0.1:<WEB_LISTEN_PORT>` |
| `nginx` + `split`/only layout | nginx (direct `listen <port> ssl`) | nginx | No | Same loopback `proxy_pass` |
| `haproxy` (pure) | External HAProxy | HAProxy itself (`bind :443 ssl crt ...`) | Only if `mtproto_is_enabled && !split` (HAProxy ACL on `req.ssl_sni`) | Direct plain‑HTTP `server ... check` to TeleMT's WEB listener — **no nginx in the path at all** |
| `haproxy-nginx` | External HAProxy (pure TCP router) | nginx (second hop, `accept-proxy ssl` in HAProxy‑TLS‑pure variant is *not* used here; nginx does full TLS with `proxy_protocol` real‑IP recovery) | Yes, in HAProxy (`req.ssl_sni` ACL) or unconditionally to nginx if MTProto disabled/split | HAProxy → nginx (PROXY protocol) → TeleMT loopback |

A subtlety worth flagging for implementers: MTProxyL's `web_nginx_http_server()` emits **two** server blocks on the WEB‑facing listener — a catch‑all `server_name _;` block returning HTTP 421, and the real `server_name <web-domain>;` block — specifically to defeat HTTP/2 **connection coalescing**: a browser/client that already has an H2 connection open to the FakeTLS masking domain (same IP, same certificate if using a wildcard or SAN cert) will try to reuse it for the WEB domain, landing in the wrong vhost; returning 421 (Misdirected Request) forces a fresh connection. This is a non‑obvious, hard‑won operational detail (visible in the code comment at `lib/web.sh:571‑574`) worth carrying into any Server‑manager renderer that generates similar shared‑port NGINX vhosts.

---

## 8. Port/listener/domain model

Consolidated from §2.3 and §4.1–4.2:

- **TeleMT‑level listener**: one `[[server.listeners]]` entry per transport per bind address, `transport = "web"` is mutually exclusive with `transport = "mtproxy"` on the *same* listener entry (they are different entries, potentially on the same or different IP:port). A WEB listener additionally carries `web_client_ip_source`, `web_trusted_proxy_cidrs` (non‑empty, no `/0`), and forbids `proxy_protocol = true`, `client_mss`, `synlimit`, `announce`/`announce_ip` (`docs/WEB/WEB_PROXY.en.md:160`).
- **Public port**: always effectively 443 from the *client's* perspective (Telegram Desktop's `tg://webproxy` link format has no port field and the client hard‑codes 443). The *frontend's* bind port can differ in principle but every one of the three repos' generated configs binds the public side at 443.
- **Private/internal ports**: entirely operator/tool‑chosen (TeleMT's own example uses 18080; MTProxyL uses a small constellation — `WEB_LISTEN_PORT` for TeleMT's own plaintext WEB listener, `WEB_TLS_PORT` for nginx's inner TLS‑terminating vhost in shared mode, `WEB_MTPROXY_PORT` for the FakeTLS/MTProto backend in shared mode).
- **Domain**: exactly one hostname per vhost is the norm across all three repos (TeleMT's schema supports multiple `[[web.vhosts]]` entries, each independently addressable, but none of the three repos generate more than one WEB vhost). The domain **must** differ from any other TLS identity sharing the same SNI‑routed port; **need not** differ from anything if it has a dedicated port (`split`).

---

## 9. Shared‑vs‑split analysis

Fully answered in §4.2 with source citations. One‑paragraph summary for cross‑reference from later sections: **"shared" = SNI‑based demultiplexing on one physical port, requiring an SNI‑aware L4 router (nginx `stream`+`ssl_preread`, or HAProxy TCP‑mode ACL on `req.ssl_sni`) in front of two or more independent backend listeners, plus a hard domain‑uniqueness constraint across everything sharing that port. "split" = a second, fully independent public port with no router logic required, at the cost of an extra open port operators/firewalls/censors can fingerprint separately.** This maps directly onto the "Вариант A vs Вариант B" distinction already documented for Xray in `xray-architecture.md` §3.1/§3.2 — split ≈ Вариант A (each protocol owns its own port, zero coupling), shared ≈ Вариант B (Nginx‑stream SNI router, one hop of added latency, one more moving part, one more thing that can misroute).

---

## 10. Carrier analysis

Covered in §2.3/§4.3. To restate the exact, non‑inferred semantics one more time in one place, quoting TeleMT's own doc (paraphrased, per copyright rules) plus the enum definitions:

- `https` (default) — one serialized uplink/downlink HTTP sequence for **all** logical MTProto streams in a session; simplest, works with plain HTTP/1.1, but streams can head‑of‑line‑block each other at the WEB protocol layer.
- `https-lanes` — same HTTP‑polling carrier, but every non‑zero logical stream gets its own independent uplink sequence/downlink cursor ("lane"), removing WEB‑layer serialization; **requires public HTTP/2** (multiple concurrent polls need to not block each other at the TCP/H1 level either).
- `websocket` — one ordered RFC 6455 WebSocket multiplexes all logical streams as binary carrier batches; a single connection/protocol failure closes the *entire* session.
- `websocket-lanes` — one independently‑owned WebSocket **per logical stream**; failure of one lane does not affect siblings or the parent session.

Auto‑negotiation (`web.carrier` as fallback + `web.carriers` as an ordered candidate list) is a TeleMT‑engine feature, not something either wrapper reimplements; MTProxyL exposes it as a pass‑through settable field and nothing more.

---

## 11. Client link and user/profile model

Answered fully in §4.4. The one point worth restating for the Server‑manager design discussion: **TeleMT profiles are not derived from users automatically — anything that creates/edits/deletes an `[access.users]` entry (a panel, an API call, a bash script) must separately create/edit/delete the matching `[[web.vhosts.profiles]]` entry, or the user silently has no WEB link.** This is exactly the kind of cross‑cutting invariant a Capability Registry / Desired State system is supposed to hold — see §16.

---

## 12. Migration/state model

From TeleMT's own reload‑behavior table (`docs/WEB/WEB_PROXY.en.md`, "Lifecycle and reload behavior"), the state introduced by WEB splits cleanly into three tiers:

1. **Restart‑only, process‑owned** (cannot be changed via hot reload, ever): the WEB listener inventory/bind address/trust policy, and everything under `[web.limits]`.
2. **Hot‑reloadable via the config watcher or a runtime‑generation reload**: `web.enabled`, carrier/negotiation policy, `web.debug`, timeouts, vhosts, profiles, decoys.
3. **Process‑owned and ephemeral, never persisted to config**: operator pause/drain lifecycle state (resets to `running` on process restart).

Persistent state an integrator must track (config‑file level): domain, public port/address, frontend choice, carrier + negotiation policy, per‑profile limits, decoy mode/target, certificate paths (owned by the frontend, not TeleMT), and — critically — the derived NGINX/HAProxy fragment that encodes the SNI/domain routing decision (this is *generated*, not hand‑authored, in both MTPROTO_FIX_By_MEKO and MTProxyL, and should be treated as **regeneratable output**, not source‑of‑truth state, in any Server‑manager design).

What must remain source‑of‑truth vs. what can be regenerated (MTProxyL's own convention, directly transferable):
- **Source of truth**: which users have a WEB profile and in what secret mode; the WEB domain; the layout/frontend choice; the carrier choice; the decoy configuration.
- **Regeneratable**: the TeleMT `[web]`/`[[server.listeners]]` TOML fragment; the NGINX/HAProxy vhost/stream fragment; the certificate (via certbot, from the domain).

MTProxyL's `_web_restore_runtime()` rollback pattern (invoked from every failure branch inside `web_enable()`, §4) is a concrete existence proof that this kind of Desired‑State‑with‑rollback pattern is *necessary* in practice, not theoretical — every one of the roughly eight failure points in `web_enable()` (frontend prep, preflight, cert issuance, config generation, engine restart, decoy‑snapshot readiness, nginx restart, HAProxy readiness) triggers the same restore‑previous‑state call.

---

## 13. Server‑manager compatibility analysis

**This section could not be fully executed against real code in this session** — see the scope‑limitation note at the top of this report. What follows uses the architectural vocabulary the task itself supplied (Inventory, Capability Registry, Desired State, Planner, Provider/renderer) plus the general, already‑verified fact that the publicly reachable `main` branch of `stump3/server-manager` has *zero* WEB‑awareness anywhere (`docs/TELEMT_CONFIG.md` last touched 2026‑04‑21, `lib/telemt.sh` last touched 2026‑08‑12 — both predate TeleMT's 2026‑08‑22/23 WEB release entirely, confirmed by `git log`). This is a **DESIGN PROPOSAL**, to be checked against `docs/edge_contracts.md`, `docs/CORE_RUNTIME_CONTRACTS.md`, and `lib/core/topology.sh` on the actual `variant-f-j` working tree before any implementation begins.

Mapping WEBPROXY's protocol invariants (§6) onto the abstractions:

1. **Is WEBPROXY logically a new transport in Desired State?** At the TeleMT layer, unambiguously yes — it is a distinct `ListenerTransport` variant requiring its own listener entry, its own domain, and (in shared layout) its own routing rule. Whatever Server‑manager's Desired State schema uses to represent "TeleMT is deployed with these listeners/transports" needs a second transport value alongside its existing MTProto/FakeTLS one. *(INFERENCE from SOURCE FACT)*
2. **Or a property of the application protocol?** No — it changes the wire path (HTTP/WebSocket + TLS‑external vs raw TCP + TeleMT‑terminated obfuscation), not the inner MTProto semantics. It should not be modeled as a flag on the existing MTProto transport.
3. **Or a frontend/carrier mode layered over MTProto?** Both, simultaneously, and this is the key modeling nuance: it is a *carrier* (which of 4 HTTP/WS shapes) layered over the inner MTProto stream, *and* it independently requires a *frontend/routing decision* (shared‑SNI vs split‑port vs which of 3 frontend software choices) that is orthogonal to the carrier choice.
4. **Should `transport = tcp` remain true [for existing things]?** Not directly answerable without the actual Desired‑State schema; nothing in the studied repos suggests WEB changes how *existing* non‑WEB transports are represented — WEB is additive.
5. **Should WEBPROXY be represented as `carrier = websocket` / `carrier = https`?** Yes, this maps 1:1 onto TeleMT's own `WebCarrier` enum (§2.3) — reusing that literal vocabulary (`https`, `https-lanes`, `websocket`, `websocket-lanes`) rather than inventing new names avoids a translation layer that could drift from upstream TeleMT.
6. **Does WEBPROXY require a separate listener?** Yes, always (§8), regardless of shared/split layout — "separate listener" and "separate public port" are independent questions; shared layout still uses a separate private TeleMT listener, just multiplexed onto the same public port by nginx/HAProxy.
7. **Can it coexist with standard MTProto on the same listener?** No — never the same TeleMT listener entry (mutually exclusive `transport` values). It can coexist on the same *public port* via an external SNI router.
8. **Can it coexist with existing F/J topologies?** **UNKNOWN — missing evidence: no definition of "F" or "J" topology was available in this session** (not in the accessible `main` branch, not in retained project memory beyond the branch name `variant-f-j`). This must be answered by someone with `docs/edge_contracts.md` open.
9. **Can it coexist with Xray/REALITY?** Not observed in any of the three studied repos (§6, item 10) — architecturally plausible via a shared SNI router (nginx‑stream `map` can hold arbitrarily many domain→upstream pairs) but **UNCONFIRMED**.
10. **Can nginx currently distinguish WEBPROXY from existing traffic without terminating something it does not currently terminate?** If Server‑manager's nginx renderer already supports an `stream {}` SNI‑router block for any purpose (e.g. for Xray "Вариант B" per the attached architecture doc), then yes, the identical primitive (`ssl_preread` + `map $ssl_preread_server_name`) extends to a WEB domain with no new nginx *capability*, only new *configuration*. If it does not yet render `stream {}` blocks at all, this is net‑new nginx‑capability work. **Which is true is UNKNOWN in this session** — requires reading the current nginx renderer.
11. **Does shared :443 require SNI?** Yes (§9) — restated for completeness.
12. **Does WEBPROXY require a different domain from selfmask/Xray/subscription/node/HY2‑CDN?** Confirmed required to differ from the *TeleMT FakeTLS/selfmask* domain specifically when sharing a port with it (§4.2). Whether it must also differ from Xray/subscription/HY2 domains depends entirely on whether those also share the same physical port/SNI‑router — **not determinable without the current topology/domain‑contract docs.**
13. **Can it reuse current domain contracts?** Likely partially — the *shape* of the constraint ("no two SNI‑routed identities behind one port may share a domain") is generic and probably already expressed for existing multi‑protocol sharing (Xray Reality vs FakeTLS vs panel vs subscription, per the attached document's own §9/§11); WEB should be addable as one more entry in whatever domain‑uniqueness check already exists, rather than needing new invariant machinery. **DESIGN PROPOSAL.**
14. **Does it require capability registry / desired‑state / planner / provider(nginx renderer) / TeleMT config / firewall / migration changes?** Almost certainly yes to nginx renderer (new vhost/stream‑block shape, §7's 421‑coalescing‑guard trick should be preserved), TeleMT config generation (new `[web]` section + listener entry, §2.3), and Desired State (new transport/carrier fields, §13.1‑3). Firewall changes are plausible (new listen ports even in loopback‑only deployments typically still want explicit deny‑from‑untrusted‑network rules — TeleMT's own doc is emphatic: *"Never expose the plain HTTP WEB listener to an untrusted network. Enforce the restriction with host firewall rules even when it binds to loopback."*) but Server‑manager's current firewall‑handling code was not inspected in this session. Migration‑component changes: yes, per §12 — profile↔user reconciliation is new persistent cross‑referenced state that doesn't exist for classic MTProto‑only TeleMT deployments today.
15. **Which parts are protocol‑level / topology‑level / provider‑specific / runtime‑level?** Protocol‑level: carrier choice, secret mode, vhost/profile schema (all TeleMT‑owned, don't reinvent). Topology‑level: shared‑vs‑split, which frontend software, domain‑collision avoidance (this is where Server‑manager's own abstractions add value). Provider‑specific: the exact nginx/HAProxy fragment syntax (a rendering concern). Runtime‑level: certificate issuance/renewal, listener bring‑up ordering, rollback‑on‑failure (§12's `_web_restore_runtime` pattern is a good reference implementation to study, even though it's bash‑against‑bash rather than the planner/provider pattern Server‑manager is moving toward).

---

## 14. Server‑manager topology compatibility matrix

Per the task's own instruction ("Do not use 'probably'. For CONDITIONAL/UNKNOWN, explain exactly what evidence is missing"):

| Topology | WEBPROXY possible? | Evidence status |
|---|---|---|
| standalone TeleMT | YES | SOURCE FACT — TeleMT's WEB feature has no dependency on any other component; it needs only an external TLS terminator, which can be anything. |
| F | UNKNOWN | Missing: definition of topology "F". Not present in the publicly reachable `server-manager` `main` branch, not present in retained project memory beyond the bare branch name `variant-f-j`. Needs `docs/edge_contracts.md` or equivalent from the current working tree. |
| J | UNKNOWN | Same missing evidence as "F". |
| F + TeleMT | UNKNOWN | Depends on "F" definition (above) plus how TeleMT is currently wired into that topology — not observable from the accessible `lib/telemt.sh` (single‑file, pre‑split, pre‑WEB). |
| J + TeleMT | UNKNOWN | Same as above. |
| F + XHTTP + TeleMT | UNKNOWN | Depends on "F" and on how XHTTP (an Xray‑world transport, per `xray-architecture.md` §2) and TeleMT currently share infrastructure, if at all — no evidence of any existing Xray+TeleMT co‑deployment pattern was found in any of the four repositories studied. |
| J + XHTTP + TeleMT | UNKNOWN | Same missing evidence as above. |
| MODE1 | UNKNOWN | No definition of "MODE1" found in any accessible source (repo or memory). |
| MODE2 | UNKNOWN | No definition of "MODE2" found in any accessible source (repo or memory). |

**This table is not usable as delivered** beyond the "standalone TeleMT" row. It is included, populated as far as honestly possible, specifically so the next agent knows exactly which single artifact (a working `docs/edge_contracts.md` / `lib/core/topology.sh` read) unlocks every remaining row — the WEBPROXY‑side facts needed to fill them in (does it need SNI, does it need a domain, does it need a dedicated port, can it share a port with a same‑purpose FakeTLS backend) are all established in §6–§10 above and do not need to be re‑researched.

---

## 15. Capability requirements

Speaking only to what WEBPROXY itself demands, independent of how Server‑manager currently models "capabilities" (not verifiable this session, §13):

- A **TeleMT capability** that can render a `[web]` section + a `transport = "web"` listener entry (extends whatever already renders TeleMT's `[server.listeners]`/`[access.users]`/`[censorship]` sections).
- An **nginx capability** that can render either (a) a plain `location`/`upstream` HTTP reverse‑proxy vhost (split/direct layouts) or (b) a `stream {}` SNI‑router block plus an inner TLS‑terminating vhost (shared layout) — note (b) is a strictly more general capability that also handles (a) as a degenerate one‑upstream case, so if Server‑manager's nginx renderer already needs `stream{}` support for any other reason (Xray Вариант B, per the attached doc), building WEB support on top of that same primitive is efficient.
- An **HAProxy capability**, if Server‑manager wants to support the `haproxy`/`haproxy-nginx` frontend modes MTProxyL offers — optional, since nginx alone covers the simplest and most common case.
- A **certificate‑issuance capability** (Let's Encrypt/certbot) scoped to the new WEB domain, independent of any certificate already issued for the FakeTLS/selfmask domain.
- A **user↔profile reconciliation capability** — something has to guarantee every enabled user has a matching `[[web.vhosts.profiles]]` entry whenever WEB is enabled, and that this stays true across ordinary user CRUD operations (§11).
- A **domain‑uniqueness / port‑sharing constraint check** capability — must know, for a given public port, every domain currently routed there (FakeTLS, WEB, and potentially Xray) and refuse to add a duplicate.

## 16. Desired State implications

If WEBPROXY is added, the Desired State for a TeleMT‑capable node plausibly needs (as new, additive fields, not replacements):
- a boolean/mode flag equivalent to `PROXY_MODE` (`mtproto` | `web` | `combined`, MTProxyL's own vocabulary, directly reusable);
- a layout choice (`shared` | `split`);
- a frontend choice (`nginx` | `haproxy` | `haproxy-nginx`, or whatever subset Server‑manager decides to support);
- a carrier choice (TeleMT's own 4‑value enum, §2.3);
- a WEB domain, distinct from any other domain sharing its resolved public port;
- the set of users who should have a WEB profile (plausibly: "all enabled users", mirroring MTProxyL's own default behavior of giving every enabled user with a unique secret a profile) and their secret‑mode representation;
- decoy configuration (mode + target).

Whether this belongs in the *existing* per‑node Desired State object or a new nested "web" sub‑object mirroring TeleMT's own `[web]` TOML table structure is a schema‑design decision for whoever owns Server‑manager's actual Desired State type today — **not decidable without seeing it.**

## 17. Planner implications

The planner would need to add, at minimum, ordering constraints matching MTProxyL's own proven sequence (§4/§12): validate preconditions (domain resolves, cert obtainable, ports free, engine version sufficient) → issue/renew certificate → render TeleMT config → restart TeleMT → verify it came up → render/restart the frontend (nginx/HAProxy) → verify frontend reachability → (if shared layout) verify the *other* thing sharing the port didn't break. MTProxyL's `_web_restore_runtime()` rollback‑to‑previous‑state‑on‑any‑failure pattern is worth treating as a minimum bar, not a nice‑to‑have — every failure branch in `web_enable()` calls it. **This is a DESIGN PROPOSAL based on direct evidence of what breaks in practice (§4.5's preflight list, §12), not a claim about what Server‑manager's actual Planner currently does or should do internally.**

## 18. Renderer/provider implications

The TeleMT‑config renderer needs new template fragments for `[web]`, `[[web.vhosts]]`, `[web.vhosts.decoy]`, `[[web.vhosts.profiles]]`, and a second `[[server.listeners]]` entry — all directly modeled on the schema in §2.3, which is the authoritative upstream schema, not something to redesign. The nginx renderer needs either a new template (split/direct case: a single vhost, closely matching TeleMT's own published template, §2.5) or an extension to any existing `stream{}` SNI‑router template (shared case, §4.2), plus the 421‑misdirected‑request coalescing guard (§7) if HTTP/2 and multiple SNI identities share a certificate. Any HAProxy renderer, if built, should follow the two HAProxy shapes MTProxyL demonstrates (pure‑TLS‑terminating vs pure‑TCP‑SNI‑router‑to‑nginx, §4.2/§4.6).

---

## 19. Security/failure analysis

All items below are **SOURCE FACT**, drawn directly from the three repositories' own documentation/code/comments — none are speculative additions.

- **Silent capability downgrade on old engines.** TeleMT versions before 3.5.1 "know" nothing about the `transport = "web"` key and silently ignore it, turning what the operator believes is a WEB listener into a second plain MTProxy listener instead (`lib/web.sh:1441‑1443` comment). Any Server‑manager implementation must hard‑gate on engine version before rendering WEB config, exactly as MTProxyL does (`web_engine_supports()`).
- **Domain/SNI collision in shared layout** routes FakeTLS clients into the WEB backend (or vice versa) if the two domains match — actively validated and refused pre‑enable by MTProxyL, and explicitly called out as a hard requirement in TeleMT's own domain‑separation reasoning.
- **HTTP/2 connection coalescing** can misdirect a client already connected to a co‑located domain sharing the same certificate into the wrong vhost; mitigated with a `421`‑returning catch‑all `server_name _;` block (§7).
- **Never expose the plain HTTP WEB listener to an untrusted network**, even when bound to loopback — TeleMT's own deployment‑invariants section is explicit that this must be enforced by host firewall rules as defense in depth, not by the bind address alone.
- **Bootstrap/session registries are process‑local.** A multi‑process or multi‑host deployment behind a load balancer requires *complete‑vhost* session affinity (every WEB path: initial/recovery GET, session creation, uplink, downlink, WS upgrade, DELETE) to the same TeleMT process; TeleMT itself has no clustering story for WEB state.
- **Decoy‑loop misconfiguration**: a decoy `http_upstream` target that resolves back to the WEB listener itself (directly or via the same‑family wildcard bind address on the same port) is explicitly rejected by TeleMT at config‑validate time (`src/config/load/validate_web/vhosts.rs`), but indirect loops through DNS/another proxy layer *cannot* be proven from config alone and must be excluded operationally — both the doc and MTProxyL's preflight checks flag this as an operator responsibility, not something the tooling can fully guarantee.
- **`/0` trusted‑proxy CIDRs are rejected** at both the TeleMT config‑validation layer and MTProxyL's own client‑side pre‑check (`_validate_web_trusted_proxy_cidrs`) — a deliberate defense against accidentally trusting `X-Forwarded-For` from the entire internet.
- **`decoy_fasttrack_mode = "enforce"`** is explicitly documented as potentially introducing a public, measurable request‑shape timing side‑channel and TeleMT's own docs recommend against enabling it "without external timing measurements through the production TLS terminator" — a nuance a Server‑manager UI/CLI exposing this knob should surface, not hide.
- **Carrier/timing interaction with independent censorship‑resistance tooling** (Zapret2, in MTProxyL's ecosystem) is a real, measured interaction (not theoretical) between an unrelated TCP‑window‑clamping technique and WEB carrier choice — worth keeping in mind if Server‑manager's environment runs anything similar (the attached `xray-architecture.md` does not mention Zapret2, so this may be MTProxyL‑ecosystem‑specific).
- **Reload semantics gotcha**: patching `[web.limits]` or listener inventory via the runtime API is *accepted and persisted* but silently has no runtime effect until a full process restart — TeleMT reports this via a `deferred_process_fields` list in the reload response, which any automation must check rather than assuming a successful PATCH means the change is live.

---

## 20. Open questions / unknowns

1. Definitions of Server‑manager's "F" and "J" topologies, and "MODE1"/"MODE2" — required before §13/§14 can be completed. *(Missing: `docs/edge_contracts.md` or equivalent from the current `variant-f-j` working tree.)*
2. Whether Server‑manager's nginx renderer currently supports (or plans to support) an `stream{}` SNI‑router block for any purpose — determines whether WEB's shared‑layout need is "reuse an existing capability" or "build a new one." *(Missing: current nginx renderer source.)*
3. Whether Xray/REALITY and TeleMT/WEB can coexist behind one SNI router in practice — architecturally plausible (§6 item 10, §13 item 9) but unconfirmed in any studied repository. *(Missing: a real or documented three‑way coexistence example; would require either testing or finding a fourth reference implementation.)*
4. Depth of MTProxyL's firewall (`lib/nft.sh`, `lib/ipblock.sh`) and backup (`lib/backup.sh`) integration with WEB — only one call site each was observed in `lib/web.sh` (`_web_reapply_geoblock`, one `backup_target_config` call); the full extent of WEB‑aware firewall/backup logic elsewhere in those ~2900‑ and unmeasured‑line files was not traced. *(Missing: targeted read of `lib/nft.sh`/`lib/ipblock.sh`/`lib/backup.sh` for WEB‑specific branches.)*
5. TeleMT's general Control API contract (`docs/Architecture/API/API.md`) beyond the WEB‑specific runtime endpoints already covered in §2/§4 — not deep‑dived in this pass; relevant if Server‑manager wants to manage WEB profiles via API instead of direct TOML editing (MTProxyL's own approach, chosen specifically *because* the API doesn't support profile creation).
6. Whether Telegram Desktop's actual current WEB‑proxy client behavior matches what TeleMT's docs describe — TeleMT's own authors flag end‑to‑end client validation as still outstanding at the time of writing (§2.4). This is an external dependency Server‑manager cannot control or verify at design time.

## 21. Recommended next implementation‑research steps

1. Obtain read access (in a session with the real working tree, not just this GitHub‑only session) to `docs/edge_contracts.md`, `docs/CORE_RUNTIME_CONTRACTS.md`, and `lib/core/topology.sh` on `variant-f-j`, and re‑run §13/§14 of this report against them — that is a short, mechanical follow‑up given everything else in this report is already established.
2. Inspect the current nginx‑rendering code path specifically for whether an `stream{}`/`ssl_preread` capability exists already (for Xray Вариант B or any other purpose) — this single fact determines most of the effort estimate for shared‑layout WEB support.
3. Decide, as an explicit design choice (not inferred from this research), whether Server‑manager will support MTProxyL's full three‑frontend model (`nginx`/`haproxy`/`haproxy-nginx`) or only the simplest (`nginx`, `split` layout) as a first cut — the latter needs no SNI‑router capability at all and could plausibly be a much smaller first increment.
4. Prototype the user↔WEB‑profile reconciliation logic (§11, §16) against Server‑manager's actual user‑management code path (`panel_api.sh`/equivalent, per this project's own memory of its architecture) — this is the one piece of WEB‑specific *business logic* (as opposed to config rendering) that has no existing analog in Server‑manager today and needs a home decided.
5. If REALITY/WEB coexistence (Open question 3) is actually wanted, prototype it in the `xray-lab` companion repository first, per this project's own established practice of validating Xray‑adjacent configurations there before touching production scripts.
