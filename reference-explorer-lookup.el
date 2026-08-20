;;; reference-explorer-lookup.el --- UI backed by Lookup for Emacs -*- lexical-binding: t -*-

;;; Commentary:

;; This module connects Reference Explorer to the external Lookup for Emacs
;; package (the library and feature named `lookup').  Lookup for Emacs is not
;; bundled with Reference Explorer or Emacs.  It owns dictionary agents,
;; searches, entry objects, and entry rendering; this module adds Quick and
;; Consult selectors, child-frame previews, Embark actions, and integration
;; with Reference Explorer providers.  Its primary use here is searching
;; locally installed EPWING and EBXA dictionary data through Lookup's `ndeb'
;; agent and the external EBLook program.
;;
;; The tested distribution is Lookup 1.4+media, published from:
;;
;;   http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup
;;
;; On Homebrew systems it and EBLook can be installed with:
;;
;;   brew install matoi/tap/emacs-lookup
;;
;; Then configure its Lisp and executable paths before loading this module:
;;
;;   (require 'reference-explorer-lookup-homebrew)
;;   (reference-explorer-lookup-homebrew-configure)
;;   (require 'reference-explorer-lookup)
;;
;; For another Lookup installation, put its Lisp directory on `load-path' and
;; configure its native variables such as `lookup-search-agents',
;; `lookup-search-modules', and `lookup-dictionary-options-alist' before
;; loading this module.  Dictionary files and search-agent configuration are
;; deliberately not owned by Reference Explorer.
;;
;; This file remains loadable when Lookup for Emacs is absent.  In that case
;; Lookup-backed commands report that Lookup is unavailable, while docset,
;; thesaurus, macOS Dictionary, and Monokakido functionality can still be used.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer)
(require 'reference-explorer-segmentation)
(require 'reference-explorer-docset)
(require 'reference-explorer-thesaurus)
(require 'reference-explorer-monokakido)
(when (eq system-type 'darwin)
  (require 'reference-explorer-macos))
(require 'seq)
(require 'subr-x)

(declare-function nerd-icons-corfu-formatter "nerd-icons-corfu" (metadata))
(defvar completion-extra-properties)

(autoload 'reference-explorer-docset-manager-install "reference-explorer-docset-manager"
  "Install a version-selected docset." t)
(autoload 'reference-explorer-docset-manager-update "reference-explorer-docset-manager"
  "Update a version-selected docset." t)
(autoload 'reference-explorer-docset-manager-list-versions "reference-explorer-docset-manager"
  "List versions published by a docset feed." t)

(defgroup reference-explorer-lookup nil
  "Shared reference and dictionary lookup behavior."
  :group 'applications)

(defcustom reference-explorer-lookup-query-function
  #'reference-explorer-segmentation-word-at-point
  "Function returning the textual reference query at point."
  :type 'function
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-origin-position-function
  #'reference-explorer-segmentation-visible-position-at-point
  "Function returning the visible buffer position used to anchor reference UI."
  :type 'function
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-word-candidates-function
  #'reference-explorer-segmentation-word-candidates-at-point
  "Function returning contextual query candidates around point."
  :type 'function
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-word-bound-candidates-function
  #'reference-explorer-segmentation-word-bound-candidates-at-point
  "Function returning contextual query bounds around point."
  :type 'function
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-display-buffer-function #'display-buffer
  "Function used to display a committed dictionary entry buffer."
  :type 'function
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-converted-completion-style nil
  "Completion style used by converted-mode Consult lookup.
The host configuration owns completion setup and should set this to the style
that corresponds to its query conversion.  Nil disables converted mode."
  :type '(choice (const :tag "Disabled" nil) symbol)
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-query-conversion-function
  #'reference-explorer-lookup--roman-to-hiragana
  "Function used to transform input in converted search mode.
It receives the minibuffer input string and returns the backend query string."
  :type 'function
  :group 'reference-explorer-lookup)

(defun reference-explorer-lookup-query-at-point ()
  "Return the configured reference query at point."
  (funcall reference-explorer-lookup-query-function))

(defun reference-explorer-lookup-origin-position-at-point ()
  "Return the visible origin position used to anchor reference UI."
  (funcall reference-explorer-lookup-origin-position-function))

(defun reference-explorer-lookup-word-candidates-at-point ()
  "Return contextual query candidates around point."
  (funcall reference-explorer-lookup-word-candidates-function))

(defun reference-explorer-lookup-word-bound-candidates-at-point ()
  "Return contextual query bounds around point."
  (funcall reference-explorer-lookup-word-bound-candidates-function))

(defun reference-explorer-lookup--set-provider-order (symbol value)
  "Set customization SYMBOL to VALUE and update Reference Explorer rules."
  (set-default symbol value)
  (setq reference-explorer-provider-rules `((t . ,value))))

(defcustom reference-explorer-lookup-provider-order
  (if (eq system-type 'darwin)
      '(docset macos-dictionary lookup)
    '(lookup))
  "Provider order used by `reference-explorer-at-point'.
The default macOS chain searches a docset configured for the originating
major mode, then uses the system Dictionary popup, then GNU Lookup.  Adding
`monokakido' at the front makes the global H-. command open Dictionaries by
Monokakido first.  A provider not listed here remains available to explicit
commands and actions."
  :type '(repeat symbol)
  :set #'reference-explorer-lookup--set-provider-order
  :group 'reference-explorer-lookup)

(setq reference-explorer-query-function
      #'reference-explorer-lookup-query-at-point
      reference-explorer-origin-position-function
      #'reference-explorer-lookup-origin-position-at-point
      reference-explorer-provider-rules
      `((t . ,reference-explorer-lookup-provider-order)))

(defcustom reference-explorer-lookup-content-font-family nil
  "Font family used for Lookup content in graphical sessions.
The setting is ignored when the family is unavailable."
  :type '(choice (const :tag "Default font" nil) string)
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-consult-mode 'literal
  "Search mode used by the next blank Lookup invocation.
`literal' searches the input as written.  `converted' transforms it with
`reference-explorer-lookup-query-conversion-function' and filters headings with
`reference-explorer-lookup-converted-completion-style'.  The value is saved by
Savehist and updated when M-m switches mode in the Lookup minibuffer."
  :type '(choice (const literal) (const converted))
  :group 'reference-explorer-lookup)

;; Migrate the value previously persisted by Savehist under the old name.
(when (eq reference-explorer-lookup-consult-mode 'reading)
  (setq reference-explorer-lookup-consult-mode 'converted))

(defcustom reference-explorer-lookup-search-debounce 0.15
  "Seconds to debounce dynamic Lookup entry searches."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-quick-max-candidates 8
  "Maximum number of candidates shown by quick Lookup."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-quick-max-width 60
  "Maximum width in columns of the quick Lookup candidate list."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-source-order nil
  "Dictionary source order used within each Lookup match class.
Each string is a dictionary title as shown beside a Consult candidate.  Sources
not listed here follow the listed sources in Lookup's original order.  Exact
matches are sorted by this order first, followed by partial matches sorted by
the same order."
  :type '(repeat string)
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-heading-filter-functions nil
  "Functions applied to each Lookup entry heading before display cleanup.
Each function receives ENTRY and the current rich HEADING string, and must
return the heading passed to the next function.  This is intended for local,
dictionary-specific corrections; common whitespace and text-property cleanup
is performed afterward."
  :type 'hook
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-highlight-sources nil
  "Dictionary source titles whose preview content highlights the query.
Titles are compared with the displayed source name returned by Lookup.  An
empty list disables query highlighting for every source."
  :type '(repeat string)
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-thesaurus-preview-sources nil
  "Ordered Lookup dictionary sources used for thesaurus previews.
Each string is a displayed dictionary title.  The first source with a matching
entry is used.  Nil keeps the normal Lookup result order across all selected
dictionaries.  A non-nil list with no matching entry suppresses the preview."
  :type '(repeat string)
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-debounce 0.25
  "Seconds to wait before previewing the selected Lookup entry."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-max-width 80
  "Maximum width in columns of the temporary Lookup preview."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-min-width 20
  "Minimum usable width in columns of the temporary Lookup preview.
No preview is shown when neither side of the selected candidate has this much
space."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-preview-max-width 100
  "Maximum width in columns of a temporary docset article preview."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-preview-min-width 64
  "Minimum displayed width in columns of a docset article preview.
Unlike a short dictionary definition, a documentation article becomes hard to
read when its child frame is fitted tightly to a short heading."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-preview-max-height 28
  "Maximum height in lines of a temporary docset article preview."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-preview-renderer 'webkit
  "Renderer used for temporary graphical docset previews.
`webkit' renders the isolated entry with its original stylesheets.  It falls
back to `shr' when this Emacs lacks xwidget support or WebKit setup fails.
Committed Popper content and terminal Emacs always use `shr'."
  :type '(choice (const :tag "WebKit with SHR fallback" webkit)
                 (const :tag "SHR" shr))
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-webkit-font-size 14
  "Root font size in pixels of a temporary WebKit docset preview.
The docset stylesheet may scale headings and code relative to this value."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-webkit-preview-width 760
  "Preferred width in pixels of a temporary WebKit docset preview."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-webkit-preview-min-width 480
  "Minimum usable width in pixels of a WebKit docset preview."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-docset-webkit-preview-height 520
  "Preferred height in pixels of a temporary WebKit docset preview.
The frame is clamped to the available height of its parent frame."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-font-height 0.9
  "Font height of temporary Lookup previews relative to the default face."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-width-slack 2
  "Extra character widths reserved beyond measured preview text."
  :type 'integer
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-quick-left-margin-width 0.5
  "Width of the quick candidate list's left margin, in columns."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-quick-right-margin-width 0.5
  "Width of the quick candidate list's right margin, in columns."
  :type 'number
  :group 'reference-explorer-lookup)

(defcustom reference-explorer-lookup-preview-margin-width 1
  "Window margin on each side of temporary reference previews, in columns."
  :type 'integer
  :group 'reference-explorer-lookup)

(defconst reference-explorer-lookup-content-buffer-name "*Lookup Content*"
  "Buffer used for committed Lookup content.")

(defconst reference-explorer-lookup-docset-content-buffer-name "*Docset Reference*"
  "Buffer used for committed docset content.")

(defconst reference-explorer-lookup-preview-buffer-name " *Lookup Preview*"
  "Base name for hidden buffers used by temporary Lookup previews.")

(defconst reference-explorer-lookup--preview-horizontal-overhead 2
  "Child-frame pixels outside the preview's horizontal body.")

(defconst reference-explorer-lookup--preview-vertical-overhead 2
  "Child-frame pixels outside the preview's measured vertical body.")

(defconst reference-explorer-lookup--preview-border-width 1
  "Internal border width of a temporary preview frame in pixels.")

(cl-defstruct (reference-explorer-lookup--preview
               (:constructor reference-explorer-lookup--make-preview
                             (frame buffer &optional entry)))
  "Resources owned by one temporary Lookup preview."
  frame
  buffer
  entry)

(cl-defstruct (reference-explorer-lookup--quick-session
               (:constructor reference-explorer-lookup--make-quick-session))
  "Resources and selection state owned by one quick Lookup invocation."
  query
  query-options
  query-index
  entries
  index
  source-window
  source-marker
  source-bounds
  source-overlay
  list-frame
  list-buffer
  list-offset
  preview
  preview-timer
  accept-function
  consult-function
  help
  exit-function)

(cl-defstruct (reference-explorer-lookup--thesaurus-candidate
               (:constructor reference-explorer-lookup--make-thesaurus-candidate))
  "A thesaurus RESULT and the source range it may replace."
  result
  buffer
  beginning
  end
  original)

(defvar reference-explorer-lookup-history nil
  "Minibuffer history for Consult Lookup queries.")

(defvar reference-explorer-lookup--entry-cache (make-hash-table :test #'equal)
  "Lookup entries cached by search mode and backend query.")

(defvar reference-explorer-lookup--roman-rules nil
  "Normalized copy of Emacs's standard Roman-to-kana rules.")

(defvar reference-explorer-lookup--consult-toggle-tag nil)
(defvar reference-explorer-lookup--active-consult-mode nil)
(defvar reference-explorer-lookup--consult-origin nil)
(defvar reference-explorer-lookup--consult-query-options nil)
(defvar reference-explorer-lookup--consult-query-index nil)
(defvar reference-explorer-lookup--quick-session nil)
(defvar reference-explorer-lookup--active-temporary-preview nil
  "Most recently displayed temporary reference preview.")
(defvar reference-explorer-lookup--preview-interaction nil
  "WebKit preview currently promoted for direct user interaction.")
(defvar reference-explorer-lookup--preview-interaction-origin-window nil
  "Window to restore after direct WebKit preview interaction.")
(defvar reference-explorer-lookup--preview-interaction-request nil
  "Preview a Consult state function must retain while its minibuffer exits.")
(defvar reference-explorer-lookup--docset-webkit-warning-shown nil
  "Non-nil after warning once about a WebKit docset preview failure.")
(defvar reference-explorer-lookup--docset-webkit-preview-caches
  (make-hash-table :test #'eq)
  "Reusable WebKit previews keyed by their parent graphical frame.")
(defvar-local reference-explorer-lookup--docset-preview-file nil
  "Temporary HTML file owned by the current WebKit preview buffer.")
(defvar-local reference-explorer-lookup--docset-preview-obsolete-files nil
  "Superseded HTML files awaiting a WebKit `load-finished' event.")
(defvar-local reference-explorer-lookup--docset-preview-file-cleanup-timer nil
  "Fallback timer that deletes HTML from superseded WebKit navigations.")
(defvar-local reference-explorer-lookup--export-preview-timer nil)
(defvar-local reference-explorer-lookup--export-preview nil)
(defvar-local reference-explorer-lookup--export-preview-entry nil)
(defvar quail-japanese-transliteration-rules)
(defvar vertico--candidates-ov)

(defvar lookup-dictionary-options-alist)
(defvar lookup-enable-splash)
(defvar xwidget-view-list)
(defvar xwidget-webkit--loading-p)
(defvar xwidget-webkit-buffer-name-format)
(defvar lookup-search-agents)
(defvar lookup-search-modules)
(defvar lookup-content-buffer)
(defvar lookup-content-current-entry)
(defvar lookup-content-line-heading)
(defvar lookup-enable-format)
(defvar completion-category-overrides)
(defvar savehist-additional-variables)
(eval-when-compile
  ;; These are configured only after Embark has loaded.  Keeping the
  ;; declarations compile-time-only avoids pre-binding Embark's defcustoms to
  ;; nil when this module happens to load first.
  (defvar embark-default-action-overrides)
  (defvar embark-exporters-alist)
  (defvar embark-general-map)
  (defvar embark-keymap-alist)
  (defvar embark-target-finders))
(declare-function consult--dynamic-collection "consult" (fun &rest options))
(declare-function consult--lookup-candidate "consult" (selected candidates &rest args))
(declare-function consult--read "consult" (table &rest options))
(declare-function consult--tofu-append "consult" (candidate id))
(declare-function display-buffer-in-child-frame "window" (buffer alist))
(declare-function lookup-content-mode "lookup-content" ())
(declare-function lookup-dictionary-methods "lookup-types" (dictionary))
(declare-function lookup-dictionary-selected-p "lookup-types" (dictionary))
(declare-function lookup-dictionary-title "lookup-types" (dictionary))
(declare-function lookup-entry-dictionary "lookup-types" (entry))
(declare-function lookup-entry-compare "lookup-types" (entry-1 entry-2))
(declare-function lookup-entry-heading "lookup-types" (entry))
(declare-function lookup-initialize "lookup" (&optional force))
(declare-function lookup-make-query "lookup-types" (method string))
(declare-function lookup-module-dictionaries "lookup-types" (module))
(declare-function lookup-module-setup "lookup-types" (module))
(declare-function lookup-default-module "lookup" ())
(declare-function lookup-reference-p "lookup-types" (entry))
(declare-function lookup-vse-insert-content "lookup-vse" (entry))
(declare-function lookup-vse-search-query "lookup-vse" (dictionary query))
(declare-function vertico-exit "vertico" (&optional arg))

(defvar reference-explorer-lookup-embark-map (make-sparse-keymap)
  "Embark actions for Lookup entries.")

(defvar reference-explorer-lookup-thesaurus-embark-map (make-sparse-keymap)
  "Embark actions for thesaurus candidates.")

(defvar reference-explorer-lookup-docset-embark-map (make-sparse-keymap)
  "Embark actions for docset candidates.")

(defface reference-explorer-lookup-preview
  '((t :inherit default))
  "Face used by the temporary Lookup preview child frame."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-preview-border
  '((((background dark)) :background "#505050")
    (((background light)) :background "#c8c8c8")
    (t :background "gray"))
  "Face used for the temporary Lookup preview border."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-quick-current
  '((t :inherit highlight :extend t))
  "Face used for the selected quick Lookup candidate."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-quick-default
  '((t :inherit reference-explorer-lookup-preview))
  "Face used for the quick Lookup candidate list."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-quick-source
  '((t :inherit shadow))
  "Face used for dictionary names in quick Lookup candidates."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-source-highlight
  '((t :inherit match))
  "Face used for the source text selected by quick Lookup."
  :group 'reference-explorer-lookup)

(defface reference-explorer-lookup-preview-match
  '((t :inherit match))
  "Face used for the active search term in Lookup previews."
  :group 'reference-explorer-lookup)

;; Query conversion

(defun reference-explorer-lookup--roman-rule-table ()
  "Return Emacs's standard Roman-to-kana transliteration rules."
  (or reference-explorer-lookup--roman-rules
      (progn
        (unless (boundp 'quail-japanese-transliteration-rules)
          (load "quail/japanese" nil t))
        (unless (boundp 'quail-japanese-transliteration-rules)
          (error "Emacs Japanese transliteration rules are unavailable"))
        (setq reference-explorer-lookup--roman-rules
              (cl-loop
               for (roman translation) in quail-japanese-transliteration-rules
               when (or (stringp translation) (vectorp translation))
               collect
               (cons roman
                     (if (vectorp translation)
                         (aref translation 0)
                       translation)))))))

(defun reference-explorer-lookup--roman-rule-prefix-p (string rules)
  "Return non-nil when STRING is an unfinished key in RULES."
  (seq-some (lambda (rule)
              (and (> (length (car rule)) (length string))
                   (string-prefix-p string (car rule))))
            rules))

(defun reference-explorer-lookup--roman-to-hiragana (input)
  "Convert Roman INPUT to hiragana with Emacs's Japanese input rules.
An unfinished trailing syllable is omitted so incremental Lookup can keep
using the last complete reading.  A final n is treated as ん for searching."
  (let* ((input (downcase input))
         (rules (reference-explorer-lookup--roman-rule-table))
         (max-key-length
          (apply #'max (mapcar (lambda (rule) (length (car rule))) rules)))
         (index 0)
         parts)
    (while (< index (length input))
      (let* ((character (aref input index))
             (next (and (< (1+ index) (length input))
                        (aref input (1+ index))))
             (remaining (substring input index))
             match)
        (cond
         ((and (= character ?n)
               (or (null next)
                   (= next ?')
                   (not (memq next '(?a ?i ?u ?e ?o ?y)))))
          (push "ん" parts)
          (setq index (+ index (if (eq next ?') 2 1))))
         ((and next (= character next)
               (string-match-p "[bcdfghjklmpqrstvwxyz]"
                               (char-to-string character))
               (/= character ?n))
          (push "っ" parts)
          (setq index (1+ index)))
         (t
          (setq match
                (cl-loop
                 for length downfrom (min max-key-length
                                          (length remaining)) to 1
                 for key = (substring remaining 0 length)
                 when (assoc key rules)
                 return (assoc key rules)))
          (cond
           (match
            (push (cdr match) parts)
            (setq index (+ index (length (car match)))))
           ((reference-explorer-lookup--roman-rule-prefix-p remaining rules)
            (setq index (length input)))
           (t
            (push (char-to-string character) parts)
            (setq index (1+ index))))))))
    (japanese-hiragana (apply #'concat (nreverse parts)))))

(defun reference-explorer-lookup--backend-query (input mode)
  "Return the Lookup backend query for INPUT in MODE."
  (let* ((input (string-trim input))
         (query (if (eq mode 'converted)
                    (funcall reference-explorer-lookup-query-conversion-function
                             input)
                  input)))
    (unless (string-empty-p query)
      query)))

;; Entry collection and formatting

(defun reference-explorer-lookup--search-entries-with-method (input mode method)
  "Return Lookup entries for INPUT in MODE using search METHOD."
  (when-let ((backend-query
              (reference-explorer-lookup--backend-query input mode)))
    (let* ((cache-key (list mode method backend-query))
           (cached (gethash cache-key reference-explorer-lookup--entry-cache
                            'missing)))
      (cond
       ((eq cached :none) nil)
       ((not (eq cached 'missing)) cached)
       (t
        (when (> (hash-table-count reference-explorer-lookup--entry-cache) 256)
          (clrhash reference-explorer-lookup--entry-cache))
        (lookup-initialize)
        (let* ((module (lookup-default-module))
               (query (lookup-make-query method backend-query))
               entries)
          (lookup-module-setup module)
          (dolist (dictionary (lookup-module-dictionaries module))
            (when (and (lookup-dictionary-selected-p dictionary)
                       (memq method
                             (lookup-dictionary-methods dictionary)))
              (setq entries
                    ;; Lookup caches and returns the actual list spine.  Do
                    ;; not `nconc' it into a multi-dictionary result: that
                    ;; would join Lookup's cached lists and can eventually
                    ;; turn a repeated search into a circular list.
                    (append entries
                            (lookup-vse-search-query dictionary query)))))
          (puthash cache-key (or entries :none)
                   reference-explorer-lookup--entry-cache)
          entries))))))

(defun reference-explorer-lookup--ranked-entries (input mode partial-method)
  "Return ranked Lookup entries for INPUT and MODE.
Exact matches come first, followed by matches from PARTIAL-METHOD.  Both
groups are ordered by `reference-explorer-lookup-source-order'."
  (let* ((exact
          (reference-explorer-lookup--search-entries-with-method
           input mode 'exact))
         (partial
          (seq-remove
           (lambda (entry)
             (seq-some
              (lambda (exact-entry)
                (lookup-entry-compare entry exact-entry))
              exact))
           (reference-explorer-lookup--search-entries-with-method
            input mode partial-method)))
         (source-ranks
          (cl-loop for source in reference-explorer-lookup-source-order
                   for rank from 0
                   collect (cons source rank)))
         (unlisted-rank (length reference-explorer-lookup-source-order))
         (source-rank
          (lambda (entry)
            (or (cdr (assoc-string
                      (lookup-dictionary-title
                       (lookup-entry-dictionary entry))
                      source-ranks))
                unlisted-rank))))
    (append
     (cl-stable-sort (copy-sequence exact) #'< :key source-rank)
     (cl-stable-sort
      (copy-sequence partial) #'< :key source-rank))))

(defun reference-explorer-lookup--search-entries (input mode)
  "Return exact and substring Lookup entries for INPUT in MODE."
  (reference-explorer-lookup--ranked-entries input mode 'substring))

(defun reference-explorer-lookup--quick-search-entries (input)
  "Return exact and prefix Lookup entries for literal INPUT."
  (reference-explorer-lookup--ranked-entries input 'literal 'prefix))

(defun reference-explorer-lookup--quick-query-candidates-at-point ()
  "Return strictly shorter contextual queries around point.
Text-object candidates are longest-first.  Equal-length alternatives are
omitted so moving through this list always has clear expand/shrink semantics."
  (let ((maximum most-positive-fixnum)
        queries)
    (dolist (candidate
             (delete-dups
              (reference-explorer-lookup-word-candidates-at-point)))
      (let ((length (length candidate)))
        (when (and (not (string-empty-p (string-trim candidate)))
                   (< length maximum))
          (push candidate queries)
          (setq maximum length))))
    (nreverse queries)))

(defun reference-explorer-lookup--quick-query-options (queries)
  "Return quick Lookup options for QUERIES, including empty results.
Each result is a cons of the query string and its exact/prefix entries."
  (cl-loop for query in queries
           unless (string-empty-p (string-trim query))
           collect (cons query
                         (reference-explorer-lookup--quick-search-entries query))))

(defun reference-explorer-lookup--plain-entry-heading (entry)
  "Return ENTRY's heading without rich display properties or edge spaces."
  (let ((heading (lookup-entry-heading entry)))
    (dolist (filter reference-explorer-lookup-heading-filter-functions)
      (setq heading (funcall filter entry heading)))
    (string-trim (substring-no-properties heading)
                 "[ \t\n\r　]+" "[ \t\n\r　]+")))

(defun reference-explorer-lookup--entry-candidates (input mode)
  "Return Consult candidates for Lookup INPUT in MODE."
  (cl-loop for entry in (reference-explorer-lookup--search-entries input mode)
           for id from 0
           ;; Dictionary headings can contain raised glyphs and inline gaiji
           ;; images.  Completion rows should have uniform text metrics;
           ;; preserve those rich properties only in rendered content.
           for heading = (reference-explorer-lookup--plain-entry-heading entry)
           for candidate = (consult--tofu-append heading id)
           do (progn
                ;; Consult's tofu ID is already invisible, but some font and
                ;; completion-display combinations still render its private
                ;; Unicode character as a missing-glyph box.  An explicit
                ;; empty display keeps the duplicate-disambiguating suffix
                ;; while making its presentation unambiguous.
                (put-text-property (length heading) (length candidate)
                                   'display "" candidate)
                (put-text-property 0 (length heading)
                                   'consult--candidate entry candidate))
           collect candidate))

(defun reference-explorer-lookup--docset-candidates (input mode)
  "Return Consult candidates for docset INPUT in major MODE."
  (cl-loop for result in (reference-explorer-docset-search input mode)
           for id from 0
           for heading = (reference-explorer-docset-result-name result)
           for candidate = (consult--tofu-append heading id)
           do (progn
                (put-text-property (length heading) (length candidate)
                                   'display "" candidate)
                (put-text-property 0 (length heading)
                                   'consult--candidate result candidate))
           collect candidate))

(defun reference-explorer-lookup--docset-annotation (candidate &optional mode)
  "Return a compact kind annotation for docset CANDIDATE in MODE."
  (when-let ((result (reference-explorer-lookup-docset-candidate candidate)))
    (concat "  "
            (reference-explorer-lookup--candidate-annotation
             result
             (> (length (reference-explorer-docset-for-mode mode)) 1)))))

(defun reference-explorer-lookup-docset-candidate (candidate)
  "Return the docset result stored in CANDIDATE, or nil."
  (when (stringp candidate)
    (let ((value (or (get-text-property 0 'consult--candidate candidate)
                     (get-text-property 0 'reference-explorer-lookup-docset
                                        candidate))))
      (and (reference-explorer-docset-result-p value) value))))

(defun reference-explorer-lookup--entry-annotation (candidate)
  "Return the dictionary annotation for Lookup CANDIDATE."
  (when-let* ((entry (get-text-property 0 'consult--candidate candidate))
              (dictionary (lookup-entry-dictionary entry)))
    (concat "  " (lookup-dictionary-title dictionary))))

;; Temporary preview and committed Popper content

(defun reference-explorer-lookup-candidate-entry (candidate)
  "Return the Lookup entry stored in CANDIDATE, or nil."
  (and (stringp candidate)
       (or (get-text-property 0 'consult--candidate candidate)
           (let ((position
                  (next-single-property-change
                   0 'consult--candidate candidate (length candidate))))
             (and (< position (length candidate))
                  (get-text-property
                   position 'consult--candidate candidate))))))

(defun reference-explorer-lookup-entry-source (entry)
  "Return the displayed dictionary source name for Lookup ENTRY."
  (lookup-dictionary-title (lookup-entry-dictionary entry)))

(defun reference-explorer-lookup--candidate-label (candidate)
  "Return the visible label for reference CANDIDATE."
  (cond
   ((reference-explorer-lookup--thesaurus-candidate-p candidate)
    (reference-explorer-thesaurus-result-term
     (reference-explorer-lookup--thesaurus-candidate-result candidate)))
   ((reference-explorer-docset-result-p candidate)
    (reference-explorer-docset-result-name candidate))
   (t (reference-explorer-lookup--plain-entry-heading candidate))))

(defun reference-explorer-lookup--docset-kind-symbol (type)
  "Return normalized symbol for docset TYPE."
  (let ((name (downcase (or type "reference"))))
    ;; Dash feeds are not consistent about singular and plural kind names.
    (intern
     (cond
      ((equal name "classes") "class")
      ((string-suffix-p "ies" name)
       (concat (string-remove-suffix "ies" name) "y"))
      ((string-suffix-p "s" name) (string-remove-suffix "s" name))
      (t name)))))

(defun reference-explorer-lookup--docset-corfu-kind (type)
  "Return the Corfu completion kind corresponding to docset TYPE."
  (pcase (reference-explorer-lookup--docset-kind-symbol type)
    ((or 'attribute 'field) 'field)
    ((or 'guide 'section) 'text)
    ('protocol 'interface)
    ('type 'class)
    (kind kind)))

(defun reference-explorer-lookup--docset-kind-fallback (type)
  "Return an unambiguous text fallback for docset TYPE."
  (propertize (format "[%s] " (or type "Reference"))
              'face 'reference-explorer-lookup-quick-source))

(defun reference-explorer-lookup--docset-kind-icon (type)
  "Return the Nerd Font field used by Corfu for docset TYPE.
Fall back to an explicit text label when `nerd-icons-corfu' is unavailable."
  (let ((kind (reference-explorer-lookup--docset-corfu-kind type)))
    (or
     (when (and (require 'nerd-icons-corfu nil t)
                (fboundp 'nerd-icons-corfu-formatter))
       (let* ((completion-extra-properties
               `(:company-kind ,(lambda (_candidate) kind)))
              (formatter (nerd-icons-corfu-formatter nil)))
         (and formatter (funcall formatter type))))
     (reference-explorer-lookup--docset-kind-fallback type))))

(defun reference-explorer-lookup--candidate-annotation
    (candidate &optional show-docset-source)
  "Return a compact annotation for reference CANDIDATE.
SHOW-DOCSET-SOURCE keeps the source name when several docsets are searched."
  (cond
   ((reference-explorer-lookup--thesaurus-candidate-p candidate) "")
   ((reference-explorer-docset-result-p candidate)
    (let ((icon
           (reference-explorer-lookup--docset-kind-icon
            (reference-explorer-docset-result-type candidate)))
          (source
           (and show-docset-source
                (reference-explorer-docset-feed
                 (reference-explorer-docset-result-docset candidate)))))
      (string-join (delq nil (list icon source)) "  ")))
   (t (reference-explorer-lookup-entry-source candidate))))

(defun reference-explorer-lookup--candidate-preview-entry (candidate)
  "Return a local entry suitable for previewing CANDIDATE."
  (if (or (reference-explorer-docset-result-p candidate)
          (not (reference-explorer-lookup--thesaurus-candidate-p candidate)))
      candidate
    ;; Candidate navigation must never contact PowerThesaurus.  Reuse the
    ;; local Lookup backend, whose own result cache also makes revisiting a
    ;; candidate inexpensive.
    (when (fboundp 'lookup-initialize)
      (let ((entries
             (reference-explorer-lookup--quick-search-entries
              (reference-explorer-lookup--candidate-label candidate))))
        (if (null reference-explorer-lookup-thesaurus-preview-sources)
            (car entries)
          (cl-loop
           for source in reference-explorer-lookup-thesaurus-preview-sources
           thereis
           (seq-find
            (lambda (entry)
              (equal (reference-explorer-lookup-entry-source entry) source))
            entries)))))))

(defun reference-explorer-lookup--preview-query-for-entry (entry query)
  "Return QUERY when ENTRY's source enables preview highlighting."
  (and (not (reference-explorer-docset-result-p entry))
       query
       (member (reference-explorer-lookup-entry-source entry)
               reference-explorer-lookup-preview-highlight-sources)
       query))

(defun reference-explorer-lookup--insert-entry-content (entry)
  "Insert the rendered body of Lookup ENTRY in the current buffer."
  (setq lookup-content-current-entry entry
        lookup-content-line-heading (lookup-entry-heading entry))
  (if (lookup-reference-p entry)
      (insert "(no contents)")
    (lookup-vse-insert-content entry)))

(defun reference-explorer-lookup-entry-text (entry)
  "Return Lookup ENTRY's body as plain text."
  (require 'lookup-content)
  (require 'lookup-vse)
  (with-temp-buffer
    (reference-explorer-lookup--insert-entry-content entry)
    (string-trim-right
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun reference-explorer-lookup-entry-description (entry)
  "Return a self-contained plain-text description of Lookup ENTRY."
  (format "%s — %s\n\n%s"
          (reference-explorer-lookup--plain-entry-heading entry)
          (reference-explorer-lookup-entry-source entry)
          (reference-explorer-lookup-entry-text entry)))

(defun reference-explorer-lookup--render-entry (entry buffer-name)
  "Render reference ENTRY in BUFFER-NAME and return that buffer."
  (if (reference-explorer-docset-result-p entry)
      (reference-explorer-docset-render entry buffer-name)
    (require 'lookup-content)
    (require 'lookup-vse)
    (let ((buffer (get-buffer-create buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (reference-explorer-lookup--insert-entry-content entry)
          (goto-char (point-min))
          (lookup-content-mode)))
      buffer)))

(defun reference-explorer-lookup--highlight-preview-query (query)
  "Highlight literal occurrences of QUERY in the current preview buffer."
  (when (and query (not (string-empty-p (string-trim query))))
    (save-excursion
      (let ((case-fold-search t)
            (regexp (regexp-quote query)))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (add-face-text-property
           (match-beginning 0) (match-end 0)
           'reference-explorer-lookup-preview-match nil))))))

(defun reference-explorer-lookup--prepare-preview-buffer (buffer &optional query)
  "Simplify and style BUFFER for a temporary preview.
Highlight literal QUERY occurrences when QUERY is non-nil."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (docset-position
           (and (derived-mode-p 'reference-explorer-docset-mode) (point))))
      (unless docset-position
        (goto-char (point-min))
        ;; Lookup adds dictionary navigation links to some entries.  They are
        ;; useful in committed content, but only distract from a transient
        ;; preview whose selection is controlled by Consult.
        (while (re-search-forward
                "^[ \t]*(\\(?:前\\|次\\|全\\)項目⇒.*)\\(?:\n\\|\\'\\)" nil t)
          (replace-match ""))
        (goto-char (point-min))
        (skip-chars-forward "\n")
        (delete-region (point-min) (point))
        (goto-char (point-max))
        (skip-chars-backward "\n")
        (delete-region (point) (point-max)))
      (reference-explorer-lookup--highlight-preview-query query)
      ;; Docsets can target an anchor inside the rendered page; Lookup
      ;; previews always begin at the article start.
      (goto-char (or docset-position (point-min))))
    (setq-local word-wrap t)
    (buffer-face-set
     (append
      (list :inherit 'reference-explorer-lookup-preview)
      (when (and reference-explorer-lookup-content-font-family
                 (find-font
                  (font-spec :family reference-explorer-lookup-content-font-family)))
        (list :family reference-explorer-lookup-content-font-family))
      (list :height reference-explorer-lookup-preview-font-height)))
    buffer))

(defun reference-explorer-lookup-display-candidate (candidate)
  "Display the Lookup entry represented by Embark CANDIDATE."
  (if-let ((entry (reference-explorer-lookup-candidate-entry candidate)))
      (reference-explorer-lookup--display-entry entry)
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-lookup-copy-candidate (candidate)
  "Copy the full Lookup description represented by Embark CANDIDATE."
  (if-let ((entry (reference-explorer-lookup-candidate-entry candidate)))
      (let ((description (reference-explorer-lookup-entry-description entry)))
        (kill-new description)
        (message "Copied Lookup entry: %s"
                 (reference-explorer-lookup--plain-entry-heading entry)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-lookup-display-docset-candidate (candidate)
  "Display the docset result represented by Embark CANDIDATE."
  (if-let ((result (reference-explorer-lookup-docset-candidate candidate)))
      (reference-explorer-lookup--display-entry result)
    (user-error "Docset result data is unavailable")))

(defun reference-explorer-lookup-copy-docset-url (candidate)
  "Copy the local URL represented by docset CANDIDATE."
  (if-let* ((result (reference-explorer-lookup-docset-candidate candidate))
            (url (reference-explorer-docset-result-url result)))
      (progn
        (kill-new url)
        (message "Copied docset URL: %s"
                 (reference-explorer-docset-result-name result)))
    (user-error "Docset URL is unavailable")))

(defun reference-explorer-lookup-browse-docset-candidate (candidate)
  "Open the local page represented by docset CANDIDATE externally."
  (if-let* ((result (reference-explorer-lookup-docset-candidate candidate))
            (url (reference-explorer-docset-result-url result)))
      (browse-url url)
    (user-error "Docset URL is unavailable")))

(defun reference-explorer-lookup-monokakido-candidate (candidate)
  "Open the heading represented by Embark CANDIDATE in Monokakido."
  (if-let ((entry (reference-explorer-lookup-candidate-entry candidate)))
      (reference-explorer-run-provider
       'monokakido
       (reference-explorer-context-create
        :query (reference-explorer-lookup--plain-entry-heading entry)
        :marker (copy-marker (point))
        :window (selected-window)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-lookup-macos-dictionary-candidate (candidate)
  "Open the heading represented by Embark CANDIDATE in macOS Dictionary."
  (if-let ((entry (reference-explorer-lookup-candidate-entry candidate)))
      (reference-explorer-run-provider
       'macos-dictionary
       (reference-explorer-context-create
        :query (reference-explorer-lookup--plain-entry-heading entry)
        :marker (copy-marker (point))
        :window (selected-window)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-lookup--display-entry (entry)
  "Render reference ENTRY and display it as committed Popper content."
  (let ((buffer
         (reference-explorer-lookup--render-entry
          entry (if (reference-explorer-docset-result-p entry)
                    reference-explorer-lookup-docset-content-buffer-name
                  reference-explorer-lookup-content-buffer-name))))
    (save-selected-window
      (funcall reference-explorer-lookup-display-buffer-function buffer))
    buffer))

(defun reference-explorer-lookup--face-includes-p (face value)
  "Return non-nil when face VALUE includes FACE."
  (or (eq value face)
      (and (listp value) (memq face value))))

(defun reference-explorer-lookup--vertico-selection (display)
  "Return selected Vertico DISPLAY data as (ROW LINE)."
  (let ((position 0)
        selected)
    (while (and (< position (length display)) (null selected))
      (when (reference-explorer-lookup--face-includes-p
             'vertico-current
             (get-text-property position 'face display))
        (setq selected position))
      (setq position
            (next-single-property-change position 'face display
                                         (length display))))
    (when selected
      (let ((start
             (1+ (or (cl-position ?\n display :from-end t :end selected)
                     -1)))
            (end (or (cl-position ?\n display :start selected)
                     (length display))))
        (list (cl-count ?\n display :end selected)
              (substring display start end))))))

(defun reference-explorer-lookup--vertico-selected-row (display)
  "Return the visual row of the selected candidate in Vertico DISPLAY."
  (car (reference-explorer-lookup--vertico-selection display)))

(defun reference-explorer-lookup--vertico-candidate-position ()
  "Return the selected Vertico candidate position in parent-frame pixels."
  (when-let* ((minibuffer-window (active-minibuffer-window))
              (buffer (window-buffer minibuffer-window))
              (overlay
               (buffer-local-value 'vertico--candidates-ov buffer))
              ((overlayp overlay))
              (display (overlay-get overlay 'before-string))
              (selection (reference-explorer-lookup--vertico-selection display))
              (row (car selection))
              (line (cadr selection)))
    (pcase-let ((`(,left ,top ,_right ,_bottom)
                 (window-inside-pixel-edges minibuffer-window)))
      (let* ((frame (window-frame minibuffer-window))
             (char-width (frame-char-width frame))
             (line-width
              (with-selected-window minibuffer-window
                (string-pixel-width line)))
             (candidate-right (+ left char-width line-width char-width))
             (candidate-top
              (+ top (* row (window-default-line-height
                             minibuffer-window)))))
        (list candidate-right
              candidate-top
              (- (frame-pixel-width frame) candidate-right char-width)
              (+ left char-width))))))

(defun reference-explorer-lookup--preview-left (position frame-width side)
  "Return preview left coordinate for POSITION, FRAME-WIDTH and SIDE."
  (if (eq side 'right)
      (car position)
    (max 0 (- (nth 3 position) frame-width 4))))

(defun reference-explorer-lookup--preview-text-pixel-size
    (window buffer max-width max-height)
  "Measure BUFFER's unwrapped extent within MAX-WIDTH and MAX-HEIGHT."
  (with-current-buffer buffer
    (window-text-pixel-size
     window (point-min) (point-max) max-width max-height)))

(defun reference-explorer-lookup--preview-wrapped-height
    (window buffer max-height)
  "Measure BUFFER's height in WINDOW, including wrapping, up to MAX-HEIGHT."
  (with-current-buffer buffer
    (cdr (window-text-pixel-size
          window (point-min) (point-max) nil max-height))))

(defun reference-explorer-lookup--preview-horizontal-layout
    (position configured-width minimum-width)
  "Return (SIDE . MAX-WIDTH) for POSITION and CONFIGURED-WIDTH.
Return nil unless the available body width is at least MINIMUM-WIDTH."
  (let* ((right-space (max 0 (nth 2 position)))
         (left-space (max 0 (- (nth 3 position) 4)))
         (side (if (>= right-space left-space) 'right 'left))
         (space (if (eq side 'right) right-space left-space))
         (width
          (min configured-width
               (max 0 (- space
                         reference-explorer-lookup--preview-horizontal-overhead)))))
    (when (>= width minimum-width)
      (cons side width))))

(defun reference-explorer-lookup--preview-max-height
    (line-height parent-height)
  "Return preview body height available inside PARENT-HEIGHT.
LINE-HEIGHT is the minimum useful body height."
  (max line-height
       (- parent-height
          reference-explorer-lookup--preview-vertical-overhead
          8)))

(defun reference-explorer-lookup--preview-top
    (position frame-height parent-height)
  "Align preview with POSITION, clamped inside PARENT-HEIGHT.
The selected candidate and preview text start at the same vertical coordinate
when the preview fits below that coordinate.  Otherwise move the preview
upward only as far as needed to keep its bottom inside the parent frame."
  (max 4
       (min (- (cadr position)
               reference-explorer-lookup--preview-border-width)
            (- parent-height frame-height 4))))

(defun reference-explorer-lookup--preview-content-width
    (measured-width max-width char-width &optional minimum-width)
  "Return safe content width from MEASURED-WIDTH within MAX-WIDTH.
CHAR-WIDTH converts `reference-explorer-lookup-preview-width-slack' to pixels."
  (min max-width
       (max (or minimum-width char-width)
            (+ measured-width
               (* reference-explorer-lookup-preview-width-slack char-width)))))

(defun reference-explorer-lookup--child-frame-parameters
    (parent-frame background-face border-width)
  "Return common child-frame parameters for PARENT-FRAME.
BACKGROUND-FACE supplies the frame background and BORDER-WIDTH is measured in
pixels.  The parameters mirror Corfu's stable presentation choices without
depending on its private frame functions."
  (let ((parent-font
         (and (framep parent-frame)
              (frame-parameter parent-frame 'font))))
    `((parent-frame . ,parent-frame)
      (minibuffer . ,(minibuffer-window parent-frame))
      ,@(when parent-font `((font . ,parent-font)))
      (no-focus-on-map . t)
      (no-accept-focus . t)
      (min-width . 0)
      (min-height . 0)
      (width . 0)
      (height . 0)
      (left-fringe . 0)
      (right-fringe . 0)
      (border-width . 0)
      (outer-border-width . 0)
      (internal-border-width . ,border-width)
      (child-frame-border-width . ,border-width)
      (vertical-scroll-bars . nil)
      (horizontal-scroll-bars . nil)
      (menu-bar-lines . 0)
      (tool-bar-lines . 0)
      (tab-bar-lines . 0)
      (cursor-type . nil)
      (no-special-glyphs . t)
      (undecorated . t)
      (unsplittable . t)
      (no-other-frame . t)
      (fullscreen . nil)
      (desktop-dont-save . t)
      (inhibit-double-buffering . t)
      (visibility . nil)
      (background-color . ,(face-background background-face nil t)))))

(defun reference-explorer-lookup--style-child-frame (frame border-face)
  "Apply BORDER-FACE to FRAME's internal and child-frame borders."
  (let ((color (face-background border-face nil t)))
    (set-face-background 'internal-border color frame)
    (when (facep 'child-frame-border)
      (set-face-background 'child-frame-border color frame))))

(defun reference-explorer-lookup--delete-docset-preview-file ()
  "Delete all temporary HTML owned by the current preview buffer."
  (when (timerp reference-explorer-lookup--docset-preview-file-cleanup-timer)
    (cancel-timer reference-explorer-lookup--docset-preview-file-cleanup-timer))
  (dolist (file (cons reference-explorer-lookup--docset-preview-file
                      reference-explorer-lookup--docset-preview-obsolete-files))
    (when (and file (file-exists-p file))
      (delete-file file)))
  (setq reference-explorer-lookup--docset-preview-file nil
        reference-explorer-lookup--docset-preview-obsolete-files nil
        reference-explorer-lookup--docset-preview-file-cleanup-timer nil))

(defun reference-explorer-lookup--delete-obsolete-docset-preview-files ()
  "Delete superseded HTML after WebKit has finished loading its replacement."
  (when (timerp reference-explorer-lookup--docset-preview-file-cleanup-timer)
    (cancel-timer reference-explorer-lookup--docset-preview-file-cleanup-timer))
  (dolist (file reference-explorer-lookup--docset-preview-obsolete-files)
    (when (file-exists-p file)
      (delete-file file)))
  (setq reference-explorer-lookup--docset-preview-obsolete-files nil
        reference-explorer-lookup--docset-preview-file-cleanup-timer nil))

(defun reference-explorer-lookup--schedule-obsolete-docset-file-cleanup (buffer)
  "Schedule fallback cleanup of superseded preview HTML owned by BUFFER.
An invisible child frame may stop delivering WebKit loading callbacks.  The
model itself remains reusable, so only its no-longer-current input files need
the bounded fallback cleanup."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp reference-explorer-lookup--docset-preview-file-cleanup-timer)
        (cancel-timer reference-explorer-lookup--docset-preview-file-cleanup-timer))
      (setq reference-explorer-lookup--docset-preview-file-cleanup-timer
            (run-at-time
             0.5 nil
             (lambda (owned-buffer)
               (when (buffer-live-p owned-buffer)
                 (with-current-buffer owned-buffer
                   (reference-explorer-lookup--delete-obsolete-docset-preview-files))))
             buffer)))))

(defun reference-explorer-lookup--docset-webkit-available-p ()
  "Return non-nil when a WebKit docset preview can be created."
  (and (eq reference-explorer-lookup-docset-preview-renderer 'webkit)
       (display-graphic-p)
       (featurep 'xwidget-internal)
       (require 'xwidget nil t)
       (fboundp 'xwidget-insert)
       (fboundp 'xwidget-webkit-goto-uri)))

(defun reference-explorer-lookup--docset-webkit-callback (xwidget event-type)
  "Handle reusable preview XWIDGET event EVENT-TYPE."
  (xwidget-webkit-callback xwidget event-type)
  ;; The standard callback renames WebKit buffers to a visible `*xwidget-*'
  ;; name after loading.  Keep reference previews internal so Consult never
  ;; offers a cached xwidget model as a regular buffer candidate.
  (when (buffer-live-p (xwidget-buffer xwidget))
    (reference-explorer-lookup--internalize-docset-webkit-buffer
     (xwidget-buffer xwidget)))
  ;; Emacs 30 on macOS reports successive `load-changed' symbols rather than
  ;; a string-valued `load-finished' event for local file URLs.  The standard
  ;; callback updates `xwidget-webkit--loading-p'; only release superseded
  ;; files after that state says the current navigation has settled.
  (when (buffer-live-p (xwidget-buffer xwidget))
    (with-current-buffer (xwidget-buffer xwidget)
      (when (and (memq event-type '(load-changed load-finished))
                 (not xwidget-webkit--loading-p))
        (reference-explorer-lookup--delete-obsolete-docset-preview-files)))))

(defun reference-explorer-lookup--navigate-docset-webkit (buffer xwidget entry)
  "Render docset ENTRY and navigate reusable XWIDGET in BUFFER to it."
  (let ((file (make-temp-file "reference-explorer-lookup-docset-preview-" nil ".html")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert
             (reference-explorer-docset-render-html
              entry
              (format "html { font-size: %spx !important; }"
                      reference-explorer-lookup-docset-webkit-font-size))))
          (with-current-buffer buffer
            (when reference-explorer-lookup--docset-preview-file
              (push reference-explorer-lookup--docset-preview-file
                    reference-explorer-lookup--docset-preview-obsolete-files))
            (setq reference-explorer-lookup--docset-preview-file file)
            (xwidget-webkit-goto-uri
             xwidget (url-encode-url (concat "file://" file)))
            (reference-explorer-lookup--schedule-obsolete-docset-file-cleanup
             buffer)
            (setq file nil)))
      (when (and file (file-exists-p file))
        (delete-file file)))))

(defun reference-explorer-lookup--make-docset-webkit-buffer
    (entry width height)
  "Create a WebKit buffer for docset ENTRY sized to WIDTH by HEIGHT pixels.
Return (BUFFER . XWIDGET)."
  (let (buffer result)
    (unwind-protect
        (setq result
              (progn
                (setq buffer
                      (generate-new-buffer
                       reference-explorer-lookup-preview-buffer-name))
                (with-current-buffer buffer
                  (insert ".")
                  (let ((xwidget
                         (xwidget-insert
                          (point-min) 'webkit
                          (reference-explorer-docset-result-name entry)
                          width height nil)))
                    (put-text-property (point-min) (point-max) 'invisible t)
                    (xwidget-put
                     xwidget 'callback
                     #'reference-explorer-lookup--docset-webkit-callback)
                    (xwidget-put xwidget 'display-callback
                                 #'xwidget-webkit-display-callback)
                    ;; Candidate navigation reuses this widget, so it must
                    ;; never prompt merely because Emacs itself eventually
                    ;; shuts down.
                    (set-xwidget-query-on-exit-flag xwidget nil)
                    (xwidget-webkit-mode)
                    (reference-explorer-lookup--internalize-docset-webkit-buffer
                     buffer)
                    (setq-local mode-line-format nil
                                header-line-format nil
                                cursor-type nil)
                    (add-hook
                     'kill-buffer-hook
                     #'reference-explorer-lookup--delete-docset-preview-file
                     nil t)
                    (reference-explorer-lookup--navigate-docset-webkit
                     buffer xwidget entry)
                    (cons buffer xwidget)))))
      (unless result
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    result))

(defun reference-explorer-lookup--internalize-docset-webkit-buffer (buffer)
  "Keep reference WebKit BUFFER out of ordinary buffer selectors."
  (with-current-buffer buffer
    (setq-local xwidget-webkit-buffer-name-format
                reference-explorer-lookup-preview-buffer-name)
    (unless (string-prefix-p " " (buffer-name))
      (rename-buffer
       (generate-new-buffer-name reference-explorer-lookup-preview-buffer-name)
       t)))
  buffer)

(defun reference-explorer-lookup--docset-webkit-layout (position anchor-window)
  "Return WebKit preview layout for POSITION beside ANCHOR-WINDOW."
  (when (window-live-p anchor-window)
    (let* ((parent-frame (window-frame anchor-window))
           (line-height (window-default-line-height anchor-window))
           (horizontal-layout
            (reference-explorer-lookup--preview-horizontal-layout
             position reference-explorer-lookup-docset-webkit-preview-width
             reference-explorer-lookup-docset-webkit-preview-min-width)))
      (when horizontal-layout
        (list :parent-frame parent-frame
              :side (car horizontal-layout)
              :width (cdr horizontal-layout)
              :height
              (min reference-explorer-lookup-docset-webkit-preview-height
                   (reference-explorer-lookup--preview-max-height
                    line-height (frame-pixel-height parent-frame))))))))

(defun reference-explorer-lookup--docset-webkit-cache (parent-frame)
  "Return the reusable WebKit preview belonging to PARENT-FRAME."
  (gethash parent-frame reference-explorer-lookup--docset-webkit-preview-caches))

(defun reference-explorer-lookup--cache-docset-webkit-preview
    (parent-frame preview)
  "Cache PREVIEW as the reusable WebKit view for PARENT-FRAME."
  (puthash parent-frame preview
           reference-explorer-lookup--docset-webkit-preview-caches)
  preview)

(defun reference-explorer-lookup--cached-docset-webkit-preview-p (preview)
  "Return non-nil when PREVIEW is its parent frame's reusable WebKit view."
  (and
   (reference-explorer-lookup--preview-p preview)
   (let (cached)
     (maphash
      (lambda (_parent-frame candidate)
        (when (eq preview candidate)
          (setq cached t)))
      reference-explorer-lookup--docset-webkit-preview-caches)
     cached)))

(defun reference-explorer-lookup--uncache-docset-webkit-preview-frame (frame)
  "Remove and return the cached preview whose child frame is FRAME."
  (let (parent-frame preview)
    (maphash
     (lambda (candidate-parent candidate-preview)
       (when (eq frame (reference-explorer-lookup--preview-frame candidate-preview))
         (setq parent-frame candidate-parent
               preview candidate-preview)))
     reference-explorer-lookup--docset-webkit-preview-caches)
    (when parent-frame
      (remhash parent-frame reference-explorer-lookup--docset-webkit-preview-caches))
    preview))

(defun reference-explorer-lookup--display-docset-webkit-preview
    (entry position layout)
  "Display WebKit docset ENTRY at POSITION using LAYOUT."
  (let* ((parent-frame (plist-get layout :parent-frame))
         (body-width (plist-get layout :width))
         (body-height (plist-get layout :height))
         (cached (reference-explorer-lookup--docset-webkit-cache parent-frame))
         (reuse
          (and (reference-explorer-lookup--preview-live-p cached)
               (eq (frame-parent
                    (reference-explorer-lookup--preview-frame cached))
                   parent-frame)))
         (buffer (and reuse
                      (reference-explorer-lookup--preview-buffer cached)))
         (frame (and reuse
                     (reference-explorer-lookup--preview-frame cached)))
         (window (and frame (frame-selected-window frame)))
         (xwidget
          (and buffer (car (get-buffer-xwidgets buffer))))
         (preview nil)
         created)
    (unwind-protect
        (progn
          (unless (and reuse (window-live-p window) xwidget)
            (let* ((resources
                    (reference-explorer-lookup--make-docset-webkit-buffer
                     entry body-width body-height))
                   (parameters
                    (reference-explorer-lookup--child-frame-parameters
                     parent-frame 'reference-explorer-lookup-preview
                     reference-explorer-lookup--preview-border-width))
                   (shown-window
                    (save-selected-window
                      (let ((display-buffer-overriding-action nil)
                            (display-buffer-alist nil))
                        (display-buffer
                         (car resources)
                         `((display-buffer-in-child-frame
                            display-buffer-no-window)
                           (child-frame-parameters . ,parameters)
                           (allow-no-window . t)
                           (no-other-window . t)
                           (no-delete-other-windows . t)))))))
              (setq buffer (car resources)
                    xwidget (cdr resources)
                    window shown-window
                    created t)
              (unless (window-live-p window)
                (error "WebKit preview child window was not created"))
              (setq frame (window-frame window))))
          (reference-explorer-lookup--internalize-docset-webkit-buffer buffer)
          (unless (eq (frame-parent frame) parent-frame)
            (error "WebKit preview was displayed outside its parent frame"))
          (when reuse
            (reference-explorer-lookup--navigate-docset-webkit
             buffer xwidget entry))
          (let* ((frame-width
                  (+ body-width
                     reference-explorer-lookup--preview-horizontal-overhead))
                 (frame-height
                  (+ body-height
                     reference-explorer-lookup--preview-vertical-overhead))
                 (left
                  (reference-explorer-lookup--preview-left
                   position frame-width (plist-get layout :side)))
                 (top
                  (reference-explorer-lookup--preview-top
                   position frame-height (frame-pixel-height parent-frame))))
            (set-window-dedicated-p window t)
            (set-frame-size frame frame-width frame-height t)
            (set-frame-parameter
             frame 'reference-explorer-lookup-preview-buffer buffer)
            (set-frame-position frame left top)
            (redirect-frame-focus frame parent-frame)
            (reference-explorer-lookup--style-child-frame
             frame 'reference-explorer-lookup-preview-border)
            (xwidget-resize xwidget body-width body-height)
            (make-frame-visible frame)
            (setq preview
                  (if reuse
                      cached
                    (reference-explorer-lookup--make-preview frame buffer entry))
                  reference-explorer-lookup--active-temporary-preview preview)
            (setf (reference-explorer-lookup--preview-entry preview) entry)
            (reference-explorer-lookup--cache-docset-webkit-preview
             parent-frame preview)))
      (unless preview
        (when (and created
                   (frame-live-p frame)
                   (not (eq frame parent-frame)))
          (delete-frame frame))
        (when (and created (buffer-live-p buffer))
          (kill-buffer buffer))))
    preview))

(defun reference-explorer-lookup--show-docset-webkit-preview-at-position
    (entry position anchor-window)
  "Show an isolated WebKit docset ENTRY beside POSITION in ANCHOR-WINDOW."
  (when (reference-explorer-lookup--docset-webkit-available-p)
    (condition-case error-data
        (when-let ((layout
                    (reference-explorer-lookup--docset-webkit-layout
                     position anchor-window)))
          (reference-explorer-lookup--display-docset-webkit-preview
           entry position layout))
      (error
       (unless reference-explorer-lookup--docset-webkit-warning-shown
         (setq reference-explorer-lookup--docset-webkit-warning-shown t)
         (display-warning
          'reference-explorer-lookup
          (format "WebKit docset preview failed; using SHR: %s"
                  (error-message-string error-data))
          :warning))
       nil))))

(defun reference-explorer-lookup--show-temporary-shr-preview-at-position
    (entry position anchor-window &optional query)
  "Show ENTRY near pixel POSITION relative to ANCHOR-WINDOW's frame.
Highlight literal QUERY occurrences in the rendered content."
  (when (and (display-graphic-p)
             (fboundp 'display-buffer-in-child-frame))
    (when-let* (((window-live-p anchor-window))
                (parent-frame (window-frame anchor-window))
                (char-width (frame-char-width parent-frame))
                ;; `when-let*' stops on nil bindings, so keep a non-nil kind
                ;; while still distinguishing the two sizing policies.
                (preview-kind
                 (if (reference-explorer-docset-result-p entry) 'docset 'lookup))
                (configured-width
                 (* (if (eq preview-kind 'docset)
                        reference-explorer-lookup-docset-preview-max-width
                      reference-explorer-lookup-preview-max-width)
                    char-width))
                (minimum-width
                 (* (if (eq preview-kind 'docset)
                        reference-explorer-lookup-docset-preview-min-width
                      reference-explorer-lookup-preview-min-width)
                    char-width))
                (margin-pixels
                 (* 2 reference-explorer-lookup-preview-margin-width char-width))
                (horizontal-layout
                 (reference-explorer-lookup--preview-horizontal-layout
                  position
                  (+ configured-width margin-pixels)
                  (+ minimum-width margin-pixels)))
                (buffer-name
                 (generate-new-buffer-name
                  reference-explorer-lookup-preview-buffer-name))
                (buffer
                 (reference-explorer-lookup--prepare-preview-buffer
                  (reference-explorer-lookup--render-entry entry buffer-name)
                  (reference-explorer-lookup--preview-query-for-entry
                   entry query))))
      (with-current-buffer buffer
        (setq-local mode-line-format nil
                    header-line-format nil
                    cursor-type nil))
      (let ((preview nil)
            window
            frame)
        (unwind-protect
            (let ((parameters
                   (reference-explorer-lookup--child-frame-parameters
                    parent-frame 'reference-explorer-lookup-preview
                    reference-explorer-lookup--preview-border-width)))
              (when-let*
                  ((shown-window
                   (setq window
                          (save-selected-window
                            (let ((display-buffer-overriding-action nil)
                                  (display-buffer-alist nil))
                              (display-buffer
                               buffer
                               `((display-buffer-in-child-frame
                                  display-buffer-no-window)
                                 (child-frame-parameters . ,parameters)
                                 (allow-no-window . t)
                                 (no-other-window . t)
                                 (no-delete-other-windows . t)))))))
                  ((window-live-p shown-window))
                  (child-frame
                   (setq frame (window-frame shown-window)))
                  ((eq (frame-parent child-frame) parent-frame)))
                (set-window-margins
                 window reference-explorer-lookup-preview-margin-width
                 reference-explorer-lookup-preview-margin-width)
                (let* ((line-height
                        (window-default-line-height anchor-window))
                       (horizontal-side (car horizontal-layout))
                       (max-width
                        (max char-width
                             (- (cdr horizontal-layout) margin-pixels)))
                       (parent-height (frame-pixel-height parent-frame))
                       (max-height
                        (min (reference-explorer-lookup--preview-max-height
                              line-height parent-height)
                             (if (eq preview-kind 'docset)
                                 (* reference-explorer-lookup-docset-preview-max-height
                                    line-height)
                               parent-height)))
                       (_initial-size
                        (set-frame-size
                         frame (+ max-width margin-pixels) max-height t))
                       (size
                        (reference-explorer-lookup--preview-text-pixel-size
                         window buffer max-width max-height))
                       (width
                        (reference-explorer-lookup--preview-content-width
                         (car size) max-width char-width
                         (and (eq preview-kind 'docset) minimum-width)))
                       ;; Width must be applied before measuring height.  With
                       ;; a non-nil X-LIMIT, `window-text-pixel-size' ignores
                       ;; text beyond that limit instead of counting the
                       ;; visual lines it wraps to.
                       (_width-sized
                        (set-frame-size
                         frame (+ width margin-pixels
                                  reference-explorer-lookup--preview-horizontal-overhead)
                         max-height t))
                       (height
                        (max line-height
                             (reference-explorer-lookup--preview-wrapped-height
                              window buffer max-height)))
                       (frame-width
                        (+ width
                           margin-pixels
                           reference-explorer-lookup--preview-horizontal-overhead))
                       (frame-height
                        (+ height
                           reference-explorer-lookup--preview-vertical-overhead))
                       (left
                        (reference-explorer-lookup--preview-left
                         position frame-width horizontal-side))
                       (top
                        (reference-explorer-lookup--preview-top
                         position frame-height parent-height)))
                  (set-window-dedicated-p window t)
                  (set-frame-size frame frame-width frame-height t)
                  (set-frame-parameter
                   frame 'reference-explorer-lookup-preview-buffer buffer)
                  (set-frame-position frame left top)
                  (redirect-frame-focus frame parent-frame)
                  (reference-explorer-lookup--style-child-frame
                   frame 'reference-explorer-lookup-preview-border)
                  (make-frame-visible frame)
                  (setq preview
                        (reference-explorer-lookup--make-preview
                         frame buffer entry))
                  (setq reference-explorer-lookup--active-temporary-preview
                        preview)
                  ;; Every extracted docset entry and Lookup article starts at
                  ;; `point-min'.  Explicit window state keeps fitting and
                  ;; child-frame creation from vertically centering it.
                  (set-window-start window (point-min) t)
                  (set-window-point window (point-min)))))
          (unless preview
            (when (and (frame-live-p frame)
                       (not (eq frame parent-frame)))
              (delete-frame frame))
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))
        preview))))

(defun reference-explorer-lookup--show-temporary-preview-at-position
    (entry position anchor-window &optional query)
  "Show ENTRY near POSITION in ANCHOR-WINDOW using its preferred renderer."
  (or (and (reference-explorer-docset-result-p entry)
           (reference-explorer-lookup--show-docset-webkit-preview-at-position
            entry position anchor-window))
      (reference-explorer-lookup--show-temporary-shr-preview-at-position
       entry position anchor-window query)))

(defun reference-explorer-lookup--show-temporary-preview (entry)
  "Show ENTRY beside the selected Consult candidate."
  (when-let ((minibuffer-window (active-minibuffer-window))
             (position (reference-explorer-lookup--vertico-candidate-position)))
    (let ((query
           (with-current-buffer (window-buffer minibuffer-window)
             (reference-explorer-lookup--backend-query
              (minibuffer-contents-no-properties)
              reference-explorer-lookup--active-consult-mode))))
      (reference-explorer-lookup--show-temporary-preview-at-position
       entry position minibuffer-window query))))

(defun reference-explorer-lookup--preview-frame-deleted (frame)
  "Schedule cleanup of the rendering buffer owned by deleted preview FRAME.
Cleanup is deferred until `delete-frame' has finished so killing a buffer in a
dedicated child-frame window cannot recursively delete that frame."
  (when-let ((buffer
              (frame-parameter frame
                               'reference-explorer-lookup-preview-buffer)))
    (when-let ((cached
                (reference-explorer-lookup--uncache-docset-webkit-preview-frame
                 frame)))
      (when (eq cached reference-explorer-lookup--active-temporary-preview)
        (setq reference-explorer-lookup--active-temporary-preview nil))
      (when (eq cached reference-explorer-lookup--preview-interaction)
        (setq reference-explorer-lookup--preview-interaction nil
              reference-explorer-lookup--preview-interaction-origin-window nil)))
    ;; Killing a buffer from inside deletion of its dedicated child frame can
    ;; recursively delete the same frame.  Let frame deletion finish first;
    ;; the short delay also lets already queued native WebKit events settle.
    (run-at-time
     0.5 nil
     (lambda (owned-buffer)
       (when (buffer-live-p owned-buffer)
         (reference-explorer-lookup--delete-xwidget-views owned-buffer)
         (reference-explorer-lookup--retire-preview-buffer owned-buffer)))
     buffer)))

(defun reference-explorer-lookup--delete-xwidget-views (buffer)
  "Delete native xwidget views owned by BUFFER and redraw immediately.
Killing an xwidget buffer normally leaves view cleanup to a later window
configuration hook.  A moving child-frame preview needs that cleanup before
the next candidate is drawn, or the old native view remains visible."
  (when (and (buffer-live-p buffer)
             (featurep 'xwidget-internal)
             (boundp 'xwidget-view-list)
             (fboundp 'get-buffer-xwidgets)
             (fboundp 'xwidget-view-model)
             (fboundp 'delete-xwidget-view))
    (let ((models (get-buffer-xwidgets buffer)))
      (dolist (view (copy-sequence xwidget-view-list))
        (when (memq (xwidget-view-model view) models)
          (delete-xwidget-view view))))
    (redraw-display)))

(defun reference-explorer-lookup--retire-preview-buffer (buffer)
  "Kill non-cached preview BUFFER."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun reference-explorer-lookup--close-temporary-preview (preview)
  "Delete temporary Lookup PREVIEW and all resources it owns."
  (when (reference-explorer-lookup--preview-p preview)
    (when (eq preview reference-explorer-lookup--active-temporary-preview)
      (setq reference-explorer-lookup--active-temporary-preview nil))
    (let ((frame (reference-explorer-lookup--preview-frame preview))
          (buffer (reference-explorer-lookup--preview-buffer preview)))
      (if (reference-explorer-lookup--cached-docset-webkit-preview-p preview)
          ;; Reusing one native view avoids both stale pixels and a race where
          ;; a queued WebKit event reaches a model that has just been killed.
          (when (frame-live-p frame)
            (make-frame-invisible frame t))
        (when (frame-live-p frame)
          (delete-frame frame))
        (reference-explorer-lookup--delete-xwidget-views buffer)
        (reference-explorer-lookup--retire-preview-buffer buffer)))))

(defun reference-explorer-lookup--preview-live-p (preview)
  "Return non-nil when PREVIEW still owns a live frame and buffer."
  (and (reference-explorer-lookup--preview-p preview)
       (frame-live-p (reference-explorer-lookup--preview-frame preview))
       (buffer-live-p (reference-explorer-lookup--preview-buffer preview))))

(defun reference-explorer-lookup--scroll-temporary-preview (direction)
  "Scroll the active temporary preview in DIRECTION.
DIRECTION is `up' to reveal later text or `down' to reveal earlier text."
  (let ((preview reference-explorer-lookup--active-temporary-preview))
    (unless (reference-explorer-lookup--preview-live-p preview)
      (user-error "No reference preview is visible"))
    (let* ((frame (reference-explorer-lookup--preview-frame preview))
           (window (frame-selected-window frame)))
      (unless (window-live-p window)
        (user-error "The reference preview window is unavailable"))
      (with-selected-window window
        (if (derived-mode-p 'xwidget-webkit-mode)
            (funcall (if (eq direction 'up)
                         #'xwidget-webkit-scroll-up
                       #'xwidget-webkit-scroll-down))
          (condition-case nil
              (funcall (if (eq direction 'up)
                           #'scroll-up-command
                         #'scroll-down-command))
            ((beginning-of-buffer end-of-buffer) nil)))))))

(defun reference-explorer-lookup-preview-scroll-up ()
  "Scroll the temporary reference preview toward later text."
  (interactive)
  (reference-explorer-lookup--scroll-temporary-preview 'up))

(defun reference-explorer-lookup-preview-scroll-down ()
  "Scroll the temporary reference preview toward earlier text."
  (interactive)
  (reference-explorer-lookup--scroll-temporary-preview 'down))

(defun reference-explorer-lookup--active-webkit-preview-xwidget ()
  "Return the xwidget displayed by the active WebKit preview, or nil."
  (when (reference-explorer-lookup--preview-live-p
         reference-explorer-lookup--active-temporary-preview)
    (let ((buffer
           (reference-explorer-lookup--preview-buffer
            reference-explorer-lookup--active-temporary-preview)))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'xwidget-webkit-mode)))
        (car (get-buffer-xwidgets buffer))))))

(defun reference-explorer-lookup-preview-copy-selection ()
  "Copy the active WebKit preview selection to the kill ring and clipboard."
  (interactive)
  (if-let ((xwidget (reference-explorer-lookup--active-webkit-preview-xwidget)))
      (xwidget-webkit-execute-script
       xwidget "window.getSelection().toString();"
       (lambda (selection)
         (if (and (stringp selection)
                  (not (string-empty-p selection)))
             (progn
               (kill-new selection)
               (message "Copied preview selection"))
           (message "The preview has no selected text"))))
    (user-error "The active reference preview is not a WebKit preview")))

(defvar-keymap reference-explorer-lookup-preview-interaction-mode-map
  :doc "Keymap active while directly operating a reference WebKit preview."
  "C-g" #'reference-explorer-lookup-preview-exit-interaction
  "H-q" #'reference-explorer-lookup-preview-exit-interaction
  "H-w" #'reference-explorer-lookup-preview-copy-selection
  "M-w" #'reference-explorer-lookup-preview-copy-selection)

(define-minor-mode reference-explorer-lookup-preview-interaction-mode
  "Allow direct mouse and keyboard operation of a reference WebKit preview."
  :init-value nil
  :lighter " RefInteract"
  :keymap reference-explorer-lookup-preview-interaction-mode-map)

(defun reference-explorer-lookup--activate-webkit-preview-interaction
    (preview origin-window)
  "Promote WebKit PREVIEW for direct interaction, returning to ORIGIN-WINDOW."
  (unless (and (eq preview reference-explorer-lookup--active-temporary-preview)
               (reference-explorer-lookup--preview-live-p preview)
               (reference-explorer-lookup--active-webkit-preview-xwidget))
    (user-error "The active reference preview is not an interactive WebKit preview"))
  (let* ((frame (reference-explorer-lookup--preview-frame preview))
         (buffer (reference-explorer-lookup--preview-buffer preview)))
    (setq reference-explorer-lookup--preview-interaction preview
          reference-explorer-lookup--preview-interaction-origin-window
          origin-window
          reference-explorer-lookup--active-temporary-preview preview)
    (with-current-buffer buffer
      (reference-explorer-lookup-preview-interaction-mode 1))
    (set-frame-parameter frame 'no-accept-focus nil)
    (set-frame-parameter frame 'no-focus-on-map nil)
    (redirect-frame-focus frame nil)
    (select-frame-set-input-focus frame)
    (message "Preview interaction: drag to select; M-w/H-w copies; C-g/H-q exits")))

(defun reference-explorer-lookup--display-entry-for-interaction
    (entry origin-window)
  "Display ENTRY as committed content and select it from ORIGIN-WINDOW."
  (let ((buffer
         (if (window-live-p origin-window)
             (with-selected-window origin-window
               (reference-explorer-lookup--display-entry entry))
           (reference-explorer-lookup--display-entry entry))))
    (if-let ((window (get-buffer-window buffer t)))
        (progn
          (select-window window)
          (select-frame-set-input-focus (window-frame window)))
      (user-error "The committed reference content could not be displayed"))))

(defun reference-explorer-lookup--activate-preview-interaction
    (preview origin-window)
  "Promote PREVIEW to an operable display, returning to ORIGIN-WINDOW.
WebKit previews retain their rendered child frame.  Other previews are
committed to a selected Popper window."
  (unless (reference-explorer-lookup--preview-p preview)
    (user-error "No reference preview is available"))
  (if (and (eq preview reference-explorer-lookup--active-temporary-preview)
           (reference-explorer-lookup--preview-live-p preview)
           (reference-explorer-lookup--active-webkit-preview-xwidget))
      (reference-explorer-lookup--activate-webkit-preview-interaction
       preview origin-window)
    (if-let ((entry (reference-explorer-lookup--preview-entry preview)))
        (reference-explorer-lookup--display-entry-for-interaction
         entry origin-window)
      (user-error "The reference preview has no operable content"))))

(defun reference-explorer-lookup-preview-exit-interaction ()
  "End direct WebKit preview interaction and return to its origin window."
  (interactive)
  (let ((preview reference-explorer-lookup--preview-interaction)
        (origin-window reference-explorer-lookup--preview-interaction-origin-window))
    (setq reference-explorer-lookup--preview-interaction nil
          reference-explorer-lookup--preview-interaction-origin-window nil)
    (when (reference-explorer-lookup--preview-p preview)
      (let ((frame (reference-explorer-lookup--preview-frame preview))
            (buffer (reference-explorer-lookup--preview-buffer preview)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (reference-explorer-lookup-preview-interaction-mode -1)))
        (when (frame-live-p frame)
          (set-frame-parameter frame 'no-accept-focus t)
          (set-frame-parameter frame 'no-focus-on-map t)
          (when-let ((parent (frame-parent frame)))
            (redirect-frame-focus frame parent)))
        (reference-explorer-lookup--close-temporary-preview preview)))
    (when (window-live-p origin-window)
      (select-window origin-window)
      (select-frame-set-input-focus (window-frame origin-window)))))

(add-hook 'delete-frame-functions
          #'reference-explorer-lookup--preview-frame-deleted)

(defun reference-explorer-lookup--preview-state ()
  "Return a Consult state function for temporary Lookup previews."
  (let (preview)
    (lambda (action entry)
      (when preview
        (if (eq preview reference-explorer-lookup--preview-interaction-request)
            (setq reference-explorer-lookup--preview-interaction-request nil)
          (reference-explorer-lookup--close-temporary-preview preview))
        (setq preview nil))
      (pcase action
        ('preview
         (when entry
           (setq preview
                 (reference-explorer-lookup--show-temporary-preview entry))))))))

;; Corfu-like quick selector

(defun reference-explorer-lookup--quick-current-entry (&optional session)
  "Return the selected entry in quick Lookup SESSION."
  (let ((session (or session reference-explorer-lookup--quick-session)))
    (and session
         (nth (reference-explorer-lookup--quick-session-index session)
              (reference-explorer-lookup--quick-session-entries session)))))

(defun reference-explorer-lookup--quick-show-help (&optional status)
  "Show a compact quick Lookup key summary in the minibuffer.
Prefix the summary with STATUS when it is non-nil."
  (message "%s%s"
           (if status (concat status " — ") "")
           (or (and reference-explorer-lookup--quick-session
                    (reference-explorer-lookup--quick-session-help
                     reference-explorer-lookup--quick-session))
               "H-s/e:検索語を縮小/拡大  H-i:preview操作  M-m:Consult")))

(defun reference-explorer-lookup--quick-visible-entries (session)
  "Return visible entries for quick Lookup SESSION and update its offset."
  (let* ((entries (reference-explorer-lookup--quick-session-entries session))
         (count (length entries))
         (limit (max 1 reference-explorer-lookup-quick-max-candidates))
         (index (reference-explorer-lookup--quick-session-index session))
         ;; Keep the initial rows stable until selection reaches the bottom,
         ;; then scroll only enough to keep the selected row visible.
         (offset (min (max 0 (- index (1- limit)))
                      (max 0 (- count limit))))
         (end (min count (+ offset limit))))
    (setf (reference-explorer-lookup--quick-session-list-offset session) offset)
    (seq-subseq entries offset end)))

(defun reference-explorer-lookup--quick-candidate-line
    (entry _selected &optional show-docset-source)
  "Return one quick Lookup line for ENTRY.
Selection styling is applied by the renderer across the complete visual row."
  (let* ((docset-p (reference-explorer-docset-result-p entry))
         (heading (reference-explorer-lookup--candidate-label entry))
         (annotation
          (reference-explorer-lookup--candidate-annotation
           entry nil))
         (docset-source
          (and docset-p show-docset-source
               (reference-explorer-docset-feed
                (reference-explorer-docset-result-docset entry))))
         (line
          (if docset-p
              ;; `annotation' is the actual Nerd Icons Corfu margin field,
              ;; including the formatter's half-column gaps around the glyph.
              (concat annotation heading
                      (if docset-source
                          (concat "  "
                                  (propertize
                                   docset-source 'face
                                   'reference-explorer-lookup-quick-source))
                        ""))
            (concat heading
                    (if (string-empty-p annotation)
                        ""
                      (concat "  "
                              (propertize
                               annotation 'face
                               'reference-explorer-lookup-quick-source)))))))
    line))

(defconst reference-explorer-lookup--quick-fringe-bitmap
  'reference-explorer-lookup--quick-fringe-bitmap)

(when (fboundp 'define-fringe-bitmap)
  ;; A zero bitmap lets the selected face color the margin without drawing a
  ;; visible symbol, matching Corfu's selected-row fringe treatment.
  (define-fringe-bitmap reference-explorer-lookup--quick-fringe-bitmap [0] 1 1))

(defconst reference-explorer-lookup--quick-current-fringes
  (propertize
   "  "
   'display nil)
  "Invisible fringe cells used to extend the selected row into both margins.")

(put-text-property
 0 1 'display
 `(left-fringe ,reference-explorer-lookup--quick-fringe-bitmap
               reference-explorer-lookup-quick-current)
 reference-explorer-lookup--quick-current-fringes)
(put-text-property
 1 2 'display
 `(right-fringe ,reference-explorer-lookup--quick-fringe-bitmap
                reference-explorer-lookup-quick-current)
 reference-explorer-lookup--quick-current-fringes)

(defun reference-explorer-lookup--quick-render-list (session)
  "Render quick Lookup SESSION into its candidate buffer."
  (let* ((buffer (reference-explorer-lookup--quick-session-list-buffer session))
         (index (reference-explorer-lookup--quick-session-index session))
         (visible (reference-explorer-lookup--quick-visible-entries session))
         (show-docset-source
          (> (length
              (delete-dups
               (delq nil
                     (mapcar
                      (lambda (entry)
                        (and (reference-explorer-docset-result-p entry)
                             (reference-explorer-docset-root
                              (reference-explorer-docset-result-docset entry))))
                      (reference-explorer-lookup--quick-session-entries
                       session)))))
             1))
         (offset (reference-explorer-lookup--quick-session-list-offset session)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cl-loop for entry in visible
                 for row from offset
                 for selected = (= row index)
                 do (let ((start (point)))
                      (insert
                       (reference-explorer-lookup--quick-candidate-line
                        entry selected show-docset-source))
                      (when (and selected (display-graphic-p))
                        (insert reference-explorer-lookup--quick-current-fringes))
                      (insert "\n")
                      ;; Include the newline so the extending face reaches the
                      ;; full content width, exactly as Corfu's popup renderer
                      ;; does for its current candidate.
                      (when selected
                        (add-face-text-property
                         start (point)
                         'reference-explorer-lookup-quick-current 'append))))
        (when (null visible)
          (insert (propertize "一致なし" 'face 'shadow)))
        (goto-char (point-min))
        ;; Keep buffer point on the selected candidate.  The child window has
        ;; no visible cursor, but its point still controls redisplay.
        (forward-line (- index offset)))
      (setq-local mode-line-format nil
                  header-line-format nil
                  cursor-type nil
                  truncate-lines t
                  buffer-read-only t)
      (buffer-face-set 'reference-explorer-lookup-quick-default))))

(defun reference-explorer-lookup--quick-query-bounds (session)
  "Return source-buffer bounds of SESSION's active query."
  (or (reference-explorer-lookup--quick-session-source-bounds session)
      (when-let* ((marker
                   (reference-explorer-lookup--quick-session-source-marker session))
                  (buffer (and (markerp marker) (marker-buffer marker)))
                  (query (reference-explorer-lookup--quick-session-query session)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char marker)
            (or
             (seq-find
              (lambda (bounds)
                (equal query
                       (buffer-substring-no-properties
                        (car bounds) (cdr bounds))))
              (reference-explorer-lookup-word-bound-candidates-at-point))
             (let ((origin (point))
                   (limit (line-end-position))
                   found)
               (goto-char (line-beginning-position))
               (while (and (not found) (search-forward query limit t))
                 (when (and (<= (match-beginning 0) origin)
                            (<= origin (match-end 0)))
                   (setq found
                         (cons (match-beginning 0) (match-end 0)))))
               found)))))))

(defun reference-explorer-lookup--quick-highlight-source (session)
  "Highlight SESSION's active query in its source buffer."
  (when-let ((overlay
              (reference-explorer-lookup--quick-session-source-overlay session)))
    (delete-overlay overlay)
    (setf (reference-explorer-lookup--quick-session-source-overlay session) nil))
  (when-let* ((marker
               (reference-explorer-lookup--quick-session-source-marker session))
              (buffer (and (markerp marker) (marker-buffer marker)))
              (bounds (reference-explorer-lookup--quick-query-bounds session)))
    (let ((overlay (make-overlay (car bounds) (cdr bounds) buffer)))
      (overlay-put overlay 'face 'reference-explorer-lookup-source-highlight)
      (overlay-put overlay 'priority 100)
      (setf (reference-explorer-lookup--quick-session-source-overlay session)
            overlay))))

(defun reference-explorer-lookup--quick-sync-list-window (session)
  "Synchronize SESSION's child window with its freshly rendered buffer."
  (when-let* ((frame (reference-explorer-lookup--quick-session-list-frame session))
              ((frame-live-p frame))
              (window (frame-selected-window frame))
              ((window-live-p window))
              (buffer (reference-explorer-lookup--quick-session-list-buffer
                       session))
              ((buffer-live-p buffer)))
    (set-window-start window
                      (with-current-buffer buffer (point-min)) t)
    (set-window-point window
                      (with-current-buffer buffer (point)))
    (set-window-vscroll window 0 t)))

(defun reference-explorer-lookup--quick-point-position (window)
  "Return point position in parent-frame pixels for WINDOW."
  (when (window-live-p window)
    (with-selected-window window
      (when-let* ((position (posn-at-point (point) window))
                  (xy (posn-x-y position)))
        (pcase-let ((`(,left ,top ,_right ,_bottom)
                     (window-inside-pixel-edges window)))
          (list (+ left (car xy))
                (+ top (cdr xy))))))))

(defun reference-explorer-lookup--quick-position-list-frame (session)
  "Position quick Lookup SESSION's candidate frame near source point."
  (when-let* ((frame (reference-explorer-lookup--quick-session-list-frame session))
              ((frame-live-p frame))
              (source-window
               (reference-explorer-lookup--quick-session-source-window session))
              (position
               (reference-explorer-lookup--quick-point-position source-window)))
    (let* ((parent (window-frame source-window))
           (frame-width (frame-pixel-width frame))
           (frame-height (frame-pixel-height frame))
           (line-height (window-default-line-height source-window))
           (parent-width (frame-pixel-width parent))
           (parent-height (frame-pixel-height parent))
           (left (max 0 (min (car position)
                             (- parent-width frame-width 4))))
           (below (+ (cadr position) line-height 4))
           (top (if (<= (+ below frame-height 4) parent-height)
                    below
                  (max 0 (- (cadr position) frame-height 4)))))
      (set-frame-position frame left top))))

(defun reference-explorer-lookup--quick-resize-list-frame (session)
  "Resize and position quick Lookup SESSION's candidate frame."
  (when-let* ((frame (reference-explorer-lookup--quick-session-list-frame session))
              ((frame-live-p frame))
              (buffer (reference-explorer-lookup--quick-session-list-buffer session))
              ((buffer-live-p buffer)))
    (let* ((window (frame-selected-window frame))
           (char-width (frame-char-width frame))
           (max-width (* reference-explorer-lookup-quick-max-width char-width))
           (border (* 2 (or (frame-parameter frame
                                             'internal-border-width)
                            0)))
           (size
            (with-current-buffer buffer
              (window-text-pixel-size
               window (point-min) (point-max) max-width nil)))
           (pixel-width
            (+ (max char-width (min max-width (car size))) border))
           (pixel-height (+ (max 1 (cdr size)) border)))
      ;; Pixel sizing accounts for Nerd Font glyphs, half-column display
      ;; padding, and headings rendered through fallback fonts.
      (set-frame-size frame pixel-width pixel-height t)
      (reference-explorer-lookup--quick-position-list-frame session)
      ;; Frame resizing is asynchronous on graphical macOS builds.  Restore
      ;; the intended viewport after every resize instead of relying on the
      ;; child window's previous redisplay state.
      (reference-explorer-lookup--quick-sync-list-window session))))

(defun reference-explorer-lookup--quick-candidate-position (session)
  "Return the selected candidate position for quick Lookup SESSION."
  (when-let* ((frame (reference-explorer-lookup--quick-session-list-frame session))
              ((frame-live-p frame))
              (source-window
               (reference-explorer-lookup--quick-session-source-window session))
              (window (frame-selected-window frame))
              ((window-live-p window))
              (position (posn-at-point (window-point window) window))
              (xy (posn-x-y position)))
    (let* ((parent (window-frame source-window))
           (left (frame-parameter frame 'left))
           (top (frame-parameter frame 'top))
           (inside-edges (window-inside-pixel-edges window))
           (candidate-left (+ left (car inside-edges)))
           (candidate-right (+ left (frame-pixel-width frame)))
           (candidate-top (+ top (cadr inside-edges) (cdr xy))))
      (list candidate-right candidate-top
            (max 0 (- (frame-pixel-width parent) candidate-right 4))
            candidate-left))))

(defun reference-explorer-lookup--quick-cancel-preview (session)
  "Cancel and close SESSION's pending and visible temporary preview."
  (when-let ((timer
              (reference-explorer-lookup--quick-session-preview-timer session)))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (reference-explorer-lookup--quick-session-preview-timer session) nil))
  (when-let ((preview
              (reference-explorer-lookup--quick-session-preview session)))
    (reference-explorer-lookup--close-temporary-preview preview)
    (setf (reference-explorer-lookup--quick-session-preview session) nil)))

(defun reference-explorer-lookup--quick-show-preview (session entry)
  "Show ENTRY preview when SESSION is still the active quick Lookup."
  (setf (reference-explorer-lookup--quick-session-preview-timer session) nil)
  (when (eq session reference-explorer-lookup--quick-session)
    (when-let ((preview-entry
                (reference-explorer-lookup--candidate-preview-entry entry))
               (position
                (reference-explorer-lookup--quick-candidate-position session)))
      (setf (reference-explorer-lookup--quick-session-preview session)
            (reference-explorer-lookup--show-temporary-preview-at-position
             preview-entry position
             (reference-explorer-lookup--quick-session-source-window session)
             (reference-explorer-lookup--candidate-label entry)))
      ;; Lookup reports its content insertion in the echo area.  Restore the
      ;; compact selector hint after rendering finishes.
      (reference-explorer-lookup--quick-show-help))))

(defun reference-explorer-lookup--quick-schedule-preview (session)
  "Schedule a preview for the selected entry in SESSION."
  (reference-explorer-lookup--quick-cancel-preview session)
  (when-let ((entry (reference-explorer-lookup--quick-current-entry session)))
    (setf (reference-explorer-lookup--quick-session-preview-timer session)
          (run-at-time reference-explorer-lookup-preview-debounce nil
                       #'reference-explorer-lookup--quick-show-preview
                       session entry))))

(defun reference-explorer-lookup--quick-refresh (session)
  "Refresh candidate presentation and preview for SESSION."
  (reference-explorer-lookup--quick-highlight-source session)
  (reference-explorer-lookup--quick-render-list session)
  (reference-explorer-lookup--quick-resize-list-frame session)
  (reference-explorer-lookup--quick-schedule-preview session)
  (reference-explorer-lookup--quick-show-help))

(defun reference-explorer-lookup--quick-show-list-frame (session)
  "Create the candidate child frame owned by quick Lookup SESSION."
  (when (and (display-graphic-p)
             (fboundp 'display-buffer-in-child-frame))
    (let* ((buffer (generate-new-buffer " *Lookup Quick*"))
           (source-window
            (reference-explorer-lookup--quick-session-source-window session))
           (parent (window-frame source-window))
           (char-width (frame-char-width parent))
           (left-margin
            (min 16
                 (ceiling
                  (* char-width reference-explorer-lookup-quick-left-margin-width))))
           (right-margin
            (min 16
                 (ceiling
                  (* char-width reference-explorer-lookup-quick-right-margin-width))))
           (parameters
            (reference-explorer-lookup--child-frame-parameters
             parent 'reference-explorer-lookup-quick-default 1)))
      (setf (alist-get 'left-fringe parameters) left-margin
            (alist-get 'right-fringe parameters) right-margin)
      (setf (reference-explorer-lookup--quick-session-list-buffer session) buffer)
      (reference-explorer-lookup--quick-render-list session)
      (when-let ((window
                  (save-selected-window
                    (let ((display-buffer-overriding-action nil)
                          (display-buffer-alist nil))
                      (display-buffer
                       buffer
                       `((display-buffer-in-child-frame
                          display-buffer-no-window)
                         (child-frame-parameters . ,parameters)
                         (allow-no-window . t)
                         (no-other-window . t)
                         (no-delete-other-windows . t)))))))
        (let ((frame (window-frame window)))
          (set-window-dedicated-p window t)
          (redirect-frame-focus frame parent)
          (setf (reference-explorer-lookup--quick-session-list-frame session)
                frame)
          (set-frame-parameter frame 'reference-explorer-lookup-quick-session
                               session)
          (reference-explorer-lookup--quick-resize-list-frame session)
          (reference-explorer-lookup--style-child-frame
           frame 'reference-explorer-lookup-preview-border)
          (make-frame-visible frame)
          frame)))))

(defun reference-explorer-lookup--quick-list-frame-deleted (frame)
  "Deactivate quick Lookup when its candidate FRAME is deleted externally."
  (when-let ((session reference-explorer-lookup--quick-session))
    (when (eq frame
              (reference-explorer-lookup--quick-session-list-frame session))
      ;; `delete-frame-functions' runs during frame deletion.  Forget FRAME
      ;; now, then deactivate after deletion has completely unwound.
      (setf (reference-explorer-lookup--quick-session-list-frame session) nil)
      (run-at-time
       0 nil
       (lambda (owned-session)
         (when (eq owned-session reference-explorer-lookup--quick-session)
           (if-let ((exit
                     (reference-explorer-lookup--quick-session-exit-function
                      owned-session)))
               (funcall exit)
             (reference-explorer-lookup--quick-cleanup))))
       session))))

(add-hook 'delete-frame-functions
          #'reference-explorer-lookup--quick-list-frame-deleted)

(defun reference-explorer-lookup--quick-cleanup ()
  "Release all resources owned by the active quick Lookup session."
  (when-let ((session reference-explorer-lookup--quick-session))
    (setq reference-explorer-lookup--quick-session nil)
    (reference-explorer-lookup--quick-cancel-preview session)
    (when-let ((overlay
                (reference-explorer-lookup--quick-session-source-overlay session)))
      (delete-overlay overlay)
      (setf (reference-explorer-lookup--quick-session-source-overlay session) nil))
    (when-let ((marker
                (reference-explorer-lookup--quick-session-source-marker session)))
      (set-marker marker nil)
      (setf (reference-explorer-lookup--quick-session-source-marker session) nil))
    (when-let ((frame
                (reference-explorer-lookup--quick-session-list-frame session)))
      (when (frame-live-p frame)
        (delete-frame frame)))
    (when-let ((buffer
                (reference-explorer-lookup--quick-session-list-buffer session)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun reference-explorer-lookup-quick-quit ()
  "Exit quick Lookup and close its temporary displays."
  (interactive)
  (when-let ((session reference-explorer-lookup--quick-session))
    (if-let ((exit
              (reference-explorer-lookup--quick-session-exit-function session)))
        (funcall exit)
      (reference-explorer-lookup--quick-cleanup))))

(defun reference-explorer-lookup-quick-next (&optional backward)
  "Select the next quick Lookup entry, or the previous one with BACKWARD."
  (interactive)
  (when-let ((session reference-explorer-lookup--quick-session))
    (let ((count
           (length (reference-explorer-lookup--quick-session-entries session))))
      (when (> count 0)
        (setf (reference-explorer-lookup--quick-session-index session)
              (mod (+ (reference-explorer-lookup--quick-session-index session)
                      (if backward -1 1))
                   count))
        (reference-explorer-lookup--quick-refresh session)))))

(defun reference-explorer-lookup-quick-previous ()
  "Select the previous quick Lookup entry."
  (interactive)
  (reference-explorer-lookup-quick-next t))

(defun reference-explorer-lookup--quick-change-query (delta)
  "Move DELTA steps through the active quick Lookup query options."
  (when-let ((session reference-explorer-lookup--quick-session))
    (let* ((options
            (reference-explorer-lookup--quick-session-query-options session))
           (old-index
            (or (reference-explorer-lookup--quick-session-query-index session) 0))
           (new-index (max 0 (min (1- (length options))
                                  (+ old-index delta)))))
      (if (= old-index new-index)
          (reference-explorer-lookup--quick-show-help
           (if (> delta 0) "これ以上縮小できません"
             "これ以上拡大できません"))
        (pcase-let ((`(,query . ,entries) (nth new-index options)))
          (setf (reference-explorer-lookup--quick-session-query-index session)
                new-index
                (reference-explorer-lookup--quick-session-query session) query
                (reference-explorer-lookup--quick-session-entries session) entries
                (reference-explorer-lookup--quick-session-index session) 0
                (reference-explorer-lookup--quick-session-list-offset session) 0)
          (reference-explorer-lookup--quick-refresh session))))))

(defun reference-explorer-lookup-quick-shorten-query ()
  "Use the next shorter contextual word around the original point."
  (interactive)
  (reference-explorer-lookup--quick-change-query 1))

(defun reference-explorer-lookup-quick-expand-query ()
  "Use the next longer contextual word around the original point."
  (interactive)
  (reference-explorer-lookup--quick-change-query -1))

(defun reference-explorer-lookup-quick-display-entry ()
  "Accept the selected quick candidate using its session action."
  (interactive)
  (when-let ((session reference-explorer-lookup--quick-session)
             (entry (reference-explorer-lookup--quick-current-entry)))
    (reference-explorer-lookup--quick-cancel-preview session)
    (if-let ((accept
              (reference-explorer-lookup--quick-session-accept-function session)))
        (progn
          (reference-explorer-lookup-quick-quit)
          (funcall accept entry))
      (let ((source-window
             (reference-explorer-lookup--quick-session-source-window session)))
        (if (window-live-p source-window)
            (with-selected-window source-window
              (reference-explorer-lookup--display-entry entry))
          (reference-explorer-lookup--display-entry entry))))))

(defun reference-explorer-lookup-quick-open-consult ()
  "Continue the active quick Lookup query in the Consult interface."
  (interactive)
  (when-let ((session reference-explorer-lookup--quick-session))
    (if-let ((continue
              (reference-explorer-lookup--quick-session-consult-function session)))
        (let ((entries
               (reference-explorer-lookup--quick-session-entries session)))
          (reference-explorer-lookup-quick-quit)
          (funcall continue entries))
      (when-let ((query
                  (reference-explorer-lookup--quick-session-query session)))
        (let ((queries
               (mapcar #'car
                       (reference-explorer-lookup--quick-session-query-options
                        session))))
          (reference-explorer-lookup-quick-quit)
          (reference-explorer-lookup--consult-loop query 'literal queries))))))

(defun reference-explorer-lookup-quick-activate-preview ()
  "Close quick candidates and promote their preview for interaction."
  (interactive)
  (let ((session reference-explorer-lookup--quick-session))
    (unless session
      (user-error "No quick Lookup session is active"))
    (let* ((candidate (reference-explorer-lookup--quick-current-entry session))
           (entry (and candidate
                       (reference-explorer-lookup--candidate-preview-entry
                        candidate)))
           (preview
            (or (reference-explorer-lookup--quick-session-preview session)
                (and entry
                     (reference-explorer-lookup--make-preview nil nil entry)))))
      (unless preview
        (user-error "The current candidate has no operable preview"))
      (let ((origin-window
             (reference-explorer-lookup--quick-session-source-window session)))
        ;; A live WebKit view is itself promoted.  Other renderers are closed
        ;; normally and recreated as selected, committed Popper content.
        (when (and (eq preview reference-explorer-lookup--active-temporary-preview)
                   (reference-explorer-lookup--active-webkit-preview-xwidget))
          (setf (reference-explorer-lookup--quick-session-preview session) nil))
        (if-let ((exit
                  (reference-explorer-lookup--quick-session-exit-function session)))
            (funcall exit)
          (reference-explorer-lookup--quick-cleanup))
        (reference-explorer-lookup--activate-preview-interaction
         preview origin-window)))))

(defun reference-explorer-lookup--quick-context ()
  "Return a reference context for the active quick Lookup query."
  (when-let ((session reference-explorer-lookup--quick-session))
    (reference-explorer-context-create
     :query (reference-explorer-lookup--quick-session-query session)
     :marker (reference-explorer-lookup--quick-session-source-marker session)
     :window (reference-explorer-lookup--quick-session-source-window session))))

(defun reference-explorer-lookup--quick-run-provider (&optional provider)
  "Open the active quick Lookup query through PROVIDER or configured order."
  (let ((context (reference-explorer-lookup--quick-context)))
    (unless context
      (user-error "No quick Lookup session is active"))
    (if provider
        (reference-explorer-run-provider provider context)
      (reference-explorer-run-context context))))

(defun reference-explorer-lookup-quick-open-reference ()
  "Open the active quick Lookup query with the configured provider order."
  (interactive)
  (reference-explorer-lookup--quick-run-provider))

(defun reference-explorer-lookup-quick-macos-dictionary ()
  "Forward the active quick Lookup query to macOS Dictionary."
  (interactive)
  (reference-explorer-lookup--quick-run-provider 'macos-dictionary))

(defun reference-explorer-lookup-quick-monokakido ()
  "Forward the active quick Lookup query to Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-lookup--quick-run-provider 'monokakido))

(defvar-keymap reference-explorer-lookup-quick-map
  :doc "Transient keymap active during quick Lookup."
  "H-n" #'reference-explorer-lookup-quick-next
  "H-p" #'reference-explorer-lookup-quick-previous
  "H-s" #'reference-explorer-lookup-quick-shorten-query
  "H-e" #'reference-explorer-lookup-quick-expand-query
  "H-v" #'reference-explorer-lookup-preview-scroll-up
  "H-V" #'reference-explorer-lookup-preview-scroll-down
  "H-i" #'reference-explorer-lookup-quick-activate-preview
  "H-q" #'reference-explorer-lookup-quick-quit
  "C-g" #'reference-explorer-lookup-quick-quit
  "TAB" #'reference-explorer-lookup-quick-display-entry
  "<tab>" #'reference-explorer-lookup-quick-display-entry
  "H-." #'reference-explorer-lookup-quick-open-reference
  "M-m" #'reference-explorer-lookup-quick-open-consult)

(defun reference-explorer-lookup--quick-start
    (queries source-window source-marker &optional source-bounds)
  "Start quick Lookup for QUERIES from SOURCE-WINDOW and SOURCE-MARKER."
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let* ((query-options
          (reference-explorer-lookup--quick-query-options queries))
         (query (or (caar query-options) (car queries))))
    (cond
     ((not (and query (not (string-empty-p (string-trim query)))))
      (message "Quick Lookup: no searchable text at point"))
     ((not (display-graphic-p))
      (reference-explorer-lookup--consult-loop query 'literal queries))
     (t
      (let ((entries (cdar query-options)))
        (reference-explorer-lookup--quick-open-session
         (reference-explorer-lookup--make-quick-session
          :query query
          :query-options query-options
          :query-index 0
          :entries entries
          :index 0
          :source-window source-window
          :source-marker source-marker
          :source-bounds source-bounds)))))))

(defun reference-explorer-lookup--quick-open-session (session)
  "Open the already populated quick candidate SESSION."
  (reference-explorer-lookup--quick-cleanup)
  (setq reference-explorer-lookup--quick-session session)
  (if (not (reference-explorer-lookup--quick-show-list-frame session))
      (progn
        (reference-explorer-lookup--quick-cleanup)
        (message "Quick reference: cannot display candidates for “%s”"
                 (reference-explorer-lookup--quick-session-query session)))
    (setf
     (reference-explorer-lookup--quick-session-exit-function session)
     (set-transient-map reference-explorer-lookup-quick-map t
                        #'reference-explorer-lookup--quick-cleanup))
    (reference-explorer-lookup--quick-highlight-source session)
    (reference-explorer-lookup--quick-schedule-preview session)
    (reference-explorer-lookup--quick-show-help)))

(defun reference-explorer-lookup-quick-lookup-query
    (query &optional source-window source-marker)
  "Show exact and prefix Lookup matches for explicit QUERY.
SOURCE-WINDOW and SOURCE-MARKER identify the point from which the lookup was
requested."
  (reference-explorer-lookup--quick-start
   (list query)
   (or source-window (selected-window))
   (or source-marker (copy-marker (point)))))

;;;###autoload
(defun reference-explorer-lookup-quick-lookup-at-point ()
  "Show exact and prefix Lookup matches for the region or word at point."
  (interactive)
  (let* ((region-active (use-region-p))
         (begin (and region-active (region-beginning)))
         (end (and region-active (region-end))))
    (reference-explorer-lookup--quick-start
     (if region-active
         (list (buffer-substring-no-properties begin end))
       (reference-explorer-lookup--quick-query-candidates-at-point))
     (selected-window)
     (copy-marker (if region-active begin (point)))
     (and region-active (cons begin end)))))

;; Thesaurus candidate selection

(defun reference-explorer-lookup--thesaurus-candidate-value (candidate)
  "Return the thesaurus target stored in CANDIDATE."
  (cond
   ((reference-explorer-lookup--thesaurus-candidate-p candidate) candidate)
   ((stringp candidate)
    (or (get-text-property 0 'consult--candidate candidate)
        (let ((position
               (next-single-property-change
                0 'consult--candidate candidate (length candidate))))
          (and (< position (length candidate))
               (get-text-property position 'consult--candidate candidate)))))))

(defun reference-explorer-lookup--thesaurus-term (candidate)
  "Return the term represented by thesaurus CANDIDATE."
  (when-let ((target
              (reference-explorer-lookup--thesaurus-candidate-value candidate)))
    (reference-explorer-thesaurus-result-term
     (reference-explorer-lookup--thesaurus-candidate-result target))))

(defun reference-explorer-lookup--preserve-word-case (replacement original)
  "Adjust REPLACEMENT to the simple letter case used by ORIGINAL."
  (cond
   ((and (string-match-p "[[:alpha:]]" original)
         (equal original (upcase original)))
    (upcase replacement))
   ((and (> (length original) 0)
         (equal original (capitalize original)))
    (capitalize replacement))
   (t replacement)))

(defun reference-explorer-lookup-thesaurus-replace (candidate)
  "Replace the source text captured by thesaurus CANDIDATE."
  (interactive)
  (let* ((target
          (reference-explorer-lookup--thesaurus-candidate-value candidate))
         (buffer
          (and target
               (reference-explorer-lookup--thesaurus-candidate-buffer target)))
         (beginning
          (and target
               (reference-explorer-lookup--thesaurus-candidate-beginning target)))
         (end
          (and target
               (reference-explorer-lookup--thesaurus-candidate-end target)))
         (original
          (and target
               (reference-explorer-lookup--thesaurus-candidate-original target)))
         (term (reference-explorer-lookup--thesaurus-term target)))
    (unless (and term (buffer-live-p buffer)
                 (markerp beginning) (marker-position beginning)
                 (markerp end) (marker-position end)
                 (eq (marker-buffer beginning) buffer)
                 (eq (marker-buffer end) buffer))
      (user-error "The thesaurus replacement target is no longer available"))
    (with-current-buffer buffer
      (let ((start (marker-position beginning))
            (finish (marker-position end)))
        (unless (equal original
                       (buffer-substring-no-properties start finish))
          (user-error "The original text changed; refusing to replace it"))
        (let ((replacement
               (reference-explorer-lookup--preserve-word-case term original)))
          (atomic-change-group
            (goto-char start)
            (delete-region start finish)
            (insert replacement))
          (message "Replaced “%s” with “%s”" original replacement))))))

(defun reference-explorer-lookup-thesaurus-copy (candidate)
  "Copy the term represented by thesaurus CANDIDATE."
  (interactive)
  (if-let ((term (reference-explorer-lookup--thesaurus-term candidate)))
      (progn (kill-new term) (message "Copied thesaurus term: %s" term))
    (user-error "Thesaurus candidate data is unavailable")))

(defun reference-explorer-lookup--thesaurus-run-provider (candidate provider)
  "Open thesaurus CANDIDATE through reference PROVIDER."
  (let* ((target
          (reference-explorer-lookup--thesaurus-candidate-value candidate))
         (term (reference-explorer-lookup--thesaurus-term target))
         (buffer
          (and target
               (reference-explorer-lookup--thesaurus-candidate-buffer target)))
         (marker
          (and target
               (reference-explorer-lookup--thesaurus-candidate-beginning target))))
    (unless term
      (user-error "Thesaurus candidate data is unavailable"))
    (reference-explorer-run-provider
     provider
     (reference-explorer-context-create
      :query term
      :marker (if (and (markerp marker) (marker-position marker))
                  (copy-marker marker)
                (copy-marker (point)))
      :window (or (and (buffer-live-p buffer)
                       (get-buffer-window buffer t))
                  (selected-window))))))

(defun reference-explorer-lookup-thesaurus-lookup (candidate)
  "Open thesaurus CANDIDATE with GNU Lookup."
  (interactive)
  (reference-explorer-lookup--thesaurus-run-provider candidate 'lookup))

(defun reference-explorer-lookup-thesaurus-macos-dictionary (candidate)
  "Open thesaurus CANDIDATE with macOS Dictionary."
  (interactive)
  (reference-explorer-lookup--thesaurus-run-provider candidate 'macos-dictionary))

(defun reference-explorer-lookup-thesaurus-monokakido (candidate)
  "Open thesaurus CANDIDATE with Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-lookup--thesaurus-run-provider candidate 'monokakido))

(defun reference-explorer-lookup--thesaurus-consult-candidate (target id)
  "Return a Consult string for thesaurus TARGET disambiguated by ID."
  (let* ((term (reference-explorer-lookup--thesaurus-term target))
         (candidate (consult--tofu-append term id)))
    (put-text-property (length term) (length candidate) 'display "" candidate)
    (put-text-property 0 (length term) 'consult--candidate target candidate)
    candidate))

(defun reference-explorer-lookup--thesaurus-annotation (candidate)
  "Return an annotation for the thesaurus Consult CANDIDATE."
  (when-let ((target
              (reference-explorer-lookup--thesaurus-candidate-value candidate)))
    (let ((annotation
           (reference-explorer-lookup--candidate-annotation target)))
      (unless (string-empty-p annotation)
        (concat "  " annotation)))))

(defun reference-explorer-lookup--thesaurus-preview-state ()
  "Return a Consult state function using only local Lookup previews."
  (let (preview)
    (lambda (action candidate)
      (when preview
        (if (eq preview reference-explorer-lookup--preview-interaction-request)
            (setq reference-explorer-lookup--preview-interaction-request nil)
          (reference-explorer-lookup--close-temporary-preview preview))
        (setq preview nil))
      (when (and (eq action 'preview) candidate)
        (when-let* ((target
                     (reference-explorer-lookup--thesaurus-candidate-value
                      candidate))
                    (entry
                     (reference-explorer-lookup--candidate-preview-entry target))
                    (minibuffer-window (active-minibuffer-window))
                    (position
                     (reference-explorer-lookup--vertico-candidate-position)))
          (setq preview
                (reference-explorer-lookup--show-temporary-preview-at-position
                 entry position minibuffer-window
                 (reference-explorer-lookup--thesaurus-term target))))))))

(defun reference-explorer-lookup--consult-thesaurus
    (targets &optional origin-window)
  "Select one of fixed thesaurus TARGETS and replace its source text.
ORIGIN-WINDOW receives focus when an interactive preview is closed."
  (require 'consult)
  (if (null targets)
      (message "Thesaurus: no matches")
    (let* ((tag (make-symbol "reference-explorer-thesaurus-control"))
           (reference-explorer-lookup--consult-toggle-tag tag)
           (reference-explorer-lookup--consult-origin
            (reference-explorer-context-create
             :window (or origin-window (selected-window))))
           (result
            (catch tag
              (list
               'return
               (consult--read
                (cl-loop for target in targets
                         for id from 0
                         collect
                         (reference-explorer-lookup--thesaurus-consult-candidate
                          target id))
                :prompt "Synonym: "
                :category 'reference-explorer-thesaurus-candidate
                :require-match t
                :sort nil
                :lookup #'consult--lookup-candidate
                :annotate #'reference-explorer-lookup--thesaurus-annotation
                :state (reference-explorer-lookup--thesaurus-preview-state)
                :preview-key
                `(:debounce ,reference-explorer-lookup-preview-debounce any))))))
      (pcase result
        (`(return ,selected)
         (when selected
           (reference-explorer-lookup-thesaurus-replace selected)))
        (`(interact ,preview ,window)
         (reference-explorer-lookup--activate-preview-interaction
          preview window))))))

(defun reference-explorer-lookup--thesaurus-show-targets
    (query targets source-window source-marker source-bounds)
  "Show QUERY's thesaurus TARGETS using quick UI or Consult."
  (if (not (display-graphic-p))
      (reference-explorer-lookup--consult-thesaurus targets source-window)
    (reference-explorer-lookup--quick-open-session
     (reference-explorer-lookup--make-quick-session
      :query query
      :query-options (list (cons query targets))
      :query-index 0
      :entries targets
      :index 0
      :source-window source-window
      :source-marker source-marker
      :source-bounds source-bounds
      :accept-function #'reference-explorer-lookup-thesaurus-replace
      :consult-function
      (lambda (entries)
        (reference-explorer-lookup--consult-thesaurus entries source-window))
      :help "TAB:置換  H-i:preview操作  M-m:Consult  Embark:その他の操作"))))

(defun reference-explorer-lookup--thesaurus-targets
    (results buffer beginning end original)
  "Wrap RESULTS with their editable source context."
  (mapcar
   (lambda (result)
     (reference-explorer-lookup--make-thesaurus-candidate
      :result result
      :buffer buffer
      :beginning (copy-marker beginning)
      :end (copy-marker end t)
      :original original))
   results))

(defun reference-explorer-lookup--query-bounds-at-point (query)
  "Return buffer bounds matching extracted QUERY around point."
  (or
   (seq-find
    (lambda (bounds)
      (equal query
             (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (reference-explorer-lookup-word-bound-candidates-at-point))
   (bounds-of-thing-at-point 'word)))

(defun reference-explorer-lookup--thesaurus-search
    (query buffer beginning end source-window source-marker)
  "Retrieve QUERY and present candidates that may replace BEGINNING to END."
  (let ((original
         (with-current-buffer buffer
           (buffer-substring-no-properties beginning end)))
        (beginning-marker (copy-marker beginning))
        (end-marker (copy-marker end t)))
    (message "Thesaurus: searching for “%s”…" query)
    (reference-explorer-thesaurus-fetch
     query 'synonyms
     (lambda (results)
       (cond
        ((not (and (buffer-live-p buffer)
                   (marker-position beginning-marker)
                   (marker-position end-marker)))
         (message "Thesaurus: source buffer is no longer available"))
        ((null results)
         (message "Thesaurus: no synonyms for “%s”" query))
        (t
         (let ((targets
                (reference-explorer-lookup--thesaurus-targets
                 results buffer beginning-marker end-marker original)))
           (reference-explorer-lookup--thesaurus-show-targets
            query targets
            (if (window-live-p source-window)
                source-window
              (or (get-buffer-window buffer t) (selected-window)))
            source-marker (cons beginning-marker end-marker))))))
     (lambda (message)
       (message "Thesaurus: %s" message)))))

;;;###autoload
(defun reference-explorer-lookup-thesaurus-at-point ()
  "Choose an online synonym and replace the region or term at point.
Retrieval starts once, when this command is invoked.  Candidate navigation,
local dictionary previews and Embark actions do not contact the online
service."
  (interactive)
  (let* ((region-active (use-region-p))
         (query (reference-explorer-query-at-point))
         (bounds
          (if region-active
              (cons (region-beginning) (region-end))
            (and query
                 (reference-explorer-lookup--query-bounds-at-point query)))))
    (unless (and query bounds)
      (user-error "No replaceable thesaurus query at point"))
    (reference-explorer-lookup--thesaurus-search
     query (current-buffer) (car bounds) (cdr bounds)
     (selected-window) (copy-marker (point)))))

(defun reference-explorer-lookup-thesaurus-search-candidate (candidate)
  "Search synonyms of thesaurus CANDIDATE as a new explicit request."
  (interactive)
  (let* ((target
          (reference-explorer-lookup--thesaurus-candidate-value candidate))
         (term (reference-explorer-lookup--thesaurus-term target))
         (buffer
          (and target
               (reference-explorer-lookup--thesaurus-candidate-buffer target)))
         (beginning
          (and target
               (reference-explorer-lookup--thesaurus-candidate-beginning target)))
         (end
          (and target
               (reference-explorer-lookup--thesaurus-candidate-end target))))
    (unless (and term (buffer-live-p buffer)
                 (markerp beginning) (marker-position beginning)
                 (markerp end) (marker-position end))
      (user-error "The thesaurus source context is no longer available"))
    (reference-explorer-lookup--thesaurus-search
     term buffer beginning end
     (or (get-buffer-window buffer t) (selected-window))
     (copy-marker beginning))))

;; Persistent Embark export

(defun reference-explorer-lookup--export-entry-at-point ()
  "Return the Lookup entry on the current export-buffer line."
  (or (get-text-property (point) 'reference-explorer-lookup-entry)
      (get-text-property (line-beginning-position)
                         'reference-explorer-lookup-entry)
      (and (> (line-end-position) (line-beginning-position))
           (get-text-property (1- (line-end-position))
                              'reference-explorer-lookup-entry))))

(defun reference-explorer-lookup--export-candidate-at-point ()
  "Return the propertized Lookup candidate on the current export line."
  (when (reference-explorer-lookup--export-entry-at-point)
    (buffer-substring (line-beginning-position) (line-end-position))))

(defun reference-explorer-lookup--embark-export-target ()
  "Return an Embark Lookup target at point in an export buffer."
  (when (derived-mode-p 'reference-explorer-lookup-export-mode)
    (when-let ((candidate
                (reference-explorer-lookup--export-candidate-at-point)))
      `(reference-explorer-lookup-entry
        ,candidate ,(line-beginning-position) . ,(line-end-position)))))

(defun reference-explorer-lookup--export-candidate-position (window)
  "Return the current export candidate position in WINDOW's frame pixels."
  (when-let* (((window-live-p window))
              (entry (reference-explorer-lookup--export-entry-at-point))
              (start (line-beginning-position))
              (end (line-end-position))
              (xy (window-absolute-pixel-position start window)))
    (ignore entry)
    ;; `window-absolute-pixel-position' already returns parent-frame
    ;; coordinates; adding the window edges again would place the child frame
    ;; beyond the right edge on a split frame.
    (let* ((frame (window-frame window))
           (char-width (frame-char-width frame))
           (window-left (car (window-inside-pixel-edges window)))
           (line-width (car (window-text-pixel-size window start end)))
           (candidate-right (+ (car xy) line-width char-width))
           (candidate-top (cdr xy)))
      (list candidate-right
            candidate-top
            (- (frame-pixel-width frame) candidate-right char-width)
            (+ window-left char-width)))))

(defun reference-explorer-lookup--export-cancel-preview ()
  "Cancel the pending or visible preview in the current export buffer."
  (when (timerp reference-explorer-lookup--export-preview-timer)
    (cancel-timer reference-explorer-lookup--export-preview-timer))
  (setq reference-explorer-lookup--export-preview-timer nil)
  (when reference-explorer-lookup--export-preview
    (reference-explorer-lookup--close-temporary-preview
     reference-explorer-lookup--export-preview))
  (setq reference-explorer-lookup--export-preview nil
        reference-explorer-lookup--export-preview-entry nil))

(defun reference-explorer-lookup--export-show-preview (buffer entry)
  "Show ENTRY if BUFFER still selects it in a visible export window."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq reference-explorer-lookup--export-preview-timer nil)
      (when (and (eq entry (reference-explorer-lookup--export-entry-at-point))
                 (derived-mode-p 'reference-explorer-lookup-export-mode))
        (when-let* ((window
                     (if (eq (window-buffer (selected-window)) buffer)
                         (selected-window)
                       (get-buffer-window buffer t)))
                    (position
                     (reference-explorer-lookup--export-candidate-position
                      window)))
          (setq reference-explorer-lookup--export-preview
                (reference-explorer-lookup--show-temporary-preview-at-position
                 entry position window)))))))

(defun reference-explorer-lookup--export-schedule-preview ()
  "Schedule a preview for the Lookup entry at point."
  (let ((entry (reference-explorer-lookup--export-entry-at-point)))
    (unless (and (eq entry reference-explorer-lookup--export-preview-entry)
                 (or (timerp reference-explorer-lookup--export-preview-timer)
                     (reference-explorer-lookup--preview-live-p
                      reference-explorer-lookup--export-preview)))
      (reference-explorer-lookup--export-cancel-preview)
      (when entry
        (setq reference-explorer-lookup--export-preview-entry entry
              reference-explorer-lookup--export-preview-timer
              (run-with-idle-timer
               reference-explorer-lookup-preview-debounce nil
               #'reference-explorer-lookup--export-show-preview
               (current-buffer) entry))))))

(defun reference-explorer-lookup--export-window-selection-change (window)
  "Close the export preview when WINDOW is no longer selected."
  ;; Child-frame creation can temporarily change the globally selected
  ;; window.  Treat our child frame as part of its parent, but close the
  ;; preview after selection moves to an unrelated frame.
  (let ((parent-frame (window-frame window))
        (selected-frame (selected-frame)))
    (unless (and (eq window (frame-selected-window parent-frame))
                 (eq (window-buffer window) (current-buffer))
                 (or (eq selected-frame parent-frame)
                     (eq (frame-parent selected-frame) parent-frame)))
      (reference-explorer-lookup--export-cancel-preview))))

(defun reference-explorer-lookup-export-display-entry ()
  "Commit the Lookup entry at point to the Popper content window."
  (interactive)
  (if-let ((entry (reference-explorer-lookup--export-entry-at-point)))
      (progn
        (reference-explorer-lookup--export-cancel-preview)
        (reference-explorer-lookup--display-entry entry))
    (user-error "No Lookup entry on this line")))

(defvar-keymap reference-explorer-lookup-export-mode-map
  :doc "Keymap for exported Lookup search results."
  :parent special-mode-map
  "RET" #'reference-explorer-lookup-export-display-entry)

(define-derived-mode reference-explorer-lookup-export-mode special-mode
  "Lookup-Results"
  "Major mode for persistent Lookup search results."
  (setq-local truncate-lines t
              header-line-format
              "RET: display  H-;: actions")
  (add-hook 'post-command-hook
            #'reference-explorer-lookup--export-schedule-preview nil t)
  (add-hook 'kill-buffer-hook
            #'reference-explorer-lookup--export-cancel-preview nil t)
  (add-hook 'window-selection-change-functions
            #'reference-explorer-lookup--export-window-selection-change nil t)
  (when (boundp 'embark-target-finders)
    (add-hook 'embark-target-finders
              #'reference-explorer-lookup--embark-export-target nil t)))

(defun reference-explorer-lookup-export-candidates (candidates)
  "Create a persistent Lookup results buffer from Embark CANDIDATES."
  (let ((buffer (generate-new-buffer " *Lookup Export*")))
    (with-current-buffer buffer
      (reference-explorer-lookup-export-mode)
      (let ((inhibit-read-only t))
        (dolist (candidate candidates)
          (when-let ((entry
                      (reference-explorer-lookup-candidate-entry candidate)))
            (let ((start (point)))
              (insert (reference-explorer-lookup--plain-entry-heading entry)
                      (propertize
                       (concat "  "
                               (reference-explorer-lookup-entry-source entry))
                       'face 'font-lock-comment-face))
              (add-text-properties
               start (point)
               `(consult--candidate ,entry
                 reference-explorer-lookup-entry ,entry
                 mouse-face highlight))
              (insert "\n"))))
        (goto-char (point-min))))
    ;; Embark exporters select their result buffer as well as returning it;
    ;; `embark-export' performs its final naming and setup in that buffer.
    (set-buffer buffer)
    (reference-explorer-lookup--export-schedule-preview)
    buffer))

;; Consult interface

(defvar-keymap reference-explorer-lookup-consult-map
  :doc "Keymap active while selecting a Lookup entry."
  "M-m" #'reference-explorer-lookup-toggle-consult-mode
  "H-s" #'reference-explorer-lookup-consult-shorten-query
  "H-e" #'reference-explorer-lookup-consult-expand-query
  "H-v" #'reference-explorer-lookup-preview-scroll-up
  "H-V" #'reference-explorer-lookup-preview-scroll-down
  "H-i" #'reference-explorer-lookup-consult-activate-preview
  "H-." #'reference-explorer-lookup-consult-open-reference
  "TAB" #'reference-explorer-lookup-select-candidate
  "<tab>" #'reference-explorer-lookup-select-candidate)

(defun reference-explorer-lookup-consult-activate-preview ()
  "Exit Consult and promote its current preview for interaction."
  (interactive)
  (unless reference-explorer-lookup--consult-toggle-tag
    (user-error "No Consult Lookup session is active"))
  (let ((preview reference-explorer-lookup--active-temporary-preview)
        (origin-window
         (and reference-explorer-lookup--consult-origin
              (reference-explorer-context-window
               reference-explorer-lookup--consult-origin))))
    (unless (and (reference-explorer-lookup--preview-p preview)
                 (reference-explorer-lookup--preview-entry preview))
      (user-error "The current candidate has no operable preview"))
    (when (reference-explorer-lookup--active-webkit-preview-xwidget)
      (setq reference-explorer-lookup--preview-interaction-request preview))
    (throw reference-explorer-lookup--consult-toggle-tag
           (list 'interact preview origin-window))))

(defun reference-explorer-lookup--consult-run-provider (&optional provider)
  "Open the active Consult query through PROVIDER or configured order."
  (unless reference-explorer-lookup--consult-origin
    (user-error "No Consult Lookup session is active"))
  (let ((query (string-trim (minibuffer-contents-no-properties))))
    (when (string-empty-p query)
      (user-error "No Consult Lookup query"))
    (let ((context
           (copy-reference-explorer-context
            reference-explorer-lookup--consult-origin)))
      (setf (reference-explorer-context-query context) query)
      (if provider
          (reference-explorer-run-provider provider context)
        (reference-explorer-run-context context)))))

(defun reference-explorer-lookup-consult-open-reference ()
  "Open the active Consult query with the configured provider order."
  (interactive)
  (reference-explorer-lookup--consult-run-provider))

(defun reference-explorer-lookup-consult-macos-dictionary ()
  "Forward the active Consult query to macOS Dictionary."
  (interactive)
  (reference-explorer-lookup--consult-run-provider 'macos-dictionary))

(defun reference-explorer-lookup-consult-monokakido ()
  "Forward the active Consult query to Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-lookup--consult-run-provider 'monokakido))

(defun reference-explorer-lookup-select-candidate ()
  "Commit the selected Consult Lookup candidate."
  (interactive)
  (if (fboundp 'vertico-exit)
      (vertico-exit)
    (minibuffer-complete-and-exit)))

(defun reference-explorer-lookup--consult-change-query (delta)
  "Move DELTA steps through the contextual Consult query options."
  (unless reference-explorer-lookup--consult-query-options
    (user-error "No contextual Lookup query options"))
  (let* ((input (minibuffer-contents-no-properties))
         (matched-index
          (seq-position reference-explorer-lookup--consult-query-options
                        input #'equal))
         (old-index (or matched-index
                        reference-explorer-lookup--consult-query-index
                        0))
         (new-index
          (max 0
               (min (1- (length reference-explorer-lookup--consult-query-options))
                    (+ old-index delta)))))
    (if (= old-index new-index)
        (message (if (> delta 0)
                     "これ以上縮小できません"
                   "これ以上拡大できません"))
      (setq reference-explorer-lookup--consult-query-index new-index)
      (delete-minibuffer-contents)
      (insert (nth new-index reference-explorer-lookup--consult-query-options)))))

(defun reference-explorer-lookup-consult-shorten-query ()
  "Use the next shorter contextual query in Consult Lookup."
  (interactive)
  (reference-explorer-lookup--consult-change-query 1))

(defun reference-explorer-lookup-consult-expand-query ()
  "Use the next longer contextual query in Consult Lookup."
  (interactive)
  (reference-explorer-lookup--consult-change-query -1))

(defun reference-explorer-lookup-toggle-consult-mode ()
  "Toggle literal and converted search in the active Lookup minibuffer."
  (interactive)
  (unless reference-explorer-lookup--consult-toggle-tag
    (user-error "No Consult Lookup session is active"))
  (let ((mode (if (eq reference-explorer-lookup--active-consult-mode 'literal)
                  'converted
                'literal))
        (input (minibuffer-contents-no-properties)))
    (setq reference-explorer-lookup-consult-mode mode)
    (throw reference-explorer-lookup--consult-toggle-tag
           (list 'toggle mode input))))

(defun reference-explorer-lookup--completion-overrides (mode)
  "Return completion category overrides appropriate for MODE."
  (if (eq mode 'converted)
      (progn
        (unless reference-explorer-lookup-converted-completion-style
          (user-error "Converted search requires a configured completion style"))
        (cons
         `(reference-explorer-lookup-entry
           (styles ,reference-explorer-lookup-converted-completion-style basic))
         completion-category-overrides))
    completion-category-overrides))

(defun reference-explorer-lookup--consult-read (initial mode)
  "Read a Lookup entry using INITIAL text and search MODE."
  (require 'consult)
  (let* ((reference-explorer-lookup--active-consult-mode mode)
         (tag (make-symbol "reference-explorer-lookup-toggle"))
         (reference-explorer-lookup--consult-toggle-tag tag)
         (completion-category-overrides
          (reference-explorer-lookup--completion-overrides mode))
         (result
          (catch tag
            (list
             'return
             (consult--read
              (consult--dynamic-collection
                  (lambda (input)
                    (reference-explorer-lookup--entry-candidates input mode))
                :min-input 1
                :debounce reference-explorer-lookup-search-debounce)
              :prompt (format "Lookup [%s] (M-m toggles): " mode)
              :initial initial
              :history 'reference-explorer-lookup-history
              :category 'reference-explorer-lookup-entry
              :require-match t
              :sort nil
              :keymap reference-explorer-lookup-consult-map
              :lookup #'consult--lookup-candidate
              :annotate #'reference-explorer-lookup--entry-annotation
              :state (reference-explorer-lookup--preview-state)
              :preview-key
              `(:debounce ,reference-explorer-lookup-preview-debounce any))))))
    result))

(defun reference-explorer-lookup--consult-loop (initial mode &optional queries)
  "Select a Lookup entry, starting with INITIAL and MODE.
QUERIES lists longest-to-shortest contextual inputs available with H-e/H-s."
  (let ((reference-explorer-lookup--consult-query-options queries)
        (reference-explorer-lookup--consult-query-index
         (and initial (seq-position queries initial #'equal)))
        (continue t)
        entry
        interaction)
    (while continue
      (pcase (reference-explorer-lookup--consult-read initial mode)
        (`(toggle ,new-mode ,new-input)
         (setq mode new-mode
               initial new-input))
        (`(return ,selected)
         (setq entry selected
               continue nil))
        (`(interact ,preview ,origin-window)
         (setq interaction (cons preview origin-window)
               continue nil))))
    (cond
     (interaction
      (reference-explorer-lookup--activate-preview-interaction
       (car interaction) (cdr interaction)))
     (entry
      (reference-explorer-lookup--display-entry entry)))))

;;;###autoload
(defun reference-explorer-lookup-consult ()
  "Select a dictionary entry from blank input using the previous mode."
  (interactive)
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let ((reference-explorer-lookup--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker (point))
          :window (selected-window))))
    (reference-explorer-lookup--consult-loop nil reference-explorer-lookup-consult-mode)))

;;;###autoload
(defun reference-explorer-lookup-consult-at-point ()
  "Select a dictionary entry using the region or word at point.
Contextual input always starts in literal mode."
  (interactive)
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let* ((queries
          (if (use-region-p)
              (list (buffer-substring-no-properties
                     (region-beginning) (region-end)))
            (reference-explorer-lookup--quick-query-candidates-at-point)))
         (initial (car queries))
        (reference-explorer-lookup--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker (point))
          :window (selected-window))))
    (reference-explorer-lookup--consult-loop initial 'literal queries)))

;; Dash-compatible docsets

(defun reference-explorer-lookup--context-major-mode (context)
  "Return the originating major mode recorded by CONTEXT."
  (when-let* ((marker (reference-explorer-context-marker context))
              (buffer (and (markerp marker) (marker-buffer marker))))
    (buffer-local-value 'major-mode buffer)))

(defun reference-explorer-lookup--context-query-options (context)
  "Return longest-to-shortest textual queries around CONTEXT."
  (let ((query (reference-explorer-context-query context)))
    (if (not (reference-explorer-context-automatic context))
        (list query)
      (when-let* ((marker (reference-explorer-context-marker context))
                  (buffer (and (markerp marker) (marker-buffer marker))))
        (with-current-buffer buffer
          (save-excursion
            (goto-char marker)
            (let ((queries
                   (mapcar
                    (lambda (bounds)
                      (buffer-substring-no-properties
                       (car bounds) (cdr bounds)))
                    (reference-explorer-lookup-word-bound-candidates-at-point))))
              (cons query (delete query queries)))))))))

(defun reference-explorer-lookup--consult-docset-read (initial mode)
  "Read and return a docset result starting with INITIAL for MODE."
  (require 'consult)
  (let* ((tag (make-symbol "reference-explorer-docset-control"))
         (reference-explorer-lookup--consult-toggle-tag tag))
    (catch tag
      (list
       'return
       (consult--read
        (consult--dynamic-collection
            (lambda (input)
              (reference-explorer-lookup--docset-candidates input mode))
          :min-input 1
          :debounce reference-explorer-lookup-search-debounce)
        :prompt "Docset: "
        :initial initial
        :history 'reference-explorer-lookup-history
        :category 'reference-explorer-docset-result
        :require-match t
        :sort nil
        :keymap reference-explorer-lookup-consult-map
        :lookup #'consult--lookup-candidate
        :annotate (lambda (candidate)
                    (reference-explorer-lookup--docset-annotation candidate mode))
        :state (reference-explorer-lookup--preview-state)
        :preview-key `(:debounce ,reference-explorer-lookup-preview-debounce any))))))

(defun reference-explorer-lookup-consult-docset (query mode &optional origin-window)
  "Select a docset result for QUERY and major MODE, then display it.
ORIGIN-WINDOW receives focus after direct preview interaction ends."
  (let ((reference-explorer-lookup--consult-origin
         (reference-explorer-context-create
          :query query
          :window (or origin-window (selected-window)))))
    (pcase (reference-explorer-lookup--consult-docset-read query mode)
      (`(return ,result)
       (when result
         (reference-explorer-lookup--display-entry result)))
      (`(interact ,preview ,window)
       (reference-explorer-lookup--activate-preview-interaction
        preview window)))))

(defun reference-explorer-lookup--docset-quick-options (queries mode)
  "Search every member of QUERIES in docsets selected for MODE."
  (mapcar (lambda (query)
            (cons query (reference-explorer-docset-search query mode)))
          queries))

(defun reference-explorer-lookup-docset-provider-available-p ()
  "Return non-nil when Emacs has built-in SQLite support."
  (sqlite-available-p))

(defun reference-explorer-lookup-docset-provider-display (context)
  "Display docset matches for reference CONTEXT."
  (let* ((mode (reference-explorer-lookup--context-major-mode context))
         (docsets (and mode (reference-explorer-docset-for-mode mode))))
    (unless docsets
      (signal 'reference-explorer-provider-unavailable
              (list (format "No installed docset is configured for %s" mode))))
    (let* ((queries (or (reference-explorer-lookup--context-query-options context)
                        (list (reference-explorer-context-query context))))
           (options (reference-explorer-lookup--docset-quick-options queries mode))
           (query (caar options))
           (source-window (reference-explorer-context-window context))
           (source-marker (reference-explorer-context-marker context)))
      (if (not (display-graphic-p))
          (reference-explorer-lookup-consult-docset query mode source-window)
        (reference-explorer-lookup--quick-open-session
         (reference-explorer-lookup--make-quick-session
          :query query
          :query-options options
          :query-index 0
          :entries (cdar options)
          :index 0
          :source-window source-window
          :source-marker source-marker
          :consult-function
          (lambda (_entries)
            (reference-explorer-lookup-consult-docset
             query mode source-window))
          :help "H-s/e:検索語を縮小/拡大  H-i:preview操作  M-m:Consult"))))))

(reference-explorer-register-provider
 'docset
 #'reference-explorer-lookup-docset-provider-display
 #'reference-explorer-lookup-docset-provider-available-p)

(defun reference-explorer-lookup-provider-available-p ()
  "Return non-nil when GNU Lookup is available."
  (or (fboundp 'lookup-initialize) (locate-library "lookup")))

(defun reference-explorer-lookup-provider-display (context)
  "Display reference CONTEXT with quick GNU Lookup."
  (unless (reference-explorer-lookup-provider-available-p)
    (signal 'reference-explorer-provider-unavailable
            '("GNU Lookup is unavailable")))
  (reference-explorer-lookup-quick-lookup-query
   (reference-explorer-context-query context)
   (reference-explorer-context-window context)
   (reference-explorer-context-marker context)))

(reference-explorer-register-provider
 'lookup
 #'reference-explorer-lookup-provider-display
 #'reference-explorer-lookup-provider-available-p)

(defun reference-explorer-lookup-lookup-content-appearance ()
  "Apply the shared appearance to a Lookup content buffer."
  (when (display-graphic-p)
    (setq-local buffer-face-mode-face
                (append
                 (when (and reference-explorer-lookup-content-font-family
                            (find-font
                             (font-spec
                              :family reference-explorer-lookup-content-font-family)))
                   (list :family reference-explorer-lookup-content-font-family))
                 '(:height 1.15)))
    (buffer-face-mode 1)))

(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables
               'reference-explorer-lookup-consult-mode)
  (add-to-list 'savehist-additional-variables
               'reference-explorer-lookup-history))

(with-eval-after-load 'embark
  (set-keymap-parent reference-explorer-lookup-embark-map embark-general-map)
  (set-keymap-parent reference-explorer-lookup-thesaurus-embark-map
                     embark-general-map)
  (set-keymap-parent reference-explorer-lookup-docset-embark-map
                     embark-general-map)
  (define-key reference-explorer-lookup-embark-map (kbd "RET")
              #'reference-explorer-lookup-display-candidate)
  (define-key reference-explorer-lookup-embark-map (kbd "w")
              #'reference-explorer-lookup-copy-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-lookup-entry
                 . reference-explorer-lookup-embark-map))
  (setf (alist-get 'reference-explorer-lookup-entry
                   embark-default-action-overrides)
        #'reference-explorer-lookup-display-candidate)
  (setf (alist-get 'reference-explorer-lookup-entry embark-exporters-alist)
        #'reference-explorer-lookup-export-candidates)
  (define-key reference-explorer-lookup-thesaurus-embark-map (kbd "RET")
              #'reference-explorer-lookup-thesaurus-replace)
  (define-key reference-explorer-lookup-thesaurus-embark-map (kbd "r")
              #'reference-explorer-lookup-thesaurus-replace)
  (define-key reference-explorer-lookup-thesaurus-embark-map (kbd "l")
              #'reference-explorer-lookup-thesaurus-lookup)
  (define-key reference-explorer-lookup-thesaurus-embark-map (kbd "w")
              #'reference-explorer-lookup-thesaurus-copy)
  (define-key reference-explorer-lookup-thesaurus-embark-map (kbd "s")
              #'reference-explorer-lookup-thesaurus-search-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-thesaurus-candidate
                 . reference-explorer-lookup-thesaurus-embark-map))
  (setf (alist-get 'reference-explorer-thesaurus-candidate
                   embark-default-action-overrides)
        #'reference-explorer-lookup-thesaurus-replace)
  (define-key reference-explorer-lookup-docset-embark-map (kbd "RET")
              #'reference-explorer-lookup-display-docset-candidate)
  (define-key reference-explorer-lookup-docset-embark-map (kbd "w")
              #'reference-explorer-lookup-copy-docset-url)
  (define-key reference-explorer-lookup-docset-embark-map (kbd "b")
              #'reference-explorer-lookup-browse-docset-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-docset-result
                 . reference-explorer-lookup-docset-embark-map))
  (setf (alist-get 'reference-explorer-docset-result
                   embark-default-action-overrides)
        #'reference-explorer-lookup-display-docset-candidate))

(when (locate-library "lookup")
  (setq lookup-enable-splash nil)
  (require 'lookup)
  (require 'lookup-kanji)
  (setq lookup-content-buffer reference-explorer-lookup-content-buffer-name)
  (add-hook 'lookup-content-mode-hook
            #'reference-explorer-lookup-lookup-content-appearance))

(provide 'reference-explorer-lookup)
;;; reference-explorer-lookup.el ends here
