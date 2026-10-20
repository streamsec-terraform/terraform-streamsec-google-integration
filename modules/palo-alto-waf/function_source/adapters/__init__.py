# The integration type (waf_integrations.type) each adapter serves -> its module here. A built
# package carries one of them (build.py --vendor).
VENDOR_MODULES = {
    "palo-alto": "palo_alto",
    "fortinet": "fortinet",
    "f5": "f5",
}
