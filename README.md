# Reference Explorer

Reference Explorer is a provider-based dictionary and documentation browser
for Emacs. It integrates Lookup for Emacs, macOS Dictionary, Dictionaries by
Monokakido, Dash-compatible docsets, and an online thesaurus.

## Installation

With Emacs 29 or later, install the repository through `package-vc`:

```elisp
(package-vc-install
 '(reference-explorer
   :url "https://github.com/matoi/emacs-reference-explorer"
   :main-file "reference-explorer.el"))
(require 'reference-explorer-source-lookup)
```

Integrations with [Lookup for Emacs](http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup),
[Consult](https://github.com/minad/consult),
[Embark](https://github.com/oantolin/embark),
[Vertico](https://github.com/minad/vertico), and
[Popper](https://github.com/karthink/popper) are optional.

When [Lookup for Emacs](http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup),
[EBLook](http://green.ribbon.to/~ikazuhiro/lookup/lookup.html#EBLOOK), and
[MeCab](https://taku910.github.io/mecab/) are installed through Homebrew,
configure their paths and select Lookup's MeCab backend before loading the UI:

```elisp
(require 'reference-explorer-source-lookup-homebrew)
(reference-explorer-source-lookup-homebrew-configure)
(require 'reference-explorer-source-lookup)
```

The helper is not loaded automatically. Other installations can put Lookup for
Emacs on `load-path` and configure it directly. Reference Explorer disables
Lookup's splash screen; backends and per-dictionary `:stemmer` options remain
user configuration.

## Architecture

`reference-explorer.el` provides dispatch, `reference-explorer-ui.el` provides
the shared UI, and the `provider-*` and `source-*` files contain optional
integrations. Configure dispatch order with
`reference-explorer-ui-provider-order`; the macOS default is docset, system
Dictionary, then Lookup.

## Lookup interfaces

`reference-explorer-source-lookup-quick-lookup-at-point` opens the compact
graphical selector, while `reference-explorer-source-lookup-consult-at-point`
opens Consult. `H-n` and
`H-p` move through results, `H-s` and `H-e` change phrase length, `TAB` accepts,
and `M-m` transfers to Consult or toggles converted input.

Results are ranked by match type and
`reference-explorer-source-lookup-source-order`. Selection previews entries in
a child frame. Embark provides display, copy, and export actions. Configure
committed-buffer display with `reference-explorer-ui-display-buffer-function`.

## Providers

The macOS provider uses Dictionary Services for automatic phrase selection and
an anchored system popup. Build its native module after installing or updating
Emacs:

```sh
scripts/build-macos-module.sh
```

The script uses `emacs` from `PATH`. Override it with `EMACS`, the header path
with `EMACS_INCLUDE_DIR`, or the destination with
`REFERENCE_EXPLORER_MODULE_DIRECTORY`.

The Monokakido provider opens its Dictionaries URL scheme. Configure optional
restrictions with
`reference-explorer-provider-monokakido-category` and
`reference-explorer-provider-monokakido-scope`.

## Docsets

The local backend reads the format described in the [Dash Docset Generation
Guide](https://kapeli.com/docsets), searches SQLite indexes, and renders matched
entries with WebKit or SHR. It supports latest, exact, and version-series
selectors.

The manager uses Kapeli's [Dash docset feeds](https://github.com/Kapeli/feeds)
by default. Review that repository's usage notice and each documentation
source's license before installing a docset.

Install or update docsets described by a manifest with:

```sh
scripts/manage-docsets.sh ensure MANIFEST
scripts/manage-docsets.sh update MANIFEST
```

## Thesaurus

`reference-explorer-ui-thesaurus-at-point` retrieves synonyms from [Power
Thesaurus](https://www.powerthesaurus.org/) and replaces the active region or
phrase. Results are cached; navigation and local Lookup previews make no
additional request. Use is subject to the [Power Thesaurus Terms and
Conditions](https://www.powerthesaurus.org/_terms_conditions).

Set `reference-explorer-source-lookup-thesaurus-preview-sources` to prioritize
local preview dictionaries. Embark provides replacement, Lookup, copy, and new
synonym-search actions.

## Phrase selection

`reference-explorer-query-segment-backends` is an ordered list of pluggable
phrase selectors. The bundled MeCab backend handles Japanese compounds, and
the Emacs backend is the fallback. MeCab initially selects the shortest
candidate of at least two characters while retaining longer candidates for
expansion. Change the minimum with
`reference-explorer-query-segment-mecab-initial-minimum-length`.

Converted mode uses `reference-explorer-ui-query-conversion-function`; its
default converts romanized Japanese to hiragana. The optional
`reference-explorer-ui-migemo` module supplies Migemo and Orderless filtering
when both are already configured. Load it explicitly:

```elisp
(require 'reference-explorer-ui-migemo)
```

## Development

Run the test suite with:

```sh
make test
```

Reference Explorer is distributed under the MIT License.
