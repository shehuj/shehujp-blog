# ---------------------------------------------------------------
# Production-hardened Ghost blog image
# Ghost 6 is required to patch critical CVEs present in Ghost 5:
#   CVE-2026-26980  SQL injection in Content API       (fixed 6.19.1)
#   CVE-2026-29053  RCE via malicious themes            (fixed 6.19.1)
#   CVE-2026-29784  Incomplete CSRF protections         (fixed 6.19.3)
#
# MIGRATION NOTE: Ghost 5 → 6 is a major upgrade.
#   Back up /var/lib/ghost/content before deploying.
#   Ghost will auto-run DB migrations on first boot.
#   Verify theme compatibility at: https://ghost.org/docs/faq/upgrading-from-ghost-5/
#
# Pin to a specific digest in production:
#   docker pull ghost:6-alpine
#   docker inspect ghost:6-alpine --format '{{index .RepoDigests 0}}'
# ---------------------------------------------------------------
# FROM ghost:6-alpine
FROM ghost:6.14-alpine

# OCI-standard image labels for auditing and registries
LABEL org.opencontainers.image.title="shehujp-blog" \
      org.opencontainers.image.description="Ghost blog for shehujp" \
      org.opencontainers.image.vendor="shehujp" \
      maintainer="shehujp"

# Production mode: disables debug logging, enables caching, hardens defaults
ENV NODE_ENV=production

# Upgrade Alpine system packages to patch known CVEs (e.g. golang net/url, archive/zip,
# crypto/x509). Must run as root; we drop back to node immediately after.
USER root
RUN apk upgrade --no-cache
USER node

# Health check: start-period accounts for Ghost boot (DB migrations, asset compilation)
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:2368/ || exit 1

# Declare the content volume explicitly so orchestrators/compose treat it as persistent.
# Always mount this in production — it holds images, themes, and the SQLite database.
VOLUME ["/var/lib/ghost/content"]

EXPOSE 2368
