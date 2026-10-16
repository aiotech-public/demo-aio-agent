# IPv6 test stand (branch `ipv6-test`)

Purpose: run the edge agent on a dual-stack host so that (1) Cloudflare reaches the agent over IPv6,
(2) the agent reaches the backend over IPv6, (3) the backend sees the agent's IPv6 address as the server IP.

## Host requirements
- Droplet created with IPv6 enabled (DigitalOcean: `ipv6: true` at creation; existing droplets need a power
  cycle plus manual netplan config).
- Docker Engine >= 27 (ip6tables on by default). `daemon.json` from this branch enables IPv6 on the default
  bridge explicitly.
- Docker Compose v2 (`docker compose`); the `docker-compose` name used by `aio.service`/`autopull.sh` must
  resolve to v2 (compose v1 does not understand `enable_ipv6` with IPAM in the override file).
- Firewall: 80/443 allowed for IPv6 as well (ufw `IPV6=yes`).

## What this branch changes
- `docker-compose.override.yml`: compose network gets an IPv6 (ULA) subnet with NAT66 egress; agent containers
  get static IPv4 addresses (`172.30.0.10` / `.11`).
- `volumes/nginx/stream.d/regular.conf` and `spare`: nginx listens on `[::]:80` / `[::]:443` and proxies to the
  static IPv4 of the agent (the agent's plain listener is IPv4-only). PROXY protocol is kept, so the agent sees
  the real peer (Cloudflare IPv6 ranges are already trusted by the agent).
- `.aio-env` (not in git): `API_URL` points at a backend hostname that has only an AAAA record, so the agent
  talks to the backend over IPv6 and the backend sees the host's public IPv6 as the server IP.

## Verify
- `docker network inspect <project>_default` shows both subnets.
- `ss -ltn` on the host shows `[::]:80` and `[::]:443`.
- From inside the agent container: `curl -6 https://<backend-host>/api/v1/agent/robots` answers.
- Agent log: peer addresses from Cloudflare are IPv6, `Cf-Connecting-Ip` is the visitor's address.
