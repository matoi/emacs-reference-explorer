;;; reference-explorer-ui.el --- Shared reference selection UI -*- lexical-binding: t -*-

;;; Commentary:

;; Shared Quick and Consult selection, child-frame preview, query conversion,
;; and interaction state for Reference Explorer sources.  Concrete sources
;; own retrieval, source-specific candidates, and committed rendering.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-core)
(require 'reference-explorer-source)
(require 'reference-explorer-phrase-segmenter)
(require 'reference-explorer-phrase-segmenter-emacs)
(require 'reference-explorer-phrase-segmenter-mecab)
(require 'reference-explorer-phrase-segmenter-org)
(require 'reference-explorer-source-docset)
(require 'reference-explorer-source-thesaurus)
(require 'reference-explorer-source-monokakido)
(when (eq system-type 'darwin)
  (require 'reference-explorer-source-macos))
(require 'seq)
(require 'subr-x)

(declare-function nerd-icons-corfu-formatter "nerd-icons-corfu" (metadata))
(declare-function reference-explorer-source-lookup--plain-entry-heading
                  "reference-explorer-source-lookup" (entry))
(declare-function reference-explorer-source-lookup--quick-search-entries
                  "reference-explorer-source-lookup" (input))
(declare-function reference-explorer-source-lookup-entry-source
                  "reference-explorer-source-lookup" (entry))
(declare-function reference-explorer-source-lookup-available-p
                  "reference-explorer-source-lookup" ())
(declare-function reference-explorer-source-lookup-render-entry
                  "reference-explorer-source-lookup" (entry buffer-name))
(declare-function xwidget-insert "xwidget" (pos type title width height
                                                &optional callback))
(declare-function xwidget-put "xwidget" (xwidget property value))
(declare-function xwidget-webkit-callback "xwidget" (xwidget event-type))
(declare-function xwidget-webkit-display-callback "xwidget" (&rest arguments))
(declare-function xwidget-webkit-mode "xwidget" ())
(declare-function xwidget-webkit-scroll-down "xwidget" ())
(declare-function xwidget-webkit-scroll-up "xwidget" ())
(defvar completion-extra-properties)
(defvar reference-explorer-source-lookup-content-buffer-name)
(defvar reference-explorer-source-lookup-preview-highlight-sources)

(autoload 'reference-explorer-source-docset-manager-install "reference-explorer-source-docset-manager"
  "Install a version-selected docset." t)
(autoload 'reference-explorer-source-docset-manager-update "reference-explorer-source-docset-manager"
  "Update a version-selected docset." t)
(autoload 'reference-explorer-source-docset-manager-list-versions "reference-explorer-source-docset-manager"
  "List versions published by a docset feed." t)

(defgroup reference-explorer-ui nil
  "Shared selection and preview UI for Reference Explorer."
  :group 'applications)



(defcustom reference-explorer-ui-phrase-selector-function
  #'reference-explorer-phrase-segmenter-at-point
  "Function selecting the textual reference phrase at point."
  :type 'function
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-origin-position-function
  #'reference-explorer-phrase-segmenter-visible-position-at-point
  "Function returning the visible buffer position used to anchor reference UI."
  :type 'function
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-phrase-candidates-function
  #'reference-explorer-phrase-segmenter-candidates-at-point
  "Function returning contextual phrase candidates around point."
  :type 'function
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-phrase-candidate-bounds-function
  #'reference-explorer-phrase-segmenter-candidate-bounds-at-point
  "Function returning contextual phrase bounds around point."
  :type 'function
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-display-buffer-function #'display-buffer
  "Function used to display a committed dictionary entry buffer."
  :type 'function
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-converted-completion-style nil
  "Completion style used by converted-mode Consult lookup.
The host configuration owns completion setup and should set this to the style
that corresponds to its query conversion.  Nil disables converted mode."
  :type '(choice (const :tag "Disabled" nil) symbol)
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-query-conversion-function
  #'reference-explorer-ui--roman-to-hiragana
  "Function used to transform input in converted search mode.
It receives the minibuffer input string and returns the backend query string."
  :type 'function
  :group 'reference-explorer-ui)

(defun reference-explorer-ui-phrase-at-point ()
  "Return the configured reference phrase at point."
  (funcall reference-explorer-ui-phrase-selector-function))

(defun reference-explorer-ui-origin-position-at-point ()
  "Return the visible origin position used to anchor reference UI."
  (funcall reference-explorer-ui-origin-position-function))

(defun reference-explorer-ui-phrase-candidates-at-point ()
  "Return contextual phrase candidates around point."
  (funcall reference-explorer-ui-phrase-candidates-function))

(defun reference-explorer-ui-phrase-candidate-bounds-at-point ()
  "Return contextual phrase bounds around point."
  (funcall reference-explorer-ui-phrase-candidate-bounds-function))

(setq reference-explorer-phrase-selector-function
      #'reference-explorer-ui-phrase-at-point
      reference-explorer-origin-position-function
      #'reference-explorer-ui-origin-position-at-point)

(defcustom reference-explorer-ui-content-font-family nil
  "Font family used for reference content in graphical sessions.
The setting is ignored when the family is unavailable."
  :type '(choice (const :tag "Default font" nil) string)
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-consult-mode 'literal
  "Search mode used by the next blank reference invocation.
`literal' searches the input as written.  `converted' transforms it with
`reference-explorer-ui-query-conversion-function' and filters headings with
`reference-explorer-ui-converted-completion-style'.  The value is saved by
Savehist and updated when M-m switches mode in the reference minibuffer."
  :type '(choice (const literal) (const converted))
  :group 'reference-explorer-ui)

;; Migrate the value previously persisted by Savehist under the old name.
(when (eq reference-explorer-ui-consult-mode 'reading)
  (setq reference-explorer-ui-consult-mode 'converted))

(defcustom reference-explorer-ui-search-debounce 0.15
  "Seconds to debounce dynamic reference entry searches."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-quick-max-candidates 8
  "Maximum number of candidates shown by quick reference."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-quick-max-width 60
  "Maximum width in columns of the quick reference candidate list."
  :type 'integer
  :group 'reference-explorer-ui)









(defcustom reference-explorer-ui-preview-debounce 0.25
  "Seconds to wait before previewing the selected reference entry."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-preview-max-width 80
  "Maximum width in columns of the temporary reference preview."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-preview-min-width 20
  "Minimum usable width in columns of the temporary reference preview.
No preview is shown when neither side of the selected candidate has this much
space."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-preview-max-width 100
  "Maximum width in columns of a temporary docset article preview."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-preview-min-width 64
  "Minimum displayed width in columns of a docset article preview.
Unlike a short dictionary definition, a documentation article becomes hard to
read when its child frame is fitted tightly to a short heading."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-preview-max-height 28
  "Maximum height in lines of a temporary docset article preview."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-preview-renderer 'webkit
  "Renderer used for temporary graphical docset previews.
`webkit' renders the isolated entry with its original stylesheets.  It falls
back to `shr' when this Emacs lacks xwidget support or WebKit setup fails.
Committed Popper content and terminal Emacs always use `shr'."
  :type '(choice (const :tag "WebKit with SHR fallback" webkit)
                 (const :tag "SHR" shr))
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-webkit-font-size 14
  "Root font size in pixels of a temporary WebKit docset preview.
The docset stylesheet may scale headings and code relative to this value."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-webkit-preview-width 760
  "Preferred width in pixels of a temporary WebKit docset preview."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-webkit-preview-min-width 480
  "Minimum usable width in pixels of a WebKit docset preview."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-docset-webkit-preview-height 520
  "Preferred height in pixels of a temporary WebKit docset preview.
The frame is clamped to the available height of its parent frame."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-preview-font-height 0.9
  "Font height of temporary reference previews relative to the default face."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-preview-width-slack 2
  "Extra character widths reserved beyond measured preview text."
  :type 'integer
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-quick-left-margin-width 0.5
  "Width of the quick candidate list's left margin, in columns."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-quick-right-margin-width 0.5
  "Width of the quick candidate list's right margin, in columns."
  :type 'number
  :group 'reference-explorer-ui)

(defcustom reference-explorer-ui-preview-margin-width 1
  "Window margin on each side of temporary reference previews, in columns."
  :type 'integer
  :group 'reference-explorer-ui)

(defconst reference-explorer-ui-preview-buffer-name " *Reference Preview*"
  "Base name for hidden buffers used by temporary reference previews.")

(defconst reference-explorer-ui--preview-horizontal-overhead 2
  "Child-frame pixels outside the preview's horizontal body.")

(defconst reference-explorer-ui--preview-vertical-overhead 2
  "Child-frame pixels outside the preview's measured vertical body.")

(defconst reference-explorer-ui--preview-border-width 1
  "Internal border width of a temporary preview frame in pixels.")

(cl-defstruct (reference-explorer-ui--preview
               (:constructor reference-explorer-ui--make-preview
                             (frame buffer &optional entry)))
  "Resources owned by one temporary reference preview."
  frame
  buffer
  entry)

(cl-defstruct (reference-explorer-ui--quick-session
               (:constructor reference-explorer-ui--make-quick-session))
  "Resources and selection state owned by one quick reference invocation."
  source
  context
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
  consult-function
  help
  exit-function)

(defvar reference-explorer-ui-history nil
  "Minibuffer history for Consult reference queries.")



(defvar reference-explorer-ui--roman-rules nil
  "Normalized copy of Emacs's standard Roman-to-kana rules.")

(defvar reference-explorer-ui--consult-toggle-tag nil)
(defvar reference-explorer-ui--active-consult-mode nil)
(defvar reference-explorer-ui--consult-origin nil)
(defvar reference-explorer-ui--consult-query-options nil)
(defvar reference-explorer-ui--consult-query-index nil)
(defvar reference-explorer-ui--quick-session nil)
(defvar reference-explorer-ui--active-temporary-preview nil
  "Most recently displayed temporary reference preview.")
(defvar reference-explorer-ui--preview-interaction nil
  "WebKit preview currently promoted for direct user interaction.")
(defvar reference-explorer-ui--preview-interaction-origin-window nil
  "Window to restore after direct WebKit preview interaction.")
(defvar reference-explorer-ui--preview-interaction-request nil
  "Preview a Consult state function must retain while its minibuffer exits.")
(defvar reference-explorer-ui--docset-webkit-warning-shown nil
  "Non-nil after warning once about a WebKit docset preview failure.")
(defvar reference-explorer-ui--docset-webkit-preview-caches
  (make-hash-table :test #'eq)
  "Reusable WebKit previews keyed by their parent graphical frame.")
(defvar-local reference-explorer-ui--docset-preview-file nil
  "Temporary HTML file owned by the current WebKit preview buffer.")
(defvar-local reference-explorer-ui--docset-preview-obsolete-files nil
  "Superseded HTML files awaiting a WebKit `load-finished' event.")
(defvar-local reference-explorer-ui--docset-preview-file-cleanup-timer nil
  "Fallback timer that deletes HTML from superseded WebKit navigations.")
(defvar-local reference-explorer-ui--export-preview-timer nil)
(defvar-local reference-explorer-ui--export-preview nil)
(defvar-local reference-explorer-ui--export-preview-entry nil)
(defvar quail-japanese-transliteration-rules)
(defvar vertico--candidates-ov)

(defvar xwidget-view-list)
(defvar xwidget-webkit--loading-p)
(defvar xwidget-webkit-buffer-name-format)
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
(declare-function vertico-exit "vertico" (&optional arg))

(defvar reference-explorer-ui-thesaurus-embark-map (make-sparse-keymap)
  "Embark actions for thesaurus candidates.")

(defvar reference-explorer-ui-docset-embark-map (make-sparse-keymap)
  "Embark actions for docset candidates.")

(defface reference-explorer-ui-preview
  '((t :inherit default))
  "Face used by the temporary reference preview child frame."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-preview-border
  '((((background dark)) :background "#505050")
    (((background light)) :background "#c8c8c8")
    (t :background "gray"))
  "Face used for the temporary reference preview border."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-quick-current
  '((t :inherit highlight :extend t))
  "Face used for the selected quick reference candidate."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-quick-default
  '((t :inherit reference-explorer-ui-preview))
  "Face used for the quick reference candidate list."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-quick-source
  '((t :inherit shadow))
  "Face used for dictionary names in quick reference candidates."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-source-highlight
  '((t :inherit match))
  "Face used for the source text selected by quick reference."
  :group 'reference-explorer-ui)

(defface reference-explorer-ui-preview-match
  '((t :inherit match))
  "Face used for the active search term in reference previews."
  :group 'reference-explorer-ui)

;; Query conversion

(defun reference-explorer-ui--roman-rule-table ()
  "Return Emacs's standard Roman-to-kana transliteration rules."
  (or reference-explorer-ui--roman-rules
      (progn
        (unless (boundp 'quail-japanese-transliteration-rules)
          (load "quail/japanese" nil t))
        (unless (boundp 'quail-japanese-transliteration-rules)
          (error "Emacs Japanese transliteration rules are unavailable"))
        (setq reference-explorer-ui--roman-rules
              (cl-loop
               for (roman translation) in quail-japanese-transliteration-rules
               when (or (stringp translation) (vectorp translation))
               collect
               (cons roman
                     (if (vectorp translation)
                         (aref translation 0)
                       translation)))))))

(defun reference-explorer-ui--roman-rule-prefix-p (string rules)
  "Return non-nil when STRING is an unfinished key in RULES."
  (seq-some (lambda (rule)
              (and (> (length (car rule)) (length string))
                   (string-prefix-p string (car rule))))
            rules))

(defun reference-explorer-ui--roman-to-hiragana (input)
  "Convert Roman INPUT to hiragana with Emacs's Japanese input rules.
An unfinished trailing syllable is omitted so incremental search can keep
using the last complete reading.  A final n is treated as ん for searching."
  (let* ((input (downcase input))
         (rules (reference-explorer-ui--roman-rule-table))
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
           ((reference-explorer-ui--roman-rule-prefix-p remaining rules)
            (setq index (length input)))
           (t
            (push (char-to-string character) parts)
            (setq index (1+ index))))))))
    (japanese-hiragana (apply #'concat (nreverse parts)))))

(defun reference-explorer-ui--backend-query (input mode)
  "Return the converted backend query for INPUT in MODE."
  (let* ((input (string-trim input))
         (query (if (eq mode 'converted)
                    (funcall reference-explorer-ui-query-conversion-function
                             input)
                  input)))
    (unless (string-empty-p query)
      query)))









(defun reference-explorer-ui--quick-query-candidates-at-point ()
  "Return strictly shorter contextual queries around point.
Text-object candidates are longest-first.  Equal-length alternatives are
omitted so moving through this list always has clear expand/shrink semantics."
  (let ((maximum most-positive-fixnum)
        queries)
    (dolist (candidate
             (delete-dups
              (reference-explorer-ui-phrase-candidates-at-point)))
      (let ((length (length candidate)))
        (when (and (not (string-empty-p (string-trim candidate)))
                   (< length maximum))
          (push candidate queries)
          (setq maximum length))))
    (nreverse queries)))

(defun reference-explorer-ui--quick-query-options (queries search-function)
  "Return quick options for QUERIES using SEARCH-FUNCTION.
Each result is a cons of the query string and its source candidates, including
empty result lists."
  (cl-loop for query in queries
           unless (string-empty-p (string-trim query))
           collect (cons query
                         (funcall search-function query))))





(defun reference-explorer-ui--docset-candidates (input mode)
  "Return Consult candidates for docset INPUT in major MODE."
  (cl-loop for result in (reference-explorer-source-docset-search input mode)
           for id from 0
           for value = (reference-explorer-source-make-candidate
                        'docset result reference-explorer-ui--consult-origin)
           for heading = (reference-explorer-candidate-label value)
           for candidate = (consult--tofu-append heading id)
           do (progn
                (put-text-property (length heading) (length candidate)
                                   'display "" candidate)
                (put-text-property 0 (length heading)
                                   'consult--candidate value candidate))
           collect candidate))

(defun reference-explorer-ui--docset-annotation (candidate &optional mode)
  "Return a compact kind annotation for docset CANDIDATE in MODE."
  (when-let ((result (reference-explorer-ui-docset-candidate candidate)))
    (concat "  "
            (reference-explorer-ui--candidate-annotation
             result
             (> (length (reference-explorer-source-docset-for-mode mode)) 1)))))

(defun reference-explorer-ui-docset-candidate (candidate)
  "Return the docset result stored in CANDIDATE, or nil."
  (let ((value
         (cond
          ((reference-explorer-candidate-p candidate) candidate)
          ((stringp candidate)
           (or (get-text-property 0 'consult--candidate candidate)
               (get-text-property 0 'reference-explorer-ui-docset
                                  candidate))))))
    (when (reference-explorer-candidate-p value)
      (setq value (reference-explorer-candidate-value value)))
    (and (reference-explorer-source-docset-result-p value) value)))







(defun reference-explorer-ui--candidate-label (candidate)
  "Return the visible label for reference CANDIDATE."
  (cond
   ((reference-explorer-candidate-p candidate)
    (reference-explorer-candidate-label candidate))
   ((reference-explorer-source-docset-result-p candidate)
    (reference-explorer-source-docset-result-name candidate))
   (t (reference-explorer-source-lookup--plain-entry-heading candidate))))

(defun reference-explorer-ui--docset-kind-symbol (type)
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

(defun reference-explorer-ui--docset-corfu-kind (type)
  "Return the Corfu completion kind corresponding to docset TYPE."
  (pcase (reference-explorer-ui--docset-kind-symbol type)
    ((or 'attribute 'field) 'field)
    ((or 'guide 'section) 'text)
    ('protocol 'interface)
    ('type 'class)
    (kind kind)))

(defun reference-explorer-ui--docset-kind-fallback (type)
  "Return an unambiguous text fallback for docset TYPE."
  (propertize (format "[%s] " (or type "Reference"))
              'face 'reference-explorer-ui-quick-source))

(defun reference-explorer-ui--docset-kind-icon (type)
  "Return the Nerd Font field used by Corfu for docset TYPE.
Fall back to an explicit text label when `nerd-icons-corfu' is unavailable."
  (let ((kind (reference-explorer-ui--docset-corfu-kind type)))
    (or
     (when (and (require 'nerd-icons-corfu nil t)
                (fboundp 'nerd-icons-corfu-formatter))
       (let* ((completion-extra-properties
               `(:company-kind ,(lambda (_candidate) kind)))
              (formatter (nerd-icons-corfu-formatter nil)))
         (and formatter (funcall formatter type))))
     (reference-explorer-ui--docset-kind-fallback type))))

(defun reference-explorer-ui--candidate-annotation
    (candidate &optional show-docset-source)
  "Return a compact annotation for reference CANDIDATE.
SHOW-DOCSET-SOURCE keeps the source name when several docsets are searched."
  (cond
   ((reference-explorer-candidate-p candidate)
    (reference-explorer-candidate-annotation candidate))
   ((reference-explorer-source-docset-result-p candidate)
    (let ((icon
           (reference-explorer-ui--docset-kind-icon
            (reference-explorer-source-docset-result-type candidate)))
          (source
           (and show-docset-source
                (reference-explorer-source-docset-feed
                 (reference-explorer-source-docset-result-docset candidate)))))
      (string-join (delq nil (list icon source)) "  ")))
   (t (reference-explorer-source-lookup-entry-source candidate))))

(defun reference-explorer-ui--candidate-preview-entry (candidate)
  "Return a local entry suitable for previewing CANDIDATE."
  (let ((source
         (cond
          ((reference-explorer-candidate-p candidate)
           (reference-explorer-candidate-source candidate))
          ((reference-explorer-source-docset-result-p candidate) 'docset)
          (t 'lookup))))
    (and (reference-explorer-source-preview-p source) candidate)))

(defun reference-explorer-ui--preview-query-for-entry (entry query)
  "Return QUERY when ENTRY's source enables preview highlighting."
  (and (not (reference-explorer-candidate-p entry))
       (not (reference-explorer-source-docset-result-p entry))
       query
       (member (reference-explorer-source-lookup-entry-source entry)
               reference-explorer-source-lookup-preview-highlight-sources)
       query))







(defun reference-explorer-ui--render-entry (entry buffer-name)
  "Render reference ENTRY in BUFFER-NAME and return that buffer."
  (cond
   ((reference-explorer-candidate-p entry)
    (reference-explorer-candidate-render entry buffer-name))
   ((reference-explorer-source-docset-result-p entry)
    (reference-explorer-source-docset-render entry buffer-name))
   (t (reference-explorer-source-lookup-render-entry entry buffer-name))))

(defun reference-explorer-ui--highlight-preview-query (query)
  "Highlight literal occurrences of QUERY in the current preview buffer."
  (when (and query (not (string-empty-p (string-trim query))))
    (save-excursion
      (let ((case-fold-search t)
            (regexp (regexp-quote query)))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (add-face-text-property
           (match-beginning 0) (match-end 0)
           'reference-explorer-ui-preview-match nil))))))

(defun reference-explorer-ui--prepare-preview-buffer (buffer &optional query)
  "Simplify and style BUFFER for a temporary preview.
Highlight literal QUERY occurrences when QUERY is non-nil."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (docset-position
           (and (derived-mode-p 'reference-explorer-source-docset-mode) (point))))
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
      (reference-explorer-ui--highlight-preview-query query)
      ;; Docsets can target an anchor inside the rendered page; Lookup
      ;; previews always begin at the article start.
      (goto-char (or docset-position (point-min))))
    (setq-local word-wrap t)
    (buffer-face-set
     (append
      (list :inherit 'reference-explorer-ui-preview)
      (when (and reference-explorer-ui-content-font-family
                 (find-font
                  (font-spec :family reference-explorer-ui-content-font-family)))
        (list :family reference-explorer-ui-content-font-family))
      (list :height reference-explorer-ui-preview-font-height)))
    buffer))





(defun reference-explorer-ui-display-docset-candidate (candidate)
  "Display the docset result represented by Embark CANDIDATE."
  (if-let ((result (reference-explorer-ui-docset-candidate candidate)))
      (reference-explorer-ui--display-entry result)
    (user-error "Docset result data is unavailable")))

(defun reference-explorer-ui-copy-docset-url (candidate)
  "Copy the local URL represented by docset CANDIDATE."
  (if-let* ((result (reference-explorer-ui-docset-candidate candidate))
            (url (reference-explorer-source-docset-result-url result)))
      (progn
        (kill-new url)
        (message "Copied docset URL: %s"
                 (reference-explorer-source-docset-result-name result)))
    (user-error "Docset URL is unavailable")))

(defun reference-explorer-ui-browse-docset-candidate (candidate)
  "Open the local page represented by docset CANDIDATE externally."
  (if-let* ((result (reference-explorer-ui-docset-candidate candidate))
            (url (reference-explorer-source-docset-result-url result)))
      (browse-url url)
    (user-error "Docset URL is unavailable")))





(defun reference-explorer-ui--display-entry (entry)
  "Render reference ENTRY and display it as committed Popper content."
  (let ((buffer
         (reference-explorer-ui--render-entry
         entry
         (cond
           ((reference-explorer-candidate-p entry)
            (format "*Reference %s*"
                    (reference-explorer-candidate-source entry)))
           ((reference-explorer-source-docset-result-p entry)
            reference-explorer-source-docset-content-buffer-name)
           (t reference-explorer-source-lookup-content-buffer-name)))))
    (save-selected-window
      (funcall reference-explorer-ui-display-buffer-function buffer))
    buffer))

(defun reference-explorer-ui-commit-display (candidate _context)
  "Display CANDIDATE, reusing the active quick preview when possible."
  (let* ((session reference-explorer-ui--quick-session)
         (preview (and session
                       (reference-explorer-ui--quick-session-preview session)))
         (reuse (and (reference-explorer-ui--preview-p preview)
                     (eq candidate
                         (reference-explorer-ui--preview-entry preview))
                     (buffer-live-p
                      (reference-explorer-ui--preview-buffer preview))
                     (not (reference-explorer-ui--cached-docset-webkit-preview-p
                           preview)))))
    (if (not reuse)
        (reference-explorer-ui--display-entry candidate)
      (let ((frame (reference-explorer-ui--preview-frame preview))
            (buffer (reference-explorer-ui--preview-buffer preview)))
        (setf (reference-explorer-ui--quick-session-preview session) nil)
        (when (eq preview reference-explorer-ui--active-temporary-preview)
          (setq reference-explorer-ui--active-temporary-preview nil))
        (when (frame-live-p frame)
          (set-frame-parameter frame 'reference-explorer-ui-preview-buffer nil)
          (delete-frame frame))
        (save-selected-window
          (funcall reference-explorer-ui-display-buffer-function buffer))
        buffer))))

(reference-explorer-register-commit-action
 'display #'reference-explorer-ui-commit-display)

(defun reference-explorer-ui--read-source-candidate (source entries _context)
  "Read one of SOURCE candidate ENTRIES with cached annotations."
  (let* ((candidates
          (cl-loop
           for result in entries
           for index from 1
           for label = (reference-explorer-candidate-label result)
           for annotation = (reference-explorer-candidate-annotation result)
           collect
           (cons
            (format "%s%s  [%d]" label
                    (if (string-empty-p annotation)
                        ""
                      (format "  %s" annotation))
                    index)
            result)))
         (selected
          (completing-read
           (format "%s: "
                   (reference-explorer-source-title
                    (reference-explorer-get-source source)))
           candidates nil t)))
    (cdr (assoc selected candidates))))

(defun reference-explorer-ui-open-source (source context)
  "Search registered SOURCE for CONTEXT and present its results."
  (unless (reference-explorer-source-available-p source context)
    (signal 'reference-explorer-source-unavailable
            (list (format "Source is unavailable: %s" source))))
  (let ((query (reference-explorer-context-query context)))
    (reference-explorer-source-search
     source query context
     (lambda (outcome)
       (let ((status (reference-explorer-search-outcome-status outcome))
             (results (reference-explorer-search-outcome-entries outcome)))
         (pcase status
           ('no-match
            (message "%s: no matches for “%s”" source query))
           ('delegated nil)
           ('unavailable
            (signal 'reference-explorer-source-unavailable
                    (list
                     (or (reference-explorer-search-outcome-message outcome)
                         (format "Source is unavailable: %s" source)))))
           ('failed
            (message "%s: %s" source
                     (or (reference-explorer-search-outcome-message outcome)
                         "search failed")))
           ('matched
            (if (display-graphic-p)
                (reference-explorer-ui--quick-open-session
                 (reference-explorer-ui--make-quick-session
                  :source source
                  :context context
                  :query query
                  :query-options (list (cons query results))
                  :query-index 0
                  :entries results
                  :index 0
                  :source-window (reference-explorer-context-window context)
                  :source-marker (reference-explorer-context-marker context)
                  :help "TAB:commit  H-i:preview操作  H-q:quit"))
              (when-let ((result
                          (reference-explorer-ui--read-source-candidate
                           source results context)))
                (reference-explorer-candidate-commit result context))))))))))

(setq reference-explorer-source-default-present-function
      #'reference-explorer-ui-open-source)

(defun reference-explorer-ui--face-includes-p (face value)
  "Return non-nil when face VALUE includes FACE."
  (or (eq value face)
      (and (listp value) (memq face value))))

(defun reference-explorer-ui--vertico-selection (display)
  "Return selected Vertico DISPLAY data as (ROW LINE)."
  (let ((position 0)
        selected)
    (while (and (< position (length display)) (null selected))
      (when (reference-explorer-ui--face-includes-p
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

(defun reference-explorer-ui--vertico-selected-row (display)
  "Return the visual row of the selected candidate in Vertico DISPLAY."
  (car (reference-explorer-ui--vertico-selection display)))

(defun reference-explorer-ui--vertico-candidate-position ()
  "Return the selected Vertico candidate position in parent-frame pixels."
  (when-let* ((minibuffer-window (active-minibuffer-window))
              (buffer (window-buffer minibuffer-window))
              (overlay
               (buffer-local-value 'vertico--candidates-ov buffer))
              ((overlayp overlay))
              (display (overlay-get overlay 'before-string))
              (selection (reference-explorer-ui--vertico-selection display))
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

(defun reference-explorer-ui--preview-left (position frame-width side)
  "Return preview left coordinate for POSITION, FRAME-WIDTH and SIDE."
  (if (eq side 'right)
      (car position)
    (max 0 (- (nth 3 position) frame-width 4))))

(defun reference-explorer-ui--preview-text-pixel-size
    (window buffer max-width max-height)
  "Measure BUFFER's unwrapped extent within MAX-WIDTH and MAX-HEIGHT."
  (with-current-buffer buffer
    (window-text-pixel-size
     window (point-min) (point-max) max-width max-height)))

(defun reference-explorer-ui--preview-wrapped-height
    (window buffer max-height)
  "Measure BUFFER's height in WINDOW, including wrapping, up to MAX-HEIGHT."
  (with-current-buffer buffer
    (cdr (window-text-pixel-size
          window (point-min) (point-max) nil max-height))))

(defun reference-explorer-ui--preview-horizontal-layout
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
                         reference-explorer-ui--preview-horizontal-overhead)))))
    (when (>= width minimum-width)
      (cons side width))))

(defun reference-explorer-ui--preview-max-height
    (line-height parent-height)
  "Return preview body height available inside PARENT-HEIGHT.
LINE-HEIGHT is the minimum useful body height."
  (max line-height
       (- parent-height
          reference-explorer-ui--preview-vertical-overhead
          8)))

(defun reference-explorer-ui--preview-top
    (position frame-height parent-height)
  "Align preview with POSITION, clamped inside PARENT-HEIGHT.
The selected candidate and preview text start at the same vertical coordinate
when the preview fits below that coordinate.  Otherwise move the preview
upward only as far as needed to keep its bottom inside the parent frame."
  (max 4
       (min (- (cadr position)
               reference-explorer-ui--preview-border-width)
            (- parent-height frame-height 4))))

(defun reference-explorer-ui--preview-content-width
    (measured-width max-width char-width &optional minimum-width)
  "Return safe content width from MEASURED-WIDTH within MAX-WIDTH.
CHAR-WIDTH converts `reference-explorer-ui-preview-width-slack' to pixels."
  (min max-width
       (max (or minimum-width char-width)
            (+ measured-width
               (* reference-explorer-ui-preview-width-slack char-width)))))

(defun reference-explorer-ui--child-frame-parameters
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

(defun reference-explorer-ui--style-child-frame (frame border-face)
  "Apply BORDER-FACE to FRAME's internal and child-frame borders."
  (let ((color (face-background border-face nil t)))
    (set-face-background 'internal-border color frame)
    (when (facep 'child-frame-border)
      (set-face-background 'child-frame-border color frame))))

(defun reference-explorer-ui--delete-docset-preview-file ()
  "Delete all temporary HTML owned by the current preview buffer."
  (when (timerp reference-explorer-ui--docset-preview-file-cleanup-timer)
    (cancel-timer reference-explorer-ui--docset-preview-file-cleanup-timer))
  (dolist (file (cons reference-explorer-ui--docset-preview-file
                      reference-explorer-ui--docset-preview-obsolete-files))
    (when (and file (file-exists-p file))
      (delete-file file)))
  (setq reference-explorer-ui--docset-preview-file nil
        reference-explorer-ui--docset-preview-obsolete-files nil
        reference-explorer-ui--docset-preview-file-cleanup-timer nil))

(defun reference-explorer-ui--delete-obsolete-docset-preview-files ()
  "Delete superseded HTML after WebKit has finished loading its replacement."
  (when (timerp reference-explorer-ui--docset-preview-file-cleanup-timer)
    (cancel-timer reference-explorer-ui--docset-preview-file-cleanup-timer))
  (dolist (file reference-explorer-ui--docset-preview-obsolete-files)
    (when (file-exists-p file)
      (delete-file file)))
  (setq reference-explorer-ui--docset-preview-obsolete-files nil
        reference-explorer-ui--docset-preview-file-cleanup-timer nil))

(defun reference-explorer-ui--schedule-obsolete-docset-file-cleanup (buffer)
  "Schedule fallback cleanup of superseded preview HTML owned by BUFFER.
An invisible child frame may stop delivering WebKit loading callbacks.  The
model itself remains reusable, so only its no-longer-current input files need
the bounded fallback cleanup."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp reference-explorer-ui--docset-preview-file-cleanup-timer)
        (cancel-timer reference-explorer-ui--docset-preview-file-cleanup-timer))
      (setq reference-explorer-ui--docset-preview-file-cleanup-timer
            (run-at-time
             0.5 nil
             (lambda (owned-buffer)
               (when (buffer-live-p owned-buffer)
                 (with-current-buffer owned-buffer
                   (reference-explorer-ui--delete-obsolete-docset-preview-files))))
             buffer)))))

(defun reference-explorer-ui--docset-webkit-available-p ()
  "Return non-nil when a WebKit docset preview can be created."
  (and (eq reference-explorer-ui-docset-preview-renderer 'webkit)
       (display-graphic-p)
       (featurep 'xwidget-internal)
       (require 'xwidget nil t)
       (fboundp 'xwidget-insert)
       (fboundp 'xwidget-webkit-goto-uri)))

(defun reference-explorer-ui--docset-webkit-callback (xwidget event-type)
  "Handle reusable preview XWIDGET event EVENT-TYPE."
  (xwidget-webkit-callback xwidget event-type)
  ;; The standard callback renames WebKit buffers to a visible `*xwidget-*'
  ;; name after loading.  Keep reference previews internal so Consult never
  ;; offers a cached xwidget model as a regular buffer candidate.
  (when (buffer-live-p (xwidget-buffer xwidget))
    (reference-explorer-ui--internalize-docset-webkit-buffer
     (xwidget-buffer xwidget)))
  ;; Emacs 30 on macOS reports successive `load-changed' symbols rather than
  ;; a string-valued `load-finished' event for local file URLs.  The standard
  ;; callback updates `xwidget-webkit--loading-p'; only release superseded
  ;; files after that state says the current navigation has settled.
  (when (buffer-live-p (xwidget-buffer xwidget))
    (with-current-buffer (xwidget-buffer xwidget)
      (when (and (memq event-type '(load-changed load-finished))
                 (not xwidget-webkit--loading-p))
        (reference-explorer-ui--delete-obsolete-docset-preview-files)))))

(defun reference-explorer-ui--navigate-docset-webkit (buffer xwidget entry)
  "Render docset ENTRY and navigate reusable XWIDGET in BUFFER to it."
  (let ((file (make-temp-file "reference-explorer-ui-docset-preview-" nil ".html")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert
             (reference-explorer-source-docset-render-html
              entry
              (format "html { font-size: %spx !important; }"
                      reference-explorer-ui-docset-webkit-font-size))))
          (with-current-buffer buffer
            (when reference-explorer-ui--docset-preview-file
              (push reference-explorer-ui--docset-preview-file
                    reference-explorer-ui--docset-preview-obsolete-files))
            (setq reference-explorer-ui--docset-preview-file file)
            (xwidget-webkit-goto-uri
             xwidget (url-encode-url (concat "file://" file)))
            (reference-explorer-ui--schedule-obsolete-docset-file-cleanup
             buffer)
            (setq file nil)))
      (when (and file (file-exists-p file))
        (delete-file file)))))

(defun reference-explorer-ui--make-docset-webkit-buffer
    (entry width height)
  "Create a WebKit buffer for docset ENTRY sized to WIDTH by HEIGHT pixels.
Return (BUFFER . XWIDGET)."
  (let (buffer result)
    (unwind-protect
        (setq result
              (progn
                (setq buffer
                      (generate-new-buffer
                       reference-explorer-ui-preview-buffer-name))
                (with-current-buffer buffer
                  (insert ".")
                  (let ((xwidget
                         (xwidget-insert
                          (point-min) 'webkit
                          (reference-explorer-source-docset-result-name entry)
                          width height nil)))
                    (put-text-property (point-min) (point-max) 'invisible t)
                    (xwidget-put
                     xwidget 'callback
                     #'reference-explorer-ui--docset-webkit-callback)
                    (xwidget-put xwidget 'display-callback
                                 #'xwidget-webkit-display-callback)
                    ;; Candidate navigation reuses this widget, so it must
                    ;; never prompt merely because Emacs itself eventually
                    ;; shuts down.
                    (set-xwidget-query-on-exit-flag xwidget nil)
                    (xwidget-webkit-mode)
                    (reference-explorer-ui--internalize-docset-webkit-buffer
                     buffer)
                    (setq-local mode-line-format nil
                                header-line-format nil
                                cursor-type nil)
                    (add-hook
                     'kill-buffer-hook
                     #'reference-explorer-ui--delete-docset-preview-file
                     nil t)
                    (reference-explorer-ui--navigate-docset-webkit
                     buffer xwidget entry)
                    (cons buffer xwidget)))))
      (unless result
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    result))

(defun reference-explorer-ui--internalize-docset-webkit-buffer (buffer)
  "Keep reference WebKit BUFFER out of ordinary buffer selectors."
  (with-current-buffer buffer
    (setq-local xwidget-webkit-buffer-name-format
                reference-explorer-ui-preview-buffer-name)
    (unless (string-prefix-p " " (buffer-name))
      (rename-buffer
       (generate-new-buffer-name reference-explorer-ui-preview-buffer-name)
       t)))
  buffer)

(defun reference-explorer-ui--docset-webkit-layout (position anchor-window)
  "Return WebKit preview layout for POSITION beside ANCHOR-WINDOW."
  (when (window-live-p anchor-window)
    (let* ((parent-frame (window-frame anchor-window))
           (line-height (window-default-line-height anchor-window))
           (horizontal-layout
            (reference-explorer-ui--preview-horizontal-layout
             position reference-explorer-ui-docset-webkit-preview-width
             reference-explorer-ui-docset-webkit-preview-min-width)))
      (when horizontal-layout
        (list :parent-frame parent-frame
              :side (car horizontal-layout)
              :width (cdr horizontal-layout)
              :height
              (min reference-explorer-ui-docset-webkit-preview-height
                   (reference-explorer-ui--preview-max-height
                    line-height (frame-pixel-height parent-frame))))))))

(defun reference-explorer-ui--docset-webkit-cache (parent-frame)
  "Return the reusable WebKit preview belonging to PARENT-FRAME."
  (gethash parent-frame reference-explorer-ui--docset-webkit-preview-caches))

(defun reference-explorer-ui--cache-docset-webkit-preview
    (parent-frame preview)
  "Cache PREVIEW as the reusable WebKit view for PARENT-FRAME."
  (puthash parent-frame preview
           reference-explorer-ui--docset-webkit-preview-caches)
  preview)

(defun reference-explorer-ui--cached-docset-webkit-preview-p (preview)
  "Return non-nil when PREVIEW is its parent frame's reusable WebKit view."
  (and
   (reference-explorer-ui--preview-p preview)
   (let (cached)
     (maphash
      (lambda (_parent-frame candidate)
        (when (eq preview candidate)
          (setq cached t)))
      reference-explorer-ui--docset-webkit-preview-caches)
     cached)))

(defun reference-explorer-ui--uncache-docset-webkit-preview-frame (frame)
  "Remove and return the cached preview whose child frame is FRAME."
  (let (parent-frame preview)
    (maphash
     (lambda (candidate-parent candidate-preview)
       (when (eq frame (reference-explorer-ui--preview-frame candidate-preview))
         (setq parent-frame candidate-parent
               preview candidate-preview)))
     reference-explorer-ui--docset-webkit-preview-caches)
    (when parent-frame
      (remhash parent-frame reference-explorer-ui--docset-webkit-preview-caches))
    preview))

(defun reference-explorer-ui--display-docset-webkit-preview
    (entry position layout)
  "Display WebKit docset ENTRY at POSITION using LAYOUT."
  (let* ((parent-frame (plist-get layout :parent-frame))
         (body-width (plist-get layout :width))
         (body-height (plist-get layout :height))
         (cached (reference-explorer-ui--docset-webkit-cache parent-frame))
         (reuse
          (and (reference-explorer-ui--preview-live-p cached)
               (eq (frame-parent
                    (reference-explorer-ui--preview-frame cached))
                   parent-frame)))
         (buffer (and reuse
                      (reference-explorer-ui--preview-buffer cached)))
         (frame (and reuse
                     (reference-explorer-ui--preview-frame cached)))
         (window (and frame (frame-selected-window frame)))
         (xwidget
          (and buffer (car (get-buffer-xwidgets buffer))))
         (preview nil)
         created)
    (unwind-protect
        (progn
          (unless (and reuse (window-live-p window) xwidget)
            (let* ((resources
                    (reference-explorer-ui--make-docset-webkit-buffer
                     entry body-width body-height))
                   (parameters
                    (reference-explorer-ui--child-frame-parameters
                     parent-frame 'reference-explorer-ui-preview
                     reference-explorer-ui--preview-border-width))
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
          (reference-explorer-ui--internalize-docset-webkit-buffer buffer)
          (unless (eq (frame-parent frame) parent-frame)
            (error "WebKit preview was displayed outside its parent frame"))
          (when reuse
            (reference-explorer-ui--navigate-docset-webkit
             buffer xwidget entry))
          (let* ((frame-width
                  (+ body-width
                     reference-explorer-ui--preview-horizontal-overhead))
                 (frame-height
                  (+ body-height
                     reference-explorer-ui--preview-vertical-overhead))
                 (left
                  (reference-explorer-ui--preview-left
                   position frame-width (plist-get layout :side)))
                 (top
                  (reference-explorer-ui--preview-top
                   position frame-height (frame-pixel-height parent-frame))))
            (set-window-dedicated-p window t)
            (set-frame-size frame frame-width frame-height t)
            (set-frame-parameter
             frame 'reference-explorer-ui-preview-buffer buffer)
            (set-frame-position frame left top)
            (redirect-frame-focus frame parent-frame)
            (reference-explorer-ui--style-child-frame
             frame 'reference-explorer-ui-preview-border)
            (xwidget-resize xwidget body-width body-height)
            (make-frame-visible frame)
            (setq preview
                  (if reuse
                      cached
                    (reference-explorer-ui--make-preview frame buffer entry))
                  reference-explorer-ui--active-temporary-preview preview)
            (setf (reference-explorer-ui--preview-entry preview) entry)
            (reference-explorer-ui--cache-docset-webkit-preview
             parent-frame preview)))
      (unless preview
        (when (and created
                   (frame-live-p frame)
                   (not (eq frame parent-frame)))
          (delete-frame frame))
        (when (and created (buffer-live-p buffer))
          (kill-buffer buffer))))
    preview))

(defun reference-explorer-ui--show-docset-webkit-preview-at-position
    (entry position anchor-window)
  "Show an isolated WebKit docset ENTRY beside POSITION in ANCHOR-WINDOW."
  (when (reference-explorer-ui--docset-webkit-available-p)
    (condition-case error-data
        (when-let ((layout
                    (reference-explorer-ui--docset-webkit-layout
                     position anchor-window)))
          (reference-explorer-ui--display-docset-webkit-preview
           entry position layout))
      (error
       (unless reference-explorer-ui--docset-webkit-warning-shown
         (setq reference-explorer-ui--docset-webkit-warning-shown t)
         (display-warning
          'reference-explorer-ui
          (format "WebKit docset preview failed; using SHR: %s"
                  (error-message-string error-data))
          :warning))
       nil))))

(defun reference-explorer-ui--show-temporary-shr-preview-at-position
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
                 (if (reference-explorer-source-docset-result-p entry) 'docset 'lookup))
                (configured-width
                 (* (if (eq preview-kind 'docset)
                        reference-explorer-ui-docset-preview-max-width
                      reference-explorer-ui-preview-max-width)
                    char-width))
                (minimum-width
                 (* (if (eq preview-kind 'docset)
                        reference-explorer-ui-docset-preview-min-width
                      reference-explorer-ui-preview-min-width)
                    char-width))
                (margin-pixels
                 (* 2 reference-explorer-ui-preview-margin-width char-width))
                (horizontal-layout
                 (reference-explorer-ui--preview-horizontal-layout
                  position
                  (+ configured-width margin-pixels)
                  (+ minimum-width margin-pixels)))
                (buffer-name
                 (generate-new-buffer-name
                  reference-explorer-ui-preview-buffer-name))
                (buffer
                 (reference-explorer-ui--prepare-preview-buffer
                  (reference-explorer-ui--render-entry entry buffer-name)
                  (reference-explorer-ui--preview-query-for-entry
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
                   (reference-explorer-ui--child-frame-parameters
                    parent-frame 'reference-explorer-ui-preview
                    reference-explorer-ui--preview-border-width)))
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
                 window reference-explorer-ui-preview-margin-width
                 reference-explorer-ui-preview-margin-width)
                (let* ((line-height
                        (window-default-line-height anchor-window))
                       (horizontal-side (car horizontal-layout))
                       (max-width
                        (max char-width
                             (- (cdr horizontal-layout) margin-pixels)))
                       (parent-height (frame-pixel-height parent-frame))
                       (max-height
                        (min (reference-explorer-ui--preview-max-height
                              line-height parent-height)
                             (if (eq preview-kind 'docset)
                                 (* reference-explorer-ui-docset-preview-max-height
                                    line-height)
                               parent-height)))
                       (_initial-size
                        (set-frame-size
                         frame (+ max-width margin-pixels) max-height t))
                       (size
                        (reference-explorer-ui--preview-text-pixel-size
                         window buffer max-width max-height))
                       (width
                        (reference-explorer-ui--preview-content-width
                         (car size) max-width char-width
                         (and (eq preview-kind 'docset) minimum-width)))
                       ;; Width must be applied before measuring height.  With
                       ;; a non-nil X-LIMIT, `window-text-pixel-size' ignores
                       ;; text beyond that limit instead of counting the
                       ;; visual lines it wraps to.
                       (_width-sized
                        (set-frame-size
                         frame (+ width margin-pixels
                                  reference-explorer-ui--preview-horizontal-overhead)
                         max-height t))
                       (height
                        (max line-height
                             (reference-explorer-ui--preview-wrapped-height
                              window buffer max-height)))
                       (frame-width
                        (+ width
                           margin-pixels
                           reference-explorer-ui--preview-horizontal-overhead))
                       (frame-height
                        (+ height
                           reference-explorer-ui--preview-vertical-overhead))
                       (left
                        (reference-explorer-ui--preview-left
                         position frame-width horizontal-side))
                       (top
                        (reference-explorer-ui--preview-top
                         position frame-height parent-height)))
                  (set-window-dedicated-p window t)
                  (set-frame-size frame frame-width frame-height t)
                  (set-frame-parameter
                   frame 'reference-explorer-ui-preview-buffer buffer)
                  (set-frame-position frame left top)
                  (redirect-frame-focus frame parent-frame)
                  (reference-explorer-ui--style-child-frame
                   frame 'reference-explorer-ui-preview-border)
                  (make-frame-visible frame)
                  (setq preview
                        (reference-explorer-ui--make-preview
                         frame buffer entry))
                  (setq reference-explorer-ui--active-temporary-preview
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

(defun reference-explorer-ui--show-temporary-preview-at-position
    (entry position anchor-window &optional query)
  "Show ENTRY near POSITION in ANCHOR-WINDOW using its preferred renderer."
  (or (and (reference-explorer-source-docset-result-p entry)
           (reference-explorer-ui--show-docset-webkit-preview-at-position
            entry position anchor-window))
      (reference-explorer-ui--show-temporary-shr-preview-at-position
       entry position anchor-window query)))

(defun reference-explorer-ui--show-temporary-preview (entry)
  "Show ENTRY beside the selected Consult candidate."
  (when-let ((minibuffer-window (active-minibuffer-window))
             (position (reference-explorer-ui--vertico-candidate-position)))
    (let ((query
           (with-current-buffer (window-buffer minibuffer-window)
             (reference-explorer-ui--backend-query
              (minibuffer-contents-no-properties)
              reference-explorer-ui--active-consult-mode))))
      (reference-explorer-ui--show-temporary-preview-at-position
       entry position minibuffer-window query))))

(defun reference-explorer-ui--preview-frame-deleted (frame)
  "Schedule cleanup of the rendering buffer owned by deleted preview FRAME.
Cleanup is deferred until `delete-frame' has finished so killing a buffer in a
dedicated child-frame window cannot recursively delete that frame."
  (when-let ((buffer
              (frame-parameter frame
                               'reference-explorer-ui-preview-buffer)))
    (when-let ((cached
                (reference-explorer-ui--uncache-docset-webkit-preview-frame
                 frame)))
      (when (eq cached reference-explorer-ui--active-temporary-preview)
        (setq reference-explorer-ui--active-temporary-preview nil))
      (when (eq cached reference-explorer-ui--preview-interaction)
        (setq reference-explorer-ui--preview-interaction nil
              reference-explorer-ui--preview-interaction-origin-window nil)))
    ;; Killing a buffer from inside deletion of its dedicated child frame can
    ;; recursively delete the same frame.  Let frame deletion finish first;
    ;; the short delay also lets already queued native WebKit events settle.
    (run-at-time
     0.5 nil
     (lambda (owned-buffer)
       (when (buffer-live-p owned-buffer)
         (reference-explorer-ui--delete-xwidget-views owned-buffer)
         (reference-explorer-ui--retire-preview-buffer owned-buffer)))
     buffer)))

(defun reference-explorer-ui--delete-xwidget-views (buffer)
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

(defun reference-explorer-ui--retire-preview-buffer (buffer)
  "Kill non-cached preview BUFFER."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun reference-explorer-ui--close-temporary-preview (preview)
  "Delete temporary reference PREVIEW and all resources it owns."
  (when (reference-explorer-ui--preview-p preview)
    (when (eq preview reference-explorer-ui--active-temporary-preview)
      (setq reference-explorer-ui--active-temporary-preview nil))
    (let ((frame (reference-explorer-ui--preview-frame preview))
          (buffer (reference-explorer-ui--preview-buffer preview)))
      (if (reference-explorer-ui--cached-docset-webkit-preview-p preview)
          ;; Reusing one native view avoids both stale pixels and a race where
          ;; a queued WebKit event reaches a model that has just been killed.
          (when (frame-live-p frame)
            (make-frame-invisible frame t))
        (when (frame-live-p frame)
          (delete-frame frame))
        (reference-explorer-ui--delete-xwidget-views buffer)
        (reference-explorer-ui--retire-preview-buffer buffer)))))

(defun reference-explorer-ui--preview-live-p (preview)
  "Return non-nil when PREVIEW still owns a live frame and buffer."
  (and (reference-explorer-ui--preview-p preview)
       (frame-live-p (reference-explorer-ui--preview-frame preview))
       (buffer-live-p (reference-explorer-ui--preview-buffer preview))))

(defun reference-explorer-ui--scroll-temporary-preview (direction)
  "Scroll the active temporary preview in DIRECTION.
DIRECTION is `up' to reveal later text or `down' to reveal earlier text."
  (let ((preview reference-explorer-ui--active-temporary-preview))
    (unless (reference-explorer-ui--preview-live-p preview)
      (user-error "No reference preview is visible"))
    (let* ((frame (reference-explorer-ui--preview-frame preview))
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

(defun reference-explorer-ui-preview-scroll-up ()
  "Scroll the temporary reference preview toward later text."
  (interactive)
  (reference-explorer-ui--scroll-temporary-preview 'up))

(defun reference-explorer-ui-preview-scroll-down ()
  "Scroll the temporary reference preview toward earlier text."
  (interactive)
  (reference-explorer-ui--scroll-temporary-preview 'down))

(defun reference-explorer-ui--active-webkit-preview-xwidget ()
  "Return the xwidget displayed by the active WebKit preview, or nil."
  (when (reference-explorer-ui--preview-live-p
         reference-explorer-ui--active-temporary-preview)
    (let ((buffer
           (reference-explorer-ui--preview-buffer
            reference-explorer-ui--active-temporary-preview)))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'xwidget-webkit-mode)))
        (car (get-buffer-xwidgets buffer))))))

(defun reference-explorer-ui-preview-copy-selection ()
  "Copy the active WebKit preview selection to the kill ring and clipboard."
  (interactive)
  (if-let ((xwidget (reference-explorer-ui--active-webkit-preview-xwidget)))
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

(defvar-keymap reference-explorer-ui-preview-interaction-mode-map
  :doc "Keymap active while directly operating a reference WebKit preview."
  "C-g" #'reference-explorer-ui-preview-exit-interaction
  "H-q" #'reference-explorer-ui-preview-exit-interaction
  "H-w" #'reference-explorer-ui-preview-copy-selection
  "M-w" #'reference-explorer-ui-preview-copy-selection)

(define-minor-mode reference-explorer-ui-preview-interaction-mode
  "Allow direct mouse and keyboard operation of a reference WebKit preview."
  :init-value nil
  :lighter " RefInteract"
  :keymap reference-explorer-ui-preview-interaction-mode-map)

(defun reference-explorer-ui--activate-webkit-preview-interaction
    (preview origin-window)
  "Promote WebKit PREVIEW for direct interaction, returning to ORIGIN-WINDOW."
  (unless (and (eq preview reference-explorer-ui--active-temporary-preview)
               (reference-explorer-ui--preview-live-p preview)
               (reference-explorer-ui--active-webkit-preview-xwidget))
    (user-error "The active reference preview is not an interactive WebKit preview"))
  (let* ((frame (reference-explorer-ui--preview-frame preview))
         (buffer (reference-explorer-ui--preview-buffer preview)))
    (setq reference-explorer-ui--preview-interaction preview
          reference-explorer-ui--preview-interaction-origin-window
          origin-window
          reference-explorer-ui--active-temporary-preview preview)
    (with-current-buffer buffer
      (reference-explorer-ui-preview-interaction-mode 1))
    (set-frame-parameter frame 'no-accept-focus nil)
    (set-frame-parameter frame 'no-focus-on-map nil)
    (redirect-frame-focus frame nil)
    (select-frame-set-input-focus frame)
    (message "Preview interaction: drag to select; M-w/H-w copies; C-g/H-q exits")))

(defun reference-explorer-ui--display-entry-for-interaction
    (entry origin-window)
  "Display ENTRY as committed content and select it from ORIGIN-WINDOW."
  (let ((buffer
         (if (window-live-p origin-window)
             (with-selected-window origin-window
               (reference-explorer-ui--display-entry entry))
           (reference-explorer-ui--display-entry entry))))
    (if-let ((window (get-buffer-window buffer t)))
        (progn
          (select-window window)
          (select-frame-set-input-focus (window-frame window)))
      (user-error "The committed reference content could not be displayed"))))

(defun reference-explorer-ui--activate-preview-interaction
    (preview origin-window)
  "Promote PREVIEW to an operable display, returning to ORIGIN-WINDOW.
WebKit previews retain their rendered child frame.  Other previews are
committed to a selected Popper window."
  (unless (reference-explorer-ui--preview-p preview)
    (user-error "No reference preview is available"))
  (if (and (eq preview reference-explorer-ui--active-temporary-preview)
           (reference-explorer-ui--preview-live-p preview)
           (reference-explorer-ui--active-webkit-preview-xwidget))
      (reference-explorer-ui--activate-webkit-preview-interaction
       preview origin-window)
    (if-let ((entry (reference-explorer-ui--preview-entry preview)))
        (reference-explorer-ui--display-entry-for-interaction
         entry origin-window)
      (user-error "The reference preview has no operable content"))))

(defun reference-explorer-ui-preview-exit-interaction ()
  "End direct WebKit preview interaction and return to its origin window."
  (interactive)
  (let ((preview reference-explorer-ui--preview-interaction)
        (origin-window reference-explorer-ui--preview-interaction-origin-window))
    (setq reference-explorer-ui--preview-interaction nil
          reference-explorer-ui--preview-interaction-origin-window nil)
    (when (reference-explorer-ui--preview-p preview)
      (let ((frame (reference-explorer-ui--preview-frame preview))
            (buffer (reference-explorer-ui--preview-buffer preview)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (reference-explorer-ui-preview-interaction-mode -1)))
        (when (frame-live-p frame)
          (set-frame-parameter frame 'no-accept-focus t)
          (set-frame-parameter frame 'no-focus-on-map t)
          (when-let ((parent (frame-parent frame)))
            (redirect-frame-focus frame parent)))
        (reference-explorer-ui--close-temporary-preview preview)))
    (when (window-live-p origin-window)
      (select-window origin-window)
      (select-frame-set-input-focus (window-frame origin-window)))))

(add-hook 'delete-frame-functions
          #'reference-explorer-ui--preview-frame-deleted)

(defun reference-explorer-ui--preview-state ()
  "Return a Consult state function for temporary reference previews."
  (let (preview)
    (lambda (action entry)
      (when preview
        (if (eq preview reference-explorer-ui--preview-interaction-request)
            (setq reference-explorer-ui--preview-interaction-request nil)
          (reference-explorer-ui--close-temporary-preview preview))
        (setq preview nil))
      (pcase action
        ('preview
         (when entry
           (setq preview
                 (reference-explorer-ui--show-temporary-preview entry))))))))

;; Corfu-like quick selector

(defun reference-explorer-ui--quick-current-entry (&optional session)
  "Return the selected entry in quick reference SESSION."
  (let ((session (or session reference-explorer-ui--quick-session)))
    (and session
         (nth (reference-explorer-ui--quick-session-index session)
              (reference-explorer-ui--quick-session-entries session)))))

(defun reference-explorer-ui--quick-show-help (&optional status)
  "Show a compact quick reference key summary in the minibuffer.
Prefix the summary with STATUS when it is non-nil."
  (message "%s%s"
           (if status (concat status " — ") "")
           (or (and reference-explorer-ui--quick-session
                    (reference-explorer-ui--quick-session-help
                     reference-explorer-ui--quick-session))
               "H-s/e:検索語を縮小/拡大  H-i:preview操作  M-m:Consult")))

(defun reference-explorer-ui--quick-visible-entries (session)
  "Return visible entries for quick reference SESSION and update its offset."
  (let* ((entries (reference-explorer-ui--quick-session-entries session))
         (count (length entries))
         (limit (max 1 reference-explorer-ui-quick-max-candidates))
         (index (reference-explorer-ui--quick-session-index session))
         ;; Keep the initial rows stable until selection reaches the bottom,
         ;; then scroll only enough to keep the selected row visible.
         (offset (min (max 0 (- index (1- limit)))
                      (max 0 (- count limit))))
         (end (min count (+ offset limit))))
    (setf (reference-explorer-ui--quick-session-list-offset session) offset)
    (seq-subseq entries offset end)))

(defun reference-explorer-ui--quick-candidate-line
    (entry _selected &optional show-docset-source)
  "Return one quick reference line for ENTRY.
Selection styling is applied by the renderer across the complete visual row."
  (let* ((docset-p (reference-explorer-source-docset-result-p entry))
         (heading (reference-explorer-ui--candidate-label entry))
         (annotation
          (reference-explorer-ui--candidate-annotation
           entry nil))
         (docset-source
          (and docset-p show-docset-source
               (reference-explorer-source-docset-feed
                (reference-explorer-source-docset-result-docset entry))))
         (line
          (if docset-p
              ;; `annotation' is the actual Nerd Icons Corfu margin field,
              ;; including the formatter's half-column gaps around the glyph.
              (concat annotation heading
                      (if docset-source
                          (concat "  "
                                  (propertize
                                   docset-source 'face
                                   'reference-explorer-ui-quick-source))
                        ""))
            (concat heading
                    (if (string-empty-p annotation)
                        ""
                      (concat "  "
                              (propertize
                               annotation 'face
                               'reference-explorer-ui-quick-source)))))))
    line))

(defconst reference-explorer-ui--quick-fringe-bitmap
  'reference-explorer-ui--quick-fringe-bitmap)

(when (fboundp 'define-fringe-bitmap)
  ;; A zero bitmap lets the selected face color the margin without drawing a
  ;; visible symbol, matching Corfu's selected-row fringe treatment.
  (define-fringe-bitmap reference-explorer-ui--quick-fringe-bitmap [0] 1 1))

(defconst reference-explorer-ui--quick-current-fringes
  (propertize
   "  "
   'display nil)
  "Invisible fringe cells used to extend the selected row into both margins.")

(put-text-property
 0 1 'display
 `(left-fringe ,reference-explorer-ui--quick-fringe-bitmap
               reference-explorer-ui-quick-current)
 reference-explorer-ui--quick-current-fringes)
(put-text-property
 1 2 'display
 `(right-fringe ,reference-explorer-ui--quick-fringe-bitmap
                reference-explorer-ui-quick-current)
 reference-explorer-ui--quick-current-fringes)

(defun reference-explorer-ui--quick-render-list (session)
  "Render quick reference SESSION into its candidate buffer."
  (let* ((buffer (reference-explorer-ui--quick-session-list-buffer session))
         (index (reference-explorer-ui--quick-session-index session))
         (visible (reference-explorer-ui--quick-visible-entries session))
         (show-docset-source
          (> (length
              (delete-dups
               (delq nil
                     (mapcar
                      (lambda (entry)
                        (and (reference-explorer-source-docset-result-p entry)
                             (reference-explorer-source-docset-root
                              (reference-explorer-source-docset-result-docset entry))))
                      (reference-explorer-ui--quick-session-entries
                       session)))))
             1))
         (offset (reference-explorer-ui--quick-session-list-offset session)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cl-loop for entry in visible
                 for row from offset
                 for selected = (= row index)
                 do (let ((start (point)))
                      (insert
                       (reference-explorer-ui--quick-candidate-line
                        entry selected show-docset-source))
                      (when (and selected (display-graphic-p))
                        (insert reference-explorer-ui--quick-current-fringes))
                      (insert "\n")
                      ;; Include the newline so the extending face reaches the
                      ;; full content width, exactly as Corfu's popup renderer
                      ;; does for its current candidate.
                      (when selected
                        (add-face-text-property
                         start (point)
                         'reference-explorer-ui-quick-current 'append))))
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
      (buffer-face-set 'reference-explorer-ui-quick-default))))

(defun reference-explorer-ui--quick-query-bounds (session)
  "Return source-buffer bounds of SESSION's active query."
  (or (reference-explorer-ui--quick-session-source-bounds session)
      (when-let* ((marker
                   (reference-explorer-ui--quick-session-source-marker session))
                  (buffer (and (markerp marker) (marker-buffer marker)))
                  (query (reference-explorer-ui--quick-session-query session)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char marker)
            (or
             (seq-find
              (lambda (bounds)
                (equal query
                       (buffer-substring-no-properties
                        (car bounds) (cdr bounds))))
              (reference-explorer-ui-phrase-candidate-bounds-at-point))
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

(defun reference-explorer-ui--quick-highlight-source (session)
  "Highlight SESSION's active query in its source buffer."
  (when-let ((overlay
              (reference-explorer-ui--quick-session-source-overlay session)))
    (delete-overlay overlay)
    (setf (reference-explorer-ui--quick-session-source-overlay session) nil))
  (when-let* ((marker
               (reference-explorer-ui--quick-session-source-marker session))
              (buffer (and (markerp marker) (marker-buffer marker)))
              (bounds (reference-explorer-ui--quick-query-bounds session)))
    (let ((overlay (make-overlay (car bounds) (cdr bounds) buffer)))
      (overlay-put overlay 'face 'reference-explorer-ui-source-highlight)
      (overlay-put overlay 'priority 100)
      (setf (reference-explorer-ui--quick-session-source-overlay session)
            overlay))))

(defun reference-explorer-ui--quick-sync-list-window (session)
  "Synchronize SESSION's child window with its freshly rendered buffer."
  (when-let* ((frame (reference-explorer-ui--quick-session-list-frame session))
              ((frame-live-p frame))
              (window (frame-selected-window frame))
              ((window-live-p window))
              (buffer (reference-explorer-ui--quick-session-list-buffer
                       session))
              ((buffer-live-p buffer)))
    (set-window-start window
                      (with-current-buffer buffer (point-min)) t)
    (set-window-point window
                      (with-current-buffer buffer (point)))
    (set-window-vscroll window 0 t)))

(defun reference-explorer-ui--quick-point-position (window)
  "Return point position in parent-frame pixels for WINDOW."
  (when (window-live-p window)
    (with-selected-window window
      (when-let* ((position (posn-at-point (point) window))
                  (xy (posn-x-y position)))
        (pcase-let ((`(,left ,top ,_right ,_bottom)
                     (window-inside-pixel-edges window)))
          (list (+ left (car xy))
                (+ top (cdr xy))))))))

(defun reference-explorer-ui--quick-position-list-frame (session)
  "Position quick reference SESSION's candidate frame near source point."
  (when-let* ((frame (reference-explorer-ui--quick-session-list-frame session))
              ((frame-live-p frame))
              (source-window
               (reference-explorer-ui--quick-session-source-window session))
              (position
               (reference-explorer-ui--quick-point-position source-window)))
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

(defun reference-explorer-ui--quick-resize-list-frame (session)
  "Resize and position quick reference SESSION's candidate frame."
  (when-let* ((frame (reference-explorer-ui--quick-session-list-frame session))
              ((frame-live-p frame))
              (buffer (reference-explorer-ui--quick-session-list-buffer session))
              ((buffer-live-p buffer)))
    (let* ((window (frame-selected-window frame))
           (char-width (frame-char-width frame))
           (max-width (* reference-explorer-ui-quick-max-width char-width))
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
      (reference-explorer-ui--quick-position-list-frame session)
      ;; Frame resizing is asynchronous on graphical macOS builds.  Restore
      ;; the intended viewport after every resize instead of relying on the
      ;; child window's previous redisplay state.
      (reference-explorer-ui--quick-sync-list-window session))))

(defun reference-explorer-ui--quick-candidate-position (session)
  "Return the selected candidate position for quick reference SESSION."
  (when-let* ((frame (reference-explorer-ui--quick-session-list-frame session))
              ((frame-live-p frame))
              (source-window
               (reference-explorer-ui--quick-session-source-window session))
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

(defun reference-explorer-ui--quick-cancel-preview (session)
  "Cancel and close SESSION's pending and visible temporary preview."
  (when-let ((timer
              (reference-explorer-ui--quick-session-preview-timer session)))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (reference-explorer-ui--quick-session-preview-timer session) nil))
  (when-let ((preview
              (reference-explorer-ui--quick-session-preview session)))
    (reference-explorer-ui--close-temporary-preview preview)
    (setf (reference-explorer-ui--quick-session-preview session) nil)))

(defun reference-explorer-ui--quick-show-preview (session entry)
  "Show ENTRY preview when SESSION is still the active quick reference."
  (setf (reference-explorer-ui--quick-session-preview-timer session) nil)
  (when (eq session reference-explorer-ui--quick-session)
    (when-let ((preview-entry
                (reference-explorer-ui--candidate-preview-entry entry))
               (position
                (reference-explorer-ui--quick-candidate-position session)))
      (setf (reference-explorer-ui--quick-session-preview session)
            (reference-explorer-ui--show-temporary-preview-at-position
             preview-entry position
             (reference-explorer-ui--quick-session-source-window session)
             (reference-explorer-ui--candidate-label entry)))
      ;; Lookup reports its content insertion in the echo area.  Restore the
      ;; compact selector hint after rendering finishes.
      (reference-explorer-ui--quick-show-help))))

(defun reference-explorer-ui--quick-schedule-preview (session)
  "Schedule a preview for the selected entry in SESSION."
  (reference-explorer-ui--quick-cancel-preview session)
  (when-let ((entry (reference-explorer-ui--quick-current-entry session)))
    (setf (reference-explorer-ui--quick-session-preview-timer session)
          (run-at-time reference-explorer-ui-preview-debounce nil
                       #'reference-explorer-ui--quick-show-preview
                       session entry))))

(defun reference-explorer-ui--quick-refresh (session)
  "Refresh candidate presentation and preview for SESSION."
  (reference-explorer-ui--quick-highlight-source session)
  (reference-explorer-ui--quick-render-list session)
  (reference-explorer-ui--quick-resize-list-frame session)
  (reference-explorer-ui--quick-schedule-preview session)
  (reference-explorer-ui--quick-show-help))

(defun reference-explorer-ui--quick-show-list-frame (session)
  "Create the candidate child frame owned by quick reference SESSION."
  (when (and (display-graphic-p)
             (fboundp 'display-buffer-in-child-frame))
    (let* ((buffer (generate-new-buffer " *Reference Quick*"))
           (source-window
            (reference-explorer-ui--quick-session-source-window session))
           (parent (window-frame source-window))
           (char-width (frame-char-width parent))
           (left-margin
            (min 16
                 (ceiling
                  (* char-width reference-explorer-ui-quick-left-margin-width))))
           (right-margin
            (min 16
                 (ceiling
                  (* char-width reference-explorer-ui-quick-right-margin-width))))
           (parameters
            (reference-explorer-ui--child-frame-parameters
             parent 'reference-explorer-ui-quick-default 1)))
      (setf (alist-get 'left-fringe parameters) left-margin
            (alist-get 'right-fringe parameters) right-margin)
      (setf (reference-explorer-ui--quick-session-list-buffer session) buffer)
      (reference-explorer-ui--quick-render-list session)
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
          (setf (reference-explorer-ui--quick-session-list-frame session)
                frame)
          (set-frame-parameter frame 'reference-explorer-ui-quick-session
                               session)
          (reference-explorer-ui--quick-resize-list-frame session)
          (reference-explorer-ui--style-child-frame
           frame 'reference-explorer-ui-preview-border)
          (make-frame-visible frame)
          frame)))))

(defun reference-explorer-ui--quick-list-frame-deleted (frame)
  "Deactivate quick reference when its candidate FRAME is deleted externally."
  (when-let ((session reference-explorer-ui--quick-session))
    (when (eq frame
              (reference-explorer-ui--quick-session-list-frame session))
      ;; `delete-frame-functions' runs during frame deletion.  Forget FRAME
      ;; now, then deactivate after deletion has completely unwound.
      (setf (reference-explorer-ui--quick-session-list-frame session) nil)
      (run-at-time
       0 nil
       (lambda (owned-session)
         (when (eq owned-session reference-explorer-ui--quick-session)
           (if-let ((exit
                     (reference-explorer-ui--quick-session-exit-function
                      owned-session)))
               (funcall exit)
             (reference-explorer-ui--quick-cleanup))))
       session))))

(add-hook 'delete-frame-functions
          #'reference-explorer-ui--quick-list-frame-deleted)

(defun reference-explorer-ui--quick-cleanup ()
  "Release all resources owned by the active quick reference session."
  (when-let ((session reference-explorer-ui--quick-session))
    (setq reference-explorer-ui--quick-session nil)
    (reference-explorer-ui--quick-cancel-preview session)
    (when-let ((overlay
                (reference-explorer-ui--quick-session-source-overlay session)))
      (delete-overlay overlay)
      (setf (reference-explorer-ui--quick-session-source-overlay session) nil))
    (when-let ((marker
                (reference-explorer-ui--quick-session-source-marker session)))
      (set-marker marker nil)
      (setf (reference-explorer-ui--quick-session-source-marker session) nil))
    (when-let ((frame
                (reference-explorer-ui--quick-session-list-frame session)))
      (when (frame-live-p frame)
        (delete-frame frame)))
    (when-let ((buffer
                (reference-explorer-ui--quick-session-list-buffer session)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun reference-explorer-ui-quick-quit ()
  "Exit quick reference and close its temporary displays."
  (interactive)
  (when-let ((session reference-explorer-ui--quick-session))
    (if-let ((exit
              (reference-explorer-ui--quick-session-exit-function session)))
        (funcall exit)
      (reference-explorer-ui--quick-cleanup))))

(defun reference-explorer-ui-quick-next (&optional backward)
  "Select the next quick reference entry, or the previous one with BACKWARD."
  (interactive)
  (when-let ((session reference-explorer-ui--quick-session))
    (let ((count
           (length (reference-explorer-ui--quick-session-entries session))))
      (when (> count 0)
        (setf (reference-explorer-ui--quick-session-index session)
              (mod (+ (reference-explorer-ui--quick-session-index session)
                      (if backward -1 1))
                   count))
        (reference-explorer-ui--quick-refresh session)))))

(defun reference-explorer-ui-quick-previous ()
  "Select the previous quick reference entry."
  (interactive)
  (reference-explorer-ui-quick-next t))

(defun reference-explorer-ui--quick-change-query (delta)
  "Move DELTA steps through the active quick reference query options."
  (when-let ((session reference-explorer-ui--quick-session))
    (let* ((options
            (reference-explorer-ui--quick-session-query-options session))
           (old-index
            (or (reference-explorer-ui--quick-session-query-index session) 0))
           (new-index (max 0 (min (1- (length options))
                                  (+ old-index delta)))))
      (if (= old-index new-index)
          (reference-explorer-ui--quick-show-help
           (if (> delta 0) "これ以上縮小できません"
             "これ以上拡大できません"))
        (pcase-let ((`(,query . ,entries) (nth new-index options)))
          (setf (reference-explorer-ui--quick-session-query-index session)
                new-index
                (reference-explorer-ui--quick-session-query session) query
                (reference-explorer-ui--quick-session-entries session) entries
                (reference-explorer-ui--quick-session-index session) 0
                (reference-explorer-ui--quick-session-list-offset session) 0)
          (reference-explorer-ui--quick-refresh session))))))

(defun reference-explorer-ui-quick-shorten-query ()
  "Use the next shorter contextual word around the original point."
  (interactive)
  (reference-explorer-ui--quick-change-query 1))

(defun reference-explorer-ui-quick-expand-query ()
  "Use the next longer contextual word around the original point."
  (interactive)
  (reference-explorer-ui--quick-change-query -1))

(defun reference-explorer-ui-quick-display-entry ()
  "Commit the selected quick candidate using its source action."
  (interactive)
  (when-let ((session reference-explorer-ui--quick-session)
             (entry (reference-explorer-ui--quick-current-entry)))
    (if (reference-explorer-candidate-p entry)
        (let ((context (reference-explorer-ui--quick-context))
              (source-window
               (reference-explorer-ui--quick-session-source-window session)))
          (if (window-live-p source-window)
              (with-selected-window source-window
                (reference-explorer-candidate-commit entry context))
            (reference-explorer-candidate-commit entry context))
          (reference-explorer-ui-quick-quit))
      (let ((source-window
             (reference-explorer-ui--quick-session-source-window session)))
        (reference-explorer-ui--quick-cancel-preview session)
        (if (window-live-p source-window)
            (with-selected-window source-window
              (reference-explorer-ui--display-entry entry))
          (reference-explorer-ui--display-entry entry))))))

(defun reference-explorer-ui-quick-open-consult ()
  "Continue the active quick reference query in the Consult interface."
  (interactive)
  (when-let ((session reference-explorer-ui--quick-session))
    (if-let ((continue
              (reference-explorer-ui--quick-session-consult-function session)))
        (let ((entries
               (reference-explorer-ui--quick-session-entries session)))
          (reference-explorer-ui-quick-quit)
          (funcall continue entries))
      (user-error "This source does not provide a Consult continuation"))))

(defun reference-explorer-ui-quick-activate-preview ()
  "Close quick candidates and promote their preview for interaction."
  (interactive)
  (let ((session reference-explorer-ui--quick-session))
    (unless session
      (user-error "No quick reference session is active"))
    (let* ((candidate (reference-explorer-ui--quick-current-entry session))
           (entry (and candidate
                       (reference-explorer-ui--candidate-preview-entry
                        candidate)))
           (preview
            (or (reference-explorer-ui--quick-session-preview session)
                (and entry
                     (reference-explorer-ui--make-preview nil nil entry)))))
      (unless preview
        (user-error "The current candidate has no operable preview"))
      (let ((origin-window
             (reference-explorer-ui--quick-session-source-window session)))
        ;; A live WebKit view is itself promoted.  Other renderers are closed
        ;; normally and recreated as selected, committed Popper content.
        (when (and (eq preview reference-explorer-ui--active-temporary-preview)
                   (reference-explorer-ui--active-webkit-preview-xwidget))
          (setf (reference-explorer-ui--quick-session-preview session) nil))
        (if-let ((exit
                  (reference-explorer-ui--quick-session-exit-function session)))
            (funcall exit)
          (reference-explorer-ui--quick-cleanup))
        (reference-explorer-ui--activate-preview-interaction
         preview origin-window)))))

(defun reference-explorer-ui--quick-context ()
  "Return a reference context for the active quick reference query."
  (when-let ((session reference-explorer-ui--quick-session))
    (or (reference-explorer-ui--quick-session-context session)
        (reference-explorer-context-create
         :query (reference-explorer-ui--quick-session-query session)
         :marker (reference-explorer-ui--quick-session-source-marker session)
         :window (reference-explorer-ui--quick-session-source-window session)))))

(defun reference-explorer-ui--quick-run-source (&optional source)
  "Open the active quick reference query through SOURCE or configured order."
  (let ((context (reference-explorer-ui--quick-context)))
    (unless context
      (user-error "No quick reference session is active"))
    (if source
        (reference-explorer-run-source source context)
      (reference-explorer-run-context context))))

(defun reference-explorer-ui-quick-open-reference ()
  "Open the active quick reference query with the configured source chain."
  (interactive)
  (reference-explorer-ui--quick-run-source))

(defun reference-explorer-ui-quick-macos-dictionary ()
  "Forward the active quick reference query to macOS Dictionary."
  (interactive)
  (reference-explorer-ui--quick-run-source 'macos-dictionary))

(defun reference-explorer-ui-quick-monokakido ()
  "Forward the active quick reference query to Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-ui--quick-run-source 'monokakido))

(defvar-keymap reference-explorer-ui-quick-map
  :doc "Transient keymap active during quick reference."
  "H-n" #'reference-explorer-ui-quick-next
  "H-p" #'reference-explorer-ui-quick-previous
  "H-s" #'reference-explorer-ui-quick-shorten-query
  "H-e" #'reference-explorer-ui-quick-expand-query
  "H-v" #'reference-explorer-ui-preview-scroll-up
  "H-V" #'reference-explorer-ui-preview-scroll-down
  "H-i" #'reference-explorer-ui-quick-activate-preview
  "H-q" #'reference-explorer-ui-quick-quit
  "C-g" #'reference-explorer-ui-quick-quit
  "TAB" #'reference-explorer-ui-quick-display-entry
  "<tab>" #'reference-explorer-ui-quick-display-entry
  "H-." #'reference-explorer-ui-quick-open-reference
  "M-m" #'reference-explorer-ui-quick-open-consult)



(defun reference-explorer-ui--quick-open-session (session)
  "Open the already populated quick candidate SESSION."
  (reference-explorer-ui--quick-cleanup)
  (setq reference-explorer-ui--quick-session session)
  (if (not (reference-explorer-ui--quick-show-list-frame session))
      (progn
        (reference-explorer-ui--quick-cleanup)
        (message "Quick reference: cannot display candidates for “%s”"
                 (reference-explorer-ui--quick-session-query session)))
    (setf
     (reference-explorer-ui--quick-session-exit-function session)
     (set-transient-map reference-explorer-ui-quick-map t
                        #'reference-explorer-ui--quick-cleanup))
    (reference-explorer-ui--quick-highlight-source session)
    (reference-explorer-ui--quick-schedule-preview session)
    (reference-explorer-ui--quick-show-help)))





;; Thesaurus candidate selection

(defun reference-explorer-ui--thesaurus-candidate-value (candidate)
  "Return the normalized thesaurus candidate stored in CANDIDATE."
  (cond
   ((reference-explorer-candidate-p candidate) candidate)
   ((stringp candidate)
    (or (get-text-property 0 'consult--candidate candidate)
        (let ((position
               (next-single-property-change
                0 'consult--candidate candidate (length candidate))))
          (and (< position (length candidate))
               (get-text-property position 'consult--candidate candidate)))))))

(defun reference-explorer-ui--thesaurus-term (candidate)
  "Return the term represented by thesaurus CANDIDATE."
  (when-let ((value
              (reference-explorer-ui--thesaurus-candidate-value candidate)))
    (reference-explorer-candidate-label value)))

(defun reference-explorer-ui--thesaurus-context (candidate)
  "Return replacement context attached to Consult CANDIDATE."
  (and (stringp candidate)
       (get-text-property 0 'reference-explorer-context candidate)))

(defun reference-explorer-ui-thesaurus-accept (candidate)
  "Run the Thesaurus source's declared action for CANDIDATE."
  (interactive)
  (if-let ((value
            (reference-explorer-ui--thesaurus-candidate-value candidate)))
      (reference-explorer-candidate-commit
       value
       (or (reference-explorer-ui--thesaurus-context candidate)
           reference-explorer-ui--consult-origin))
    (user-error "Thesaurus candidate data is unavailable")))

(defun reference-explorer-ui-thesaurus-copy (candidate)
  "Copy the term represented by thesaurus CANDIDATE."
  (interactive)
  (if-let ((term (reference-explorer-ui--thesaurus-term candidate)))
      (progn (kill-new term) (message "Copied thesaurus term: %s" term))
    (user-error "Thesaurus candidate data is unavailable")))

(defun reference-explorer-ui--thesaurus-run-source (candidate source)
  "Open thesaurus CANDIDATE through reference SOURCE."
  (let* ((term (reference-explorer-ui--thesaurus-term candidate))
         (context (or (reference-explorer-ui--thesaurus-context candidate)
                      reference-explorer-ui--consult-origin))
         (marker (and context (reference-explorer-context-marker context)))
         (window (and context (reference-explorer-context-window context))))
    (unless term
      (user-error "Thesaurus candidate data is unavailable"))
    (reference-explorer-run-source
     source
     (reference-explorer-context-create
      :query term
      :marker (if (and (markerp marker) (marker-position marker))
                  (copy-marker marker)
                (copy-marker (point)))
      :window (or (and (window-live-p window) window) (selected-window))))))

(defun reference-explorer-ui-thesaurus-lookup (candidate)
  "Open thesaurus CANDIDATE with Lookup."
  (interactive)
  (reference-explorer-ui--thesaurus-run-source candidate 'lookup))

(defun reference-explorer-ui-thesaurus-macos-dictionary (candidate)
  "Open thesaurus CANDIDATE with macOS Dictionary."
  (interactive)
  (reference-explorer-ui--thesaurus-run-source candidate 'macos-dictionary))

(defun reference-explorer-ui-thesaurus-monokakido (candidate)
  "Open thesaurus CANDIDATE with Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-ui--thesaurus-run-source candidate 'monokakido))

(defun reference-explorer-ui--thesaurus-consult-candidate
    (value context id)
  "Return a Consult string for thesaurus VALUE and replacement CONTEXT."
  (let* ((term (reference-explorer-ui--thesaurus-term value))
         (candidate (consult--tofu-append term id)))
    (put-text-property (length term) (length candidate) 'display "" candidate)
    (put-text-property 0 (length term) 'consult--candidate value candidate)
    (put-text-property 0 (length term) 'reference-explorer-context
                       context candidate)
    candidate))

(defun reference-explorer-ui--thesaurus-annotation (candidate)
  "Return an annotation for the thesaurus Consult CANDIDATE."
  (when-let ((value
              (reference-explorer-ui--thesaurus-candidate-value candidate)))
    (let ((annotation
           (reference-explorer-ui--candidate-annotation value)))
      (unless (string-empty-p annotation)
        (concat "  " annotation)))))

(defun reference-explorer-ui--consult-thesaurus
    (candidates context)
  "Select one of fixed thesaurus CANDIDATES using replacement CONTEXT."
  (require 'consult)
  (if (null candidates)
      (message "Thesaurus: no matches")
    (let* ((tag (make-symbol "reference-explorer-source-thesaurus-control"))
           (reference-explorer-ui--consult-toggle-tag tag)
           (reference-explorer-ui--consult-origin
            context)
           (result
            (catch tag
              (list
               'return
               (consult--read
                (cl-loop for value in candidates
                         for id from 0
                         collect
                         (reference-explorer-ui--thesaurus-consult-candidate
                          value context id))
                :prompt "Synonym: "
                :category 'reference-explorer-source-thesaurus-candidate
                :require-match t
                :sort nil
                :lookup #'consult--lookup-candidate
                :annotate #'reference-explorer-ui--thesaurus-annotation)))))
      (pcase result
        (`(return ,selected)
         (when selected
           (reference-explorer-ui-thesaurus-accept selected)))
        (`(interact ,preview ,window)
         (reference-explorer-ui--activate-preview-interaction
          preview window))))))

(defun reference-explorer-ui--thesaurus-show-candidates
    (query candidates context source-bounds)
  "Show QUERY's thesaurus CANDIDATES using quick UI or Consult."
  (if (not (display-graphic-p))
      (reference-explorer-ui--consult-thesaurus candidates context)
    (reference-explorer-ui--quick-open-session
     (reference-explorer-ui--make-quick-session
      :query query
      :context context
      :query-options (list (cons query candidates))
      :query-index 0
      :entries candidates
      :index 0
      :source-window (reference-explorer-context-window context)
      :source-marker (reference-explorer-context-marker context)
      :source-bounds source-bounds
      :source 'thesaurus
      :consult-function
      (lambda (entries)
        (reference-explorer-ui--consult-thesaurus entries context))
      :help "TAB:置換  M-m:Consult  Embark:その他の操作"))))

(defun reference-explorer-ui--query-bounds-at-point (query)
  "Return buffer bounds matching extracted QUERY around point."
  (or
   (seq-find
    (lambda (bounds)
      (equal query
             (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (reference-explorer-ui-phrase-candidate-bounds-at-point))
   (bounds-of-thing-at-point 'word)))

(defun reference-explorer-ui--thesaurus-search
    (query buffer beginning end source-window source-marker)
  "Retrieve QUERY and present candidates that may replace BEGINNING to END."
  (let ((original
         (with-current-buffer buffer
           (buffer-substring-no-properties beginning end)))
        (beginning-marker (copy-marker beginning))
        (end-marker (copy-marker end t)))
    (message "Thesaurus: searching for “%s”…" query)
    (reference-explorer-source-thesaurus-fetch
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
         (let* ((context
                 (reference-explorer-context-create
                  :phrase query :query query :marker source-marker
                  :window (if (window-live-p source-window)
                              source-window
                            (or (get-buffer-window buffer t)
                                (selected-window)))
                  :selection-beginning beginning-marker
                  :selection-end end-marker
                  :selection-text original))
                (candidates
                 (mapcar (lambda (result)
                           (reference-explorer-source-make-candidate
                            'thesaurus result context))
                         results)))
           (reference-explorer-ui--thesaurus-show-candidates
            query candidates context
            (cons beginning-marker end-marker))))))
     (lambda (message)
       (message "Thesaurus: %s" message)))))

;;;###autoload
(defun reference-explorer-ui-thesaurus-at-point ()
  "Choose an online synonym and replace the region or term at point.
Retrieval starts once, when this command is invoked.  Candidate navigation,
local dictionary previews and Embark actions do not contact the online
service."
  (interactive)
  (let* ((region-active (use-region-p))
         (query (reference-explorer-phrase-at-point))
         (bounds
          (if region-active
              (cons (region-beginning) (region-end))
            (and query
                 (reference-explorer-ui--query-bounds-at-point query)))))
    (unless (and query bounds)
      (user-error "No replaceable thesaurus query at point"))
    (reference-explorer-ui--thesaurus-search
     query (current-buffer) (car bounds) (cdr bounds)
     (selected-window) (copy-marker (point)))))

(defun reference-explorer-ui-thesaurus-search-candidate (candidate)
  "Search synonyms of thesaurus CANDIDATE as a new explicit request."
  (interactive)
  (let* ((term (reference-explorer-ui--thesaurus-term candidate))
         (context (or (reference-explorer-ui--thesaurus-context candidate)
                      reference-explorer-ui--consult-origin))
         (beginning (and context
                         (reference-explorer-context-selection-beginning context)))
         (end (and context
                   (reference-explorer-context-selection-end context)))
         (buffer (and (markerp beginning) (marker-buffer beginning))))
    (unless (and term (buffer-live-p buffer)
                 (markerp beginning) (marker-position beginning)
                 (markerp end) (marker-position end))
      (user-error "The thesaurus source context is no longer available"))
    (reference-explorer-ui--thesaurus-search
     term buffer beginning end
     (or (and context (reference-explorer-context-window context))
         (get-buffer-window buffer t) (selected-window))
     (copy-marker beginning))))

























;; Consult interface

(defvar-keymap reference-explorer-ui-consult-map
  :doc "Keymap active while selecting a reference entry."
  "M-m" #'reference-explorer-ui-toggle-consult-mode
  "H-s" #'reference-explorer-ui-consult-shorten-query
  "H-e" #'reference-explorer-ui-consult-expand-query
  "H-v" #'reference-explorer-ui-preview-scroll-up
  "H-V" #'reference-explorer-ui-preview-scroll-down
  "H-i" #'reference-explorer-ui-consult-activate-preview
  "H-." #'reference-explorer-ui-consult-open-reference
  "TAB" #'reference-explorer-ui-select-candidate
  "<tab>" #'reference-explorer-ui-select-candidate)

(defun reference-explorer-ui-consult-activate-preview ()
  "Exit Consult and promote its current preview for interaction."
  (interactive)
  (unless reference-explorer-ui--consult-toggle-tag
    (user-error "No Consult reference session is active"))
  (let ((preview reference-explorer-ui--active-temporary-preview)
        (origin-window
         (and reference-explorer-ui--consult-origin
              (reference-explorer-context-window
               reference-explorer-ui--consult-origin))))
    (unless (and (reference-explorer-ui--preview-p preview)
                 (reference-explorer-ui--preview-entry preview))
      (user-error "The current candidate has no operable preview"))
    (when (reference-explorer-ui--active-webkit-preview-xwidget)
      (setq reference-explorer-ui--preview-interaction-request preview))
    (throw reference-explorer-ui--consult-toggle-tag
           (list 'interact preview origin-window))))

(defun reference-explorer-ui--consult-run-source (&optional source)
  "Open the active Consult query through SOURCE or configured order."
  (unless reference-explorer-ui--consult-origin
    (user-error "No Consult reference session is active"))
  (let ((query (string-trim (minibuffer-contents-no-properties))))
    (when (string-empty-p query)
      (user-error "No Consult reference query"))
    (let ((context
           (copy-reference-explorer-context
            reference-explorer-ui--consult-origin)))
      (setf (reference-explorer-context-phrase context) query
            (reference-explorer-context-query context) query)
      (if source
          (reference-explorer-run-source source context)
        (reference-explorer-run-context context)))))

(defun reference-explorer-ui-consult-open-reference ()
  "Open the active Consult query with the configured source chain."
  (interactive)
  (reference-explorer-ui--consult-run-source))

(defun reference-explorer-ui-consult-macos-dictionary ()
  "Forward the active Consult query to macOS Dictionary."
  (interactive)
  (reference-explorer-ui--consult-run-source 'macos-dictionary))

(defun reference-explorer-ui-consult-monokakido ()
  "Forward the active Consult query to Dictionaries by Monokakido."
  (interactive)
  (reference-explorer-ui--consult-run-source 'monokakido))

(defun reference-explorer-ui-select-candidate ()
  "Commit the selected Consult reference candidate."
  (interactive)
  (if (fboundp 'vertico-exit)
      (vertico-exit)
    (minibuffer-complete-and-exit)))

(defun reference-explorer-ui--consult-change-query (delta)
  "Move DELTA steps through the contextual Consult query options."
  (unless reference-explorer-ui--consult-query-options
    (user-error "No contextual reference query options"))
  (let* ((input (minibuffer-contents-no-properties))
         (matched-index
          (seq-position reference-explorer-ui--consult-query-options
                        input #'equal))
         (old-index (or matched-index
                        reference-explorer-ui--consult-query-index
                        0))
         (new-index
          (max 0
               (min (1- (length reference-explorer-ui--consult-query-options))
                    (+ old-index delta)))))
    (if (= old-index new-index)
        (message (if (> delta 0)
                     "これ以上縮小できません"
                   "これ以上拡大できません"))
      (setq reference-explorer-ui--consult-query-index new-index)
      (delete-minibuffer-contents)
      (insert (nth new-index reference-explorer-ui--consult-query-options)))))

(defun reference-explorer-ui-consult-shorten-query ()
  "Use the next shorter contextual query in Consult reference."
  (interactive)
  (reference-explorer-ui--consult-change-query 1))

(defun reference-explorer-ui-consult-expand-query ()
  "Use the next longer contextual query in Consult reference."
  (interactive)
  (reference-explorer-ui--consult-change-query -1))

(defun reference-explorer-ui-toggle-consult-mode ()
  "Toggle literal and converted search in the active reference minibuffer."
  (interactive)
  (unless reference-explorer-ui--consult-toggle-tag
    (user-error "No Consult reference session is active"))
  (let ((mode (if (eq reference-explorer-ui--active-consult-mode 'literal)
                  'converted
                'literal))
        (input (minibuffer-contents-no-properties)))
    (setq reference-explorer-ui-consult-mode mode)
    (throw reference-explorer-ui--consult-toggle-tag
           (list 'toggle mode input))))

(defun reference-explorer-ui--completion-overrides (mode category)
  "Return completion overrides for MODE and source CATEGORY."
  (if (eq mode 'converted)
      (progn
        (unless reference-explorer-ui-converted-completion-style
          (user-error "Converted search requires a configured completion style"))
        (cons
         `(,category
           (styles ,reference-explorer-ui-converted-completion-style basic))
         completion-category-overrides))
    completion-category-overrides))









;; Dash-compatible docsets

(defun reference-explorer-ui--context-major-mode (context)
  "Return the originating major mode recorded by CONTEXT."
  (when-let* ((marker (reference-explorer-context-marker context))
              (buffer (and (markerp marker) (marker-buffer marker))))
    (buffer-local-value 'major-mode buffer)))

(defun reference-explorer-ui--context-query-options (context)
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
                    (reference-explorer-ui-phrase-candidate-bounds-at-point))))
              (cons query (delete query queries)))))))))

(defun reference-explorer-ui--consult-docset-read (initial mode)
  "Read and return a docset result starting with INITIAL for MODE."
  (require 'consult)
  (let* ((tag (make-symbol "reference-explorer-source-docset-control"))
         (reference-explorer-ui--consult-toggle-tag tag))
    (catch tag
      (list
       'return
       (consult--read
        (consult--dynamic-collection
            (lambda (input)
              (reference-explorer-ui--docset-candidates input mode))
          :min-input 1
          :debounce reference-explorer-ui-search-debounce)
        :prompt "Docset: "
        :initial initial
        :history 'reference-explorer-ui-history
        :category 'reference-explorer-source-docset-result
        :require-match t
        :sort nil
        :keymap reference-explorer-ui-consult-map
        :lookup #'consult--lookup-candidate
        :annotate (lambda (candidate)
                    (reference-explorer-ui--docset-annotation candidate mode))
        :state (reference-explorer-ui--preview-state)
        :preview-key `(:debounce ,reference-explorer-ui-preview-debounce any))))))

(defun reference-explorer-ui-consult-docset (query mode &optional origin-window)
  "Select a docset result for QUERY and major MODE, then display it.
ORIGIN-WINDOW receives focus after direct preview interaction ends."
  (let ((reference-explorer-ui--consult-origin
         (reference-explorer-context-create
          :query query
          :window (or origin-window (selected-window)))))
    (pcase (reference-explorer-ui--consult-docset-read query mode)
      (`(return ,result)
       (when result
         (reference-explorer-candidate-commit
          (if (reference-explorer-candidate-p result)
              result
            (reference-explorer-source-make-candidate
             'docset result reference-explorer-ui--consult-origin))
          reference-explorer-ui--consult-origin)))
      (`(interact ,preview ,window)
       (reference-explorer-ui--activate-preview-interaction
        preview window)))))

(defun reference-explorer-ui--docset-quick-options (queries mode)
  "Search every member of QUERIES in docsets selected for MODE."
  (mapcar (lambda (query)
            (cons query (reference-explorer-source-docset-search query mode)))
          queries))

(defun reference-explorer-ui-docset-available-p ()
  "Return non-nil when Emacs has built-in SQLite support."
  (sqlite-available-p))

(defun reference-explorer-ui-docset-present (context)
  "Display docset matches for reference CONTEXT."
  (let* ((mode (reference-explorer-ui--context-major-mode context))
         (docsets (and mode (reference-explorer-source-docset-for-mode mode))))
    (unless docsets
      (signal 'reference-explorer-source-unavailable
              (list (format "No installed docset is configured for %s" mode))))
    (let* ((queries (or (reference-explorer-ui--context-query-options context)
                        (list (reference-explorer-context-query context))))
           (options
            (mapcar
             (lambda (option)
               (cons (car option)
                     (mapcar
                      (lambda (result)
                        (reference-explorer-source-make-candidate
                         'docset result context))
                      (cdr option))))
             (reference-explorer-ui--docset-quick-options queries mode)))
           (query (caar options))
           (source-window (reference-explorer-context-window context))
           (source-marker (reference-explorer-context-marker context)))
      (if (not (display-graphic-p))
          (reference-explorer-ui-consult-docset query mode source-window)
        (reference-explorer-ui--quick-open-session
         (reference-explorer-ui--make-quick-session
          :source 'docset
          :context context
          :query query
          :query-options options
          :query-index 0
          :entries (cdar options)
          :index 0
          :source-window source-window
          :source-marker source-marker
          :consult-function
          (lambda (_entries)
            (reference-explorer-ui-consult-docset
             query mode source-window))
          :help "H-s/e:検索語を縮小/拡大  H-i:preview操作  M-m:Consult"))))))


(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables
               'reference-explorer-ui-consult-mode)
  (add-to-list 'savehist-additional-variables
               'reference-explorer-ui-history))

(with-eval-after-load 'embark
  (set-keymap-parent reference-explorer-ui-thesaurus-embark-map
                     embark-general-map)
  (set-keymap-parent reference-explorer-ui-docset-embark-map
                     embark-general-map)
  (define-key reference-explorer-ui-thesaurus-embark-map (kbd "RET")
              #'reference-explorer-ui-thesaurus-accept)
  (define-key reference-explorer-ui-thesaurus-embark-map (kbd "r")
              #'reference-explorer-ui-thesaurus-accept)
  (define-key reference-explorer-ui-thesaurus-embark-map (kbd "l")
              #'reference-explorer-ui-thesaurus-lookup)
  (define-key reference-explorer-ui-thesaurus-embark-map (kbd "w")
              #'reference-explorer-ui-thesaurus-copy)
  (define-key reference-explorer-ui-thesaurus-embark-map (kbd "s")
              #'reference-explorer-ui-thesaurus-search-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-source-thesaurus-candidate
                 . reference-explorer-ui-thesaurus-embark-map))
  (setf (alist-get 'reference-explorer-source-thesaurus-candidate
                   embark-default-action-overrides)
        #'reference-explorer-ui-thesaurus-accept)
  (define-key reference-explorer-ui-docset-embark-map (kbd "RET")
              #'reference-explorer-ui-display-docset-candidate)
  (define-key reference-explorer-ui-docset-embark-map (kbd "w")
              #'reference-explorer-ui-copy-docset-url)
  (define-key reference-explorer-ui-docset-embark-map (kbd "b")
              #'reference-explorer-ui-browse-docset-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-source-docset-result
                 . reference-explorer-ui-docset-embark-map))
  (setf (alist-get 'reference-explorer-source-docset-result
                   embark-default-action-overrides)
        #'reference-explorer-ui-display-docset-candidate))

(provide 'reference-explorer-ui)
;;; reference-explorer-ui.el ends here
