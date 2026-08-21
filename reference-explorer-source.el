;;; reference-explorer-source.el --- Pluggable reference sources -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A source converts a selected phrase into its own query, performs the
;; search, and reports a status-bearing outcome.  Candidate sources normalize
;; lightweight completion metadata once, render content lazily, declare preview
;; policy, and select a commit action.  Delegating sources can instead hand
;; search and presentation to an external application.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-core)
(require 'subr-x)

(cl-defstruct (reference-explorer-source
               (:constructor reference-explorer-source--create))
  "Operations supplied by one registered reference source."
  name title convert-function search-function candidate-function fetch-function
  render-function preview commit available-p-function present-function)

(cl-defstruct (reference-explorer-candidate
               (:constructor reference-explorer-candidate-create))
  "A lightweight source result used for filtering and candidate actions.
VALUE remains source-owned and may identify content fetched only for preview
or display.  LABEL is searchable, ANNOTATION is display-only, and COMMIT-TEXT
is the short string used by text-oriented commit actions such as `replace'."
  source value label annotation commit-text)

(cl-defstruct (reference-explorer-search-outcome
               (:constructor reference-explorer-search-outcome-create))
  "The status and data produced by one source search.
STATUS is one of `matched', `no-match', `delegated', `unavailable', or
`failed'.  ENTRIES contains source-owned values before protocol wrapping."
  status entries value message)

(defvar reference-explorer--sources nil
  "Registered sources as an alist of names and source descriptors.")

(defvar reference-explorer-source-default-present-function nil
  "Function used to present sources without their own presenter.
The function receives a source name and converted context.")

(defcustom reference-explorer-source-preview-overrides nil
  "Per-source overrides for declared candidate preview policy.
Each entry is (SOURCE . ENABLED).  Sources absent from this alist use the
`:preview' value declared at registration time."
  :type '(alist :key-type symbol :value-type boolean)
  :group 'reference-explorer)

(defvar reference-explorer-commit-actions nil
  "Registered symbolic candidate commit actions.")

(defvar reference-explorer-source-registered-hook nil
  "Hook run with a source name after it is registered or replaced.")

(defvar reference-explorer-source-unregistered-hook nil
  "Hook run with a source name after it is unregistered.")

(defun reference-explorer-source--function-designator-p (value)
  "Return non-nil when VALUE can designate a function."
  (or (functionp value) (and value (symbolp value))))

(cl-defun reference-explorer-register-source
    (name &key title convert search candidate fetch render preview
          (commit 'display) available-p present)
  "Register source NAME and return its descriptor.

CONVERT receives a selected phrase and CONTEXT and returns the source query;
nil means identity conversion.  SEARCH receives QUERY, CONTEXT, and COMPLETE,
and calls COMPLETE with a `reference-explorer-search-outcome'.  CANDIDATE
normalizes each matched source value and CONTEXT into a lightweight
`reference-explorer-candidate'.  FETCH optionally retrieves full content only
when RENDER is requested.  RENDER converts that content into a buffer.
PREVIEW declares whether candidate navigation may request rendered content.
COMMIT is a registered action symbol, a function receiving candidate and
CONTEXT, or nil.  AVAILABLE-P receives CONTEXT.
PRESENT receives the converted CONTEXT and may replace the shared candidate
presenter for this source."
  (unless (symbolp name)
    (error "Source name must be a symbol: %S" name))
  (unless (reference-explorer-source--function-designator-p search)
    (error "Source %s requires a search function" name))
  (dolist (operation `((convert . ,convert) (candidate . ,candidate)
                       (fetch . ,fetch) (render . ,render)
                       (available-p . ,available-p)
                       (present . ,present)))
    (when (and (cdr operation)
               (not (reference-explorer-source--function-designator-p
                     (cdr operation))))
      (error "Source %s has an invalid %s function" name (car operation))))
  (unless (or (null commit) (symbolp commit) (functionp commit))
    (error "Source %s has an invalid commit action: %S" name commit))
  (let ((source
         (reference-explorer-source--create
          :name name :title (or title (symbol-name name))
          :convert-function convert :search-function search
          :candidate-function candidate :fetch-function fetch
          :render-function render :preview (and preview t) :commit commit
          :available-p-function available-p :present-function present)))
    (setf (alist-get name reference-explorer--sources) source)
    (run-hook-with-args 'reference-explorer-source-registered-hook name)
    source))

(defun reference-explorer-unregister-source (name)
  "Unregister source NAME and return non-nil when it existed."
  (when (assq name reference-explorer--sources)
    (setq reference-explorer--sources
          (assq-delete-all name reference-explorer--sources))
    (run-hook-with-args 'reference-explorer-source-unregistered-hook name)
    t))

(defun reference-explorer-source-names ()
  "Return registered source names."
  (mapcar #'car reference-explorer--sources))

(defun reference-explorer-get-source (name)
  "Return registered source NAME or signal an unavailable error."
  (or (alist-get name reference-explorer--sources)
      (signal 'reference-explorer-source-unavailable
              (list (format "Source is not registered: %s" name)))))

(defun reference-explorer-source-available-p (name &optional context)
  "Return non-nil when source NAME is available for CONTEXT."
  (let* ((source (reference-explorer-get-source name))
         (predicate (reference-explorer-source-available-p-function source)))
    (or (null predicate) (funcall predicate context))))

(defun reference-explorer-source-convert (name phrase context)
  "Convert PHRASE into source NAME's query for CONTEXT."
  (let* ((source (reference-explorer-get-source name))
         (converter (reference-explorer-source-convert-function source)))
    (if converter (funcall converter phrase context) phrase)))

(defun reference-explorer-source--validate-outcome (name outcome)
  "Validate OUTCOME returned by source NAME."
  (unless (reference-explorer-search-outcome-p outcome)
    (error "Source %s returned an invalid search outcome: %S" name outcome))
  (unless (memq (reference-explorer-search-outcome-status outcome)
                '(matched no-match delegated unavailable failed))
    (error "Source %s returned an invalid search status: %S"
           name (reference-explorer-search-outcome-status outcome)))
  outcome)

(defun reference-explorer-source-search (name query context complete)
  "Search source NAME for QUERY in CONTEXT and call COMPLETE once.
COMPLETE receives a `reference-explorer-search-outcome'.  Source values in a
`matched' outcome are normalized into `reference-explorer-candidate' values."
  (let ((source (reference-explorer-get-source name)))
    (if (not (reference-explorer-source-available-p name context))
        (funcall complete
                 (reference-explorer-search-outcome-create
                  :status 'unavailable
                  :message (format "Source is unavailable: %s" name)))
      (funcall
       (reference-explorer-source-search-function source)
       query context
       (lambda (outcome)
         (setq outcome
               (copy-reference-explorer-search-outcome
                (reference-explorer-source--validate-outcome name outcome)))
         (when (eq (reference-explorer-search-outcome-status outcome)
                   'matched)
           (setf (reference-explorer-search-outcome-entries outcome)
                 (mapcar
                  (lambda (value)
                    (reference-explorer-source-make-candidate
                     name value context))
                  (reference-explorer-search-outcome-entries outcome))))
         (funcall complete outcome))))))

(defun reference-explorer-run-source (name context)
  "Convert and present source NAME for reference CONTEXT."
  (let ((source (reference-explorer-get-source name)))
    (unless (reference-explorer-source-available-p name context)
      (signal 'reference-explorer-source-unavailable
              (list (format "Source is unavailable: %s" name))))
    (let* ((source-context (copy-reference-explorer-context context))
           (phrase (or (reference-explorer-context-phrase context)
                       (reference-explorer-context-query context)))
           (query (reference-explorer-source-convert name phrase source-context))
           (present (reference-explorer-source-present-function source)))
      (unless (and (stringp query) (not (string-empty-p query)))
        (user-error "Source %s produced no query" name))
      (setf (reference-explorer-context-phrase source-context) phrase
            (reference-explorer-context-query source-context) query)
      (unless (or present reference-explorer-source-default-present-function)
        (error "No presenter is configured for source: %s" name))
      (if present
          (funcall present source-context)
        (funcall reference-explorer-source-default-present-function
                 name source-context)))))

(defun reference-explorer-source-make-candidate (name value context)
  "Normalize source NAME's VALUE into one candidate for CONTEXT."
  (let* ((source (reference-explorer-get-source name))
         (function (reference-explorer-source-candidate-function source)))
    (unless function
      (error "Source %s matched entries without a candidate function" name))
    (let ((candidate (funcall function value context)))
      (unless (reference-explorer-candidate-p candidate)
        (error "Source %s returned an invalid candidate: %S" name candidate))
      (unless (and (stringp (reference-explorer-candidate-label candidate))
                   (not (string-empty-p
                         (reference-explorer-candidate-label candidate))))
        (error "Source %s returned a candidate without a label" name))
      (setf (reference-explorer-candidate-source candidate) name
            (reference-explorer-candidate-value candidate) value
            (reference-explorer-candidate-annotation candidate)
            (or (reference-explorer-candidate-annotation candidate) ""))
      candidate)))

(defun reference-explorer-candidate-descriptor (candidate)
  "Return the registered source descriptor for CANDIDATE."
  (unless (reference-explorer-candidate-p candidate)
    (error "Not a reference candidate: %S" candidate))
  (reference-explorer-get-source
   (reference-explorer-candidate-source candidate)))

(defun reference-explorer-candidate-fetch (candidate)
  "Return the full content represented by CANDIDATE.
When the source has no separate fetch operation, return its entry value."
  (let* ((source (reference-explorer-candidate-descriptor candidate))
         (function (reference-explorer-source-fetch-function source))
         (value (reference-explorer-candidate-value candidate)))
    (if function (funcall function value) value)))

(defun reference-explorer-candidate-render (candidate buffer-name)
  "Lazily fetch and render CANDIDATE in BUFFER-NAME."
  (let* ((source (reference-explorer-candidate-descriptor candidate))
         (function (reference-explorer-source-render-function source)))
    (unless function
      (error "Source %s does not render candidate results"
             (reference-explorer-source-name source)))
    (funcall function
             (reference-explorer-candidate-fetch candidate) buffer-name)))

(defun reference-explorer-source-preview-p (name)
  "Return effective preview policy for source NAME."
  (let ((override (assq name reference-explorer-source-preview-overrides)))
    (if override
        (and (cdr override) t)
      (reference-explorer-source-preview
       (reference-explorer-get-source name)))))

(defun reference-explorer-register-commit-action (name function)
  "Register FUNCTION as symbolic candidate commit action NAME."
  (unless (and (symbolp name)
               (reference-explorer-source--function-designator-p function))
    (error "Invalid commit action: %S %S" name function))
  (setf (alist-get name reference-explorer-commit-actions) function)
  name)

(defun reference-explorer-candidate-commit (candidate context)
  "Run CANDIDATE's source-declared commit action in CONTEXT."
  (let* ((source (reference-explorer-candidate-descriptor candidate))
         (action (reference-explorer-source-commit source))
         (function
          (cond
           ((null action) nil)
           ((functionp action) action)
           ((symbolp action)
            (or (alist-get action reference-explorer-commit-actions)
                (error "Commit action is not registered: %s" action)))
           (t (error "Invalid commit action: %S" action)))))
    (when function
      (funcall function candidate context))))

(defun reference-explorer--preserve-replacement-case (replacement original)
  "Adjust REPLACEMENT to the simple letter case used by ORIGINAL."
  (cond
   ((and (string-match-p "[[:alpha:]]" original)
         (equal original (upcase original)))
    (upcase replacement))
   ((and (> (length original) 0)
         (equal original (capitalize original)))
    (capitalize replacement))
   (t replacement)))

(defun reference-explorer-commit-replace (candidate context)
  "Replace CONTEXT's captured selection with CANDIDATE's commit text."
  (let* ((beginning
          (and context
               (reference-explorer-context-selection-beginning context)))
         (end
          (and context
               (reference-explorer-context-selection-end context)))
         (original
          (and context
               (reference-explorer-context-selection-text context)))
         (replacement
          (or (reference-explorer-candidate-commit-text candidate)
              (reference-explorer-candidate-label candidate)))
         (buffer (and (markerp beginning) (marker-buffer beginning))))
    (unless (and (stringp replacement) (buffer-live-p buffer)
                 (markerp end) (marker-position beginning)
                 (marker-position end)
                 (eq (marker-buffer end) buffer))
      (user-error "The replacement target is no longer available"))
    (with-current-buffer buffer
      (let ((start (marker-position beginning))
            (finish (marker-position end)))
        (unless (equal original
                       (buffer-substring-no-properties start finish))
          (user-error "The original text changed; refusing to replace it"))
        (let ((replacement
               (reference-explorer--preserve-replacement-case
                replacement original)))
          (atomic-change-group
            (goto-char start)
            (delete-region start finish)
            (insert replacement))
          (message "Replaced “%s” with “%s”" original replacement))))))

(reference-explorer-register-commit-action
 'replace #'reference-explorer-commit-replace)

(provide 'reference-explorer-source)
;;; reference-explorer-source.el ends here
