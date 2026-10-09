# Q1 — Migrating approximately 40 Ingresses to Gateway API

I would inventory hostnames, paths, TLS secrets, annotations and dependencies,
assign owners, and record error/latency baselines. I would check required
behavior against a maintained controller's conformance and extensions before
choosing it. Annotation conversion alone does not establish equivalence.

I would install Gateway API CRDs and the new controller alongside ingress-nginx,
using a separate address. Platform owners manage GatewayClass, Gateway listeners
and certificates; application teams own HTTPRoutes. Namespace attachment and
cross-namespace references need explicit authorization. This follows the
[Gateway API migration model](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/).

I would test every route against the new address with the real Host header and
TLS SNI. Likely differences include regex/rewrite semantics, external auth,
snippets, redirects, upload limits, timeouts, sticky sessions, forwarded headers,
WebSockets and certificate renewal.

Migrate low-risk hosts first, gradually shifting traffic through an upstream
load balancer where available. HTTPRoute backend weights do not automatically
split traffic between old and new controllers. With DNS, lower TTL beforehand,
expect cached addresses and keep both paths healthy. Monitor per-host errors,
latency and business transactions; define rollback thresholds and test switching
back before cutover.

After a stable observation window, drain long-lived connections, confirm
old-address traffic has stopped, then remove old Ingresses and the controller.
Zero downtime is a tested objective, not a guarantee from DNS alone.
