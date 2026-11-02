.PHONY: defconfig olddefconfig bzImage kernelversion

defconfig:
	@printf 'CONFIG_BASE=y\n' > .config

olddefconfig:
	@if test "$${DROP_NUMBER:-0}" = 1; then grep -v '^CONFIG_NUMBER=' .config > .config.new; mv .config.new .config; fi

bzImage:
	@mkdir -p arch/x86/boot
	@printf 'kernel\n' > arch/x86/boot/bzImage
	@printf 'symbols\n' > System.map
	@printf 'unstripped kernel\n' > vmlinux

kernelversion:
	@printf '6.18-test\n'
