# This makefile is largely inspired from "Recursive Make Considered
# Harmful" [Miller, 1997] and from "Implementing non-recursive make"
# [van Bergen, 2002] # <http://evbergen.home.xs4all.nl/nonrecursive-make.html>.
#
# This file is the entry point for make. It defines global variables
# used elsewhere in the source tree, and sources the src/Makefile.config
# which has been generated by configure.ml.
#
# It the visits each subdirectory (among those declared in the
# $(MODULES) variable below) and includes the file Rules.mk when it
# exists. Each Rules.mk can use:
# * the $(d) variable, whose value is either empty (at the root of the
#   source tree), or contains the path of the including directory
#   relative to the top of the source tree; and
# * the $(mod) variable, which contains the name of the directory being
#   visited.
#
# In other words, at the top of src/Patoline/Rules.mk, $(d) is "src/"
# and $(mod) is "Patoline".
#
# Each Rules.mk is expected to change the value of $(d) for its own
# paperwork, but it must be reset to the previous value at the end of
# the file.
#
# See for example the beginning and the end of src/Patoline/Rules.mk,
# which look like:
# * at the top:  d := $(if $(d),$(d)/,)$(mod)
# * at the end:  d := $(patsubst %/,%,$(dir $(d)))
#
# This implementation uses GNU Make $(dir) and $(patsubst) functions,
# which remove the stack-like trick used in [van Bergen]. This requires
# that $(d) MUST NOT end with a trailing slash.
#
# Beware that although each Rules.mk lives in its own directory, all
# paths must be written relatively to the top of the source tree. For
# example, the file "src/Drivers/DriverGL/Rules.mk" must refer to
# "src/Drivers/DriverGL/DriverGL.cmxa" using the string
# "$(d)/DriverGL.cmxa" and not simply "DriverGL.cmxa". The latter would
# be interpreted as <patoline_source_tree>/DriverGL.cmxa (where
# <patoline_source_tree> is the toplevel directory, where the current
# makefile lives).
#
# CLEANING
# ========
#
# Each Rules.mk can use variables defined here before the "Visit
# subdirectories" part. It is also expected to expand (but NOT replace)
# the value of $(CLEAN) and $(DISTCLEAN) variables with paths of files
# which must be respectively cleaned by "make clean" (e.g., object files,
# binaries) or by "make distclean" (e.g., dependencies files ending in
# ".depends", or src/Makefile.config).
#
# Each Rules.mk is responsible for its own cleaning. You can use:
#   darcs status --boring | grep "^a"
# after a "make distclean" to check that no generated file remains after
# a distclean.
#
#
# INSTALLING
# ==========
#
# Create your own install-something in your Rules.mk, and add
# "install-something" to the $(INSTALL_TARGETS) variable.
#
# Use the "install" command in your rules.
#
#
# COMMON PITFALLS
# ===============
#
# It is usually a WRONG idea to use "./" or "../" in Rules.mk, since
# make won't simplify them to get canonical filenames when parsing
# rules. Better define a global $(SOMETHING_DIR) from an upper-level
# Rules.mk.
#
# Variables inside make rules are not expanded immediately: you cannot
# use $(d) there, since its value will probably be different from what
# you expect.
#
# When building both bytecode and native code from the same .ml source
# file, which has no corresponding .mli, both ocamlc and ocamlopt output
# a .cmi file. This means that they must not be run in parallel,
# otherwise we get a corrupted .cmi file. One can prevent this from
# happening by making the .cmx native object depend on the .cmo object.
# (The converse dependency is a wrong idea, because on some platforms we
# cannot build the .cmx file.)
#
#
# QUIET OUTPUT
# ============
#
# This file defines standard pattern rules to call various OCaml tools.
# It suppresses make's usual output, and echoes instead a short summary
# of the command being run.
#
# One can alter the value of the $(Q), standing for "Quiet", to change
# this behaviour. Its default value is "@" to suppress make output. By
# calling:
#   make Q=
# you get back the full compilation trace.
#
#
# OUTPUT TARGET SPECIFIC VARIABLES
# ================================
#
# Unlike [van Bergen], we do not use target-specific variables, which
# have a blocker design flaw: their get inherited by prerequisites. GNU
# Make 3.82 introduced the "private" modifier on variable declarations,
# which exactly suppresses this inheritance. Yet, as long as GNU Make
# 3.82 has not made it to Debian (testing) and Ubuntu, we won't use this
# useful feature.



# Check that we have at least GNU Make 3.81. This works as long as
# lexicographic order on strings coincides with the order of gmake
# versions.
need_gmake := 3.81
ifeq "$(strip $(filter $(need_gmake),$(firstword $(sort $(MAKE_VERSION) $(need_gmake)))))" ""
  $(error This Makefile requires at least GNU Make version $(need_gmake))
endif

# Import variables computed by configure.ml
ifneq "$(wildcard src/Makefile.config)" ""
  include src/Makefile.config
endif

# Compilers and various tools
OCAML    := ocaml
OCAMLC   := ocamlfind ocamlc $(if $(OCPP),-pp '$(OCPP)',)
OCAMLOPT_NOPP := ocamlfind ocamlopt -g
OCAMLOPT_NOINTF := $(OCAMLOPT_NOPP) $(if $(OCPP),-pp '$(OCPP)',)
OCAMLOPT := $(OCAMLOPT_NOINTF) -intf-suffix .cmi
OCAMLDEP := ocamlfind ocamldep $(if $(OCPP),-pp '$(OCPP)',)
OCAMLMKLIB := ocamlfind ocamlmklib
OCAMLDOC := ocamlfind ocamldoc $(if $(OCPP),-pp '$(OCPP)',)
OCAMLYACC := ocamlyacc
OCAMLLEX := ocamllex
DYPGEN := dypgen

export OCAML OCAMLC OCAMLOPT OCAMLDEP OCAMLMKLIB

# Useful directories, to be referenced from other Rules.ml
FONTS_DIR := Fonts
FORMAT_DIR := Format
HYPHENATION_DIR := Hyphenation
EDITORS_DIR := editors

# Environment variable for ocamlfind to search for local package
# and ignore duplicate definition due to previous installation
OCAMLPATH_SAVE := $(OCAMLPATH)
OCAMLPATH = $(SRC_DIR):$(OCAMLPATH_SAVE)
OCAMLFIND_IGNORE_DUPS_IN=$(dir $(INSTALL_TYPOGRAPHY_DIR))
export OCAMLPATH 
export OCAMLFIND_IGNORE_DUPS_IN

OCAMLVERSION=$(shell $(OCAMLC) -version)

ifeq ($(OCAMLVERSION),3.12.1)
COMPILER_INC = -I +compiler-libs/parsing -I +compiler-libs/typing -I +compiler-libs/utils
COMPILER_LIBS = misc.cmo config.cmo warnings.cmo linenum.cmo location.cmo longident.cmo printast.cmo
else
COMPILER_INC = -I +compiler-libs
COMPILER_LIBS = ocamlcommon.cma
endif

COMPILER_LIBO := $(COMPILER_LIBS:.cma=.cmxa)
COMPILER_LIBO := $(COMPILER_LIBO:.cmo=.cmx)

# Main rule prerequisites are expected to be extended by each Rules.mk
# We just declare it here to make it the (phony) default target.
.PHONY: all
all: configure testconfig

configure: configure.ml
	$(ECHO) "[OPT] -> $@"
	$(Q)- rm -f src/Makefile.config
	$(Q)ocamlfind ocamlopt -package unix,str,findlib unix.cmxa str.cmxa findlib.cmxa configure.ml -o configure

testconfig:
	@ if [ ! -f "src/Makefile.config" ]; then echo Run './configure [options]' before make; exit 1; fi

# Sanity tests, empty for now
.PHONY: check
check:

# The following declarations are necessary to make $(CLEAN) and
# $(DISTCLEAN) immediate variables (i.e., right hand side of the
# declaration is expanded immediately). Otherwise, Rules.mk cannot use
# extend it with the "+=" operator, along with $(d) on the right-hand
# side.
CLEAN :=
DISTCLEAN :=

-include Rules.clean
clean:
	rm -f $(CLEAN)

distclean: clean
	rm -f $(DISTCLEAN)
	rm -f configure configure.cmi configure.cmx configure.o

ifneq "$(wildcard ./configure)" "" 
ifneq "$(wildcard src/Makefile.config)" ""
# Visit subdirectories if configure is ok (otherwise ocamldep is run too soon)
  MODULES := src Hyphenation editors Fonts Accessoires
  d := 
  $(foreach mod,$(MODULES),$(eval include $$(mod)/Rules.mk))
endif
endif

# Phony targets
.PHONY: install doc test clean distclean

install: install-bindir
install-bindir:
	install -m 755 -d $(DESTDIR)/$(INSTALL_BIN_DIR)

# Prevent make from removing intermediate build targets
.SECONDARY:	$(CLEAN) $(DISTCLEAN)

# Common rules for OCaml
Q=@
ifeq "$(strip $(Q))" "@"
  ECHO=@echo
else
  ECHO=@\#
endif

# Force INCLUDES to be an immediate variable
INCLUDES:=

%.ml.depends: %.ml
	$(ECHO) "[DEPS]   $< -> $@"
	$(Q)$(OCAMLDEP) $(INCLUDES) -I $(<D) $< > $@
%.mli.depends: %.mli
	$(ECHO) "[DEPS]   $< -> $@"
	$(Q)$(OCAMLDEP) $(INCLUDES) $< > $@
%.cmi: %.mli %.ml.depends
	$(ECHO) "[OCAMLC] $< -> $@"
	$(Q)$(OCAMLC) $(OFLAGS) $(INCLUDES) -o $@ -c $<
%.cmo: %.ml %.ml.depends
	$(ECHO) "[OCAMLC] $< -> $@"
	$(Q)$(OCAMLC) $(OFLAGS) $(INCLUDES) -o $@ -c $<
%.cmx: %.ml %.ml.depends
	$(ECHO) "[OPT]    $< -> $@"
	$(Q)$(OCAMLOPT) $(OFLAGS) $(INCLUDES) -o $@ -c $<
%.p.cmx: %.ml %.ml.depends
	$(ECHO) "[OPT -p] $< -> $@"
	$(Q)$(OCAMLOPT) -p $(OFLAGS) $(INCLUDES) -o $@ -c $<
%.cmo: %.mlpack
	$(ECHO) "[PACK]   $< -> $@"
	$(Q)$(OCAMLC) -pack -o $@ $(addprefix $(dir $<),$(addsuffix .cmo,$(shell cat $<)))
%.cmx: %.mlpack
	$(ECHO) "[PACK X] $< -> $@"
	$(Q)$(OCAMLOPT) -pack -o $@ $(addprefix $(dir $<),$(addsuffix .cmx,$(shell cat $<)))
%: %.cmo
	$(ECHO) "[LINK]   $< -> $@"
	$(Q)$(OCAMLC) -linkpkg $(INCLUDES) -o $@ $<
%: %.cmx
	$(ECHO) "[LINK X] $< -> $@"
	$(Q)$(OCAMLOPT) -linkpkg $(INCLUDES) -o $@ $<

%.ml: %.mly
	$(ECHO) "[YACC]   $< -> $@"
	$(Q)$(OCAMLYACC) $<

%.ml: %.mll
	$(ECHO) "[LEX]    $< -> $@"
	$(Q)$(OCAMLLEX) -q $<

# Common rules for Patoline
%.pdf: %.txp $(RBUFFER_DIR)/rbuffer.cmxa $(TYPOGRAPHY_DIR)/Typography.cmxa $(TYPOGRAPHY_DIR)/ParseMainArgs.cmx $(DRIVERS_DIR)/Pdf/Pdf.cmxa $(FORMAT_DIR)/DefaultFormat.cmxa $(SRC_DIR)/DefaultGrammar.cmx
	$(ECHO) "[PATOLINE] $< -> $*.tml"
	$(Q)$(PATOLINE_IN_SRC) --recompile --driver Pdf --extra-hyph-dir $(HYPHENATION_DIR) --ml --extra-fonts-dir $(FONTS_DIR) -I $(SRC_DIR) $<

	$(ECHO) "[PATOLINE] $< -> $*_.tml"
	$(Q)$(PATOLINE_IN_SRC) --recompile --driver Pdf --extra-hyph-dir $(HYPHENATION_DIR) --main-ml --extra-fonts-dir $(FONTS_DIR) -I $(SRC_DIR) $<

	$(ECHO) "[OPT]    $*.tml $*_.tml -> $*.tmx"
	$(Q)$(OCAMLOPT_NOPP) -linkpkg -I $(SRC_DIR) -I $(RBUFFER_DIR) rbuffer.cmxa -I $(TYPOGRAPHY_DIR) Typography.cmxa ParseMainArgs.cmx -I $(DRIVERS_DIR)/Pdf Pdf.cmxa -I $(FORMAT_DIR) DefaultFormat.cmxa -o $*.tmx $(SRC_DIR)/DefaultGrammar.cmx -impl $*.tml -impl $*_.tml

	./$*.tmx --extra-fonts-dir $(FONTS_DIR) --extra-hyph-dir $(HYPHENATION_DIR)

CLEAN += Patoline_.cmi Patoline.cmi Patoline_.cmx Patoline.cmx Patoline_.dep \
	 Patoline_.o Patoline.o Patoline.pdf Patoline.tdx Patoline_.tml \
	 Patoline.tmx Patoline.tml
