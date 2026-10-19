savedcmd_fogccc-irq.mod := printf '%s\n'   fogccc-irq.o | awk '!x[$$0]++ { print("./"$$0) }' > fogccc-irq.mod
