;;; reference-explorer-source-lookup.el --- Lookup for Emacs search source -*- lexical-binding: t -*-

;;; Commentary:

;; Lookup search, ranking, entry rendering, commands, and presentation
;; integration.  Its primary purpose is searching locally installed EPWING
;; and EBXA dictionary data through Lookup's `ndeb' agent and EBLook.  Shared
;; Quick, Consult, preview, and interaction UI lives in `reference-explorer-ui'.
;;
;; Lookup for Emacs is an external package, not part of Emacs or Reference
;; Explorer.  The tested Lookup 1.4+media distribution is published at:
;;
;;   http://ikazuhiro.s206.xrea.com/staticpages/index.php/lookup
;;
;; Homebrew users can install Lookup and EBLook with:
;;
;;   brew install matoi/tap/emacs-lookup
;;
;; Then configure paths before loading this source:
;;
;;   (require 'reference-explorer-source-lookup-homebrew)
;;   (reference-explorer-source-lookup-homebrew-configure)
;;   (require 'reference-explorer-source-lookup)
;;
;; Other installations should put Lookup on `load-path' and configure its
;; native search agents, modules, and dictionary options before loading this
;; file.  When Lookup is absent, the shared UI and other sources remain usable.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-core)
(require 'reference-explorer-source)
(require 'reference-explorer-ui)
(require 'seq)
(require 'subr-x)

(defvar lookup-content-buffer)
(defvar lookup-content-current-entry)
(defvar lookup-content-line-heading)
(defvar lookup-enable-splash)
(defvar savehist-additional-variables)

(defconst reference-explorer-source-lookup-content-buffer-name "*Lookup Content*"
  "Buffer used for committed Lookup content.")

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
(declare-function consult--dynamic-collection "consult" (fun &rest options))
(declare-function consult--lookup-candidate "consult" (selected candidates &rest args))
(declare-function consult--read "consult" (table &rest options))
(declare-function consult--tofu-append "consult" (candidate id))

(eval-when-compile
  (defvar embark-default-action-overrides)
  (defvar embark-exporters-alist)
  (defvar embark-general-map)
  (defvar embark-keymap-alist))

(defvar reference-explorer-source-lookup-embark-map (make-sparse-keymap)
  "Embark actions for Lookup entries.")

(defgroup reference-explorer-source-lookup nil
  "Lookup for Emacs search source for Reference Explorer."
  :group 'reference-explorer-ui)

(defcustom reference-explorer-source-lookup-source-order nil
  "Dictionary source order used within each Lookup match class.
Each string is a dictionary title as shown beside a Consult candidate.  Sources
not listed here follow the listed sources in Lookup's original order.  Exact
matches are sorted by this order first, followed by partial matches sorted by
the same order."
  :type '(repeat string)
  :group 'reference-explorer-source-lookup)

(defcustom reference-explorer-source-lookup-heading-filter-functions nil
  "Functions applied to each Lookup entry heading before display cleanup.
Each function receives ENTRY and the current rich HEADING string, and must
return the heading passed to the next function.  This is intended for local,
dictionary-specific corrections; common whitespace and text-property cleanup
is performed afterward."
  :type 'hook
  :group 'reference-explorer-source-lookup)

(defconst reference-explorer-source-lookup--expanded-heading-prefix-regexp
  "\\`\\[[^]\n]+ ->\\][ \t　]*"
  "Regexp matching Lookup's source-word prefix on expanded headings.")

(defcustom reference-explorer-source-lookup-preview-highlight-sources nil
  "Dictionary source titles whose preview content highlights the query.
Titles are compared with the displayed source name returned by Lookup.  An
empty list disables query highlighting for every source."
  :type '(repeat string)
  :group 'reference-explorer-source-lookup)

(defvar reference-explorer-source-lookup--entry-cache (make-hash-table :test #'equal)
  "Lookup entries cached by search mode and backend query.")

;; Entry collection and formatting

(defun reference-explorer-source-lookup--search-entries-with-method (input mode method)
  "Return Lookup entries for INPUT in MODE using search METHOD."
  (when-let ((backend-query
              (reference-explorer-ui--backend-query input mode)))
    (let* ((cache-key (list mode method backend-query))
           (cached (gethash cache-key reference-explorer-source-lookup--entry-cache
                            'missing)))
      (cond
       ((eq cached :none) nil)
       ((not (eq cached 'missing)) cached)
       (t
        (when (> (hash-table-count reference-explorer-source-lookup--entry-cache) 256)
          (clrhash reference-explorer-source-lookup--entry-cache))
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
                   reference-explorer-source-lookup--entry-cache)
          entries))))))

(defun reference-explorer-source-lookup--ranked-entries (input mode partial-method)
  "Return ranked Lookup entries for INPUT and MODE.
Exact matches come first, followed by matches from PARTIAL-METHOD.  Both
groups are ordered by `reference-explorer-source-lookup-source-order'."
  (let* ((exact
          (reference-explorer-source-lookup--search-entries-with-method
           input mode 'exact))
         (partial
          (seq-remove
           (lambda (entry)
             (seq-some
              (lambda (exact-entry)
                (lookup-entry-compare entry exact-entry))
              exact))
           (reference-explorer-source-lookup--search-entries-with-method
            input mode partial-method)))
         (source-ranks
          (cl-loop for source in reference-explorer-source-lookup-source-order
                   for rank from 0
                   collect (cons source rank)))
         (unlisted-rank (length reference-explorer-source-lookup-source-order))
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

(defun reference-explorer-source-lookup--search-entries (input mode)
  "Return exact and substring Lookup entries for INPUT in MODE."
  (reference-explorer-source-lookup--ranked-entries input mode 'substring))

(defun reference-explorer-source-lookup--quick-search-entries (input)
  "Return exact and prefix Lookup entries for literal INPUT."
  (reference-explorer-source-lookup--ranked-entries input 'literal 'prefix))

(defun reference-explorer-source-lookup--plain-entry-heading (entry)
  "Return ENTRY's plain heading without expansion provenance or edge spaces."
  (let ((heading (lookup-entry-heading entry)))
    (dolist (filter reference-explorer-source-lookup-heading-filter-functions)
      (setq heading (funcall filter entry heading)))
    (string-trim
     (replace-regexp-in-string
      reference-explorer-source-lookup--expanded-heading-prefix-regexp ""
      (substring-no-properties heading))
     "[ \t\n\r　]+" "[ \t\n\r　]+")))

(defun reference-explorer-source-lookup--entry-candidates (input mode)
  "Return Consult candidates for Lookup INPUT in MODE."
  (cl-loop for entry in (reference-explorer-source-lookup--search-entries input mode)
           for id from 0
           for value = (reference-explorer-source-make-candidate
                        'lookup entry reference-explorer-ui--consult-origin)
           ;; Dictionary headings can contain raised glyphs and inline gaiji
           ;; images.  Completion rows should have uniform text metrics;
           ;; preserve those rich properties only in rendered content.
           for heading = (reference-explorer-candidate-label value)
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
                                   'consult--candidate value candidate))
           collect candidate))

(defun reference-explorer-source-lookup--entry-annotation (candidate)
  "Return the dictionary annotation for Lookup CANDIDATE."
  (when-let ((value (get-text-property 0 'consult--candidate candidate)))
    (let ((annotation (reference-explorer-candidate-annotation value)))
      (unless (string-empty-p annotation)
        (concat "  " annotation)))))

;; Temporary preview and committed Popper content

(defun reference-explorer-source-lookup-candidate-entry (candidate)
  "Return the Lookup entry stored in CANDIDATE, or nil."
  (let ((value
         (cond
          ((reference-explorer-candidate-p candidate) candidate)
          ((stringp candidate)
           (or (get-text-property 0 'consult--candidate candidate)
               (let ((position
                      (next-single-property-change
                       0 'consult--candidate candidate (length candidate))))
                 (and (< position (length candidate))
                      (get-text-property
                       position 'consult--candidate candidate))))))))
    (if (reference-explorer-candidate-p value)
        (reference-explorer-candidate-value value)
      value)))

(defun reference-explorer-source-lookup-entry-source (entry)
  "Return the displayed dictionary source name for Lookup ENTRY."
  (lookup-dictionary-title (lookup-entry-dictionary entry)))

(defun reference-explorer-source-lookup--insert-entry-content (entry)
  "Insert the rendered body of Lookup ENTRY in the current buffer."
  (setq lookup-content-current-entry entry
        lookup-content-line-heading
        (reference-explorer-source-lookup--plain-entry-heading entry))
  (if (lookup-reference-p entry)
      (insert "(no contents)")
    (lookup-vse-insert-content entry)))

(defun reference-explorer-source-lookup-entry-text (entry)
  "Return Lookup ENTRY's body as plain text."
  (require 'lookup-content)
  (require 'lookup-vse)
  (with-temp-buffer
    (reference-explorer-source-lookup--insert-entry-content entry)
    (string-trim-right
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun reference-explorer-source-lookup-entry-description (entry)
  "Return a self-contained plain-text description of Lookup ENTRY."
  (format "%s — %s\n\n%s"
          (reference-explorer-source-lookup--plain-entry-heading entry)
          (reference-explorer-source-lookup-entry-source entry)
          (reference-explorer-source-lookup-entry-text entry)))

(defun reference-explorer-source-lookup-render-entry (entry buffer-name)
  "Render Lookup ENTRY in BUFFER-NAME and return that buffer."
  (require 'lookup-content)
  (require 'lookup-vse)
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (reference-explorer-source-lookup--insert-entry-content entry)
        (goto-char (point-min))
        (lookup-content-mode)))
    buffer))

(defun reference-explorer-source-lookup-display-candidate (candidate)
  "Display the Lookup entry represented by Embark CANDIDATE."
  (if-let ((entry (reference-explorer-source-lookup-candidate-entry candidate)))
      (reference-explorer-ui--display-entry entry)
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-source-lookup-copy-candidate (candidate)
  "Copy the full Lookup description represented by Embark CANDIDATE."
  (if-let ((entry (reference-explorer-source-lookup-candidate-entry candidate)))
      (let ((description (reference-explorer-source-lookup-entry-description entry)))
        (kill-new description)
        (message "Copied Lookup entry: %s"
                 (reference-explorer-source-lookup--plain-entry-heading entry)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-source-lookup-monokakido-candidate (candidate)
  "Open the heading represented by Embark CANDIDATE in Monokakido."
  (if-let ((entry (reference-explorer-source-lookup-candidate-entry candidate)))
      (reference-explorer-run-source
       'monokakido
       (reference-explorer-context-create
        :query (reference-explorer-source-lookup--plain-entry-heading entry)
        :marker (copy-marker (point))
        :window (selected-window)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-source-lookup-macos-dictionary-candidate (candidate)
  "Open the heading represented by Embark CANDIDATE in macOS Dictionary."
  (if-let ((entry (reference-explorer-source-lookup-candidate-entry candidate)))
      (reference-explorer-run-source
       'macos-dictionary
       (reference-explorer-context-create
        :query (reference-explorer-source-lookup--plain-entry-heading entry)
        :marker (copy-marker (point))
        :window (selected-window)))
    (user-error "Lookup entry data is unavailable")))

(defun reference-explorer-source-lookup--quick-start
    (queries source-window source-marker &optional source-bounds initial-query)
  "Start quick Lookup for QUERIES from SOURCE-WINDOW and SOURCE-MARKER.
SOURCE-BOUNDS delimit an explicit region.  When INITIAL-QUERY is a member of
QUERIES, begin at that query while retaining the full expand/shrink sequence."
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let* ((query-options
          (reference-explorer-ui--quick-query-options
           queries #'reference-explorer-source-lookup--quick-search-entries))
         (context
          (reference-explorer-context-create
           :query initial-query :marker source-marker :window source-window
           :selection-beginning (and source-bounds (car source-bounds))
           :selection-end (and source-bounds (cdr source-bounds))))
         (query-options
          (mapcar
           (lambda (option)
             (cons (car option)
                   (mapcar
                    (lambda (entry)
                      (reference-explorer-source-make-candidate
                       'lookup entry context))
                    (cdr option))))
           query-options))
         (query-index
          (or (and initial-query
                   (cl-position initial-query query-options
                                :key #'car :test #'equal))
              0))
         (query-option (nth query-index query-options))
         (query (or (car query-option) (car queries))))
    (cond
     ((not (and query (not (string-empty-p (string-trim query)))))
      (message "Quick Lookup: no searchable text at point"))
     ((not (display-graphic-p))
      (reference-explorer-source-lookup--consult-loop query 'literal queries))
     (t
      (let ((entries (cdr query-option)))
        (reference-explorer-ui--quick-open-session
         (reference-explorer-ui--make-quick-session
          :source 'lookup
          :context context
          :query query
          :query-options query-options
          :query-index query-index
          :entries entries
          :index 0
          :source-window source-window
          :source-marker source-marker
          :source-bounds source-bounds
          :consult-function
          (lambda (_entries)
            (reference-explorer-source-lookup--consult-loop
             query 'literal queries)))))))))

(defun reference-explorer-source-lookup-quick-lookup-query
    (query &optional source-window source-marker)
  "Show exact and prefix Lookup matches for explicit QUERY.
SOURCE-WINDOW and SOURCE-MARKER identify the point from which the lookup was
requested."
  (reference-explorer-source-lookup--quick-start
   (list query)
   (or source-window (selected-window))
   (or source-marker (copy-marker (point)))))

;;;###autoload
(defun reference-explorer-source-lookup-quick-lookup-at-point ()
  "Show exact and prefix Lookup matches for the region or word at point."
  (interactive)
  (let* ((region-active (use-region-p))
         (begin (and region-active (region-beginning)))
         (end (and region-active (region-end))))
    (reference-explorer-source-lookup--quick-start
     (if region-active
         (list (buffer-substring-no-properties begin end))
       (reference-explorer-ui--quick-query-candidates-at-point))
     (selected-window)
     (copy-marker (if region-active begin (point)))
     (and region-active (cons begin end))
     (if region-active
         (buffer-substring-no-properties begin end)
       (reference-explorer-ui-phrase-at-point)))))

;; Persistent Embark export

(defun reference-explorer-source-lookup--export-entry-at-point ()
  "Return the Lookup entry on the current export-buffer line."
  (or (get-text-property (point) 'reference-explorer-source-lookup-entry)
      (get-text-property (line-beginning-position)
                         'reference-explorer-source-lookup-entry)
      (and (> (line-end-position) (line-beginning-position))
           (get-text-property (1- (line-end-position))
                              'reference-explorer-source-lookup-entry))))

(defun reference-explorer-source-lookup--export-candidate-at-point ()
  "Return the propertized Lookup candidate on the current export line."
  (when (reference-explorer-source-lookup--export-entry-at-point)
    (buffer-substring (line-beginning-position) (line-end-position))))

(defun reference-explorer-source-lookup--embark-export-target ()
  "Return an Embark Lookup target at point in an export buffer."
  (when (derived-mode-p 'reference-explorer-source-lookup-export-mode)
    (when-let ((candidate
                (reference-explorer-source-lookup--export-candidate-at-point)))
      `(reference-explorer-source-lookup-entry
        ,candidate ,(line-beginning-position) . ,(line-end-position)))))

(defun reference-explorer-source-lookup--export-candidate-position (window)
  "Return the current export candidate position in WINDOW's frame pixels."
  (when-let* (((window-live-p window))
              (entry (reference-explorer-source-lookup--export-entry-at-point))
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

(defun reference-explorer-source-lookup--export-cancel-preview ()
  "Cancel the pending or visible preview in the current export buffer."
  (when (timerp reference-explorer-ui--export-preview-timer)
    (cancel-timer reference-explorer-ui--export-preview-timer))
  (setq reference-explorer-ui--export-preview-timer nil)
  (when reference-explorer-ui--export-preview
    (reference-explorer-ui--close-temporary-preview
     reference-explorer-ui--export-preview))
  (setq reference-explorer-ui--export-preview nil
        reference-explorer-ui--export-preview-entry nil))

(defun reference-explorer-source-lookup--export-show-preview (buffer entry)
  "Show ENTRY if BUFFER still selects it in a visible export window."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq reference-explorer-ui--export-preview-timer nil)
      (when (and (eq entry (reference-explorer-source-lookup--export-entry-at-point))
                 (derived-mode-p 'reference-explorer-source-lookup-export-mode))
        (when-let* ((window
                     (if (eq (window-buffer (selected-window)) buffer)
                         (selected-window)
                       (get-buffer-window buffer t)))
                    (position
                     (reference-explorer-source-lookup--export-candidate-position
                      window)))
          (setq reference-explorer-ui--export-preview
                (reference-explorer-ui--show-temporary-preview-at-position
                 entry position window)))))))

(defun reference-explorer-source-lookup--export-schedule-preview ()
  "Schedule a preview for the Lookup entry at point."
  (let ((entry (reference-explorer-source-lookup--export-entry-at-point)))
    (unless (and (eq entry reference-explorer-ui--export-preview-entry)
                 (or (timerp reference-explorer-ui--export-preview-timer)
                     (reference-explorer-ui--preview-live-p
                      reference-explorer-ui--export-preview)))
      (reference-explorer-source-lookup--export-cancel-preview)
      (when entry
        (setq reference-explorer-ui--export-preview-entry entry
              reference-explorer-ui--export-preview-timer
              (run-with-idle-timer
               reference-explorer-ui-preview-debounce nil
               #'reference-explorer-source-lookup--export-show-preview
               (current-buffer) entry))))))

(defun reference-explorer-source-lookup--export-window-selection-change (window)
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
      (reference-explorer-source-lookup--export-cancel-preview))))

(defun reference-explorer-source-lookup-export-display-entry ()
  "Commit the Lookup entry at point to the Popper content window."
  (interactive)
  (if-let ((entry (reference-explorer-source-lookup--export-entry-at-point)))
      (progn
        (reference-explorer-source-lookup--export-cancel-preview)
        (reference-explorer-ui--display-entry entry))
    (user-error "No Lookup entry on this line")))

(defvar-keymap reference-explorer-source-lookup-export-mode-map
  :doc "Keymap for exported Lookup search results."
  :parent special-mode-map
  "RET" #'reference-explorer-source-lookup-export-display-entry)

(define-derived-mode reference-explorer-source-lookup-export-mode special-mode
  "Lookup-Results"
  "Major mode for persistent Lookup search results."
  (setq-local truncate-lines t
              header-line-format
              "RET: display  H-;: actions")
  (add-hook 'post-command-hook
            #'reference-explorer-source-lookup--export-schedule-preview nil t)
  (add-hook 'kill-buffer-hook
            #'reference-explorer-source-lookup--export-cancel-preview nil t)
  (add-hook 'window-selection-change-functions
            #'reference-explorer-source-lookup--export-window-selection-change nil t)
  (when (boundp 'embark-target-finders)
    (add-hook 'embark-target-finders
              #'reference-explorer-source-lookup--embark-export-target nil t)))

(defun reference-explorer-source-lookup-export-candidates (candidates)
  "Create a persistent Lookup results buffer from Embark CANDIDATES."
  (let ((buffer (generate-new-buffer " *Lookup Export*")))
    (with-current-buffer buffer
      (reference-explorer-source-lookup-export-mode)
      (let ((inhibit-read-only t))
        (dolist (candidate candidates)
          (when-let ((entry
                      (reference-explorer-source-lookup-candidate-entry candidate)))
            (let ((start (point)))
              (insert (reference-explorer-source-lookup--plain-entry-heading entry)
                      (propertize
                       (concat "  "
                               (reference-explorer-source-lookup-entry-source entry))
                       'face 'font-lock-comment-face))
              (add-text-properties
               start (point)
               `(consult--candidate ,entry
                 reference-explorer-source-lookup-entry ,entry
                 mouse-face highlight))
              (insert "\n"))))
        (goto-char (point-min))))
    ;; Embark exporters select their result buffer as well as returning it;
    ;; `embark-export' performs its final naming and setup in that buffer.
    (set-buffer buffer)
    (reference-explorer-source-lookup--export-schedule-preview)
    buffer))

(defun reference-explorer-source-lookup--consult-read (initial mode)
  "Read a Lookup entry using INITIAL text and search MODE."
  (require 'consult)
  (let* ((reference-explorer-ui--active-consult-mode mode)
         (tag (make-symbol "reference-explorer-ui-toggle"))
         (reference-explorer-ui--consult-toggle-tag tag)
         (completion-category-overrides
          (reference-explorer-ui--completion-overrides
           mode 'reference-explorer-source-lookup-entry))
         (result
          (catch tag
            (list
             'return
             (consult--read
              (consult--dynamic-collection
                  (lambda (input)
                    (reference-explorer-source-lookup--entry-candidates input mode))
                :min-input 1
                :debounce reference-explorer-ui-search-debounce)
              :prompt (format "Lookup [%s] (M-m toggles): " mode)
              :initial initial
              :history 'reference-explorer-ui-history
              :category 'reference-explorer-source-lookup-entry
              :require-match t
              :sort nil
              :keymap reference-explorer-ui-consult-map
              :lookup #'consult--lookup-candidate
              :annotate #'reference-explorer-source-lookup--entry-annotation
              :state (reference-explorer-ui--preview-state)
              :preview-key
              `(:debounce ,reference-explorer-ui-preview-debounce any))))))
    result))

(defun reference-explorer-source-lookup--consult-loop (initial mode &optional queries)
  "Select a Lookup entry, starting with INITIAL and MODE.
QUERIES lists longest-to-shortest contextual inputs available with H-e/H-s."
  (let ((reference-explorer-ui--consult-query-options queries)
        (reference-explorer-ui--consult-query-index
         (and initial (seq-position queries initial #'equal)))
        (continue t)
        entry)
    (while continue
      (pcase (reference-explorer-source-lookup--consult-read initial mode)
        (`(toggle ,new-mode ,new-input)
         (setq mode new-mode
               initial new-input))
        (`(return ,selected)
         (setq entry selected
               continue nil))))
    (when entry
      (reference-explorer-candidate-commit
       (if (reference-explorer-candidate-p entry)
           entry
         (reference-explorer-source-make-candidate
          'lookup entry reference-explorer-ui--consult-origin))
       reference-explorer-ui--consult-origin))))

;;;###autoload
(defun reference-explorer-source-lookup-consult ()
  "Select a dictionary entry from blank input using the previous mode."
  (interactive)
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let ((reference-explorer-ui--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker (point))
          :window (selected-window))))
    (reference-explorer-source-lookup--consult-loop nil reference-explorer-ui-consult-mode)))

;;;###autoload
(defun reference-explorer-source-lookup-consult-at-point ()
  "Select a dictionary entry using the region or word at point.
Contextual input always starts in literal mode."
  (interactive)
  (unless (fboundp 'lookup-initialize)
    (user-error "Lookup is unavailable"))
  (let* ((queries
          (if (use-region-p)
              (list (buffer-substring-no-properties
                     (region-beginning) (region-end)))
            (reference-explorer-ui--quick-query-candidates-at-point)))
         (initial (car queries))
         (reference-explorer-ui--consult-origin
         (reference-explorer-context-create
          :query nil
          :marker (copy-marker (point))
          :window (selected-window))))
    (reference-explorer-source-lookup--consult-loop
     (if (use-region-p)
         initial
       (or (reference-explorer-ui-phrase-at-point) initial))
     'literal queries)))

(defun reference-explorer-source-lookup-available-p (&optional _context)
  "Return non-nil when Lookup is available."
  (or (fboundp 'lookup-initialize) (locate-library "lookup")))

(defun reference-explorer-source-lookup-present (context)
  "Display reference CONTEXT with quick Lookup."
  (unless (reference-explorer-source-lookup-available-p context)
    (signal 'reference-explorer-source-unavailable
            '("Lookup is unavailable")))
  (reference-explorer-source-lookup-quick-lookup-query
   (reference-explorer-context-query context)
   (reference-explorer-context-window context)
   (reference-explorer-context-marker context)))

(defun reference-explorer-source-lookup-protocol-search
    (query _context complete)
  "Search Lookup for QUERY, then call COMPLETE with its outcome."
  (let ((entries (reference-explorer-source-lookup--quick-search-entries query)))
    (funcall complete
             (reference-explorer-search-outcome-create
              :status (if entries 'matched 'no-match)
              :entries entries))))

(defun reference-explorer-source-lookup-protocol-candidate (entry _context)
  "Normalize Lookup ENTRY into lightweight completion metadata."
  (reference-explorer-candidate-create
   :label (reference-explorer-source-lookup--plain-entry-heading entry)
   :annotation (reference-explorer-source-lookup-entry-source entry)))

(defun reference-explorer-source-lookup-lookup-content-appearance ()
  "Apply the shared appearance to a Lookup content buffer."
  (when (display-graphic-p)
    (setq-local buffer-face-mode-face
                (append
                 (when (and reference-explorer-ui-content-font-family
                            (find-font
                             (font-spec
                              :family reference-explorer-ui-content-font-family)))
                   (list :family reference-explorer-ui-content-font-family))
                 '(:height 1.15)))
    (buffer-face-mode 1)))


(reference-explorer-register-source
 'lookup
 :title "Lookup for Emacs"
 :search #'reference-explorer-source-lookup-protocol-search
 :candidate #'reference-explorer-source-lookup-protocol-candidate
 :render #'reference-explorer-source-lookup-render-entry
 :preview t
 :commit 'display
 :available-p #'reference-explorer-source-lookup-available-p
 :present #'reference-explorer-source-lookup-present)

(with-eval-after-load 'embark
  (set-keymap-parent reference-explorer-source-lookup-embark-map
                     embark-general-map)
  (define-key reference-explorer-source-lookup-embark-map (kbd "RET")
              #'reference-explorer-source-lookup-display-candidate)
  (define-key reference-explorer-source-lookup-embark-map (kbd "w")
              #'reference-explorer-source-lookup-copy-candidate)
  (add-to-list 'embark-keymap-alist
               '(reference-explorer-source-lookup-entry
                 . reference-explorer-source-lookup-embark-map))
  (setf (alist-get 'reference-explorer-source-lookup-entry
                   embark-default-action-overrides)
        #'reference-explorer-source-lookup-display-candidate)
  (setf (alist-get 'reference-explorer-source-lookup-entry embark-exporters-alist)
        #'reference-explorer-source-lookup-export-candidates))

(when (locate-library "lookup")
  (setq lookup-enable-splash nil)
  (require 'lookup)
  (require 'lookup-kanji)
  (setq lookup-content-buffer reference-explorer-source-lookup-content-buffer-name)
  (add-hook 'lookup-content-mode-hook
            #'reference-explorer-source-lookup-lookup-content-appearance))

(provide 'reference-explorer-source-lookup)
;;; reference-explorer-source-lookup.el ends here
