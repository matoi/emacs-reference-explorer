#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
    printf 'usage: %s ensure|update MANIFEST\n' "$0" >&2
    exit 64
fi

action=$1
manifest=$2

case $action in
    ensure|update) ;;
    *)
        printf 'error: action must be ensure or update: %s\n' "$action" >&2
        exit 64
        ;;
esac

if [ ! -r "$manifest" ]; then
    printf 'error: unreadable docset manifest: %s\n' "$manifest" >&2
    exit 66
fi

script_directory=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
lisp_directory=$script_directory/..

REFERENCE_DOCSET_ACTION=$action \
REFERENCE_DOCSET_MANIFEST=$manifest \
command emacs --batch -Q \
    -L "$lisp_directory" \
    -l reference-explorer-source-docset-manager \
    -f reference-explorer-source-docset-manager-batch
