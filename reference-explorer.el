;;; reference-explorer.el --- Provider-based reference lookup -*- lexical-binding: t -*-
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/matoi/emacs-reference-explorer
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Select a reference provider from the current editing context.  Providers
;; own retrieval and presentation; this core owns query context, dispatch, and
;; configurable fallback.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)

(defgroup reference-explorer nil
  "Explore local and external reference sources."
  :group 'applications)

(define-error 'reference-explorer-provider-unavailable
  "Reference provider is unavailable")

(cl-defstruct (reference-explorer-context
               (:constructor reference-explorer-context-create))
  "A query and its originating Emacs location."
  query
  marker
  window
  automatic)

(defcustom reference-explorer-query-function
  #'reference-explorer-default-query-at-point
  "Function returning the reference query at point.
The function is called without arguments after an active region has already
been considered."
  :type 'function
  :group 'reference-explorer)

(defcustom reference-explorer-origin-position-function #'point
  "Function returning the buffer position represented by visible point.
This lets a mode map hidden markup onto the visible character at which an
automatic reference lookup originates.  An explicit region uses its beginning
as the display anchor."
  :type 'function
  :group 'reference-explorer)

(defcustom reference-explorer-provider-rules
  nil
  "Ordered reference providers selected by major-mode ancestry.
Each entry is (MODE . PROVIDERS).  MODE is t or a major mode accepted by
`derived-mode-p'.  A provider later in PROVIDERS is tried only when an earlier
provider is unavailable and `unavailable' is enabled in
`reference-explorer-fallback-conditions'."
  :type '(repeat
          (cons (choice (const :tag "Every mode" t) symbol)
                (repeat symbol)))
  :group 'reference-explorer)

(defcustom reference-explorer-fallback-conditions '(unavailable)
  "Conditions under which dispatch may try the next provider.
`unavailable' covers a missing executable, module, data set, or display.
`error' additionally permits fallback after any provider error.  An empty
list disables fallback.  A successful search with no matches never falls
through implicitly."
  :type '(set (const unavailable) (const error))
  :group 'reference-explorer)

(defvar reference-explorer--providers nil
  "Registered providers as (NAME ACTION AVAILABLE-P).")

(defun reference-explorer-default-query-at-point ()
  "Return a plain word at point for reference lookup."
  (when-let ((word (thing-at-point 'word t)))
    (string-trim word)))

(defun reference-explorer-query-at-point ()
  "Return the active region or configured textual query at point."
  (let ((query
         (if (use-region-p)
             (buffer-substring-no-properties
              (region-beginning) (region-end))
           (funcall reference-explorer-query-function))))
    (and query
         (let ((trimmed (string-trim (substring-no-properties query))))
           (unless (string-empty-p trimmed) trimmed)))))

(defun reference-explorer-context-at-point ()
  "Capture the reference query and current displayed location."
  (let ((region-active (use-region-p)))
    (when-let ((query (reference-explorer-query-at-point)))
      (reference-explorer-context-create
       :query query
       :marker (copy-marker
                (if region-active
                    (region-beginning)
                  (funcall reference-explorer-origin-position-function)))
       :window (selected-window)
       :automatic (not region-active)))))

(defun reference-explorer-register-provider (name action &optional available-p)
  "Register provider NAME using ACTION and optional AVAILABLE-P predicate.
ACTION receives a `reference-explorer-context'."
  (setf (alist-get name reference-explorer--providers)
        (list action available-p)))

(defun reference-explorer-provider-names ()
  "Return registered reference provider names."
  (mapcar #'car reference-explorer--providers))

(defun reference-explorer--provider (name)
  "Return registered provider NAME or signal an unavailable error."
  (or (alist-get name reference-explorer--providers)
      (signal 'reference-explorer-provider-unavailable
              (list (format "Provider is not registered: %s" name)))))

(defun reference-explorer--providers-for-context (context)
  "Return the configured provider chain for CONTEXT's major mode."
  (let* ((marker (reference-explorer-context-marker context))
         (buffer (and (markerp marker) (marker-buffer marker))))
    (when buffer
      (with-current-buffer buffer
        (cdr
         (seq-find
          (lambda (entry)
            (or (eq (car entry) t)
                (derived-mode-p (car entry))))
          reference-explorer-provider-rules))))))

(defun reference-explorer-run-provider (name context)
  "Run provider NAME with reference CONTEXT without fallback."
  (pcase-let ((`(,action ,available-p)
               (reference-explorer--provider name)))
    (when (and available-p (not (funcall available-p)))
      (signal 'reference-explorer-provider-unavailable
              (list (format "Provider is unavailable: %s" name))))
    (funcall action context)))

(defun reference-explorer--dispatch (providers context)
  "Run the first usable member of PROVIDERS with CONTEXT."
  (let (failures result completed)
    (while (and providers (not completed))
      (let ((name (pop providers)))
        (condition-case error-data
            (setq result (reference-explorer-run-provider name context)
                  completed t)
          (reference-explorer-provider-unavailable
           (push (error-message-string error-data) failures)
           (unless (and providers
                        (memq 'unavailable
                              reference-explorer-fallback-conditions))
             (signal (car error-data) (cdr error-data))))
          (error
           (push (error-message-string error-data) failures)
           (unless (and providers
                        (memq 'error reference-explorer-fallback-conditions))
             (signal (car error-data) (cdr error-data)))))))
    (if completed
        result
      (user-error "No reference provider succeeded%s"
                  (if failures
                      (format ": %s" (string-join (nreverse failures) "; "))
                    "")))))

(defun reference-explorer-run-context (context)
  "Dispatch reference CONTEXT according to its originating major mode."
  (let ((providers (reference-explorer--providers-for-context context)))
    (unless providers
      (user-error "No reference providers configured for this context"))
    (reference-explorer--dispatch providers context)))

;;;###autoload
(defun reference-explorer-at-point (&optional choose-provider)
  "Open the configured reference for the region or object at point.
With prefix argument CHOOSE-PROVIDER, choose one registered provider and do
not use fallback."
  (interactive "P")
  (let ((context (reference-explorer-context-at-point)))
    (unless context
      (user-error "No reference query at point"))
    (if choose-provider
        (let* ((names (reference-explorer-provider-names))
               (selected
                (intern
                 (completing-read "Reference provider: "
                                  (mapcar #'symbol-name names) nil t))))
          (reference-explorer-run-provider selected context))
      (reference-explorer-run-context context))))

(provide 'reference-explorer)
;;; reference-explorer.el ends here
