SHELL=/usr/bin/env bash
PY:=/usr/bin/env python


# Print Colors (exported for use in py installer)
export C_OFF:=$(shell tput -Txterm sgr0)
export C_DEBUG:=$(shell tput -Txterm setaf 5)
export C_INFO:=$(shell tput -Txterm setaf 6)
export C_NOTICE:=$(shell tput -Txterm setaf 2)
export C_WARNING:=$(shell tput -Txterm setaf 3)
export C_ERROR:=$(shell tput -Txterm setaf 1)

# Prevent the user from running with sudo. This isn't perfect if something else than sudo is used.
# Just checking for root isn't enough, as user on Creality K1 printers usually run as root (ugh)
ifneq ($(SUDO_COMMAND),) 
  $(error $(C_ERROR)Please do not run with sudo$(C_OFF))
endif

export KCONFIG_CONFIG ?= .config
include $(KCONFIG_CONFIG)

# For quiet builds, override with make Q= for verbose output
Q?=@
ifneq ($(Q),@)
	V?=-v
endif
export SRC ?= $(CURDIR)


# Use the name of the 'name.config' file as the out_name directory, or 'out' if just '.config' is used
ifeq ($(basename $(notdir $(KCONFIG_CONFIG))),)
  export OUT ?= $(CURDIR)/out
else
  export OUT ?= $(CURDIR)/out_$(basename $(notdir $(KCONFIG_CONFIG)))
endif

export IN=$(OUT)/in


MAKEFLAGS += --jobs 16 # Parallel build
# kconfiglib/menuconfig doesn't like --output-sync, so we don't add it if it's the target or if .config is outdated
ifeq ($(findstring menuconfig,$(MAKECMDGOALS)),)
  ifeq ($(shell [ "$(KCONFIG_CONFIG)" -ot "$(SRC)/installer/Kconfig" ] || echo y),y)
    MAKEFLAGS += --output-sync
  endif
endif


# If CONFIG_KLIPPER_HOME is not yet set by .config, set it to the default value.
# This is required to make menuconfig work the first time.
# If the klipper directory is not at one of the standard locations,
# it can be overridden with 'make CONFIG_KLIPPER_HOME=/path/to/klipper <target>'
ifneq ($(wildcard /usr/share/klipper),)
  export CONFIG_KLIPPER_HOME ?= /usr/share/klipper
else
  export CONFIG_KLIPPER_HOME ?= ~/klipper
endif


KLIPPER_HOME:=$(patsubst "%",%,$(CONFIG_KLIPPER_HOME))
KLIPPER_CONFIG_HOME:=$(patsubst "%",%,$(CONFIG_KLIPPER_CONFIG_HOME))
MOONRAKER_HOME:=$(patsubst "%",%,$(CONFIG_MOONRAKER_HOME))
PRINTER_CONFIG_FILE:=$(patsubst "%",%,$(CONFIG_PRINTER_CONFIG_FILE))
MOONRAKER_CONFIG_FILE:=$(patsubst "%",%,$(CONFIG_MOONRAKER_CONFIG_FILE))

export PYTHONPATH:=$(KLIPPER_HOME)/lib/kconfiglib:$(PYTHONPATH)
BUILD_MODULE:=$(PY) -m installer.build $(V)

hh_klipper_extras_files = $(patsubst extras/%,%,$(wildcard extras/*.py extras/*/*.py))
hh_old_klipper_modules = mmu.py mmu_toolhead.py # These will get removed upon install
hh_config_files = $(patsubst config/%,%,$(wildcard config/*.cfg config/**/*.cfg))
hh_moonraker_components = $(patsubst components/%,%,$(wildcard components/*.py))

# use sudo if the klipper home is at a system location
SUDO:=$(shell [ -d $(KLIPPER_HOME) ] && [ "$$(stat -c %u $(KLIPPER_HOME))" != "$$(id -u)" ] && echo "sudo " || echo "")

hh_configs_to_parse = $(subst $(KLIPPER_CONFIG_HOME),$(IN),$(wildcard $(addprefix $(KLIPPER_CONFIG_HOME)/mmu/, \
	base/mmu.cfg \
	base/mmu_parameters.cfg \
	base/mmu_hardware.cfg \
	base/mmu_macro_vars.cfg \
	addons/*.cfg)))

# Files/targets that need to be build
build_targets = \
	$(OUT)/$(MOONRAKER_CONFIG_FILE) \
	$(OUT)/$(PRINTER_CONFIG_FILE) \
	$(addprefix $(OUT)/mmu/, $(hh_config_files)) \
	$(addprefix $(OUT)/klippy/extras/,$(hh_klipper_extras_files)) \
	$(addprefix $(OUT)/moonraker/components/,$(hh_moonraker_components)) 

# Files/targets that need to be installed
install_targets = \
	$(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE) \
	$(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE) \
	$(addprefix $(KLIPPER_CONFIG_HOME)/mmu/, $(hh_config_files)) \
	$(addprefix $(KLIPPER_HOME)/klippy/extras/, $(hh_klipper_extras_files)) \
	$(addprefix $(MOONRAKER_HOME)/moonraker/components/, $(hh_moonraker_components))


# Recipe functions
install = \
	$(info $(C_INFO)Installing $(2)...$(C_OFF)) \
	$(SUDO)mkdir -p $(dir $(2)); \
	$(SUDO)cp -af $(3) "$(1)" "$(2)";

link = \
	mkdir -p $(dir $(2)); \
	ln -sf "$(abspath $(1))" "$(2)";

backup_ext ::= .old-$(shell date '+%Y%m%d-%H%M%S')
backup_name = $(addsuffix $(backup_ext),$(1))
backup = \
	if [ -e "$(1)" ] && [ ! -e "$(call backup_name,$(1))" ]; then \
		echo -e "$(C_NOTICE)Making a backup of '$(1)' to '$(call backup_name,$(1))'$(C_OFF)"; \
		$(SUDO)cp -a "$(1)" "$(call backup_name,$(1))"; \
	fi

# Bool to check if moonraker/klipper needs to be restarted
restart_moonraker = 0
restart_klipper = 0

.SECONDEXPANSION:
.DEFAULT_GOAL := build
.PRECIOUS: $(KCONFIG_CONFIG)
.PHONY: update menuconfig install uninstall check_root check_version diff test build clean
.SECONDARY: $(call backup_name,$(KLIPPER_CONFIG_HOME)/mmu) \
	$(call backup_name,$(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE)) \
	$(call backup_name,$(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE))


##### Build targets #####

# Link existing config files to the out/in directory to break circular dependency
$(IN)/%:
	$(Q)[ -f "$(KLIPPER_CONFIG_HOME)/$*" ] || { echo "The file '$(KLIPPER_CONFIG_HOME)/$*' does not exist. Please check your config for the correct paths"; exit 1; }
	$(Q)$(call link,$(KLIPPER_CONFIG_HOME)/$*,$@)

ifneq ($(wildcard $(KCONFIG_CONFIG)),) # To prevent make errors when .config is not yet created

# Copy existing moonraker.conf and printer.cfg to the out directory
$(OUT)/$(MOONRAKER_CONFIG_FILE): $(IN)/$$(@F) 
	$(info $(C_INFO)Copying $(MOONRAKER_CONFIG_FILE) to '$(notdir $(OUT))' directory$(C_OFF))
	$(Q)cp -aL "$<" "$@" # Copy the current version to the out directory
	$(Q)chmod +w "$@" # Make sure the file is writable
	$(Q)$(BUILD_MODULE) --install-moonraker "$(SRC)/moonraker_update.txt" "$@" "$(KCONFIG_CONFIG)"

$(OUT)/$(PRINTER_CONFIG_FILE): $(IN)/$$(@F) 
	$(info $(C_INFO)Copying $(PRINTER_CONFIG_FILE) to '$(notdir $(OUT))' directory$(C_OFF))
	$(Q)cp -aL "$<" "$@" # Copy the current version to the out directory
	$(Q)chmod +w "$@" # Make sure the file is writable
	$(Q)$(BUILD_MODULE) --install-includes "$@" "$(KCONFIG_CONFIG)"

# We link all config files, those that need to be updated will be written over in the install script
$(OUT)/mmu/%.cfg: $(SRC)/config/%.cfg | $(hh_configs_to_parse)
	$(Q)$(call link,$<,$@)
	$(Q)$(BUILD_MODULE) --build "$<" "$@" "$(KCONFIG_CONFIG)" $(hh_configs_to_parse)

# Python files are linked to the out directory
$(OUT)/klippy/extras/%.py: $(SRC)/extras/%.py
	$(Q)$(call link,$<,$@)

$(OUT)/moonraker/components/%.py: $(SRC)/components/%.py
	$(Q)$(call link,$<,$@)

$(OUT):
	$(Q)mkdir -p "$@"

$(build_targets): $(KCONFIG_CONFIG) | $(OUT) update check_version 

build: $(build_targets)


##### Install targets #####

# Check whether the required paths exist
$(KLIPPER_HOME)/klippy/extras $(MOONRAKER_HOME)/moonraker/components:
	$(error The directory '$@' does not exist. Please check your config for the correct paths)

$(KLIPPER_HOME)/%: $(OUT)/% | $(KLIPPER_HOME)/klippy/extras
	$(Q)$(call install,$<,$@)
	$(Q)$(eval restart_klipper = 1)

$(MOONRAKER_HOME)/%: $(OUT)/% | $(MOONRAKER_HOME)/moonraker/components
	$(Q)$(call install,$<,$@)
	$(Q)$(eval restart_moonraker = 1)

$(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE): $(OUT)/$$(@F) | $(call backup_name,$$@)
	$(Q)$(call install,$<,$@)
	$(Q)$(eval restart_klipper = 1)

$(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE): $(OUT)/$$(@F) | $(call backup_name,$$@)
	$(Q)$(call install,$<,$@)
	$(Q)$(eval restart_moonraker = 1)

$(KLIPPER_CONFIG_HOME)/mmu/%.cfg: $(OUT)/mmu/%.cfg | $(call backup_name,$(KLIPPER_CONFIG_HOME)/mmu) 
	$(Q)$(call install,$<,$@)
	$(Q)$(eval restart_klipper = 1)

$(KLIPPER_CONFIG_HOME)/mmu/mmu_vars.cfg: | $(OUT)/mmu/mmu_vars.cfg $(call backup_name,$(KLIPPER_CONFIG_HOME)/mmu) 
	$(Q)$(call install,$(OUT)/mmu/mmu_vars.cfg,$@,--no-clobber)
	$(Q)$(eval restart_klipper = 1)

$(call backup_name,$(KLIPPER_CONFIG_HOME)/%): $(OUT)/% | build
	$(Q)$(call backup,$(basename $@))

$(call backup_name,$(KLIPPER_CONFIG_HOME)/mmu): $(addprefix $(OUT)/mmu/, $(hh_config_files)) | build
	$(Q)$(call backup,$(basename $@))

endif

$(install_targets): build

install: $(install_targets)
	$(Q)rm -rf $(addprefix $(KLIPPER_HOME)/klippy/extras,$(hh_old_klipper_modules))
	$(Q)[ "$(restart_moonraker)" -eq 0 ] || $(BUILD_MODULE) --restart-service "Moonraker" $(CONFIG_SERVICE_MOONRAKER) "$(KCONFIG_CONFIG)"
	$(Q)[ "$(restart_klipper)" -eq 0 ] || $(BUILD_MODULE) --restart-service "Klipper" $(CONFIG_SERVICE_KLIPPER) "$(KCONFIG_CONFIG)"
	$(Q)$(BUILD_MODULE) --print-happy-hare "Done! Happy Hare $(CONFIG_F_VERSION) is ready!"

uninstall:
	$(Q)$(call backup,$(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE))
	$(Q)$(call backup,$(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE))
	$(Q)$(call backup,$(KLIPPER_CONFIG_HOME)/mmu)
	$(Q)rm -rf $(addprefix $(KLIPPER_HOME)/klippy/extras/,$(hh_klipper_extras_files) $(filter-out ./,$(dir $(hh_klipper_extras_files))))
	$(Q)rm -rf $(addprefix $(MOONRAKER_HOME)/moonraker/components/,$(hh_moonraker_components) $(filter-out ./,$(dir $(hh_moonraker_components))))
	$(Q)rm -rf $(KLIPPER_CONFIG_HOME)/mmu
	$(Q)$(BUILD_MODULE) --uninstall-moonraker $(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE)
	$(Q)$(BUILD_MODULE) --uninstall-includes $(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE)
	$(Q)$(BUILD_MODULE) --restart-service "Moonraker" $(CONFIG_SERVICE_MOONRAKER) "$(KCONFIG_CONFIG)"
	$(Q)$(BUILD_MODULE) --restart-service "Klipper" $(CONFIG_SERVICE_KLIPPER) "$(KCONFIG_CONFIG)"
	$(Q)$(BUILD_MODULE) --print-unhappy-hare "Done... Very unHappy Hare."


##### Misc targets #####

update: 
	$(Q)$(SRC)/installer/self_update.sh

clean:
	$(Q)rm -rf $(OUT)

diff=\
	 git diff -U2 --color --src-prefix="current: " --dst-prefix="built: " \
	 	--minimal --word-diff=color --stat --no-index -- "$(1)" "$(2)" | \
        grep -v "diff --git " | \
		grep -Ev "index [[:xdigit:]]+\.\.[[:xdigit:]]+" || true;

diff: | build
	$(Q)$(call diff,$(KLIPPER_CONFIG_HOME)/mmu,$(patsubst $(SRC)/%,%,$(OUT)/mmu))
	$(Q)$(call diff,$(KLIPPER_CONFIG_HOME)/$(PRINTER_CONFIG_FILE),$(patsubst $(SRC)/%,%,$(OUT)/$(PRINTER_CONFIG_FILE)))
	$(Q)$(call diff,$(KLIPPER_CONFIG_HOME)/$(MOONRAKER_CONFIG_FILE),$(patsubst $(SRC)/%,%,$(OUT)/$(MOONRAKER_CONFIG_FILE)))

UT?=*
test: 
	$(Q)$(PY) -m unittest $(V) -k $(UT)

check_version:
	$(Q)$(BUILD_MODULE) --check-version "$(KCONFIG_CONFIG)" $(hh_configs_to_parse)  

$(KCONFIG_CONFIG): $(SRC)/installer/Kconfig
# if KCONFIG_CONFIG is outdated or doesn't exist run menuconfig first. If the user doesn't save the config, we will update it with olddefconfig
# touch in case .config does not get updated by olddefconfig.py
ifneq ($(findstring menuconfig,$(MAKECMDGOALS)),menuconfig)
	$(Q)$(MAKE) -s MAKEFLAGS= menuconfig
	$(Q)python $(KLIPPER_HOME)/lib/kconfiglib/olddefconfig.py $(SRC)/installer/Kconfig >/dev/null # Always update the .config file in case user doesn't save it
	$(Q)touch $(KCONFIG_CONFIG)
endif

menuconfig: $(SRC)/installer/Kconfig
	$(Q)MENUCONFIG_STYLE="aquatic" python $(KLIPPER_HOME)/lib/kconfiglib/menuconfig.py $(SRC)/installer/Kconfig

