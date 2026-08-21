;;; reference-explorer-source.el --- Pluggable reference sources -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A source retrieves structured entries and describes how the shared UI can
;; label, annotate, and render them.  Searches use callbacks so local and
;; network-backed sources implement the same protocol.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-core)

(cl-defstruct (reference-explorer-source
               (:constructor reference-explorer-source--create))
  "Operations supplied by one registered reference source."
  name
  title
  search-function
  label-function
  annotation-function
  render-function
  available-p-function
  provider
  provider-function)

(cl-defstruct (reference-explorer-source-result
               (:constructor reference-explorer-source-result-create))
  "A source-owned VALUE returned from a registered SOURCE."
  source
  value)

(defvar reference-explorer--sources nil
  "Registered sources as an alist of names and source descriptors.")

(defvar reference-explorer-source-registered-hook nil
  "Hook run with a source name after it is registered or replaced.")

(defvar reference-explorer-source-unregistered-hook nil
  "Hook run with a source name after it is unregistered.")

(defun reference-explorer-source--function-designator-p (value)
  "Return non-nil when VALUE can designate a function."
  (or (functionp value) (and value (symbolp value))))

(cl-defun reference-explorer-register-source
    (name &key title search label annotation render available-p provider
          provider-function)
  "Register source NAME and return its descriptor.

SEARCH receives QUERY, CONTEXT, SUCCESS, and FAILURE.  It calls SUCCESS with a
list of source-owned values or FAILURE with a human-readable string.  LABEL
receives one value and returns its visible candidate label.  RENDER receives a
value and buffer name, and returns the rendered buffer.  ANNOTATION receives a
value and CONTEXT and returns optional candidate annotation text.  AVAILABLE-P
receives a CONTEXT and reports whether the source can search it.

When PROVIDER is non-nil, the shared UI also exposes NAME as a dispatcher
provider.  PROVIDER-FUNCTION may supply a specialized provider action;
otherwise the shared source UI is used."
  (unless (symbolp name)
    (error "Source name must be a symbol: %S" name))
  (dolist (operation `((search . ,search) (label . ,label) (render . ,render)))
    (unless (reference-explorer-source--function-designator-p (cdr operation))
      (error "Source %s requires a %s function" name (car operation))))
  (dolist (operation `((annotation . ,annotation)
                       (available-p . ,available-p)
                       (provider-function . ,provider-function)))
    (when (and (cdr operation)
               (not (reference-explorer-source--function-designator-p
                     (cdr operation))))
      (error "Source %s has an invalid %s function" name (car operation))))
  (let ((source
         (reference-explorer-source--create
          :name name
          :title (or title (symbol-name name))
          :search-function search
          :label-function label
          :annotation-function annotation
          :render-function render
          :available-p-function available-p
          :provider provider
          :provider-function provider-function)))
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
  "Return registered source NAME or signal an error."
  (or (alist-get name reference-explorer--sources)
      (error "Reference source is not registered: %s" name)))

(defun reference-explorer-source-available-p (name &optional context)
  "Return non-nil when source NAME is available for CONTEXT."
  (let* ((source (reference-explorer-get-source name))
         (predicate (reference-explorer-source-available-p-function source)))
    (or (null predicate) (funcall predicate context))))

(defun reference-explorer-source-search
    (name query context success &optional failure)
  "Search source NAME for QUERY in CONTEXT.
Call SUCCESS with wrapped `reference-explorer-source-result' objects.  Call
FAILURE with a human-readable string; by default signal an error."
  (let* ((source (reference-explorer-get-source name))
         (fail (or failure (lambda (message) (error "%s" message)))))
    (if (not (reference-explorer-source-available-p name context))
        (funcall fail (format "Source is unavailable: %s" name))
      (funcall
       (reference-explorer-source-search-function source)
       query context
       (lambda (values)
         (funcall
          success
          (mapcar
           (lambda (value)
             (reference-explorer-source-result-create
              :source name :value value))
           values)))
       fail))))

(defun reference-explorer-source-result-descriptor (result)
  "Return the registered source descriptor for RESULT."
  (unless (reference-explorer-source-result-p result)
    (error "Not a reference source result: %S" result))
  (reference-explorer-get-source
   (reference-explorer-source-result-source result)))

(defun reference-explorer-source-result-label (result)
  "Return the visible candidate label for RESULT."
  (funcall
   (reference-explorer-source-label-function
    (reference-explorer-source-result-descriptor result))
   (reference-explorer-source-result-value result)))

(defun reference-explorer-source-result-annotation (result &optional context)
  "Return annotation text for RESULT in CONTEXT."
  (let* ((source (reference-explorer-source-result-descriptor result))
         (function (reference-explorer-source-annotation-function source)))
    (if function
        (or (funcall function
                     (reference-explorer-source-result-value result) context)
            "")
      "")))

(defun reference-explorer-source-result-render (result buffer-name)
  "Render RESULT in BUFFER-NAME and return the resulting buffer."
  (let ((source (reference-explorer-source-result-descriptor result)))
    (funcall
     (reference-explorer-source-render-function source)
     (reference-explorer-source-result-value result) buffer-name)))

(provide 'reference-explorer-source)
;;; reference-explorer-source.el ends here
