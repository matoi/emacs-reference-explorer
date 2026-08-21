;;; reference-explorer-source.el --- Pluggable reference sources -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A source converts a selected phrase into its own query, performs the
;; search, and reports a status-bearing outcome.  Candidate sources may also
;; label, annotate, and render entries.  Delegating sources can instead hand
;; search and presentation to an external application.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-core)
(require 'subr-x)

(cl-defstruct (reference-explorer-source
               (:constructor reference-explorer-source--create))
  "Operations supplied by one registered reference source."
  name title convert-function search-function fetch-function label-function
  annotation-function render-function available-p-function present-function)

(cl-defstruct (reference-explorer-source-result
               (:constructor reference-explorer-source-result-create))
  "A source-owned VALUE returned from a registered SOURCE."
  source value)

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

(defvar reference-explorer-source-registered-hook nil
  "Hook run with a source name after it is registered or replaced.")

(defvar reference-explorer-source-unregistered-hook nil
  "Hook run with a source name after it is unregistered.")

(defun reference-explorer-source--function-designator-p (value)
  "Return non-nil when VALUE can designate a function."
  (or (functionp value) (and value (symbolp value))))

(cl-defun reference-explorer-register-source
    (name &key title convert search fetch label annotation render available-p
          present)
  "Register source NAME and return its descriptor.

CONVERT receives a selected phrase and CONTEXT and returns the source query;
nil means identity conversion.  SEARCH receives QUERY, CONTEXT, and COMPLETE,
and calls COMPLETE with a `reference-explorer-search-outcome'.  FETCH
optionally retrieves the full content for one entry.  LABEL, ANNOTATION, and
RENDER describe candidate results and may be omitted by a source that always
reports `delegated'.  AVAILABLE-P receives CONTEXT.
PRESENT receives the converted CONTEXT and may replace the shared candidate
presenter for this source."
  (unless (symbolp name)
    (error "Source name must be a symbol: %S" name))
  (unless (reference-explorer-source--function-designator-p search)
    (error "Source %s requires a search function" name))
  (dolist (operation `((convert . ,convert) (fetch . ,fetch) (label . ,label)
                       (annotation . ,annotation) (render . ,render)
                       (available-p . ,available-p) (present . ,present)))
    (when (and (cdr operation)
               (not (reference-explorer-source--function-designator-p
                     (cdr operation))))
      (error "Source %s has an invalid %s function" name (car operation))))
  (let ((source
         (reference-explorer-source--create
          :name name :title (or title (symbol-name name))
          :convert-function convert :search-function search
          :fetch-function fetch
          :label-function label :annotation-function annotation
          :render-function render :available-p-function available-p
          :present-function present)))
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
COMPLETE receives a `reference-explorer-search-outcome'.  Entries in a
`matched' outcome are wrapped as `reference-explorer-source-result' values."
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
                    (reference-explorer-source-result-create
                     :source name :value value))
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

(defun reference-explorer-source-result-descriptor (result)
  "Return the registered source descriptor for RESULT."
  (unless (reference-explorer-source-result-p result)
    (error "Not a reference source result: %S" result))
  (reference-explorer-get-source
   (reference-explorer-source-result-source result)))

(defun reference-explorer-source-result-label (result)
  "Return the visible candidate label for RESULT."
  (let* ((source (reference-explorer-source-result-descriptor result))
         (function (reference-explorer-source-label-function source)))
    (unless function
      (error "Source %s does not label candidate results"
             (reference-explorer-source-name source)))
    (funcall function (reference-explorer-source-result-value result))))

(defun reference-explorer-source-result-annotation (result &optional context)
  "Return annotation text for RESULT in CONTEXT."
  (let* ((source (reference-explorer-source-result-descriptor result))
         (function (reference-explorer-source-annotation-function source)))
    (if function
        (or (funcall function
                     (reference-explorer-source-result-value result) context)
            "")
      "")))

(defun reference-explorer-source-result-fetch (result)
  "Return the full content represented by RESULT.
When the source has no separate fetch operation, return its entry value."
  (let* ((source (reference-explorer-source-result-descriptor result))
         (function (reference-explorer-source-fetch-function source))
         (value (reference-explorer-source-result-value result)))
    (if function (funcall function value) value)))

(defun reference-explorer-source-result-render (result buffer-name)
  "Render RESULT in BUFFER-NAME and return the resulting buffer."
  (let* ((source (reference-explorer-source-result-descriptor result))
         (function (reference-explorer-source-render-function source)))
    (unless function
      (error "Source %s does not render candidate results"
             (reference-explorer-source-name source)))
    (funcall function
             (reference-explorer-source-result-fetch result) buffer-name)))

(provide 'reference-explorer-source)
;;; reference-explorer-source.el ends here
