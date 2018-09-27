#!/usr/bin/fontforge

# useful fontforge script that fix some issues with font
# generated by patoline on some naviguator. use in Patonet driver
# with --font-prefix path/fixfont.sh

Open($1)
SetFontOrder(3)
SelectAll()
Simplify(128+32+8,1.5)
ScaleToEm(1000)
Generate($1)