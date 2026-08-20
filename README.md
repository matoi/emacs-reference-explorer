# Reference Explorer

Reference Explorer is a provider-based reference and dictionary lookup package
for Emacs. It includes providers for the macOS Dictionary popup and
Dictionaries by Monokakido, a Dash-compatible docset backend and manager, and
an asynchronous thesaurus backend.

The package owns retrieval, provider dispatch, Quick and Consult selection,
preview child frames, Lookup for Emacs integration, Embark actions, and thesaurus
and docset presentation. Optional integrations activate when their libraries
are available.

## Installation

With Emacs 29 or later, install the repository through `package-vc`:

```elisp
(package-vc-install
 '(reference-explorer
   :url "https://github.com/matoi/emacs-reference-explorer"
   :main-file "reference-explorer.el"))
(require 'reference-explorer-source-lookup)
```

Lookup for Emacs, Consult, Embark, Vertico, and Popper integrations are optional.
The core provider dispatcher, docset backend, Monokakido provider, and
thesaurus backend use Emacs built-ins.

When Lookup for Emacs, EBLook, and MeCab are installed through Homebrew, configure
their paths and select Lookup's MeCab backend before loading the UI:

```elisp
(require 'reference-explorer-source-lookup-homebrew)
(reference-explorer-source-lookup-homebrew-configure)
(require 'reference-explorer-source-lookup)
```

This helper is never loaded automatically. Other package layouts can put GNU
Lookup on `load-path` and configure its native variables directly. Reference
Explorer disables Lookup's splash screen but does not otherwise select a
Lookup backend or add a stemmer globally. A stemmer can be set per dictionary
with Lookup's `:stemmer` dictionary option.

## Architecture

`reference-explorer.el` owns query context, provider registration, ordered
dispatch, and fallback. `reference-explorer-provider-macos.el` and
`reference-explorer-provider-monokakido.el` register reference providers with
that dispatcher. `reference-explorer-ui.el` owns source-independent query
selection, Quick and Consult sessions, child-frame previews, and interaction
state. `reference-explorer-source-lookup.el` owns only the Lookup search,
ranking, entry rendering, Lookup commands, and provider registration. Docset
retrieval and thesaurus retrieval remain in their respective source modules.

Provider order is controlled by `reference-explorer-ui-provider-order`.
On macOS the default order is docset, system Dictionary, then Lookup.
Monokakido remains available explicitly unless it is added to that order. A
provider falls through only when it signals that it is unavailable; an empty
result does not silently change providers.

## Lookup interfaces

`reference-explorer-source-lookup-quick-lookup-at-point` opens a compact graphical
selector for exact and prefix matches. `H-n` and `H-p` move through results,
`TAB` commits the selected entry, `M-m` transfers the current query to Consult,
and `H-s` and `H-e` select shorter and longer contextual phrases. The source
query is highlighted in its original buffer. A no-match selector remains open
so another contextual length can be tried; an unrelated key closes it and is
handled normally by the source buffer.

`reference-explorer-source-lookup-consult-at-point` starts the Consult interface with
the active region or phrase at point. Its `H-s` and `H-e` bindings use the same
contextual alternatives, while `M-m` switches between literal and converted
input. Exact matches precede partial matches. Within each group,
`reference-explorer-source-lookup-source-order` gives displayed dictionary titles an
explicit priority and preserves Lookup's order for unspecified sources.

Moving through either interface previews the current entry in a temporary
child frame. Sources listed in
`reference-explorer-source-lookup-preview-highlight-sources` highlight literal query
occurrences. Preview is suppressed when neither side of the selected row has
the configured usable width. A committed result is passed to
`reference-explorer-ui-display-buffer-function`, allowing a host to use
ordinary `display-buffer`, Popper, or another display policy.

Lookup entries have Embark actions for display and copying their complete
plain-text description. Embark export creates a persistent result buffer whose
selection continues to drive the same temporary preview.

## Providers

The macOS provider sends the surrounding visible text and UTF-8 point offset
to Dictionary Services for an automatic point lookup, allowing the system to
select a word or compound phrase. Explicit regions and edited queries remain
exact. Its popup is anchored at the selected term and uses the originating
Emacs glyph's font metrics. The next Emacs command dismisses the popup before
continuing.

The native module is loaded lazily from
`~/.emacs.d/site-lisp/reference-explorer/reference-explorer-provider-macos-module` plus
the platform module suffix. Build and install it after installing or updating
Emacs:

```sh
scripts/build-macos-module.sh
```

The script targets the `emacs` found on `PATH`. Set `EMACS` to another Emacs
executable when needed. It locates that Emacs's `emacs-module.h`; if the header
is installed separately, set `EMACS_INCLUDE_DIR` to its containing directory.
`REFERENCE_EXPLORER_MODULE_DIRECTORY` overrides the installation directory.

The Monokakido provider opens the Dictionaries URL scheme. Optional category
and scope restrictions are configured with
`reference-explorer-provider-monokakido-category` and
`reference-explorer-provider-monokakido-scope`.

## Docsets

The Dash-compatible backend discovers installed docsets, selects versions by
major mode, searches their SQLite indexes, and renders only the matched entry.
Selectors accept a latest version, an exact version, or a version series. The
manager resolves a selector to one concrete bundle before installation, so
equivalent selectors do not create duplicate contents.

Graphical previews use WebKit when available and fall back to SHR; committed
content and terminal Emacs use SHR. The renderer isolates the selected entry,
resolves aliases and anchors, and preserves local stylesheet assets for WebKit
previews.

Install or update docsets described by a manifest with:

```sh
scripts/manage-docsets.sh ensure MANIFEST
scripts/manage-docsets.sh update MANIFEST
```

## Thesaurus

`reference-explorer-ui-thesaurus-at-point` retrieves synonyms for the
active region or contextual phrase. Candidate movement previews definitions
through local Lookup and performs no additional online request. Configure
`reference-explorer-source-lookup-thesaurus-preview-sources` with displayed Lookup
dictionary titles to prioritize those previews; nil retains normal source
order.

Accepting a candidate replaces the captured source text while preserving
simple capitalization. Replacement is refused if the source changed during
the asynchronous request. Embark actions provide replacement, Lookup,
copying, and a new synonym search rooted at the selected term.

`reference-explorer-source-thesaurus.el` talks directly to PowerThesaurus rather than
loading the Emacs `powerthesaurus` package. An uncached search obtains the term
identifier and then its complete relation list. Completed results and term
identifiers are cached in memory, and concurrent identical searches share the
same pending requests. Incremental input, candidate movement, and previews do
not initiate network requests.

## Phrase selection

`reference-explorer-query-segment-backends` is an ordered list of phrase-bound
functions. The bundled MeCab backend selects Japanese words and compound
nouns; the Emacs backend provides the final ordinary word-boundary fallback.
A language-specific backend can be inserted before the fallback without
changing the reference UI. Each backend receives the visible position and an
optional visible-region restriction and returns candidate buffer bounds from
most useful to least useful.

Converted lookup mode applies `reference-explorer-ui-query-conversion-function`
to minibuffer input; its default converts romanized Japanese to hiragana with
Emacs's built-in Quail rules. The host environment supplies the matching
completion behavior through `reference-explorer-ui-converted-completion-style`.
The optional module below supplies one implementation backed by Migemo and
Orderless.

The optional `reference-explorer-ui-migemo` module extends the shared UI's
converted-input filtering. It is not a reference provider: unlike the macOS
and Monokakido modules, it attaches to `reference-explorer-ui`. It assumes the
host has already configured and loaded Migemo and Orderless. Loading it
defines `reference-explorer-ui-migemo-orderless` and selects that as the
converted-mode completion style. Nothing loads this module automatically:

```elisp
(require 'reference-explorer-ui-migemo)
```

## Development

Run the test suite with:

```sh
make test
```

Reference Explorer is distributed under the MIT License.
