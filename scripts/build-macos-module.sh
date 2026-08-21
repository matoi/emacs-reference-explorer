#!/bin/sh

set -eu

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 64
fi

if [ "$(uname -s)" != Darwin ]; then
    printf 'note: macOS Dictionary module is unavailable on this platform\n'
    exit 0
fi

for command_name in cksum uname xcrun; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'error: required command is unavailable: %s\n' \
            "$command_name" >&2
        exit 127
    fi
done

emacs_program=${EMACS:-emacs}
if ! command -v "$emacs_program" >/dev/null 2>&1; then
    printf 'error: target Emacs is unavailable: %s\n' "$emacs_program" >&2
    exit 127
fi

script_directory=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
source_file=$script_directory/../native/reference-explorer-source-macos-module.m
clang_program=$(xcrun --find clang)
sdk_path=$(xcrun --show-sdk-path)

emacs_include_directory=${EMACS_INCLUDE_DIR:-}
if [ -z "$emacs_include_directory" ]; then
    emacs_include_directory=$(
        "$emacs_program" --batch -Q --eval \
            '(progn
               (require (quote seq))
               (let ((candidates
                    (list
                     (expand-file-name "../include" invocation-directory)
                     (expand-file-name "../Resources/include" invocation-directory)
                     (expand-file-name "../../../../include" data-directory))))
                 (let ((directory
                        (seq-find
                         (lambda (candidate)
                           (file-readable-p
                            (expand-file-name "emacs-module.h" candidate)))
                         candidates)))
                   (when directory (princ directory)))))'
    )
fi
module_header=$emacs_include_directory/emacs-module.h

if [ ! -f "$source_file" ]; then
    printf 'error: module source is unavailable: %s\n' "$source_file" >&2
    exit 66
fi
if [ ! -f "$module_header" ]; then
    printf 'error: emacs-module.h for %s is unavailable; set EMACS_INCLUDE_DIR\n' \
        "$emacs_program" >&2
    exit 66
fi

module_suffix=$("$emacs_program" --batch -Q --eval '(princ module-file-suffix)')
site_lisp_directory=${REFERENCE_EXPLORER_MODULE_DIRECTORY:-$HOME/.emacs.d/site-lisp/reference-explorer}
module_file=$site_lisp_directory/reference-explorer-source-macos-module$module_suffix
revision_file=$site_lisp_directory/reference-explorer-source-macos-module.revision
fingerprint=$(
    {
        cksum "$source_file"
        "$emacs_program" --version | sed -n '1p'
        uname -m
        xcrun --show-sdk-version
    } | cksum | awk '{ print $1 ":" $2 }'
)

module_loads() {
    "$emacs_program" --batch -Q \
        --eval "(progn
                  (module-load \"$module_file\")
	                  (unless
	                      (and
	                       (fboundp 'reference-explorer-source-macos-show-definition)
	                       (fboundp
	                        'reference-explorer-source-macos-show-definition-with-font)
	                       (fboundp
	                        'reference-explorer-source-macos-show-definition-at-offset)
	                       (fboundp 'reference-explorer-source-macos-term-at-offset)
	                       (fboundp
	                        'reference-explorer-source-macos-selection-at-offset)
	                       (fboundp
	                        'reference-explorer-source-macos-hide-definition))
	                    (kill-emacs 1)))" >/dev/null 2>&1
}

installed_revision=
if [ -f "$revision_file" ]; then
    installed_revision=$(sed -n '1p' "$revision_file")
fi
if [ "$installed_revision" = "$fingerprint" ] && \
    [ -f "$module_file" ] && module_loads
then
    printf 'ok: Reference Explorer macOS module at %s\n' "$module_file"
    exit 0
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/reference-explorer-source-macos.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
built_module=$temporary_directory/reference-explorer-source-macos-module$module_suffix
module_cache=$temporary_directory/clang-module-cache
/bin/mkdir -p "$module_cache"

printf 'Building Reference Explorer macOS module...\n'
CLANG_MODULE_CACHE_PATH=$module_cache \
    "$clang_program" \
    -x objective-c \
    -fmodules \
    -fobjc-arc \
    -O2 \
    -bundle \
    -undefined dynamic_lookup \
    -isysroot "$sdk_path" \
    -I"$emacs_include_directory" \
    -framework AppKit \
    -framework CoreServices \
    -framework Foundation \
    "$source_file" \
    -o "$built_module"

/bin/mkdir -p "$site_lisp_directory"
staged_module=$site_lisp_directory/.reference-explorer-source-macos-module$module_suffix.tmp.$$
/bin/cp "$built_module" "$staged_module"
/bin/mv -f "$staged_module" "$module_file"
printf '%s\n' "$fingerprint" >"$revision_file"

if ! module_loads; then
    printf 'error: built module could not be loaded: %s\n' "$module_file" >&2
    exit 70
fi

printf 'Installed Reference Explorer macOS module at %s\n' "$module_file"
