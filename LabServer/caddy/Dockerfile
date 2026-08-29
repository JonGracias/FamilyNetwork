# Caddy + the Cloudflare DNS module.
#
# The stock caddy image cannot do DNS-01 against Cloudflare -- the provider
# module is not compiled in. Build it from the OFFICIAL caddy builder image
# rather than pulling a third-party "caddy-cloudflare" image, so nothing
# unvetted ends up terminating TLS for the family's services.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
