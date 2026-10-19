FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# No kernel config fragment is used: linux-xlnx/bsp.cfg was empty, and an empty
# KERNEL_FEATURES entry is a build hazard. Add a real fragment here if needed.
