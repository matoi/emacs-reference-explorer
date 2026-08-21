# Reference Explorer

## Overview

Reference Explorer is a dictionary and documentation browser for Emacs. It
integrates Lookup for Emacs, Dash-compatible docsets, macOS Dictionary,
Dictionaries by Monokakido, and an online thesaurus.

A source retrieves and renders entries; a provider is a target of the common
reference dispatcher. Some integrations serve both roles. Configure provider
order with `reference-explorer-ui-provider-order`. The macOS default is
`docset`, `macos-dictionary`, then `lookup`.

## Installation

Install with Emacs 29 or later through `package-vc`:

```elisp
(package-vc-install
 '(reference-explorer
   :url "https://github.com/matoi/emacs-reference-explorer"
   :main-file "reference-explorer.el"))
(require 'reference-explorer-ui)
```

Integrations with [Consult](https://github.com/minad/consult),
[Embark](https://github.com/oantolin/embark),
[Vertico](https://github.com/minad/vertico), and
[Popper](https://github.com/karthink/popper) are optional.

## Sources and providers

- Lookup for Emacs is a dictionary source and the `lookup` provider.
- Docsets are a documentation source and the `docset` provider.
- macOS Dictionary is the `macos-dictionary` provider.
- Dictionaries by Monokakido is the `monokakido` provider.
- The thesaurus is a source used by its own replacement command, not a
  dispatcher provider.

### Dispatch order and fallback

For one provider order in every major mode, set
`reference-explorer-ui-provider-order`:

```elisp
(customize-set-variable
 'reference-explorer-ui-provider-order
 '(docset macos-dictionary lookup))
```

`reference-explorer-at-point` tries providers from left to right. With a
prefix argument it prompts for one provider instead. To use different chains
by major mode, configure the lower-level rules after loading the UI:

```elisp
(with-eval-after-load 'reference-explorer-ui
  (setq reference-explorer-provider-rules
        '((emacs-lisp-mode . (docset lookup))
          (text-mode . (macos-dictionary lookup))
          (t . (lookup)))))
```

The first rule whose mode is an ancestor of the originating major mode wins,
so keep the `t` rule last. By default, dispatch advances only when a provider
is unavailable. To also continue after provider errors, use:

```elisp
(setq reference-explorer-fallback-conditions '(unavailable error))
```

An available provider that returns no matches does not fall through. Source
ordering is source-specific and is configured in the sections below.

### Lookup for Emacs

This optional source searches locally installed EPWING and EBXA dictionaries
through [Lookup for Emacs](http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup)
and [EBLook](http://green.ribbon.to/~ikazuhiro/lookup/lookup.html#EBLOOK).

For a Homebrew installation of Lookup, EBLook, and
[MeCab](https://taku910.github.io/mecab/), configure paths before loading the
source:

```elisp
(require 'reference-explorer-source-lookup-homebrew)
(reference-explorer-source-lookup-homebrew-configure)
(require 'reference-explorer-source-lookup)
```

The helper is not loaded automatically. Other installations can put Lookup on
`load-path` and configure its agents, modules, dictionaries, and
per-dictionary `:stemmer` options directly.

Available interfaces are:

- `reference-explorer-source-lookup-quick-lookup-at-point`: compact graphical
  selector.
- `reference-explorer-source-lookup-consult-at-point`: Consult selector.

Relevant settings are:

- `reference-explorer-source-lookup-source-order`: dictionary priority.
- `reference-explorer-source-lookup-preview-highlight-sources`: preview
  highlighting.
- `reference-explorer-ui-display-buffer-function`: committed-buffer display.

For example:

```elisp
(setq reference-explorer-source-lookup-source-order
      '("Dictionary title" "Another dictionary"))
```

Unlisted dictionaries follow these in Lookup's original order.

Embark adds display, copy, and export actions when available.

### Docsets

The local backend reads the format described in the [Dash Docset Generation
Guide](https://kapeli.com/docsets), searches SQLite indexes, and renders entries
with WebKit or SHR.

Configure installed bundles and mode-specific selectors with:

- `reference-explorer-source-docset-directories`
- `reference-explorer-source-docset-mode-alist`

Selectors and results follow the order written for each mode group:

```elisp
(setq reference-explorer-source-docset-mode-alist
      '(((python-mode python-ts-mode) . ("Python@3.13.*" "NumPy"))
        ((js-mode js-ts-mode typescript-ts-mode) . ("JavaScript" "NodeJS"))))
```

The manager supports latest, exact, and version-series selectors. It uses
Kapeli's [Dash docset feeds](https://github.com/Kapeli/feeds) by default; review
that repository's usage notice and each documentation source's license.

```sh
scripts/manage-docsets.sh ensure MANIFEST
scripts/manage-docsets.sh update MANIFEST
```

### macOS Dictionary

The macOS provider uses Dictionary Services for automatic phrase selection and
an anchored system popup. Build its native module after installing or updating
Emacs:

```sh
scripts/build-macos-module.sh
```

The script uses `emacs` from `PATH`. Override it with `EMACS`, the header path
with `EMACS_INCLUDE_DIR`, or the destination with
`REFERENCE_EXPLORER_MODULE_DIRECTORY`.

### Dictionaries by Monokakido

The Monokakido provider opens the application's URL scheme. Optional settings
are:

- `reference-explorer-provider-monokakido-category`
- `reference-explorer-provider-monokakido-scope`

### Thesaurus

`reference-explorer-ui-thesaurus-at-point` retrieves synonyms from [Power
Thesaurus](https://www.powerthesaurus.org/) and replaces the active region or
phrase. Results are cached; navigation and local Lookup previews make no
additional request. Use is subject to the [Power Thesaurus Terms and
Conditions](https://www.powerthesaurus.org/_terms_conditions).

Set `reference-explorer-source-lookup-thesaurus-preview-sources` to prioritize
local preview dictionaries. Embark adds replacement, Lookup, copy, and new
synonym-search actions when available.

```elisp
(setq reference-explorer-source-lookup-thesaurus-preview-sources
      '("English dictionary" "Fallback dictionary"))
```

## Key bindings

Reference Explorer installs no global bindings. Bind the common dispatcher or
individual interfaces with the normal Emacs keymap functions, for example:

```elisp
(keymap-global-set "H-." #'reference-explorer-at-point)
(keymap-global-set "H-q"
                   #'reference-explorer-source-lookup-quick-lookup-at-point)
(keymap-global-set "H-M-q"
                   #'reference-explorer-source-lookup-consult-at-point)
(keymap-global-set "H-t" #'reference-explorer-ui-thesaurus-at-point)
```

During the quick selector, `H-n` and `H-p` move, `H-s` and `H-e` change phrase
length, `TAB` accepts, `M-m` opens Consult, and `H-q` or `C-g` quits. Consult
uses the same phrase and preview keys; `M-m` toggles literal and converted
input. The active quick selector displays these bindings in its help text.

The session maps are ordinary keymaps and can be changed after the owning
feature loads:

```elisp
(with-eval-after-load 'reference-explorer-ui
  (keymap-set reference-explorer-ui-quick-map
              "C-n" #'reference-explorer-ui-quick-next)
  (keymap-set reference-explorer-ui-consult-map
              "C-c s" #'reference-explorer-ui-consult-shorten-query))
```

Other customizable maps are
`reference-explorer-ui-preview-interaction-mode-map`,
`reference-explorer-source-lookup-embark-map`,
`reference-explorer-source-lookup-export-mode-map`,
`reference-explorer-ui-docset-embark-map`, and
`reference-explorer-ui-thesaurus-embark-map`.

## Phrase selection

`reference-explorer-query-segment-backends` is an ordered list of pluggable
phrase selectors. The bundled MeCab backend handles Japanese compounds, and
the Emacs backend is the fallback. MeCab initially selects the shortest
candidate of at least two characters while retaining longer candidates for
expansion. Change the minimum with
`reference-explorer-query-segment-mecab-initial-minimum-length`.

Converted input uses `reference-explorer-ui-query-conversion-function`; its
default converts romanized Japanese to hiragana. The optional
`reference-explorer-ui-migemo` module supplies Migemo and Orderless filtering
when both are already configured:

```elisp
(require 'reference-explorer-ui-migemo)
```

## Development

Core dispatch lives in `reference-explorer.el`, shared interaction in
`reference-explorer-ui.el`, and integrations in the role-named `source-*` and
`provider-*` files.

Run the test suite with:

```sh
make test
```

Reference Explorer is distributed under the MIT License.
