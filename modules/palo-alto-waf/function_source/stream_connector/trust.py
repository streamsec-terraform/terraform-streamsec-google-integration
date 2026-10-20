# Ed25519 public keys (raw, base64) whose signatures the connector accepts on adapter releases;
# more than one during a key rotation. Changing this list is a redeploy, by design: a
# compromised backend cannot add a key. Empty: releases are not fetched, the built-in adapter
# always runs.
PUBLIC_KEYS = []
