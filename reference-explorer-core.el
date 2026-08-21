;;; reference-explorer-core.el --- Reference query context and dispatch -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Capture a phrase from the current editing context and dispatch it to an
;; ordered chain of registered reference sources.  Source implementations own
;; query conversion, retrieval, and optional presentation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)

(defgroup reference-explorer nil
  "Explore local and external reference sources."
  :group 'applications)

(define-error 'reference-explorer-source-unavailable
  "Reference source is unavailable")

(cl-defstruct (reference-explorer-context
               (:constructor reference-explorer-context-create))
  "A selected phrase, source query, and originating Emacs location."
  phrase
  query
  marker
  window
  automatic
  selection-beginning
  selection-end
  selection-text)

(defcustom reference-explorer-phrase-selector-function
  #'reference-explorer-default-phrase-at-point
  "Function selecting a reference phrase at point.
The function is called without arguments after an active region has already
been considered.  Source-specific conversion happens after this selection."
  :type 'function
  :group 'reference-explorer)

(defcustom reference-explorer-origin-position-function #'point
  "Function returning the buffer position represented by visible point.
This lets a mode map hidden markup onto the visible character at which an
automatic reference lookup originates.  An explicit region uses its beginning
as the display anchor."
  :type 'function
  :group 'reference-explorer)

(defcustom reference-explorer-source-rules
  (if (eq system-type 'darwin)
      '((t . (docset macos-dictionary lookup)))
    '((t . (lookup))))
  "Ordered source chains selected by major-mode ancestry.
Each entry is (MODE . SOURCES).  MODE is t or a major mode accepted by
`derived-mode-p'.  The first matching entry supplies the complete source
chain.  Put a catch-all t entry last to define the default chain.  A later
source is tried only when an earlier source is unavailable and `unavailable'
is enabled in `reference-explorer-fallback-conditions'."
  :type '(repeat
          (cons (choice (const :tag "Every mode" t) symbol)
                (repeat symbol)))
  :group 'reference-explorer)

(defcustom reference-explorer-fallback-conditions '(unavailable)
  "Conditions under which dispatch may try the next source.
`unavailable' covers a missing executable, module, data set, or display.
`error' additionally permits fallback after any source error.  An empty list
disables fallback.  A completed search with no matches never falls through
implicitly."
  :type '(set (const unavailable) (const error))
  :group 'reference-explorer)

(declare-function reference-explorer-source-names "reference-explorer-source" ())
(declare-function reference-explorer-run-source
                  "reference-explorer-source" (name context))

(defun reference-explorer-default-phrase-at-point ()
  "Return a plain word at point as a reference phrase."
  (when-let ((word (thing-at-point 'word t)))
    (string-trim word)))

(defun reference-explorer-phrase-at-point ()
  "Return the active region or configured phrase at point."
  (let ((phrase
         (if (use-region-p)
             (buffer-substring-no-properties
              (region-beginning) (region-end))
           (funcall reference-explorer-phrase-selector-function))))
    (and phrase
         (let ((trimmed (string-trim (substring-no-properties phrase))))
           (unless (string-empty-p trimmed) trimmed)))))

(defun reference-explorer-context-at-point ()
  "Capture the reference phrase and current displayed location."
  (let ((region-active (use-region-p)))
    (when-let ((phrase (reference-explorer-phrase-at-point)))
      (reference-explorer-context-create
       :phrase phrase
       :query phrase
       :marker (copy-marker
                (if region-active
                    (region-beginning)
                  (funcall reference-explorer-origin-position-function)))
       :window (selected-window)
       :automatic (not region-active)
       :selection-beginning
       (and region-active (copy-marker (region-beginning)))
       :selection-end
       (and region-active (copy-marker (region-end) t))
       :selection-text (and region-active phrase)))))

(defun reference-explorer--sources-for-context (context)
  "Return the configured source chain for CONTEXT's major mode."
  (let* ((marker (reference-explorer-context-marker context))
         (buffer (and (markerp marker) (marker-buffer marker))))
    (when buffer
      (with-current-buffer buffer
        (cdr
         (seq-find
          (lambda (entry)
            (or (eq (car entry) t)
                (derived-mode-p (car entry))))
          reference-explorer-source-rules))))))

(defun reference-explorer--dispatch (sources context)
  "Run the first usable member of SOURCES with CONTEXT."
  (let (failures result completed)
    (while (and sources (not completed))
      (let ((name (pop sources)))
        (condition-case error-data
            (setq result (reference-explorer-run-source name context)
                  completed t)
          (reference-explorer-source-unavailable
           (push (error-message-string error-data) failures)
           (unless (and sources
                        (memq 'unavailable
                              reference-explorer-fallback-conditions))
             (signal (car error-data) (cdr error-data))))
          (error
           (push (error-message-string error-data) failures)
           (unless (and sources
                        (memq 'error reference-explorer-fallback-conditions))
             (signal (car error-data) (cdr error-data)))))))
    (if completed
        result
      (user-error "No reference source succeeded%s"
                  (if failures
                      (format ": %s" (string-join (nreverse failures) "; "))
                    "")))))

(defun reference-explorer-run-context (context)
  "Dispatch reference CONTEXT according to its originating major mode."
  (let ((sources (reference-explorer--sources-for-context context)))
    (unless sources
      (user-error "No reference sources configured for this context"))
    (reference-explorer--dispatch sources context)))

;;;###autoload
(defun reference-explorer-at-point (&optional choose-source)
  "Open the configured reference for the region or phrase at point.
With prefix argument CHOOSE-SOURCE, choose one registered source and do not
use fallback."
  (interactive "P")
  (let ((context (reference-explorer-context-at-point)))
    (unless context
      (user-error "No reference phrase at point"))
    (if choose-source
        (let* ((names (reference-explorer-source-names))
               (selected
                (intern
                 (completing-read "Reference source: "
                                  (mapcar #'symbol-name names) nil t))))
          (reference-explorer-run-source selected context))
      (reference-explorer-run-context context))))

(provide 'reference-explorer-core)
;;; reference-explorer-core.el ends here
