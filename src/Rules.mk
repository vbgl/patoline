# Standard things which help keeping track of the current directory
# while include all Rules.mk.
d := $(if $(d),$(d)/,)$(mod)

# Useful directories, to be referenced from other Rules.ml
SRC_DIR := $(d)
PATOLINE_IN_SRC := $(d)/patobuild/patoline
PA_PATOLINE_DIR := $(d)/pa_patoline
PA_PATOLINE_IN_SRC := $(PA_PATOLINE_DIR)/pa_patoline
PATOBUILD_DIR := $(d)/patobuild
TYPOGRAPHY_DIR := $(d)/Typography
RAWLIB_DIR := $(d)/rawlib
DB_DIR := $(d)/db
DRIVERS_DIR := $(d)/Drivers
FORMAT_DIR := $(d)/Format
UTIL_DIR := $(d)/patutil
RBUFFER_DIR := $(d)/rbuffer
LIBFONTS_DIR := $(d)/patfonts
CESURE_DIR := $(d)/cesure
UNICODE_DIR := $(d)/unicodelib
CONFIG_DIR := $(d)/config
GRAMMAR_DIR := $(d)/grammar
PACKAGES_DIR := $(d)/Packages
PATOBUILD_DIR := $(d)/patobuild
RBUFFER_DIR := $(d)/rbuffer
PA_PATOLINE_DIR := $(d)/pa_patoline

# Visit subdirectories
MODULES := unicodelib rbuffer patutil patfonts rawlib db Typography \
	Drivers Pdf cesure Format bibi plot proof patobuild grammar config \
	pa_patoline

$(foreach mod,$(MODULES),$(eval include $(d)/$$(mod)/Rules.mk))

#foreach to define mod ...bof FIXME
ifeq ($(MAKECMDGOALS),clean)
  $(foreach mod,Packages,$(eval include $(d)/$$(mod)/Rules.mk))
endif
ifeq ($(MAKECMDGOALS),distclean)
  $(foreach mod,Packages,$(eval include $(d)/$$(mod)/Rules.mk))
endif
ifeq ($(filter packages,$(MAKECMDGOALS)),packages)
  $(foreach mod,Packages,$(eval include $(d)/$$(mod)/Rules.mk))
endif

# Rolling back changes made at the top
d := $(patsubst %/,%,$(dir $(d)))
