#!/bin/bash

# This script creates a Windows NSIS MSI installer from the current set of installed opam Coq packages

set -o nounset
set -o errexit

##### Files and folders #####

# The opam prefix - stripped from absolute paths to create relative paths
OPAM_PREFIX="$(opam conf var prefix)"

# The folder for the windows installer stuff
DIR_TARGET=windows_installer
rm -rf "$DIR_TARGET"
mkdir -p "$DIR_TARGET"

# The NSIS include file for the visible installer sections
FILE_SEC_VISIBLE="$DIR_TARGET"/sections_visible.nsh
> "$FILE_SEC_VISIBLE"

# The NSIS include file for the hidden installer sections
FILE_SEC_HIDDEN="$DIR_TARGET"/sections_hidden.nsh
> "$FILE_SEC_HIDDEN"

# The NSIS include file for dependencies between user visible packages
FILE_DEP_VISIBLE="$DIR_TARGET"/dependencies_visible.nsh
> "$FILE_DEP_VISIBLE"

# The NSIS include file for dependencies between hidden packages
FILE_DEP_HIDDEN="$DIR_TARGET"/dependencies_hidden.nsh
> "$FILE_DEP_HIDDEN"

# The NSIS include file for strings, e.g. section descriptions
FILE_STRINGS="$DIR_TARGET"/strings.nsh
> "$FILE_STRINGS"

# The NSIS include file for section descriptions
FILE_SEC_DESCRIPTIONS="$DIR_TARGET"/section_descriptions.nsh
> "$FILE_SEC_DESCRIPTIONS"

##### Utility functions #####

# Check if a newline searated list contains an item
# $1 = list
# $2 = item

function list_contains {
#   This variant does not work when $2 contains regexp chars like conf-g++
#   [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]]
    [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

# Add dlls for an executable using ldd to find them
# $1 = executable name
# $2 = regexp filter (grep)
# $3 = file list file name

function add_dlls_using_ldd {
  if [ -f "$DIR_TARGET/$3.nsh" ]
  then
    echo "Adding DLLs for $1"
    echo 'SetOutPath $INSTDIR\bin' >> "$DIR_TARGET/$3.nsh"
    for file in $(ldd $(which "$1") | cut -d ' ' -f 3 | grep "$2" | sort -u)
    do
      echo -n "FILE "; cygpath -aw "$file";
    done >> "$DIR_TARGET/$3.nsh"
  fi
}

# Add files from a cygwin package using package name and grp filter
# $1 = cygwin package name
# $2 = regexp filter (grep)
# $3 = file list file name

function add_files_using_cygwin_package {
  prevpath="--none--"
  if [ -f "$DIR_TARGET/$3.nsh" ]
  then
    echo "Adding files from cygwin package $1"
    for file in $(cygcheck -l "$1" | grep "$2" | sort -u)
    do
      relpath="${file#/usr/x86_64-w64-mingw32/sys-root/mingw/}"
      relpath="${relpath%/*}"
      if [ "$relpath" != "$prevpath" ]
      then
        echo 'SetOutPath $INSTDIR\'"$(cygpath -w "$relpath")"
        prevpath="$relpath"
      fi
      echo -n "FILE "; cygpath -aw "$file";
    done >> "$DIR_TARGET/$3.nsh"
  fi
}

###### Get filtered list of explicitly installed packages #####

# Note: since both positive and negative filtering makes sense, we do both and require that the result is identical.
# This ensures people get what they expect.

echo "Create package list"

packages_pos="$(opam list --installed-roots --short --columns=name | grep '^coq\|^menhir\|^gappa')"
packages_neg="$(opam list --installed-roots --short --columns=name | grep -v '^ocaml\|^opam\|^depext\|^conf\|^lablgtk\|^elpi')"

if [ "$packages_pos" != "$packages_neg" ]
then
  echo "The positive and negative list of opam packages deferes. Please adjust the package filters!"
  echo "Positive list = $packages_pos"
  echo "Negative list = $packages_neg"
  exit 1
fi

SELECTABLE_PACKAGES=$packages_pos

###### Associative array with package name -> file filter (shell glob pattern) #####

# If not white list regexp is given it is "."
# If not black list list regexp is given it is "\.byte\.exe$"

declare -A OPAM_FILE_WHITELIST
declare -A OPAM_FILE_BLACKLIST

OPAM_FILE_WHITELIST[ocaml-variants]='.^' # this has the ocaml compiler in
OPAM_FILE_WHITELIST[base]='.^' # ocaml stdlib
OPAM_FILE_WHITELIST[ocaml-compiler-libs]='.^'

OPAM_FILE_WHITELIST[dune]='.^'
OPAM_FILE_WHITELIST[configurator]='.^'
OPAM_FILE_WHITELIST[sexplib0]='.^'
OPAM_FILE_WHITELIST[csexp]='.^'
OPAM_FILE_WHITELIST[ocamlbuild]='.^'
OPAM_FILE_WHITELIST[result]='.^'
OPAM_FILE_WHITELIST[cppo]='.^'

OPAM_FILE_WHITELIST[elpi]='.^' # linked in coq-elpi
OPAM_FILE_WHITELIST[camlp5]='.^' # linked in elpi
OPAM_FILE_WHITELIST[ppx_drivers]='.^' # linked in elpi
OPAM_FILE_WHITELIST[ppxlib]='.^' # linked in elpi
OPAM_FILE_WHITELIST[ppx_deriving]='.^' # linked in elpi
OPAM_FILE_WHITELIST[ocaml-migrate-parsetree]='.^' # linked in elpi
OPAM_FILE_WHITELIST[re]='.^' # linked in elpi

OPAM_FILE_WHITELIST[lablgtk3]="stubs.dll$" # we keep only the stublib DLL, the rest is linked in coqide
OPAM_FILE_WHITELIST[lablgtk3-sourceview3]="stubs.dll$" # we keep only the stublib DLL, the rest is linked in coqide
OPAM_FILE_WHITELIST[cairo2]="stubs.dll$" # we keep only the stublib DLL, the rest is linked in coqide

###### Function for analyzing one package

# Analyze one package
# - retrieve list of files and create NSIS include file
# - retrieve dependencies and create NSIS file for user visible and hidden dependencies
# $1 = package name
# $2 = dependency level

function analyze_package {
  echo "Analyzing package $1 ($2)"

  # Create section entry
  if list_contains "$SELECTABLE_PACKAGES" "$1"
  then
    # This is a user visible package which can be explicitly selected or deselected
    echo "Section \"$1\" Sec_${1//-/_}" >> "$FILE_SEC_VISIBLE"
    echo 'SetOutPath "$INSTDIR\"' >> "$FILE_SEC_VISIBLE"
    echo "!include \"files_$1.nsh\"" >> "$FILE_SEC_VISIBLE"
    echo "SectionEnd" >> "$FILE_SEC_VISIBLE"

    descr="$(opam show --field=synopsis "$1")"
    echo 'LangString DESC_'"${1//-/_}"' ${LANG_ENGLISH} "'"$descr"'"' >> "$FILE_STRINGS"
    echo '!insertmacro MUI_DESCRIPTION_TEXT ${Sec_'"${1//-/_}"'} $(DESC_'"${1//-/_}"')' >> "$FILE_SEC_DESCRIPTIONS"
  else
    # This is a hidden section which is selected automatically by dependency
    echo "Section \"-$1\" Sec_${1//-/_}" >> "$FILE_SEC_HIDDEN"
    echo 'SetOutPath "$INSTDIR\"' >> "$FILE_SEC_HIDDEN"
    echo "!include \"files_$1.nsh\"" >> "$FILE_SEC_HIDDEN"
    echo "SectionEnd" >> "$FILE_SEC_HIDDEN"
  fi

  # Create file list include file

  if [ ${OPAM_FILE_WHITELIST[$1]+_} ]
  then
    whitelist="${OPAM_FILE_WHITELIST[$1]}"
  else
    whitelist="." # take everything
  fi

  if [ ${OPAM_FILE_BLACKLIST[$1]+_} ]
  then
    blacklist="${OPAM_FILE_BLACKLIST[$1]}"
  else
    blacklist="(\.byte\.exe|\.cm[aiox]|\.cmxa|\.o)$" # exclude byte code and library stuff
  fi

  echo "# File list for $1 matching $whitelist excluding $blacklist" > "$DIR_TARGET"/files_$1.nsh
  files="$(opam show --list-files $1 | grep -E "$whitelist" | grep -E -v "$blacklist" )" || true
  reldir_win_prev="--none--"
  for file in $files
  do
    if [ -d "$file" ]
    then
      true # ignore directories
    elif [ -f "$file" ]
    then
      relpath="${file#$OPAM_PREFIX}"
      reldir="${relpath%/*}"

      file_win="${file//\//\\}"
      reldir_win="${reldir//\//\\}"

      if [ "$reldir_win" != "$reldir_win_prev" ]
      then
        echo SetOutPath "\$INSTDIR$reldir_win" >> "$DIR_TARGET"/files_$1.nsh
      fi
      echo FILE "$file_win" >> "$DIR_TARGET"/files_$1.nsh

      reldir_win_prev="$reldir_win"
    else
      echo "In package '$1' the file '$file' does not exist"
      exit 1
    fi
  done

# handle dependencies
  # Note: the --installed is required cause of an opam bug.
  # See https://github.com/ocaml/opam/issues/4461
  dependencies="$(opam list --required-by=$1 --short --installed)"
  for dependency in $dependencies
  do
    # Check if dependency is visible or hidden and write dependency checker macro call in respective NSIS include file
    if list_contains "$SELECTABLE_PACKAGES" "$dependency"
    then
      # This is a user visible package which can be explicitly selected or deselected
      echo "${1//-/_}" "${dependency//-/_}" >> "$FILE_DEP_VISIBLE.in"
    else
      # This is a hidden dependency package
      echo "${1//-/_}" "${dependency//-/_}" >> "$FILE_DEP_HIDDEN.in"
    fi

    # Check if dependency is already in the list of known packages
    if ! list_contains "$PACKAGES" "$dependency"
    then
      PACKAGES="$PACKAGES"$'\n'"$dependency"
      analyze_package "$dependency" $(($2 + 1))
    fi
  done
}

###### Go through selected packages and recursively analyze dependencies #####

# The initial list of packages is the list of top level packages
PACKAGES="$SELECTABLE_PACKAGES"

for package in $SELECTABLE_PACKAGES
do
  analyze_package "$package" 0
done

###### Add system DLLs to some packages #####

add_dlls_using_ldd "coqc" '/usr/x86_64-w64-mingw32/sys-root/' "files_coq"
add_dlls_using_ldd "coqide" '/usr/x86_64-w64-mingw32/sys-root/' "files_coqide"
add_dlls_using_ldd "gappa" '/usr/x86_64-w64-mingw32/sys-root/' "files_gappa"

###### Add subset of adwaita icon theme #####

add_files_using_cygwin_package "mingw64-x86_64-adwaita-icon-theme"  \
"/\(16x16\|22x22\|32x32\|48x48\)/.*\("\
"actions/bookmark\|actions/document\|devices/drive\|actions/format-text\|actions/go\|actions/list\|"\
"actions/media\|actions/pan\|actions/process\|actions/system\|actions/window\|"\
"mimetypes/text\|places/folder\|places/user\|status/dialog\)"  \
"files_conf-adwaita-icon-theme"
