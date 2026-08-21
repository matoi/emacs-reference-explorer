# Reference Explorer

## Overview

Reference Explorer is a dictionary and documentation browser for Emacs. It
integrates Lookup for Emacs, Dash-compatible docsets, macOS Dictionary,
Dictionaries by Monokakido, and an online thesaurus.

Every search integration is a source. A source may return candidates for the
shared UI or delegate the complete search to an external application. Configure
the dispatch order with `reference-explorer-source-rules`. The macOS default is
`docset`, `macos-dictionary`, then `lookup`.

## Installation

Install with Emacs 29 or later through `package-vc`:

```elisp
(package-vc-install
 '(reference-explorer
   :url "https://github.com/matoi/emacs-reference-explorer"
   :main-file "reference-explorer.el"))
(require 'reference-explorer)
```

Integrations with [Consult](https://github.com/minad/consult),
[Embark](https://github.com/oantolin/embark),
[Vertico](https://github.com/minad/vertico), and
[Popper](https://github.com/karthink/popper) are optional.

## Sources

- `lookup`: EPWING and EBXA dictionaries through Lookup for Emacs.
- `docset`: Dash-compatible documentation bundles.
- `macos-dictionary`: the macOS Dictionary popup.
- `monokakido`: Dictionaries by Monokakido through its URL scheme.
- `thesaurus`: Power Thesaurus results used by the replacement command.

All five use the same registry. A source need not appear in the default
dispatcher rule; `monokakido` and `thesaurus` are registered but omitted by
default.

### Adding a source

A search passes through four stages:

1. A phrase selector obtains text from the buffer or region.
2. The source's optional converter turns that phrase into its query.
3. The source searches and reports a status-bearing outcome.
4. A source-specific or shared presenter displays the result.

Register a source with `reference-explorer-register-source`. Its search
function receives `QUERY`, `CONTEXT`, and `COMPLETE`. It calls `COMPLETE` with
a `reference-explorer-search-outcome` whose status is `matched`, `no-match`,
`delegated`, `unavailable`, or `failed`. Callbacks support both local and
asynchronous searches.

```elisp
(require 'reference-explorer-source)

(defun my-glossary-search (query _context complete)
  (let ((entries (my-glossary-find query)))
    (funcall complete
             (reference-explorer-search-outcome-create
              :status (if entries 'matched 'no-match)
              :entries entries))))

(defun my-glossary-render (entry buffer-name)
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (my-glossary-body entry))
        (special-mode)))
    buffer))

(reference-explorer-register-source
 'my-glossary
 :title "My glossary"
 :search #'my-glossary-search
 :label #'my-glossary-heading
 :annotation (lambda (_entry _context) "local")
 :render #'my-glossary-render
 :available-p (lambda (_context) t))
```

Matched entries are wrapped as source-owned results before reaching the shared
candidate UI. `:label` and `:annotation` describe candidates, optional `:fetch`
retrieves one selected entry's full content, and `:render` displays it. Use
`:convert` for source-specific query conversion and `:present` when a source
needs its own presentation flow.

A delegating source performs its external action in `:search`, reports
`delegated`, and does not need candidate or rendering functions. The macOS and
Monokakido sources follow this form. `delegated` means the query was handed off;
it does not claim that the external application found a match.

### Dispatch order and fallback

Each rule associates a major mode with an ordered source chain. For one
chain in every mode, set only the catch-all rule:

```elisp
(setq reference-explorer-source-rules
      '((t . (docset macos-dictionary lookup))))
```

`reference-explorer-at-point` tries sources from left to right. With a
prefix argument it prompts for one source instead. Put mode-specific rules
before the catch-all rule:

```elisp
(setq reference-explorer-source-rules
      '((emacs-lisp-mode . (docset lookup))
        (text-mode . (macos-dictionary lookup))
        (t . (lookup))))
```

The first rule whose mode is an ancestor of the originating major mode wins.
If no rule matches, no source is configured, so normally keep the `t` rule
last. By default, dispatch advances only when a source is unavailable. To
also continue after source errors, use:

```elisp
(setq reference-explorer-fallback-conditions '(unavailable error))
```

An available source that completes with no matches does not fall through.
Ordering within a source is configured in the sections below.

### Lookup for Emacs

This optional source searches locally installed EPWING and EBXA dictionaries
through [Lookup for Emacs](http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup)
and [EBLook](http://green.ribbon.to/~ikazuhiro/lookup/lookup.html#EBLOOK).

On macOS, install Lookup for Emacs from the
[Homebrew tap](https://github.com/matoi/homebrew-tap). The formula also
installs EBLook and the EB Library; install
[MeCab](https://taku910.github.io/mecab/) for Japanese phrase selection:

```sh
brew install matoi/tap/emacs-lookup mecab
```

Then configure the Homebrew paths before loading the source:

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

[Dash](https://kapeli.com/dash) is a macOS application for browsing offline API
documentation. It stores each documentation collection as a docset: a bundle
of pages and a searchable index. Reference Explorer reads the format described
in the [Dash Docset Generation Guide](https://kapeli.com/docsets), searches its
SQLite indexes, and renders entries with WebKit or SHR. Dash itself is not
required.

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

The macOS source uses Dictionary Services for automatic phrase selection and
an anchored system popup. On graphical macOS, loading Reference Explorer
asynchronously builds or updates its native module when necessary. The check
tracks the module source, Emacs version, architecture, and macOS SDK.

Run the same check manually with:

```elisp
(reference-explorer-source-macos-install-module)
```

Set `reference-explorer-source-macos-auto-build` to nil for an externally
managed module. Build failures remain in
`*Reference Explorer macOS module build*`. The underlying script can also be
run directly; it accepts `EMACS`, `EMACS_INCLUDE_DIR`, and
`REFERENCE_EXPLORER_MODULE_DIRECTORY` overrides.

### Dictionaries by Monokakido

[Dictionaries by Monokakido](https://www.monokakido.jp/ja/dictionaries/) is a
dictionary application for macOS, iPhone, and iPad that manages and searches
multiple dictionary titles. The source opens its URL scheme. Optional
settings are:

- `reference-explorer-source-monokakido-category`
- `reference-explorer-source-monokakido-scope`

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

## Phrase selection and conversion

`reference-explorer-phrase-segmenters` is an ordered list of pluggable
segmenter functions. Each receives a
`reference-explorer-phrase-segmenter-context` and returns candidates plus its
preferred initial candidate in a `reference-explorer-phrase-segmenter-result`.
The bundled MeCab segmenter handles Japanese compounds, and the Emacs
segmenter is the fallback. MeCab initially selects the shortest
candidate of at least two characters while retaining longer candidates for
expansion. Change the minimum with
`reference-explorer-phrase-segmenter-mecab-initial-minimum-length`.

Mode-specific context adapters are independently pluggable through
`reference-explorer-phrase-segmenter-context-functions`. The bundled Org
adapter restricts segmentation to a link's visible description.

The selected text is stored separately from the source query. A source can set
`:convert` to normalize, stem, or otherwise transform it without changing the
original phrase. Interactive Consult conversion remains controlled by
`reference-explorer-ui-query-conversion-function`.

Its default converts romanized Japanese to hiragana. The optional
`reference-explorer-ui-migemo` module supplies Migemo and Orderless filtering
when both are already configured:

```elisp
(require 'reference-explorer-ui-migemo)
```

## Development

`reference-explorer.el` is the package entry point. Core dispatch lives in
`reference-explorer-core.el`, the source protocol in
`reference-explorer-source.el`, shared interaction in
`reference-explorer-ui.el`, phrase selection in the
`reference-explorer-phrase-segmenter*.el` files, and integrations in the
`source-*` files.

Run the test suite with:

```sh
make test
```

Reference Explorer is distributed under the MIT License.
